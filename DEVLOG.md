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

## Phase 2B — Chainlink adapter upgrade (2026-11-15)

Upgrade B of the phase-2 design: a second, self-consistent trio whose
price origin is the real Chainlink ETH/USD feed on Base Sepolia, relayed
by `ChainlinkPriceAdapter`. Demo A (mock-origin trio) untouched. Testnet
only (Base Sepolia 84532 + Lasna 5318007), executed per
`phase2b-deploy-runbook.md`; every figure below was read back on-chain.
Full run report:
`~/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/phase2b-deploy-report.md`.
Local gate before any transaction: `forge build` + `forge test` →
**53/53 pass** (42 existing + 11 new adapter tests).

**Funding.** Dev wallet `0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94`
preflight: Lasna 0.459128299998591283 lREACT · Sepolia
0.029999048614758796 ETH · Base Sepolia 0.004967498075732014 ETH. (a)
lREACT faucet round: `request(devWallet)` on the Sepolia faucet
`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` with 0.02 ETH —
`0xb5ee1b72ed6df7768cc1195833967a55117af0139d106c32110379a92b4b4b38`,
credited exactly **+2.1 lREACT** on Lasna (Lasna balance after:
2.559128299998591283). (b) Bridge: plain ETH transfer to the
L1StandardBridge `0xfd0Bf71F60660E2f608ed56e1659C450eB113120` on Sepolia
(the phase-1 route) — **0.0095 ETH**,
`0x731ca5be13d8fbe9c0555c874edca9fe285899fd9a01682bccf71b648fec79f1`
(gasUsed 634,136 — identical to phase 1's deposit); L2 credit landed
~7 minutes later (Base Sepolia 0.004967 → 0.014467498075732014). No
external funding was needed and none was requested. The old reactive's
0.3371809 lREACT stays stranded, as documented (no owner-withdraw path).

**Deployments (runbook order)** — all four **Sourcify-verified
(exact match)**:

| Contract | Address | Deploy tx | Sourcify |
|----------|---------|-----------|----------|
| `ChainlinkPriceAdapter` | `0xAb9c7a5178B444cd1C1fD705e5eBeCf4b9A1C25F` | `0xba16d14ade1d586fcbc3d309e898587cac2fcec188a53b4aace5ea3799d60a66` | job `4d79d881-c33d-457b-b699-a603303fc367` |
| `SentinelSwap` (#2) | `0x6E270B88133155E4c21d71029EF3Fe47Ce9e813D` | `0x76eb9e283e5942dbf2bad37aba7073e25ff4e7690bc5b4a80d78b0be19e7a498` | exact_match (verified 2026-11-15T13:05:43Z) |
| `SentinelReactive` (#2) | `0x92ea50b0De053BE2D7FA6F73853aC403364c9330` | `0xd1728c9618599bdefa0698d3cd1dd3a5174d0c3259bd6543242daab45842429d` | job `41e61aac-fafb-4845-9b97-3da2b819de8a` |
| `SentinelVaultV2` (#2) | `0x41e86278264C0C4FB83e5328329ff6F459Ba3dF4` | `0xdb2c6b1e77b9c2eba4ab5e149018ed0430ec08027b228bb2e1be467cafe5f5fe` | exact_match (verified 2026-11-15T13:06:35Z) |

Constructor args per runbook: adapter (feed
`0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`, token WETH, deadband
10 bps, minInterval 60, heartbeat 300, maxStaleness 3600); swap #2
(WETH, reused MockUSDC `0x96E467Ff7958851d307D28118EBAAD333CAb85B2`,
priceSource = adapter, vault = 0); reactive #2 (origin 84532, oracle =
adapter, token WETH, dest 84532, cooldown 300, **2.0 lREACT attached at
deploy**); vault #2 (proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585`,
reactive #2, WETH, MockUSDC, swap #2). Post-deploy reads all passed
before wiring (adapter `feed/token/priceScaleFactor` = proxy / WETH /
1e10; reactive #2 `oracle()` = adapter, balance 2.0 lREACT, debt 0).

**Wiring and arming:** `swap#2.setVault(vault#2)`
`0x14c02c07f8fcad5898f0d6f3bc9e4fed6e5426b3dd83837ec6b9ba6c449c32ec` ·
`reactive#2.setVault(vault#2)` (Lasna)
`0x8c296dc8d29df0c512724e204c78197fdba0d312fdac888cad8f109bf17ac52f` ·
seed desk `MockUSDC.mint(swap#2, 1000e18)`
`0xccc24cac73d26d038cd2e2a5ed81df2c65e28ee2ece895a73a172e4c1f0df9e2` ·
fund vault #2 with 0.005 ETH (callback billing)
`0x3b3308c60b174269e6c1b310af6992a204b09a75e11845aa40dac659688fe453` ·
wrap 0.0093 ETH → WETH
`0xdb95f7c9583caff855cf649df1558fcbb4ec6466b700237cb68858908d1978e4` ·
`WETH.approve(vault#2, max)`
`0xe9ff6d93518e5ea97cbcf289f3c356a5ae2169ee934702b12fe7d18e4195bf91` ·
`vault#2.deposit(0.0093 WETH)` — position armed
`0xb8f8972a9547098819daac4b8b654f475bb7ed22ee3512dc50677fcf31d3f6b2`.
Post-arm: `positionSize()` = 0.0093 WETH, `closed` false, proxy debt 0,
swap #2 reserve 1,000 mUSDC (≈59× the position's ~$17 value).

**First sync — real Chainlink price ingested.** Feed answer at sync
time: **183512571218** ($1,835.12571218, 8 decimals), round 351 s old
(fresh). Origin sync (Base Sepolia, block 59130727)
`0x5c82ed22b9d4f957f1bfd0246284451b7a0db29887fa005f37323bf73c5da80f`
emitted `PriceUpdated(WETH, 1835125712180000000000, 1794747486)` →
reactive ingestion (Lasna, block 8410350)
`0xfc4e70a88736c6d4abb46910575f84cc62e928b32af38770c07c8e3bc6546026`
(`PriceSeen(price=1835125712180000000000, originTs=1794747486,
updates=1)`). Adapter `lastPrice` read back as 1835125712180000000000.

**Live window (13:06–14:36 UTC, ~90 min).** Driver
`tools/drive_chainlink.sh` (poll feed every 15 s; `sync()` on round
change or 150 s poke; the adapter's on-chain gates decide what emits);
watcher `tools/watch_reactive.sh` tailing Lasna events. Totals: 44
`sync()` calls → **24 `PriceUpdated` emissions** → **24 reactive
transactions** (`updates` 0 → 24) → **22 `Decision` events, all HOLD,
0 `CallbackRequested`, 0 callbacks** (the other 20 syncs were silent
no-ops, correctly suppressed by the gates). Market (real Chainlink
ETH/USD): opened $1,835.13, ranged $1,809.08–$1,835.95, closed
$1,812.15 — a genuine −1.4% slide into the final third. TRIM logit
climbed from ~1.25–1.57 (calm first half) to **2.289** at the $1,809.08
print while HOLD stayed ahead (**6.436**); the 9-price window drawdown
never approached the ~3% TRIM pattern. **No TRIM/EXIT fired, and none
was forced** (no forcing mechanism exists). Decision evidence (all
HOLD): first
`0xaee9b392ee899d16211bbfdf1e5cd08d1832919ab34449939c70278c5641f65d`
(block 8411019, $1,835.0274; H 7.831 / T 1.399 / E −11.305) ·
most-stressed
`0xd1b009add072e00304faa2091c72ac1d3a041317cf0d2acdf16f7ca8141216a3`
(block 8415096, $1,809.0794; H 6.436 / T 2.289 / E −10.547) · last
`0x42f7dd4451ffdcfc2be273fe7909efc0bae5fb0f77c2e623c1a0f03aafd7747d`
(block 8415270, $1,812.1546). Full driver/watcher logs are archived
beside the run report in the goal workspace.

**Final on-chain state:** reactive #2 `updates` 24 / `lastAction` HOLD /
debt 0 / **lREACT remaining 1.3623139** (spent 0.6376861 ≈ 0.02657/react;
≈51 reacts of headroom) · vault #2 WETH **0.0093** / mUSDC 0 / ETH 0.005
/ `closed` false / `protectionCount` 0 / proxy debt 0 · swap #2 WETH 0 /
mUSDC reserve 1,000 (intact) · adapter `lastPrice` 1812154642420000000000
($1,812.1546) · dev wallet after: Base Sepolia 0.000138874300687092 ETH ·
Lasna 0.423364599997233646 lREACT · Sepolia 0.0001490024055249 ETH · WETH
0. All balances reconcile (24 emissions = 24 updates; 22 Decisions =
updates − 2 warm-up).

**Deviations & notes:**

1. **Bridge 0.0095 ETH instead of ~0.03–0.05; wrap/deposit 0.0093 WETH
   instead of 0.02/0.01.** One funding pool: the dev wallet held exactly
   0.03 Sepolia ETH, the faucet round consumed 0.02, so at most ~0.0099
   could bridge. Gas on both chains is near-zero, so the shortfall landed
   entirely on the two value transfers (bridge 0.0095; after the
   runbook-exact 0.005 ETH vault billing, a 0.0093 WETH position — 7%
   smaller, no spare WETH held back for a re-arm). All functional
   parameters (faucet 0.02, billing 0.005, reserve 1,000 mUSDC, reactive
   funding 2.0 lREACT ≥ 1.5) match the runbook.
2. **Bridge mechanics:** the publicnode RPC's gas estimator reverts on
   the bridge's receive path and its default fee suggestion exceeded the
   wallet's upfront balance at a 700k gas limit; the deposit was sent
   with explicit gas limit 700,000 and explicit EIP-1559 fees (max 0.6 /
   priority 0.55 gwei). gasUsed 634,136 — identical to phase 1's deposit,
   confirming the same route.
3. **Driver/watcher restarts:** the first driver launch inherited a shell
   without `~/.foundry/bin` on PATH (`cast` unresolved); both tools now
   export the PATH themselves and were relaunched before any sync was
   due — no emission missed (adapter `lastPrice` verified unchanged
   across the restart). A runtime restart of the agent environment later
   killed both background processes (~13:19Z, after emission #3 and the
   first Decision were captured); relaunched 13:21Z for the remainder of
   the window. The on-chain record is continuous; only the off-chain poke
   cadence had a ~2-minute gap, which the heartbeat semantics absorb.
4. Demo A trio, the old reactive (0.3371809 lREACT) and all phase-1/A
   evidence are untouched; reactive #2 is an additional deployment, not
   a replacement.

## Trio #4 — repair release (2026-11-19)

Ordered after the 73-test adversarial pass documented two contract-level
weaknesses and one model limitation. Full record: TRIO4.md.

**Repairs shipped** in `src/SentinelReactiveV3.sol` (V2 sources
untouched): (1) replay dedup — log-identity mapping
(`keccak256(chainId, contract, txHash, logIndex)`), `duplicatesIgnored`
counter; (2) TRIM suppression — 10 updates after a TRIM fire, bypass on
EXIT conditions (anchorDD ≥ 18% + negative momentum), EXIT never
suppressed, `TrimSuppressed` event. 20 new tests (12 V3 + 7 adversarial
re-pins + 1 end-to-end) → **93/93**.

**Model v3 DESCOPED.** Diagnosis: teacher labels the recovery path
correctly (TRIM from step 1); the v2 model underfits it. Three retrains
with fresh-peak decline families + recovery anchors: attempts 2–3 hit
recovery step 1 but held-out fidelity fell to 93.6–94.2% vs the 95.41%
gate (attempt 1: step 5, 95.05%). Per the work order's rule the model
was not shipped; trio #4 runs v2 weights; the blind window stays a
documented limitation (pinned by adversarial case (e) and re-measured
live: HOLD ×7, EXIT at step 8). Failed v3 weight artifacts deleted;
training code retained (`tools/train.py` v3 section,
`tools/backtest_v3.py`).

**Funding.** User sent 1 Sepolia ETH to the dev wallet; faucet round
tx `0x87711812…` (0.02 ETH → ~2.1 lREACT); bridge tx `0x833539a2…`
(0.01 ETH Sepolia → Base Sepolia via L1StandardBridge
`0xfd0Bf71F…`, method confirmed from the official Base docs).

**Deployments** (all Sourcify exact_match): reactive #4
`0xcE8615E0…d2AA3` (Lasna, 1.05 lREACT), swap #4 `0xfc25B4e4…Bf05`,
vault #4 `0xBd5d3146…9d06` (0.0001 WETH position); rehearsal trio #4R:
oracle `0xA9aCa385…f63a`, reactive `0xC497213a…52B8` (1.10 lREACT),
swap `0x05111b77…B4B5`, vault `0x57298806…50d3` (0.0002 WETH).
Tooling note: this Foundry (1.9.0) needs `--broadcast` on `forge
create`; two non-broadcast invocations deployed nothing (verified via
unchanged nonce/balance) and were re-run correctly.

**Live proof.** Rehearsal (`tools/rehearse_v3.sh`, 27 pushes): calm
HOLDs; −2% bleed → TRIM (cb `0x2ec7cb8b…`), 7 `TrimSuppressed` events,
EXIT (cb `0x4a27b310…`); re-arm; recovery TRIM at $83.70 (cb
`0x3d9c60e5…` — deviation from the mirror's 14-push-bleed simulation,
inside the teacher's anchor-TRIM band, recorded in TRIO4.md); −3%
decline → EXIT at step 8 (cb `0x2f6c3371…`). Vault mUSDC 0.0343135 =
exact sum of fills; protections 4; closed. Main trio: 2 real Chainlink
emissions ($1,770.91 → $1,775.53614611; syncs `0xd8303e1d…`,
`0x401ed273…`; reacts `0xd5262af6…`, `0xd590c8d6…`), anchor re-anchored
to the wei, HOLD. Trio #3 ingested the same emissions (1.46745 lREACT
after). Fuel after: R4 1.010342, R4R 0.1856625 lREACT; dev 0.2296481
lREACT / 0.950149 Sepolia ETH / 0.0093168 Base Sepolia ETH.
