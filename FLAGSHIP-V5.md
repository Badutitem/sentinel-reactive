# Flagship swap — the per-user release (2026-11-25)

The live flagship is now the **per-user system**: the same brain and
desk as the previous flagship, with `SentinelVaultV5` — a pooled vault
with per-user share accounting — in place of the single-position
vault. Anyone can deposit WETH through the public flow and receives
shares; anyone can redeem their shares at any time for their pro-rata
slice of both pool legs (WETH + MockUSDC). The guard still acts on the
whole pool at once; every holder shares the same decisions pro-rata.
Design: `VAULTV5-DESIGN.md`. The on-chain multi-user rehearsal of this
exact vault code passed with wei-exact reconciliation earlier the same
night: `VAULTV5-REHEARSAL.md`. The previous flagship set (Release 5,
`SentinelVaultV4`) stays live and untouched as the previous
generation; its record is `RELEASE5.md`.

## Deployments — all Sourcify exact_match (creation + runtime)

| Contract | Chain | Address | Deploy tx | Sourcify matchId |
|----------|-------|---------|-----------|------------------|
| `SentinelReactiveV5` (flagship brain) | Lasna (5318007) | `0x37EeF5e3179E55c0e96E1528180B55Fa20DC150B` | `0x38cd921ef3bb091803fa763014800e2c5973d9b5efe423c9d865def5774c52d7` | 59863280 |
| `SentinelSwapV2` (flagship desk) | Base Sepolia (84532) | `0x17700999733F766968EA252D5a17ac39F96F2C28` | `0x5966d9ad15f5cd5e76efdfe6c4f79121915ae7d71a1a9d628b376fa1461dda63` | 59863068 |
| `SentinelVaultV5` (flagship vault) | Base Sepolia (84532) | `0x108513e6439664fdeE9050e1ccc208e8c1b61441` | `0xc2c4b6b1c26aa220daf0c46ec8f5ceceaebf3eb6ce0915de37949ec8a4389117` | 59863253 |

Constructor wiring identical to the previous flagship: the brain
subscribes to the Release 2 Chainlink adapter
(`0xAb9c7a5178B444cd1C1fD705e5eBeCf4b9A1C25F`, token WETH, cooldown
300 s); the desk's price source is the same adapter; the vault's
callback proxy is `0x476F44b11F5C942c58f4c8E3d0300E5710743585`. The
brain was funded with **1.15 lREACT attached at deploy** (the previous
flagship's 1.05-at-deploy + 0.10 top-up end state, in one attach).

Wiring and seeding (all verified by reads after each step):
`swap.setVault` `0x4a7dffac4758f34aaefdecf499cdc7976c23c723f61884d73c792b104ab12cc5` ·
`reactive.setVault` `0x82f3d0472e86bb50371c303735959bfbf53a959f94200414e288d0aad570949a` ·
desk seeded with exactly 1,000 mUSDC (mint
`0x4dbc5a17416889d2cca22e5416a537a8f854d003a87164256685407fac4794b8`) ·
vault callback billing funded 0.0001 ETH
(`0x177fbf8b46ca9d5939d04aa91c6f15e37e753bee9a4281c347b5ae3821c58f48`).

## Owner seed deposit — the user path, proven on the flagship itself

The dev wallet deposited **0.002 WETH** through the public flow —
wrap `0x4ccbda98ccee2bcf9e20825e6164968fb57e5fa9bc776cbdf31c2c1e9a775618` →
approve `0xf7d27957d7305d24f5bd02cfc2a7b04fb4dd7d0dc4dd1da4dfab5d46d859494f` →
deposit `0x3b8ad6816fcee11de8e46e1dd5c6616cab6adf8168fbddc7e91ffc16b04dccb4`.
Read back: owner shares **2,000,000,000,000,000 (exactly 1:1, first
deposit)**, `totalShares` the same, `managedRisk` 0.002 WETH,
`managedSafe` 0, `closed` false. The flagship holds a real guarded
position from birth.

## Live window — real Chainlink feed (2026-11-24 23:01–23:15 UTC)

Driver window (13 min, pokes every 75 s; gates 10 bps / 60 s / 300 s
heartbeat). The feed had moved since the previous flagship's window:
three emissions, all ingested by the new brain —

| Sync tx (Base Sepolia) | Emitted price |
|------------------------|---------------|
| `0xf1418b5ff204c9814ebda859a68e28fe22c7e3558358257ed45e5675555c34ad` | $1,682.55553774 (price move) |
| `0xc5fff0d96db3953e1a0426b76ac7c459810ff309ee0e80001dc932ccaa209041` | $1,682.55553774 (heartbeat) |
| `0xe788f3ef5be5fd6e4c2d3ddb71108c5d76d041ab4931cb9d992498307965c1da` | $1,679.60422012 (new round) |

Brain read back after the window: `updates = 3`, `lastAction = 0`
(HOLD — warm-up, as designed), anchor $1,680.87298220226 (the decayed
peak, read to the wei), `duplicatesIgnored = 0`, balance
**1.0613437 lREACT** (0.0886563 over 3 reacts). Vault untouched by the
window: `managedRisk` still 0.002 WETH, `protectionCount = 0` — no
firing was forced; the firing proof for this vault code is the
rehearsal record. The previous flagship's brain ingested the same
three emissions in parallel (`updates` 3 → 6), untouched.

## Fuel after the swap (read on-chain, 2026-11-24 ~23:16 UTC)

| Balance | Value |
|---------|-------|
| Flagship brain, Lasna | **1.0613437 lREACT** (1.15 attached; 3 reacts) |
| Flagship vault position / billing, Base Sepolia | 0.002 WETH (owner seed) / 0.0001 ETH |
| Flagship desk reserve, Base Sepolia | 1,000 mUSDC (seeded; untouched) |
| Dev wallet, Base Sepolia | 0.068233341749342422 ETH (spent 0.002119378809401102 this swap, incl. the 0.002 seed principal + 0.0001 billing) |
| Dev wallet, Lasna | 0.706857799986795632 lREACT (spent 1.330171500001801715: 1.15 attach + deploy/setVault gas) |
| Dev wallet, Ethereum Sepolia | 0.790149002359556650 ETH (untouched; no faucet round was needed) |

Local gate before any transaction: `forge build --force` +
`forge test` → **165/165 pass** (24 suites).

## Process incidents, recorded plainly

1. The first deploy driver (forge create) broadcast the desk
   successfully, then aborted on its own `--json` output parsing.
   The desk was recovered and verified from chain state (nonce →
   computed address → code + `priceSource` reads; deploy tx found by
   block scan) and asserted, not redeployed — no duplicate desk
   exists.
2. `cast send --create` in this Foundry build takes all options
   *before* `--create`; two client-side failures (nothing broadcast,
   nonces unchanged) preceded the successful brain deploy.
3. Sepolia L1 balances were unmeasurable for ~10 minutes (several
   public RPCs failing from this VM) until the Tenderly gateway
   answered: 0.790149002359556650 ETH, matching the expected figure.
   No Sepolia funds were needed this swap.
