# Sentinel — Development Log

Historical record of how Sentinel was built, funded, deployed and rehearsed
during the Reactive Omni Buildathon (November 2026). This file preserves the
phase-by-phase working notes that used to live in the README. For the
project overview, see [README.md](README.md).

## Deployment order (phase 2, for reference)

1. Get testnet funds: Sepolia ETH → swap for lREACT via the faucet contract
   (from Ethereum Sepolia: `request(address)` on
   `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`; from Base Sepolia:
   `0x2afaFD298b23b62760711756088F75B7409f5967`; 1 ETH → 100 lREACT); keep
   some Base Sepolia ETH for the vault's callback billing.
2. Deploy `MockPriceOracle` on Base Sepolia (the reactive contract's
   constructor needs its address — immutable, so the oracle goes first).
3. Deploy `SentinelReactive` on Lasna, funded with lREACT (it pays for its own
   reactive transactions; a contract in debt receives nothing).
4. Deploy `SentinelVault` on Base Sepolia with the reactive contract's
   address (immutable), then `SentinelReactive.setVault(vault)` and
   `SentinelVault.openPosition(1000)`; fund the vault with a little Base
   Sepolia ETH (callback billing).
5. Drive price scenarios with `setPrice` and collect the three tx hashes.

A single-chain rehearsal deploy (anvil) is in `script/Deploy.s.sol`.

## Phase-2 status (2026-11-13) — DEPLOYED + rehearsed live

- ✅ **Training done**: `tools/train.py` written, weights regenerated, test
  vectors re-pinned, `forge test` 24/24. Shipped integer model: 97.47%
  held-out accuracy (see README "Model & training").
- ✅ **Throwaway dev wallet**: `0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94`
  (testnet only, never held real funds; its private key was kept in a
  git-ignored local env file and never committed — it is NOT the user's
  wallet).
- ✅ **Funding done.** The user transferred 0.1 Sepolia ETH to the dev
  wallet, which unlocked the scripted sequence: faucet swap of 0.02 ETH →
  **2.1 lREACT** credited on Lasna (tx
  `0x1dc70912d6a930cf9024668509487268e1de7f75ba985c8645281b3f531cde0d`), and
  a 0.05 ETH bridge deposit to Base Sepolia via the L1StandardBridge (tx
  `0x08345c161a808a498413933eb42113b05d29724cd3456dfd2833798f3c32a591` —
  plain transfer, same address credited on L2).
- ✅ **Deployed + Sourcify-verified (exact match)** — all three contracts;
  addresses and deploy txs are in the README's "Live proof" section.
  Wiring txs: `setVault` (Lasna)
  `0x6ba3b56887ada7058a11b44bf0ebb1b4a9f6700e9ba5fe87d1733c7a83bc5cf5` ·
  `openPosition(1000)`
  `0xff14511b7503588fed6b023570f0f012702c6510faab7f2c749eedaba01b4945` ·
  vault funded with 0.02 ETH
  `0xe2d94fcad0ad7fc58b522b65995ece5c511ade3c9a496b6acdee332544c3bcb4`.
  The reactive contract was funded with 1.0 lREACT at deploy + a 0.5 lREACT
  top-up
  `0xfd3b08d9865502970462f31fe63d40fee572fe3aac52567d45f9d4e4eac21710`.
- ✅ **Live rehearsal completed** — summary in the README; full log below.

## Live rehearsal — full log (2026-11-13, real cross-chain loop)

30 oracle pushes on Base Sepolia → 30 reactive transactions on Lasna →
2 protection callbacks back on Base Sepolia. Driver: `tools/rehearse.sh`.
Latencies are block-timestamp deltas (Base Sepolia blocks 2 s, Lasna ~1 s).

**Stage A — calm** (9 pushes, 100.0 → 100.2 wiggle): 7 `Decision` events,
all **HOLD**, **zero callbacks**, position untouched. Last origin push
`0x294fa60da3b2932bc3282dfda44bb7836afbca6201a9404745f313aeed4d8dfd`
(07:32:29 UTC) → its Lasna `Decision` tx
`0x83cd350deaa77d0bef29dc5c6ae5332eb4ba969047863cf1dc4c4f220a578411`
(07:32:54 UTC) — ≈25 s, the slowest reaction observed (relay cadence at
first contact; the callback stages below reacted within the same second).

**Stage B — grind down** (9 pushes, 99.0 → 87.7): **TRIM** decided on the
3rd push (96.0) and fired immediately — origin
`0x7aba9f0d8cb303763c1c5298b17193f4c32cfbf9dbe819c5649ba1170f2cded9` →
reactive `0x9142977c5df4a28d149d62218849bd1ec36abfda5e05546789a4c6486aa3448e`
→ callback `0xb5914403cbd5b49baa10abdd9436fde3f8f0ca6f08ba972318e3e9e664b20eaa`
(position 1000 → 500). Full loop ≈ **2 s**. Later grind pushes kept deciding
TRIM; the 300 s cooldown suppressed duplicate callbacks, as designed.

**Stage C — crash** (position re-armed to 1000 via
`0xdecad42804adae02170e7d04f492e9f699de82ab34573618fc3e959ff04e5778`,
9 flush pushes ~100, then 92.0 / 81.0 / 76.0): the 92 and 81 legs decided
TRIM (cooldown-suppressed); at 76.0 the model escalated to **EXIT**,
bypassing the cooldown — origin
`0x1bc65058749df45c25215642d520657fe6a7a2148d2ff3c41f237dba77bc7086` →
reactive `0x42cf48c375a3453ff09410d8fecc5b7f64ebad8e8925f8596213e0b9ce1400c2`
→ callback `0x1d506a0077b046cf043e303635f5f118800f7b0c7661a172207918c6946d40d7`
(position 1000 → 0, vault closed). Full loop ≈ **2 s**.

End state verified on-chain: `updates = 30`, `lastAction = EXIT`,
`protectionCount = 2`, position 0, vault closed, **zero service debt** on
both the Lasna system contract and the Base Sepolia callback proxy.

**Operating costs observed:** ~0.027 lREACT per reactive transaction
(30 updates ≈ 0.81 lREACT drawn from the reactive contract's balance — it
held 0.69 lREACT after a post-rehearsal top-up, enough for ~25 more
updates); callbacks cost the vault ~0.0000009 ETH each.

## Phase 2 TODO — history (all items closed)

- [x] `tools/train.py`: synthetic series generator + trainer + quantizer;
      regenerate `SentinelWeights.sol` with trained weights; refresh the
      reference test vectors and re-run `forge test`. **Done 2026-11-13 —
      integer model 97.47% held-out, 24/24 tests pass.**
- [x] Faucet run: Sepolia ETH → lREACT; fund reactive contract + vault.
      **Done 2026-11-13** (user-funded dev wallet; see status note above).
- [x] Deploy to Lasna + Base Sepolia (order above); verify contracts on
      Sourcify (`forge verify-contract --verifier sourcify`). **Done
      2026-11-13 — all three exact_match.**
- [x] Live rehearsal on testnet: calm (no action), grind-down (TRIM), flash
      crash (EXIT); record the origin → reactive → callback tx-hash triples
      and full-loop latency for each. **Done 2026-11-13 — full loop ≈ 2 s
      on both firing stages.**
- [x] Fill in deployed addresses + tx hashes in the README. **Done
      2026-11-13.**
- [x] Demo video (< 3 min): drive the crash live on testnet, show the model
      deciding (Decision events) and the vault closing. **Done — public at
      https://www.youtube.com/watch?v=mcEdWm5whgE**
- [x] Submit the BUIDL on DoraHacks. **Done 2026-11-14 — Build 51122:
      https://dorahacks.io/build/51122** (track deadline Dec 5, 2026).

## Phase 2 — real-asset vault upgrade (2026-11-15)

Upgrade A of the phase-2 design: replace the counter-only vault with a
real-asset vault, wired into the *existing* `SentinelReactive` +
`MockPriceOracle` (no reactive redeploy). Executed end-to-end on testnet
(Base Sepolia 84532 + Lasna 5318007) with zero reverts; every figure below
was read back on-chain. Full run report:
`~/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/phase2-deploy-report.md`.

**Preflight.** Dev wallet `0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94`:
Base Sepolia 0.029990636441348677 ETH · Sepolia 0.029999048614758796 ETH ·
Lasna 0.462130799998621308 lREACT. Reactive held 0.6912877 lREACT, debt 0,
`vault()` = V1 (`0x6f723a2F0E4A45111F42A74448426AAAAb3d7641`), `updates`
= 30. **Fuel decision:** lean rehearsal plan = 13 trigger pushes ≈ 0.35
lREACT < 0.691 available → **no faucet top-up needed, none performed**;
Sepolia ETH untouched. Local gate before deploying: `forge build` +
`forge test` → **42/42 pass** (24 phase-1 tests + 18 new).

**Deployments (Base Sepolia, in design order)** — all three
**Sourcify-verified (exact match)**:

| Contract | Address | Deploy tx | Sourcify job |
|----------|---------|-----------|--------------|
| `MockUSDC` | `0x96E467Ff7958851d307D28118EBAAD333CAb85B2` | `0xb6e416a3d303dbcb721634d09a2c57bfdbe379d0acfa623d10c2eb6e04dd7876` | `5cd5bb14-c510-4534-8c9a-9b44edbf95fc` |
| `SentinelSwap` | `0x2C1d278d31d52Ec8405cF33E319ba0eB8C6b0d1F` | `0x31a88186cb276fe19e046283b8d745982b7775e5602d25648dd0c779dc08e3ea` | `f65eb462-1271-480b-9421-6e1d98711f3e` |
| `SentinelVaultV2` | `0x29c0b2FAc813e59E23E12b8f6699bF17d4512192` | `0x1907efc0c1b346ec1d1405b8ae8321022f14502dd401d1fedf6e264139826922` | `55c85c9b-2713-4f90-8add-dbefea2f3e78` |

Setup txs: `swap.setVault(VaultV2)`
`0x135df96a05b54298a2419348c5e5d9a5c142364f3ede481146adcd1cc66e1d68` ·
seed reserve (mint 1,000 mUSDC → swap)
`0xfb9d2ffca862fea68957fbd491ba685d7063abc2fa8c874cfb5dc8c0a44bbc1f` ·
fund VaultV2 with 0.005 ETH (callback billing)
`0x56f4673d0d76e3090ef3a74c3ed34dd147e19381a1254ddfe6a77cac42efb7b4` ·
wrap 0.02 ETH → WETH
`0xb851578a0efe3ba0202518797e0e122c5ebaed13b2a4e9641e9e0955797113b5` ·
WETH `approve` vault (max)
`0x0fef69ba4ebdaa641e7d0e07ee7c425ec1839be01035b1fbd4df475bf5402818` ·
`vault.deposit(0.01 WETH)` — position armed
`0xfbab1cd6a2d6949cc908f8761a1559c3450fbba90a98e0ce3743f5a6c3a966cd`.
Post-deploy reads verified all constructor wiring, incl. the vault→swap
max WETH allowance.

**Wiring (Lasna):** `SentinelReactive.setVault(VaultV2)`
`0xd9d983a15f270a916d60d7c4914ae3d4b82aedc84232c2427a44d7c72ea8d9ee` —
verified after via `reactive.vault()` read-back. V1 vault and the phase-1
trio are untouched; only the reactive's callback pointer moved.

**Live rehearsal — full log (2026-11-15).** Driver convention: each step
pushed the WETH mirror price first (18-dec USD, swap pricing), then the
trigger price on the subscribed `0xdEaD` key (1e8 scale, same % series —
see deviation 1). 13 trigger pushes → 13 reacts.

*Stage A — calm* (5 pushes): `100.0`
`0x884de11d67b487b5db6570ec38d69118d69c44a824d2a2d6b5348cbddb95f3b8` ·
`100.5` `0x0b55876bd69abb44bd70da909163a62d1f7a8dbfc139e0c32002d7f50e51727d` ·
`99.8` `0x9987c0d11abcb4473226fe5f9a61e7acaa031dec8a3f73afac6d40fee3d7c009` ·
`100.2` `0x34a004b90dede473ebfd820fc1e238ac403d112c72f8601b5003720a61451728` ·
`100.1` `0xc4f33572c6995db79d877fea75c3b207700525e3685f533a00b4f6961004b75b`.
Lasna `Decision` txs (all **HOLD**):
`0xa1fc23246229a68959029713a1986438a242d9853efaea1e9deda14c7c2c3800`,
`0xea3223a0486031c41001addcfbcb3ae651c872486f923bc2be971bb27a235fc3`,
`0x1ec61fb784caab3b87298dca9d8d00888886275b6a7790432e393a5ce88d4944`,
`0xde611664f6beec51ca5eee43839afe259b90f82b8d328085c77a65a17f7d35d4`,
`0xabe3822c6ac437ef9caab3201c915e6a12d914b5e0f6f83bb66885086ad908c9`.
Result: `updates` 30 → 35, **zero callbacks**, vault untouched (WETH 0.01,
mUSDC 0, protectionCount 0).

*Stage B — grind down:* `99.0`
`0x50ab0773e88bf436834b42f608e154f3800358ed95825eb0a6773aa2534b313b` ·
`97.5` `0xd60bb44797052512481f7a1be2af97460c4aa420b23e48d6b4f0ef0f8550b159` ·
`96.0` `0x6990543a9dde12504193733199cadf5d129cd64272371cfe6a4804eace01ae81` ·
**`94.0` `0xa1c46ea2b9fbd2bc70ee0e4fd946cec200a643582a287f12171b377018f31c4a` ← TRIM fired** ·
`92.0` `0xcc665458687d78cd4dad266c6a8133cd72a310013adf6207a6a295da1352da95`.
Triple: origin
`0xa1c46ea2b9fbd2bc70ee0e4fd946cec200a643582a287f12171b377018f31c4a` →
reactive `0x00fc5e4537786544f1a9a6ca6a8d7ad17d8c63d836e6fa05bccf441fd2d30d10`
→ callback `0xf8dabf14c32a5bd234f58ff14e9a8328f717707377acf2989c77fb1e07232072`.
Callback events (decoded): WETH Transfer vault→swap **0.005**; mUSDC
Transfer swap→vault **14.1**; `Swapped(0.005, 14.1, price 2820e18)`;
`DeRisked(TRIM, 0.005, 14.1)`; `ProtectionExecuted(reactive, TRIM,
0.01 → 0.005)`. **Full loop ≈ 1 s.** The 5th grind push decided TRIM
again; the 300 s cooldown suppressed the duplicate callback, as designed.
Vault after stage: WETH **0.005**, mUSDC **14.1**, protectionCount 1,
closed false. Re-arm: `vault.deposit(0.01 WETH)`
`0xedf40e19ae3e0d96aca241e89869ea099d63fa752ca89481aa238418da43fd8f`
→ vault WETH 0.015.

*Stage C — crash:* `86.0`
`0xda05dc253a9ccc3ba231e07cd4e183fb7021261922daf39825667e5bffbc0b40` ·
**`78.0` `0xbed70db574e02bd3912b4cfa74f5e86cca004800620104effd766e9374a13995` ← EXIT fired (escalation, cooldown bypassed)** ·
`72.0` `0x3a787d02b57af28e00e1e8cc8b39afa9addf6393793b3a5fab8d37a2b934430b`.
Triple: origin
`0xbed70db574e02bd3912b4cfa74f5e86cca004800620104effd766e9374a13995` →
reactive `0xfe39a88434271543356c988fa70fd256946a68d6cba0ee19a49fe3492715af60`
→ callback `0xa55c9079d19bb55ff6e69f992bc2e7fea56a8aa12747d3b1ed9f7f9f0e3c14d2`.
Callback events: WETH Transfer vault→swap **0.015**; mUSDC Transfer
swap→vault **35.1**; `Swapped(0.015, 35.1, price 2340e18)`;
`DeRisked(EXIT, 0.015, 35.1)`; `ProtectionExecuted(reactive, EXIT,
0.015 → 0)`. **Full loop ≈ 2 s.**

WETH mirror pushes (Base Sepolia, swap pricing; no reacts): calm
`0xae50114d…f51b`, `0xc7968b10…5709`, `0x83254f80…6ec`, `0x14e1b3e6…e068`,
`0xef795d20…e644`; grind `0xafed3000…288a`, `0xbd781b5f…7d38`,
`0xe2a028c2…88b9`, `0x66338157…63e0`, `0x9c8683b9…7c9c`; crash
`0x80f36b5c…009f`, `0xf6b8143a…a329`, `0xfec9e8db…5bc` (truncated here as
in the run report; full hashes in the run log; prices 3000→3015→2994→
3006→3003, 2970→2925→2880→2820→2760, 2580→2340→2160, all ×1e18).

**Final on-chain state:** VaultV2 WETH **0** · mUSDC **49.2** (14.1 TRIM +
35.1 EXIT) · ETH 0.0049974972734 · `protectionCount` 2 · `closed` true ·
proxy debt 0. Swap WETH 0.02 / mUSDC reserve 950.8. Reactive `updates`
43 / `lastAction` EXIT / debt 0. **Reactive lREACT remaining: 0.3371809**
(spent 0.3541068 over 13 reacts ≈ 0.02724/react; ≈ 12 reacts left, held
for upgrade B work). All balances reconcile exactly (reserve 1000 − 14.1
− 35.1 = 950.8; swap WETH 0.005 + 0.015 = 0.02; vault mUSDC 14.1 + 35.1
= 49.2).

**Deviations & notes:**

1. **Watched token ≠ WETH.** Decoding the reactive's deployment tx
   (`0x1349cd6d58fdda0c2a15fee36549d3b25e566988e374ca782445c268b058e563`)
   proved its subscription topic1 is the phase-1 stand-in token
   `0x000000000000000000000000000000000000dEaD`, *not* WETH. With the
   reactive kept as-is (per plan), the rehearsal drove decisions on
   `0xdEaD` (1e8 scale, consistent with the ring buffer's existing
   contents; the model is ratio-based) and mirrored the identical %
   series onto the WETH key at 18-decimal scale — the key `SentinelSwap`
   prices from. Both keys live in the same `MockPriceOracle`; WETH pushes
   cannot trigger reacts (topic1 filter). A WETH-subscribed reactive
   remains upgrade B's redeploy.
2. **TRIM fired on grind push #4 (94.0), not #3** as in phase 1 — the
   window composition differs (5-push calm vs 9, plus the phase-1 tail).
   Behaviour stayed inside the design envelope; no extra pushes were
   needed and the total (13) stayed inside the lean fuel plan.
3. **Tooling quirk:** Foundry 1.9's `forge create` needs `--broadcast`;
   the first MockUSDC invocation without it only prepared the tx
   (diagnosed via unchanged nonce; nothing was sent, no funds spent) and
   was re-run correctly.
4. **No top-up performed** — the lean plan fit the existing fuel (above).
