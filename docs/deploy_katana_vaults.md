# Katana mainnet deployment — WETH & USDC V2 vaults

Two vaults, one script (`script/DeployVaultV2WithMarketAdapterFromV1.s.sol`):

| V2 Vault | Source V1 | Asset | Liquidity market |
|---|---|---|---|
| Yearn OG ETH V2 | [`0xFaDe...dc2E`](https://app.morpho.org/katana/vault/0xFaDe0C546f44e33C134c4036207B314AC643dc2E/yearn-og-eth) | vbETH (18 dec) | weETH collateral |
| Yearn OG USDC V2 | [`0xCE2b...29D7`](https://app.morpho.org/katana/vault/0xCE2b8e464Fc7b5E58710C24b7e5EBFB6027f29D7/yearn-og-usdc) | vbUSDC (6 dec) | vbETH collateral |

Names and symbols are inherited from the V1 vaults automatically (no `NAME` / `SYMBOL` env vars needed).

---

## 1. Funds needed in the deployer EOA before starting

The deployer is the EOA (or address behind your Ledger) you sign with. Tokens are pulled from `tx.origin` for the dead deposits. **No new Morpho Blue markets are deployed** — all markets involved are the existing ones the V1 vault already allocates to.

| Asset | ETH vault deploy | USDC vault deploy | Why |
|---|---|---|---|
| **ETH** (gas) | ~0.02 ETH | ~0.03 ETH | ~16M gas for ETH deploy, ~22M gas for USDC deploy |
| **vbETH** | **2 gwei** (`2_000_000_000` wei) ceiling | — | Phase 8 vault dead deposit (1 gwei) + Phase 7 Morpho market dead deposit (1 gwei, usually skipped) |
| **vbUSDC** | — | **2 USDC** (`2_000_000` wei) ceiling | Same breakdown — $1 vault dead deposit + $1 Morpho market dead deposit (usually skipped) |

**Budget vs. expected:**

- **Phase 8 (vault dead deposit) always runs** — this is the deposit into the freshly deployed V2 vault, sending shares to `0xdead` so the vault can't be share-inflated. Requires 1 gwei vbETH (ETH vault) or 1 USDC (USDC vault).
- **Phase 7 (Morpho market dead deposit) usually skips** — the script only supplies if the existing liquidity-target market doesn't already have a `0xdead` supply position ≥ `DEAD_DEPOSIT_AMOUNT`. Since these markets are live and the threshold is tiny (1 gwei / $1), this almost always skips.

So the realistic cost is **~1 gwei vbETH + $1 USDC + ~0.05 ETH gas**, but keep the `2x` ceiling in the wallet in case the market hasn't been seeded at `0xdead` yet.

Which existing Morpho Blue market gets the (possibly-skipped) dead deposit:

| V2 vault | Target Morpho market | Market id |
|---|---|---|
| Yearn OG ETH V2 | weETH / vbETH | `0x1e74d36ffbda65b8a45d72754b349cdd5ce807c5fa814f91ba8e3cd27881c34b` |
| Yearn OG USDC V2 | vbETH / vbUSDC | `0x2fb14719030835b8e0a39a1461b384ad6a9c8392550197a7c857cf9fcbd6c534` |

The deployer EOA does **not** need to be the final owner. The script hands ownership off to `OWNER` in Phase 6, so you can deploy from a disposable EOA and point `OWNER` at your multisig.

---

## 2. Shared infrastructure (same for both vaults)

```bash
# Katana mainnet RPC (swap for your own endpoint if you have one)
export RPC=https://rpc.katana.network

# Morpho V2 infra on Katana
export VAULT_V2_FACTORY=0xFcb8b57E56787bB29e130Fca67f3c5a1232975D1
export MORPHO_MARKET_V1_ADAPTER_V2_FACTORY=0x6d6A3ba62836d6B40277767dCAc8fd390d4BcedC
export ADAPTER_REGISTRY=0xA9132a09838fD20304dF2B2892679d06A4cc6371

# Roles
export OWNER=0x518C21DC88D9780c0A1Be566433c571461A70149
export CURATOR=0x90D0f26025571295D18a6c041E47450B81886B51
export ALLOCATOR=0x75a1253432356f90611546a487b5350CEF08780D
export SENTINEL=0xe6ad5A88f5da0F276C903d9Ac2647A937c917162
export ADDITIONAL_ALLOCATOR=0x50B75d586929Ab2F75dC15f07E1B921b7C4Ba8fA    # tapir

# Timelocks (both meet Morpho listing minima)
export VAULT_TIMELOCK_DURATION=604800      # 7 days
export ADAPTER_TIMELOCK_DURATION=259200    # 3 days

# 100% max annual rate (per-second scaled)
export MAX_RATE=31709791983
```

Signing uses the Foundry encrypted keystore account named `morpho` (imported once via `cast wallet import morpho --interactive`). The signer (deployer EOA) does **not** need to equal `OWNER` — Phase 6 hands ownership off. The signer pays gas and provides the dead-deposit tokens.

```bash
export DEPLOYER=$(cast wallet address --account morpho)
SIGNER_FLAGS="--account morpho --sender $DEPLOYER"
```

Other signing options if you ever need them: `--ledger --sender <addr>`, `--private-key $PK` (derives sender from key), `--interactive` (prompt for PK).

You do NOT need `--sig "run()"` — `run()` is the default entry point forge looks for.

---

## 3. Deploy Yearn OG ETH V2

```bash
export ASSET=0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62                       # vbETH
export VAULT_V1=0xFaDe0C546f44e33C134c4036207B314AC643dc2E                    # Yearn OG ETH V1
export LIQUIDITY_COLLATERAL_TOKEN=0x9893989433e7a383Cb313953e4c2365107dc19a7  # weETH
export ADAPTER_ABSOLUTE_CAP=30000000000000000000000                           # 30,000 vbETH (~$100M)
export DEAD_DEPOSIT_AMOUNT=1000000000                                         # 1 gwei of vbETH
unset NAME SYMBOL                                                             # inherit from V1

# Dry-run first (simulate, no broadcast)
forge script script/DeployVaultV2WithMarketAdapterFromV1.s.sol:DeployVaultV2WithMarketAdapterFromV1 \
  --rpc-url $RPC $SIGNER_FLAGS

# If the dry-run output looks good, add --broadcast --slow:
forge script script/DeployVaultV2WithMarketAdapterFromV1.s.sol:DeployVaultV2WithMarketAdapterFromV1 \
  --rpc-url $RPC $SIGNER_FLAGS --broadcast --slow
```

Expected V1 → V2 market mapping: 3 non-idle markets (weETH, wstETH, yvvbUSDC), 1 idle market skipped.

---

## 4. Deploy Yearn OG USDC V2

```bash
export ASSET=0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36                       # vbUSDC
export VAULT_V1=0xCE2b8e464Fc7b5E58710C24b7e5EBFB6027f29D7                    # Yearn OG USDC V1
export LIQUIDITY_COLLATERAL_TOKEN=0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62  # vbETH
export ADAPTER_ABSOLUTE_CAP=100000000000000                                   # 100M USDC
export DEAD_DEPOSIT_AMOUNT=1000000                                            # 1 USDC ($1)
unset NAME SYMBOL                                                             # inherit from V1

# Dry-run first
forge script script/DeployVaultV2WithMarketAdapterFromV1.s.sol:DeployVaultV2WithMarketAdapterFromV1 \
  --rpc-url $RPC $SIGNER_FLAGS

# Broadcast
forge script script/DeployVaultV2WithMarketAdapterFromV1.s.sol:DeployVaultV2WithMarketAdapterFromV1 \
  --rpc-url $RPC $SIGNER_FLAGS --broadcast --slow
```

Expected V1 → V2 market mapping: 12 non-idle markets (vbETH, vbWBTC, LBTC, weETH, BTC.b, yvvbUSDT, yvvbWBTC, yvvbETH, yvAUSD, wstETH, KAT, siUSD), 1 idle market skipped.

---

## 5. After each deploy — sanity checks

Grab `VaultV2` and `MorphoMarketV1AdapterV2` addresses from the script log (last lines under `=== DEPLOYMENT COMPLETE ===`), then:

```bash
export VAULT=0x...    # new V2 vault address
export ADAPTER=0x...  # new adapter address

cast call $VAULT "name()(string)"              --rpc-url $RPC
cast call $VAULT "symbol()(string)"            --rpc-url $RPC
cast call $VAULT "owner()(address)"            --rpc-url $RPC
cast call $VAULT "curator()(address)"          --rpc-url $RPC
cast call $VAULT "liquidityAdapter()(address)" --rpc-url $RPC   # must == $ADAPTER
cast call $VAULT "totalAssets()(uint256)"      --rpc-url $RPC   # >= DEAD_DEPOSIT_AMOUNT
```

Deposits will auto-allocate to the liquidity market (weETH for ETH vault, vbETH for USDC vault) and land as `supplyShares` on that market held by the adapter.

---

## 6. Listing the vaults on the Morpho app

After both vaults are live and verified, register them via the Morpho listing flow: https://docs.morpho.org/overview/resources/listing/. Requirements already baked into the script: timelocks (7d / 3d), gates abdicated, dead deposit seeded, name/symbol free of the "morpho" substring.
