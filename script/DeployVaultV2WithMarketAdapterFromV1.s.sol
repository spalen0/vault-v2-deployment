// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {VaultV2} from "vault-v2/VaultV2.sol";
import {VaultV2Factory} from "vault-v2/VaultV2Factory.sol";
import {IMorphoMarketV1AdapterV2} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";
import {IMorphoMarketV1AdapterV2Factory} from "vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2Factory.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMorpho, MarketParams, Id, Position} from "morpho-blue/src/interfaces/IMorpho.sol";

/// @dev Minimal MetaMorpho V1 interface — only what we need to read markets + caps.
interface IMetaMorphoV1 {
    function withdrawQueue(uint256 index) external view returns (Id);
    function withdrawQueueLength() external view returns (uint256);
    function config(Id id) external view returns (uint184 cap, bool enabled, uint64 removableAt);
    function asset() external view returns (address);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function fee() external view returns (uint96);
    function feeRecipient() external view returns (address);
}

/**
 * @title DeployVaultV2WithMarketAdapterFromV1
 * @notice Deploys a VaultV2 with MorphoMarketV1AdapterV2 and seeds every non-idle market
 *         from an existing MetaMorpho V1 vault's withdrawQueue.
 * @dev Variant of `DeployVaultV2WithMarketAdapter.s.sol` that reads markets + caps from a
 *      source MetaMorpho V1 vault instead of taking a single market via env vars. Also
 *      preserves NAME / SYMBOL / MAX_RATE / ADDITIONAL_ALLOCATOR from the old
 *      `DeployVaultV2.s.sol` flow.
 *
 *      Cap structure (3 levels):
 *        - Market:    absoluteCap = v1.config(mid).cap (copied per market)
 *        - Collateral: absoluteCap = sum of V1 caps across markets sharing that collateral
 *        - Adapter:   absoluteCap = ADAPTER_ABSOLUTE_CAP env var (~$100M in asset units)
 *        - All relative caps = 1e18 (100%)
 *
 *      Skips markets where collateralToken == address(0) (idle) or V1 cap == 0 (disabled).
 *
 *      Liquidity adapter target = first non-idle, non-zero-cap market in V1 withdrawQueue.
 */
contract DeployVaultV2WithMarketAdapterFromV1 is Script {
    uint256 constant DEAD_DEPOSIT_HIGH_DECIMALS = 1e9;
    uint256 constant DEAD_DEPOSIT_LOW_DECIMALS = 1e12;
    uint8 constant DECIMALS_THRESHOLD = 10;
    uint256 constant DEFAULT_MAX_MARKETS = 50;

    struct DeploymentConfig {
        address vaultOwner;
        address vaultCurator;
        address vaultAllocator;
        address additionalAllocator;
        address vaultSentinel;
        address asset;
        address adapterRegistry;
        address vaultV2FactoryAddress;
        address morphoMarketAdapterFactoryAddress;
        address sourceVaultV1;
        address liquidityCollateralToken;
        string name;
        string symbol;
        uint256 maxRate;
        uint128 adapterAbsoluteCap;
        uint256 maxMarkets;
        uint256 vaultTimelockDuration;
        uint256 adapterTimelockDuration;
        uint256 deadDepositAmount; // 0 = auto-size by decimals (see _getDeadDepositAmount)
    }

    /// @notice Main entry: reads configuration from environment variables.
    function run() external returns (address) {
        DeploymentConfig memory config = _readEnvironmentConfig();
        return deployVaultV2WithConfig(config);
    }

    function _readEnvironmentConfig() internal view returns (DeploymentConfig memory config) {
        config.vaultOwner = vm.envAddress("OWNER");
        config.vaultCurator = vm.envOr("CURATOR", config.vaultOwner);
        config.vaultAllocator = vm.envOr("ALLOCATOR", config.vaultOwner);
        config.additionalAllocator = vm.envOr("ADDITIONAL_ALLOCATOR", address(0));
        config.vaultSentinel = vm.envOr("SENTINEL", address(0));
        config.asset = vm.envAddress("ASSET");
        config.adapterRegistry = vm.envAddress("ADAPTER_REGISTRY");
        config.vaultV2FactoryAddress = vm.envAddress("VAULT_V2_FACTORY");
        config.morphoMarketAdapterFactoryAddress = vm.envAddress("MORPHO_MARKET_V1_ADAPTER_V2_FACTORY");
        config.sourceVaultV1 = vm.envAddress("VAULT_V1");
        config.liquidityCollateralToken = vm.envAddress("LIQUIDITY_COLLATERAL_TOKEN");
        require(config.liquidityCollateralToken != address(0), "LIQUIDITY_COLLATERAL_TOKEN required");

        // NAME / SYMBOL default to the source V1 vault's values when unset or empty.
        config.name = vm.envOr("NAME", string(""));
        config.symbol = vm.envOr("SYMBOL", string(""));
        if (bytes(config.name).length == 0) {
            config.name = IMetaMorphoV1(config.sourceVaultV1).name();
        }
        if (bytes(config.symbol).length == 0) {
            config.symbol = IMetaMorphoV1(config.sourceVaultV1).symbol();
        }
        require(bytes(config.name).length > 0, "V1 vault name is empty");
        require(bytes(config.symbol).length > 0, "V1 vault symbol is empty");

        config.maxRate = vm.envUint("MAX_RATE");
        require(config.maxRate > 0, "MAX_RATE required");

        uint256 adapterCap = vm.envUint("ADAPTER_ABSOLUTE_CAP");
        require(adapterCap > 0, "ADAPTER_ABSOLUTE_CAP required");
        require(adapterCap <= type(uint128).max, "ADAPTER_ABSOLUTE_CAP exceeds uint128");
        config.adapterAbsoluteCap = uint128(adapterCap);

        config.maxMarkets = vm.envOr("MAX_MARKETS", DEFAULT_MAX_MARKETS);
        config.vaultTimelockDuration = vm.envOr("VAULT_TIMELOCK_DURATION", uint256(0));
        config.adapterTimelockDuration = vm.envOr("ADAPTER_TIMELOCK_DURATION", uint256(0));
        // DEAD_DEPOSIT_AMOUNT in raw wei of the underlying asset. 0 = use decimal-based default.
        // For USDC (6 decimals), 1000000 = $1. For WETH (18 decimals), 1000000000 = 1 gwei.
        config.deadDepositAmount = vm.envOr("DEAD_DEPOSIT_AMOUNT", uint256(0));

        // Sanity: the source V1 vault must be denominated in the same asset
        require(IMetaMorphoV1(config.sourceVaultV1).asset() == config.asset, "V1 asset mismatch");
    }

    function deployVaultV2WithConfig(DeploymentConfig memory config) public returns (address) {
        address deployer = tx.origin;

        vm.startBroadcast();

        // Phase 1: Deploy VaultV2 instance
        VaultV2 vault = _deployVaultV2Instance(config.vaultV2FactoryAddress, deployer, config.asset);

        // Phase 2: Temporary curator for the deployer
        vault.setCurator(deployer);
        console.log("Phase 2: Temporary curator assigned:", deployer);

        // Phase 2.1: Set name, symbol (owner-only, deployer is still owner)
        vault.setName(config.name);
        vault.setSymbol(config.symbol);
        console.log("  Name:", config.name);
        console.log("  Symbol:", config.symbol);

        // Phase 3: Deploy the market adapter
        address adapterAddress = _deployAndConfigureMorphoMarketAdapter(
            config.morphoMarketAdapterFactoryAddress, address(vault)
        );

        // Phase 4 + 5: Submit and execute base configuration (allocator roles, registry,
        // adapter, adapter-level caps, gates abdication). liquidityAdapterAndData is NOT
        // set here — it needs MarketParams and is set in Phase 7.
        _submitAndExecuteBaseConfig(vault, deployer, config, adapterAddress);

        // Phase 5.1: setMaxRate requires allocator role — deployer is allocator.
        vault.setMaxRate(config.maxRate);
        console.log("  MaxRate:", config.maxRate);

        // Phase 5.2: Mirror performance fee + recipient from the source V1 vault.
        // Both selectors are timelocked but timelock is still 0, so submit + execute in one shot.
        // Invariant (VaultV2.sol:508): recipient must be non-zero if fee > 0 — set recipient first.
        uint256 v1Fee = uint256(IMetaMorphoV1(config.sourceVaultV1).fee());
        address v1FeeRecipient = IMetaMorphoV1(config.sourceVaultV1).feeRecipient();
        vault.submit(abi.encodeCall(vault.setPerformanceFeeRecipient, (v1FeeRecipient)));
        vault.setPerformanceFeeRecipient(v1FeeRecipient);
        if (v1Fee > 0) {
            vault.submit(abi.encodeCall(vault.setPerformanceFee, (v1Fee)));
            vault.setPerformanceFee(v1Fee);
        }
        console.log("  PerformanceFeeRecipient (from V1):", v1FeeRecipient);
        console.log("  PerformanceFee (from V1):", v1Fee);

        // Phase 7: Seed every non-idle market from the source V1 vault + set liquidity adapter.
        // Requires curator (vault.submit) + allocator (setLiquidityAdapterAndData).
        _seedMarketsFromV1(vault, IMorphoMarketV1AdapterV2(adapterAddress), config);

        // Phase 8: Vault dead deposit (inflation attack protection). Public call.
        _executeVaultDeadDeposit(vault, config.asset, _resolveDeadDepositAmount(config));

        // ============================================================================
        // Timelocks go before the role handoff — they need curator (vault.submit,
        // adapter.submit). After this, changes to caps / registry / abdicate /
        // burnShares / etc. require waiting for the timelock window.
        // ============================================================================

        // Phase 9: Vault timelocks (curator)
        if (config.vaultTimelockDuration > 0) {
            _configureVaultTimelocks(vault, config.vaultTimelockDuration);
        } else {
            console.log("Phase 9: Skipped - VAULT_TIMELOCK_DURATION is 0");
        }

        // Phase 10: Adapter timelocks (requires vault's curator)
        if (config.adapterTimelockDuration > 0) {
            _configureAdapterTimelocks(IMorphoMarketV1AdapterV2(adapterAddress), config.adapterTimelockDuration);
        } else {
            console.log("Phase 10: Skipped - ADAPTER_TIMELOCK_DURATION is 0");
        }

        // Phase 11: Final role handoff — LAST. Transfers allocator (still curator),
        // curator (still owner), sets sentinel (owner), transfers owner (must be last).
        _setFinalRoleAssignments(
            vault, deployer, config.vaultAllocator, config.vaultCurator, config.vaultSentinel, config.vaultOwner
        );

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("VaultV2:", address(vault));
        console.log("MorphoMarketV1AdapterV2:", adapterAddress);
        console.log("Source V1 vault:", config.sourceVaultV1);
        console.log("===========================");

        return address(vault);
    }

    function _deployVaultV2Instance(address factoryAddress, address temporaryOwner, address underlyingAsset)
        internal
        returns (VaultV2 deployedVault)
    {
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp + gasleft()));
        deployedVault =
            VaultV2(VaultV2Factory(factoryAddress).createVaultV2(temporaryOwner, underlyingAsset, salt));
        console.log("Phase 1: VaultV2 deployed at:", address(deployedVault));
    }

    function _deployAndConfigureMorphoMarketAdapter(address factoryAddress, address vaultV2Address)
        internal
        returns (address adapterAddress)
    {
        IMorphoMarketV1AdapterV2Factory factory = IMorphoMarketV1AdapterV2Factory(factoryAddress);
        adapterAddress = factory.createMorphoMarketV1AdapterV2(vaultV2Address);

        require(factory.isMorphoMarketV1AdapterV2(adapterAddress), "Adapter not registered in factory");
        IMorphoMarketV1AdapterV2 adapter = IMorphoMarketV1AdapterV2(adapterAddress);
        require(adapter.parentVault() == vaultV2Address, "Parent vault mismatch");

        console.log("Phase 3: MorphoMarketV1AdapterV2 deployed at:", adapterAddress);
        console.log("  Morpho:", adapter.morpho());
        console.log("  Adaptive Curve IRM:", adapter.adaptiveCurveIrm());
    }

    function _submitAndExecuteBaseConfig(
        VaultV2 vault,
        address deployer,
        DeploymentConfig memory config,
        address adapter
    ) internal {
        bytes memory adapterIdData = abi.encode("this", adapter);

        // --- Submit phase ---
        // Grant deployer temporary allocator. Final allocator handoff (deployer -> vaultAllocator)
        // happens in Phase 11 (_setFinalRoleAssignments), AFTER all calls that need allocator
        // (setMaxRate, setLiquidityAdapterAndData) and curator (submit) are done.
        vault.submit(abi.encodeCall(vault.setIsAllocator, (deployer, true)));
        if (config.additionalAllocator != address(0)) {
            vault.submit(abi.encodeCall(vault.setIsAllocator, (config.additionalAllocator, true)));
        }

        vault.submit(abi.encodeCall(vault.setAdapterRegistry, (config.adapterRegistry)));
        vault.submit(abi.encodeCall(vault.addAdapter, (adapter)));
        vault.submit(abi.encodeCall(vault.increaseAbsoluteCap, (adapterIdData, config.adapterAbsoluteCap)));
        vault.submit(abi.encodeCall(vault.increaseRelativeCap, (adapterIdData, 1e18)));

        vault.submit(abi.encodeCall(vault.abdicate, (IVaultV2.setAdapterRegistry.selector)));

        require(vault.receiveSharesGate() == address(0), "receiveSharesGate must be 0");
        require(vault.sendSharesGate() == address(0), "sendSharesGate must be 0");
        require(vault.receiveAssetsGate() == address(0), "receiveAssetsGate must be 0");

        vault.submit(abi.encodeCall(vault.abdicate, (IVaultV2.setReceiveSharesGate.selector)));
        vault.submit(abi.encodeCall(vault.abdicate, (IVaultV2.setSendSharesGate.selector)));
        vault.submit(abi.encodeCall(vault.abdicate, (IVaultV2.setReceiveAssetsGate.selector)));

        console.log("Phase 4: Base config submitted");

        // --- Execute phase ---
        vault.setAdapterRegistry(config.adapterRegistry);
        vault.setIsAllocator(deployer, true);
        if (config.additionalAllocator != address(0)) {
            vault.setIsAllocator(config.additionalAllocator, true);
        }
        vault.addAdapter(adapter);
        vault.increaseAbsoluteCap(adapterIdData, config.adapterAbsoluteCap);
        vault.increaseRelativeCap(adapterIdData, 1e18);

        vault.abdicate(IVaultV2.setAdapterRegistry.selector);
        vault.abdicate(IVaultV2.setReceiveSharesGate.selector);
        vault.abdicate(IVaultV2.setSendSharesGate.selector);
        vault.abdicate(IVaultV2.setReceiveAssetsGate.selector);

        require(vault.abdicated(IVaultV2.setAdapterRegistry.selector), "setAdapterRegistry abdication failed");
        require(vault.abdicated(IVaultV2.setReceiveSharesGate.selector), "setReceiveSharesGate abdication failed");
        require(vault.abdicated(IVaultV2.setSendSharesGate.selector), "setSendSharesGate abdication failed");
        require(vault.abdicated(IVaultV2.setReceiveAssetsGate.selector), "setReceiveAssetsGate abdication failed");

        console.log("Phase 5: Base config executed");
        console.log("  Adapter cap:", config.adapterAbsoluteCap);
    }

    /**
     * @notice Final role handoff. Runs LAST — all curator/allocator-gated work is done by now.
     * @dev Order is load-bearing:
     *      1. Allocator handoff (deployer -> vaultAllocator) requires curator — deployer still is.
     *         Allocator changes go through submit/execute (timelocked(), but selector not raised yet).
     *      2. setCurator(vaultCurator) requires owner — deployer still is.
     *      3. setIsSentinel requires owner — deployer still is (curator transfer doesn't affect owner).
     *      4. setOwner(vaultOwner) requires owner — MUST BE LAST.
     */
    function _setFinalRoleAssignments(
        VaultV2 vault,
        address deployer,
        address vaultAllocator,
        address vaultCurator,
        address vaultSentinel,
        address vaultOwner
    ) internal {
        // 1. Allocator handoff: deployer -> vaultAllocator (skip if same address).
        if (deployer != vaultAllocator) {
            vault.submit(abi.encodeCall(vault.setIsAllocator, (deployer, false)));
            vault.submit(abi.encodeCall(vault.setIsAllocator, (vaultAllocator, true)));
            vault.setIsAllocator(deployer, false);
            vault.setIsAllocator(vaultAllocator, true);
        }

        // 2. Curator
        vault.setCurator(vaultCurator);

        // 3. Sentinel (owner-only per VaultV2.sol:326)
        if (vaultSentinel != address(0)) {
            vault.setIsSentinel(vaultSentinel, true);
        }

        // 4. Owner (MUST BE LAST — after this the deployer has no privileges)
        vault.setOwner(vaultOwner);

        console.log("Phase 11: Final roles set");
        console.log("  Owner:", vaultOwner);
        console.log("  Curator:", vaultCurator);
        console.log("  Allocator:", vaultAllocator);
        if (vaultSentinel != address(0)) {
            console.log("  Sentinel:", vaultSentinel);
        }
    }

    /**
     * @notice Seed the V2 vault with every non-idle market from the V1 vault's withdrawQueue.
     * @dev Skips markets where collateralToken == address(0) (idle) or V1 cap == 0 (disabled).
     *      Uses two in-memory arrays to aggregate per-collateral caps (Solidity memory has no
     *      mappings; linear-scan dedupe is cheap for ≤50 markets — matches the python's
     *      setdefault pattern at external/v2_adapter_caps.py:72-80).
     */
    function _seedMarketsFromV1(
        VaultV2 vault,
        IMorphoMarketV1AdapterV2 adapter,
        DeploymentConfig memory config
    ) internal {
        IMetaMorphoV1 v1 = IMetaMorphoV1(config.sourceVaultV1);
        IMorpho morpho = IMorpho(adapter.morpho());
        address expectedIrm = adapter.adaptiveCurveIrm();

        uint256 queueLen = v1.withdrawQueueLength();
        uint256 count = queueLen < config.maxMarkets ? queueLen : config.maxMarkets;
        console.log("Phase 7: Seeding markets from V1 vault");
        console.log("  V1 vault:", config.sourceVaultV1);
        console.log("  Queue length:", queueLen);
        console.log("  Processing up to:", count);

        address[] memory collaterals = new address[](count);
        uint128[] memory collateralCaps = new uint128[](count);
        uint256 collateralCount = 0;

        MarketParams memory liqParams;
        bool liqParamsSet = false;

        for (uint256 i = 0; i < count; i++) {
            Id mid = v1.withdrawQueue(i);
            MarketParams memory p = morpho.idToMarketParams(mid);
            (uint184 v1Cap,,) = v1.config(mid);

            if (p.collateralToken == address(0)) {
                console.log("  Skip idle market at index:", i);
                continue;
            }
            if (v1Cap == 0) {
                console.log("  Skip zero-cap market at index:", i);
                continue;
            }

            require(p.loanToken == config.asset, "Market loanToken mismatch");
            require(p.irm == expectedIrm, "Market IRM mismatch");

            uint128 marketCap = uint128(v1Cap);

            // Per-market cap (3rd level)
            bytes memory midData = abi.encode("this/marketParams", address(adapter), p);
            vault.submit(abi.encodeCall(vault.increaseAbsoluteCap, (midData, marketCap)));
            vault.submit(abi.encodeCall(vault.increaseRelativeCap, (midData, 1e18)));
            vault.increaseAbsoluteCap(midData, marketCap);
            vault.increaseRelativeCap(midData, 1e18);

            // Aggregate per collateral (linear scan dedupe)
            bool found = false;
            for (uint256 j = 0; j < collateralCount; j++) {
                if (collaterals[j] == p.collateralToken) {
                    collateralCaps[j] += marketCap;
                    found = true;
                    break;
                }
            }
            if (!found) {
                collaterals[collateralCount] = p.collateralToken;
                collateralCaps[collateralCount] = marketCap;
                collateralCount++;
            }

            // Liquidity adapter target = first market whose collateral matches LIQUIDITY_COLLATERAL_TOKEN.
            // Business rule (caller-driven): USDC/USDT vaults use WETH; WBTC uses LBTC; ETH uses weETH.
            if (!liqParamsSet && p.collateralToken == config.liquidityCollateralToken) {
                liqParams = p;
                liqParamsSet = true;
            }

            console.log("  Market seeded (collateral / cap):", p.collateralToken, marketCap);
        }

        require(liqParamsSet, "No V1 market found with the specified LIQUIDITY_COLLATERAL_TOKEN");

        // Per-collateral caps (2nd level)
        for (uint256 j = 0; j < collateralCount; j++) {
            bytes memory cData = abi.encode("collateralToken", collaterals[j]);
            vault.submit(abi.encodeCall(vault.increaseAbsoluteCap, (cData, collateralCaps[j])));
            vault.submit(abi.encodeCall(vault.increaseRelativeCap, (cData, 1e18)));
            vault.increaseAbsoluteCap(cData, collateralCaps[j]);
            vault.increaseRelativeCap(cData, 1e18);
            console.log("  Collateral cap set:", collaterals[j], collateralCaps[j]);
        }

        // Liquidity adapter target = first non-idle market
        bytes memory liqData = abi.encode(liqParams);
        vault.submit(abi.encodeCall(vault.setLiquidityAdapterAndData, (address(adapter), liqData)));
        vault.setLiquidityAdapterAndData(address(adapter), liqData);
        console.log("  liquidityAdapter set, target collateral:", liqParams.collateralToken);

        // Ensure the liquidity target market has a dead deposit on Morpho (inflation protection)
        _ensureMarketDeadDeposit(morpho, liqParams, config.asset, _resolveDeadDepositAmount(config));
    }

    function _resolveDeadDepositAmount(DeploymentConfig memory config) internal view returns (uint256) {
        return config.deadDepositAmount > 0 ? config.deadDepositAmount : _getDeadDepositAmount(config.asset);
    }

    function _ensureMarketDeadDeposit(IMorpho morpho, MarketParams memory params, address asset, uint256 required)
        internal
    {
        Id mid = _toId(params);
        Position memory deadPos = morpho.position(mid, address(0xdead));
        if (deadPos.supplyShares >= required) {
            console.log("  Liquidity market already has dead deposit, shares:", deadPos.supplyShares);
            return;
        }

        uint256 balance = IERC20(asset).balanceOf(tx.origin);
        if (balance < required) {
            console.log("  SKIPPED market dead deposit - insufficient balance");
            console.log("    Required:", required);
            console.log("    Available:", balance);
            return;
        }
        IERC20(asset).approve(address(morpho), required);
        morpho.supply(params, required, 0, address(0xdead), hex"");
        console.log("  Market dead deposit created:", required);
    }

    function _toId(MarketParams memory p) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(p)));
    }

    function _getDeadDepositAmount(address asset) internal view returns (uint256) {
        uint8 decimals = IERC20Metadata(asset).decimals();
        return decimals >= DECIMALS_THRESHOLD ? DEAD_DEPOSIT_HIGH_DECIMALS : DEAD_DEPOSIT_LOW_DECIMALS;
    }

    function _executeVaultDeadDeposit(VaultV2 vault, address asset, uint256 depositAmount) internal {
        uint256 balance = IERC20(asset).balanceOf(tx.origin);
        if (balance < depositAmount) {
            console.log("Phase 8: SKIPPED vault dead deposit - insufficient balance");
            console.log("  Required:", depositAmount);
            console.log("  Available:", balance);
            return;
        }
        IERC20(asset).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, address(0xdead));
        console.log("Phase 8: Vault dead deposit executed:", depositAmount);
    }

    function _configureVaultTimelocks(VaultV2 vault, uint256 duration) internal {
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = IVaultV2.addAdapter.selector;
        selectors[1] = IVaultV2.increaseAbsoluteCap.selector;
        selectors[2] = IVaultV2.increaseRelativeCap.selector;
        selectors[3] = IVaultV2.setForceDeallocatePenalty.selector;
        selectors[4] = IVaultV2.abdicate.selector;
        selectors[5] = IVaultV2.removeAdapter.selector;
        selectors[6] = IVaultV2.increaseTimelock.selector; // MUST BE LAST

        for (uint256 i = 0; i < selectors.length; i++) {
            vault.submit(abi.encodeCall(vault.increaseTimelock, (selectors[i], duration)));
            vault.increaseTimelock(selectors[i], duration);
        }
        console.log("Phase 9: Vault timelocks configured:", duration, "seconds");
    }

    function _configureAdapterTimelocks(IMorphoMarketV1AdapterV2 adapter, uint256 duration) internal {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = IMorphoMarketV1AdapterV2.abdicate.selector;
        selectors[1] = IMorphoMarketV1AdapterV2.setSkimRecipient.selector;
        selectors[2] = IMorphoMarketV1AdapterV2.burnShares.selector;
        selectors[3] = IMorphoMarketV1AdapterV2.increaseTimelock.selector; // MUST BE LAST

        for (uint256 i = 0; i < selectors.length; i++) {
            adapter.submit(abi.encodeCall(adapter.increaseTimelock, (selectors[i], duration)));
            adapter.increaseTimelock(selectors[i], duration);
        }
        console.log("Phase 10: Adapter timelocks configured:", duration, "seconds");
    }
}
