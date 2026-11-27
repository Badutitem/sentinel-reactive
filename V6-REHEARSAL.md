# Release 6 — Brain V6 rehearsal record

Parallel rehearsal set for the AH-2..AH-6 fixes (design: `V6-DESIGN.md`).
Mock oracle, NOT the flagship. The flagship set (brain
`0x162DdFa4…`, vault `0xD61E27bC…`) was never touched — verified
updates 1 / shares 2e15 before and after every leg.

## 1. The set

| Role | Contract | Address | Sourcify |
|---|---|---|---|
| Oracle | MockPriceOracle | `0x94244819916102Db22FbA4f58542055dF3E37f55` | exact_match, matchId 60066448 |
| Swap | SentinelSwapV3 | `0x4Fc177121BD477F97291246D1EB06503ed84c10B` | exact_match, matchId 60066528 |
| Brain | SentinelReactiveV6 | `0x66d7bd3e11cE7934ED425b0E7df23Ed7e39a79B4` | exact_match, matchId 60066535 |
| Vault | SentinelVaultV6 | `0xbA9ed52D3a4A4Cb20EFD2BC9Fc60742CeB7683F6` | exact_match, matchId 60066537 |

Deployed 2026-11-27 10:58–10:59 UTC (`tools/deploy_release6.sh`,
log `hidden_files/release6-deploy.log`). All in-script gates passed.
Deploy txs: oracle
`0xaa27a2fed5e1a255e10e5730d09d3063c62ed1833b4e59d83b141f5906f1b95e`,
swap
`0xc4b6d88c56872b71b541f08785b0804ac3b29c58b08a0a3e83d4065db5cc5d92`,
brain
`0x18268d95e26808fecf266f5f83cb964e516d94be110dc798c86576a129d58ba3`
(2.20 lREACT attached), vault
`0x844252b982a0abb2badc328b0d683d55464801769ce1ef84fd9104cdb2593807`.
Wiring: swap.setVault
`0xed30ef6784f369309bffb49f3ab1bf5997925bb3b367d162d25ea668df187980`,
reactive.setVault
`0x28c4291fd823c63d1f036fac4b2908fa38a397b17c8b6c40eb96d9102512fb26`,
oracle.allowPusher(pusher)
`0xd7295bbf661101e713be1fd4ad7ff15395a7846eec59e6945a96252bac75c926`.
Desk seeded 1,000 mUSDC
(`0x86ab5f3f46a4304143bd3213b38021dd0e7eb144b7c94dafebc6802261e3886e`),
vault billing 0.0001 ETH
(`0x150630a72c88c168e3797c63fcc2477110b794e9f02f382ba5b9d942e07c8ef5`).

Faucet round 1 (deploy gate): 0.02 Sepolia ETH,
`0x50993da8a1401b2f42b6ad347fa52f42e782a26761c7f26af811e3cb1f5cc20f`
— dev Lasna 1.8146 -> 3.9146 lREACT.

Dedicated pusher key (AH-5 separation): address
`0x82cFCFe9e33772D971c4e19870325fD311c12c5f`. Private key ONLY in
goal `hidden_files/v6-pusher.env` (mode 600). All 104 rehearsal
pushes (June 56 + bleed 40 + crash 8) were sent with the pusher key;
the dev key never pushed a price in this run. Burner top-ups from
dev (all status 1): A +0.003
`0x6b311c5869f500350930ef0e637277cd9d4969aee21aef8b25ea727d8b237311`,
B +0.002
`0xc1f94d723fece54518ecaeeedee9c245e21fcc6297177ba6da8212b2497c561b`,
C +0.0015
`0xe7da9c7f1ba277e9e8f57c61761597fc2147396ea1557a3b888cf237d41f30d7`,
pusher +0.005
`0x15273d8f595e672a9b37bab9de47b6f76d61c990f73d03f0cd5cb37ecd04b685`.

## 2. June core — 56 pushes, mirror-exact (PASS)

Driver `tools/rehearse_release6.sh`, log
`hidden_files/release6-driver.log`, push table
`hidden_files/release6-push-table.md` (56 rows). June 2022 crash,
klines 120–175, $1,679.28 -> $1,283.46.

Fires: TRIM@9 ($1,578.19), TRIM@21 ($1,523.34), TRIM@32 ($1,471.26),
TRIM@44 ($1,479.59), TRIM@55 ($1,324.35), EXIT@56 ($1,283.46).
Votes H/T/E 18/35/1, 30 TrimSuppressed, 0 cooldown blocks.
Deposits (public flow): A 0.003 WETH, B 0.002 WETH, C 0.0015 WETH.
A partial redeem at update 32: 0.000175 WETH + 1.2640965 mUSDC
(`0x903177e70000b34e4272e77c935c20e2271339c5c48e7c0ab67c9a53afd24c67`).
Final redemptions (receipt Transfer logs, exact to the wei):
A = B = 2.926934955370680890 mUSDC, C = 2.132596839258638220 mUSDC
(A `0x02cf2e52d0575e00868341bb521abda9a5f9d981572435e0c7f0e41e6305f1a0`,
B `0xab5e425c801e1804d0ed24b41cd776585b5552ca012c9996b4b22dd69d594ba5`,
C `0x0be6c0b2c0d617dc7b840274936e9956713af23ccc5c9ee6fe2471c7cc81fd8b`).
Conservation: WETH users 0.000175 + desk 0.006325 = 0.0065; mUSDC
users 9.25056325 + desk 990.74943675 = 1,000. End state: shares 0,
managed 0/0, closed true, prot 6.

Independent Lasna verification (script
`hidden_files/release6-june-verify-logs.py`, 13/13 PASS): 56
PriceSeen (prices == klines x1e10 in order), 54 Decisions matching
the mirror, 30 TrimSuppressed, 6 CallbackRequested (5x TRIM then
1x EXIT), 6 EpisodeOpened with anchors matching the mirror to the
wei, 0 EpisodeCancelled, 56 unique reaction txs.
June fuel: brain 2.20 -> 0.2455827 lREACT = 1.9544173 burned
(R8 June was 1.947808 — V6 is +0.3%, within gas variance).

## 3. Bleed leg (AH-2) — 40 pushes, 0 callbacks (PASS)

Driver `tools/rehearse_release6_bleed.sh`, log
`hidden_files/release6-bleed.log`. Entry: brain 0.2455827 lREACT
— under the 1.50 gate, so faucet round 2 ran first: 0.02 Sepolia
ETH (`0xd35ccbfd3b79027939a6dd9bf70917ba58de64fd278516de0be01243faf18c3f`),
attach 2.1 lREACT
(`0x2cabdf58a75dbae1660205f79ed77ec3122ed405974735d5621c9543e24a4a08`),
brain -> 2.3455827 lREACT.

40 pushes, -1% per update from $1,283.46 to $858.60, updates 57–96.
**Every one of the 40 votes was EXIT (action 2); protectionCount
stayed 6 the whole leg — 0 bleed callbacks.** Brain 2.3455827 ->
1.0349879 lREACT = 1.3105948 burned.

Independent Lasna check: 94 Decisions total (54 June + 40 bleed);
the last 40 are all EXIT; CallbackRequested still 6; exactly one
PostExitLatch event (true, update 56) — set at June's EXIT, never
cleared during the bleed.

**Correction to the design:** §3 predicted 3 bleed callbacks (the
fresh-brain H12 shape: 2 TRIM + 1 EXIT). On the post-June brain the
June episode anchor (~$1,594) carries over, so the bleed votes EXIT
from push 1 and the latch suppresses all 40. 0 is the correct
outcome — the vault was closed and empty, there was nothing to
protect — and it is strictly better than the predicted 3. The
bleed script aborted on the stale "9" assertion and was corrected
to 6; the design addendum (§8 of V6-DESIGN.md) records this.

**AH-2 before/after (the number the task asked for):**

| | V5 (attacker-hunt H12) | V6 (live bleed) |
|---|---|---|
| Callbacks over 40 bleed updates | 20 (2 TRIM + 18 EXIT) | 0 |
| Fuel burned by the bleed leg | ~2.16 lREACT | 1.3105948 lREACT |
| Fuel saving | — | -39% |

Honest decomposition: the saving is the callback spend going to
zero. The 40 reactions themselves still cost ~1.31 lREACT and no
suppression can avoid that — that is the floor the design records
(§6 residual risk 1). On a fresh brain (forge H12) the same fix
gives 3 callbacks instead of 20.

## 4. Attack re-runs (AH-3, AH-4, AH-6 live; AH-5 via the recovery leg)

Script `tools/attack_release6_post.sh`, log
`hidden_files/release6-attacks-post.log`. Entry: updates 96,
lastAction 2, exitLatched true, vault closed, shares 0, prot 6.

**AH-3 — 1-wei print: BLOCKED.** Stranger push reverts
`NotPusher` in eth_call (selector 0x31d7f16e) and on-chain tx
`0x6c8e4e71833c6dd29cbfc014b8ecbf0ac30e2184ebe63d69caf3d021ab0ff9f7`
status 0x0. Dev pushed 1 wei
(`0x81383231258c3c625935ad89b1ee1e2728477e4e13fc6ea04d6fbe9ba70ed87f`):
45 s later brain updates still 96, prot still 6 — poison consumed,
never ingested. Sane follow-up (bleed-close price
`0x6f9bd6d6095553f7aae1336feb238196032aa795c8cde48440bbe985769d84e6`):
brain advanced to 97, lastAction 2 (vote latch-suppressed), prot
still 6 — BRAIN ALIVE.

**AH-4 — 2^200 price: BLOCKED.** Dev pushed 2^200
(`0x4562fc3bd3b9a324a04cfd4dfae69c466af8a2578df9951b6253887e8ca7b643`):
45 s later brain updates still 97 — absurd price consumed, never
ingested. Both swap directions from the vault return 0 +
`InsanePriceRefused` at 2^200 (no revert, no fill). Vault managed
totals still 0/0. Sane follow-up
(`0x5900f823c77fde3fecd5b0ba6d7ab4dd04d663df51689cc64add35a5f9a773e5`):
brain advanced to 98, prot still 6 — BRAIN ALIVE.

**AH-5 — band: see §5 (recovery leg).** The attack script's AH-5
section aborted here, for a diagnosed reason: on the post-June
vault managedSafe == 0, so the band guard correctly does not engage
— the +21% deposit reverted for missing allowance (the anchor
deposit had consumed it), not for PriceDeviation. The live band
proof moved to the recovery leg, which rebuilt a mixed pool first.

**AH-6 — setVault redirection: BLOCKED (run standalone after the
attack script aborted at AH-5).** Owner `setVault(attacker)`
reverts `VaultAlreadySet(0xbA9ed52D3a4A4Cb20EFD2BC9Fc60742CeB7683F6)`
in eth_call on both contracts, and on-chain both txs landed
status 0x0: swap
`0x4238ab4969f945a57f12a872be4260094eb1ee03aa955cb872380a8017dd6914`,
brain
`0x4fbebdada807b2263e3e1ec29e037c13c14d23519a022626f46839089dfb1378`.
Wiring unchanged (both vaults still the V6 vault), both
`vaultLocked` true.

## 5. Recovery leg — latch clears live, band gates live deposits (PASS)

Driver `tools/rehearse_release6_recovery.sh`, log
`hidden_files/release6-recovery.log`. Two things happened
organically during the AH-5 attack that changed this leg's entry:

- The AH-5 anchor push ($1,283.46) was ingested as update 99.
- The AH-5 +21% push ($1,552.99) was ingested as update 100 and
  **fired tranche-1**: $1,552.99 >= 97% of the June episode anchor
  ($1,546.14). Latch cleared live, reriskCount 0->1, prot 6->7
  (RERISK callback executed; spend 0 on the empty vault, no fill).
  The recovery leg's Phase R was therefore skipped; the leg started
  at Phase D with the latch already proven cleared on-chain.

Phase D: dev topped the position up +0.0009 WETH (total 0.001 WETH,
`0x035cdf62b7af1e5284c365ab7555d8f16e86280d201e89dcddc9c3b64e0241a3`).
Phase C: crash -2%/update from $1,552.99; push 8 (update 108)
voted TRIM and fired (prot 7->8): managedRisk 0.0005 WETH,
managedSafe 0.660611786922505220 mUSDC, anchor $1,321.22, vault
open. Mixed pool rebuilt.
Phase B (live band test, anchor $1,321.22): +21% deposit reverts
`PriceDeviation` in eth_call (selector 0xa9a9c04c) AND on-chain tx
`0xbe2fd9e5bca31d430466870ef2fd993ef93116ce2a4e8678e8765e52d0347d3d`
status 0x0 — BLOCKED. Exactly +20% deposit SUCCEEDS (boundary
inclusive, `0x25b5000cad366c0e790599062469c7a7aefd22593cb8fd655978d4945aa374e4`).
redeemAll resets the vault to empty
(`0xa075a7b6a0637d4c9b3622b8fba6c7d280feb6addb84d9c89210d79a748900db`).

Recovery leg fuel: brain 0.8632567 -> 0.5120516 lREACT = 0.3512051
burned (8 crash + 2 band-test reactions + 1 TRIM callback).
Final state: updates 110, lastAction 0 (HOLD), exitLatched false,
reriskCount 1, protectionCount 8, vault shares 0 / managed 0/0.

## 6. Gate 2 — tests (recap)

Full suite **219/219 green, 29 suites, 0 failed** (205 baseline +
14 new in `test/Release6Regression.t.sol`). The 14 fail on V5 code
(verified by running the AttackerHunt PoCs: H12 20 callbacks,
1-wei EXIT, 2^200 brick, pump +12.5% / dump -24.3% / walk +41.2%,
setVault redirection works) and pass on V6:

| Fix | V5 (old) | V6 (new) |
|---|---|---|
| AH-2 bleed, 40 updates | 20 callbacks | 3 callbacks (fresh brain) / 0 (post-June brain, live) |
| AH-3 1-wei print | EXIT, 10 WETH -> 10 wei mUSDC | consumed, never ingested; $1 boundary ingests |
| AH-4 2^200 price | callback reverts, position unprotected | fill refused (0 + InsanePriceRefused), brain alive |
| AH-5a pump +20% | +12.5% theft | +5.88% (5.294117647058823528 on 5.0 in) |
| AH-5b dump -20% | -24.3% victim loss | -7.69% (4.615384615384615383 on 5.0 in) |
| AH-5c walk 12x20% | +41.2% (walked 129.7x) | +33.6% (8.286116313305057708 on 6.2 in; walked 8.9x) |
| AH-5 band edge | — | +21% reverts, +20% passes (both directions) |
| AH-6 setVault | redirection works | reverts VaultAlreadySet on both contracts |

Honest note on AH-5c: the first bound (< 5.5) was wrong, not the
code — the theft saturates because the final deposit dominates; the
band slows the walk (~25 steps to ~100x) but does not crush it at
12 steps. Recorded as design §6 residual risk 4.

## 7. Spend (whole V6 run)

- Sepolia ETH: **0.04** (2 faucet rounds x 0.02).
- lREACT: **3.7879484 consumed** (attached 2.20 + 2.10 = 4.30;
  0.5120516 remains on the V6 brain). Breakdown: June 1.9544173,
  bleed 1.3105948, attacks (updates 97–100) 0.1717312, recovery leg
  0.3512051.
- Base ETH: **~0.0126 net** (dev top-ups 0.0115 + gas across dev,
  pusher, burners; pusher pushed 104 prices for ~0.0000223 gas).
- Lasna gas: **~0.20 lREACT** (V6 deploy dominates).

## 8. What the rehearsal set is now

A completed demonstration set, like R7/R8: brain updates 110,
protectionCount 8, reriskCount 1, latch false, vault empty and
open, brain balance 0.5120516 lREACT. It is NOT a live system and
was never pointed at by the app, Live Proof, or MCP.

## 9. Residual risks (unchanged from V6-DESIGN.md §6, plus two live notes)

1. React spend is the AH-2 floor (~1.31 lREACT per 40-hour bleed);
   funding must cover reacts, not just callbacks.
2. Sawtooth markets can cost one EXIT + two re-risk callbacks per
   recovery-crash cycle (genuine protection work).
3. The $1 floor is scale-dependent (18-decimal USD only).
4. The 20% band is a speed bump (compromised pusher + ~25 settled
   deposits can still walk ~100x).
5. Single-EOA owner remains (lock removes redirection only).
6. Latch vs a re-armed vault: one withheld vote per latched period
   at worst, never a permanent blind spot.
7. **Live note:** the bleed's 0-callback result depends on the
   episode anchor carrying over from June. On a fresh brain the same
   bleed gives 3 callbacks (forge H12) — the latch bounds the
   damage either way, but the exact count is state-dependent.
8. **Live note:** the AH-5 band only engages when managedSafe > 0.
   A deposit into a risk-only pool is ungated by design (nothing to
   reprice); the theft surface opens only once a fill has created
   safe balance.
