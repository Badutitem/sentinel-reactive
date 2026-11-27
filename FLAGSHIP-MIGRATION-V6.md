# Sentinel — Flagship Migration to V6

**Status: MIGRATION COMPLETE AND VERIFIED.** 27 Nov 2026, 16:01–16:12 UTC
(23:01–23:12 WIB). User approved the flagship migration to V6. Maintenance
only: no new features, no redesign, no model changes. The live flagship
position moved from the fixed-code V5 set onto a fresh set built from the
V6 code (V6-DESIGN.md fixes AH-2..AH-6). Deploy driver:
`tools/deploy_flagship_v6.sh` (adapted from `tools/deploy_flagship_fixed.sh`);
verify `tools/verify_flagship_v6.sh`. Logs: goal
`hidden_files/flagship-migration-v6-deploy.log`,
`flagship-migration-v6-verify.log`, `flagship-migration-v6.log`
(consolidated step transcript). Nothing was pushed to GitHub by this run;
no DoraHacks page was edited.

## 0. Preflight (all gates passed)

- `forge test`: **219/219, 29 suites, 0 failed** (re-run this run).
- Old flagship state re-read live before any spend: brain updates 1,
  lastAction 0, balance 2.1776106 lREACT; vault totalShares 2e15,
  managedRisk 2e15, managedSafe 0, closed false, protectionCount 0,
  billing 0.0001 ETH; dev shares 2e15; swap desk 1,000 mUSDC / 0 WETH;
  adapter lastPrice $1,728.01138712, lastEmittedAt 1795771287 (~6.6 h
  stale), params 10/60/3600/3600/1e10, feed
  `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`, WETH; feed live at
  $1,672.1871; dev Base ETH 0.022043580874645480, WETH 0.01065, mUSDC
  0.744739563809505220, Lasna 1.225458999971981644 lREACT, Sepolia ETH
  0.450115385558882778.

## 1. The old set (retired as flagship, still functional for redemption)

| Contract | Chain | Address |
|---|---|---|
| SentinelReactiveV5 (old flagship brain) | Lasna (5318007) | `0x162DdFa4dD0db9bA60c4444b9a1BD1fa6b5343A9` |
| SentinelSwapV2 (old flagship desk) | Base Sepolia (84532) | `0xe8427C91A5456a4Ee82AE033A72ac3A3Ab11A371` |
| SentinelVaultV5 (old flagship vault) | Base Sepolia (84532) | `0xD61E27bC945ceE8Bd967aA42c907e7bA6968b5e9` |
| ChainlinkPriceAdapter (old adapter) | Base Sepolia (84532) | `0xcc99348d41eec983584eE071EADC7091a895030d` |

Final state (16:12 UTC): brain updates 2, lastAction 0 (HOLD), balance
**2.1603304 lREACT — STRANDED, no withdraw path by Reactive design; do
not try to recover it**. Vault totalShares **0**, managedRisk 0,
managedSafe 0, closed false. Desk 1,000 mUSDC / 0 WETH. Old adapter
lastEmittedAt 1795795297, lastPrice $1,669.62997167. The old brain keeps
its subscription to the old adapter and will keep reacting on stranded
fuel; its callbacks hit the drained old vault and no-op.

## 2. The new set (live flagship, V6 code)

| Contract | Chain | Address | Deploy tx | Sourcify matchId |
|---|---|---|---|---|
| ChainlinkPriceAdapter (fresh, heartbeat 3600 — AH-1) | Base Sepolia | `0x9d48DA37bd27B261753b2E39602E4bF4E77Db890` | `0x6cf97b6fd17998dbdd808d9432210da10e63ee5c9dddac9d49707556b573984a` | 60083429 |
| SentinelSwapV3 | Base Sepolia | `0x77478B3b48F5C05b59BE5F2EA421F02550CD1958` | `0x506d94f14bca0ef37ea118568c0e5c6160304f9f87501c1837b70342afd77310` | 60083430 |
| SentinelReactiveV6 (new flagship brain, 2.20 lREACT attached) | Lasna | `0x155a8bA966fd179980c4BeB21354D908bBbB356f` | `0x0f1c281821c996b9b78170a1fcfe180ba2e15a9c4b627bb3ab594934baa0a23a` | 60083432 |
| SentinelVaultV6 | Base Sepolia | `0xB6afd71a0c87c43aA02C3256F89e54044c537192` | `0xc6201ef1eb2e464703fd811e89b019407254ddd18a33cd602220629b0fefed08` | 60083435 |

All four Sourcify **exact_match (creation + runtime)**, verified
independently against the v2 API (not just forge's accept). Reused shared
contracts: WETH `0x4200000000000000000000000000000000000006`, MockUSDC
`0x96E467Ff7958851d307D28118EBAAD333CAb85B2`, callback proxy
`0x476F44b11F5C942c58f4c8E3d0300E5710743585` (same as the old flagship).
No mock oracle anywhere in this set (Chainlink origin throughout).

Wiring (all read back after deploy, all in-set): brain oracle = fresh
adapter, brain vault = new vault; vault swap = new swap, vault
`_CALLBACK_SENDER` = new brain; swap priceSource = fresh adapter, swap
vault = new vault; `vaultLocked` true on brain + swap (AH-6 single-use).
Wiring txs: swap.setVault
`0xe008280e73191b9f5df7d05b1f1e02d726eabf6d2e0507915837d18f14bda1d7`,
reactive.setVault
`0x43890aa378b61bc4f2271689a5daa31e13fe27c4498b636ec89c149d43e7f386`.
Desk seeded exactly 1,000 mUSDC (mint
`0xbf3fc747d4ffa26d4e599dacf4da4a37179fffc495c1586bea22523a686d9375`);
vault billing funded 0.0001 ETH
(`0xd400426c8e92be4219fd77c618ea1d1db0b84d1e0a7eac58290c479242818596`).

Fresh adapter params read back after deploy: feed
`0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`, token WETH, deadbandBps 10,
minInterval 60, **heartbeat 3600**, maxStaleness 3600, priceScaleFactor
1e10; lastPrice 0 / lastEmittedAt 0 at birth; `priceUpdatedAt(WETH)` 0 at
birth. Swap read-backs: MIN_SANE_PRICE 1e18, MAX_SANE_PRICE
1_000_000e18, MAX_PRICE_AGE 3600, `priceStale()` true pre-sync. Vault
read-back: MAX_DEPOSIT_DEVIATION_BPS 2000. Brain read-backs at birth:
`exitLatched()` false, `vaultLocked()` false pre-wiring.

## 3. Step (a) — fresh sync on the OLD adapter first

Sync tx `0xf2807fc26b1173086c6938584c5456919f3eab2cf78d7815d777521fc069f637`
(16:01:51 UTC, previewed via eth_call first, no revert): emission
landed, lastEmittedAt 1795771287 → 1795795297, lastPrice
$1,728.01138712 → **$1,669.62997167** (live Chainlink round; ETH down
~3.4% since the last emission). Old brain ingested it: updates 1 →
**2**, lastAction **0 (HOLD — the 3.4% drop did not trip a TRIM; the
warm-up/anchor logic held, as designed)**, balance 2.1776106 →
2.1603304 (one react cost 0.0172802). Old vault untouched by the sync:
totalShares 2e15, managedRisk 2e15, managedSafe 0, protectionCount 0.
Gate passed; funds moved only after this read. The redeem mix after
this sync stayed all-risk (0.002 WETH, 0 mUSDC).

## 4. Step (b) — funding + deploy

Dev Lasna was 1.2254590 — below the 2.40 gate. ONE faucet round:
`request(dev)` on `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` with 0.02
Sepolia ETH (tx
`0x5cd02ac31e95e7737a4219aefadc13c9322ffccb2ba328cce8dc6089b4a5f4c6`,
16:02:13 UTC): **+2.1 lREACT exact**, dev Lasna 1.225458999971981644 →
3.325458999971981644; dev Sepolia 0.450115385558882778 →
0.430115131278603070. Gate passed with margin 0.9255. Note: the
eth_call preview of `request()` reverted ("Just no") because the
preview carried no value — the faucet requires the 0.02 ETH with the
call; the funded send itself succeeded (status 0x1). Recorded, not
hidden.

Deploy 16:02:44–16:04:40 UTC (see §2 for addresses/txs). New brain
attached exactly **2.20 lREACT** at creation (balance read 2.20 exact).
Deploy gas from dev Lasna ≈ 0.1921 lREACT (dev Lasna after deploy
0.933359599970060650). R7/R8/live-V6 sets verified untouched before AND
after every step: R7 brain updates 56, R8 brain updates 57, live-V6
brain updates 56, all vaults 0.

## 5. Step (c) — redeem the old flagship in full (pro-rata, to the wei)

Dev `redeemAll()` tx
`0x6e2853ec33ec7987d91c91e5f283380d8771a0f6c997abf50aa1bac235ee276b`
(16:06:53 UTC, status 0x1; eth_call preview returned 2e15 WETH / 0
mUSDC first): dev WETH 0.01065 → **0.01265 (+0.002 exact)**, dev mUSDC
unchanged (0.744739563809505220 — no mUSDC back, the vault was
all-risk). Old vault after: totalShares **0**, managedRisk 0,
managedSafe 0. Reconciliation exact to the wei: 2e15 in − 2e15 dev out
= 0 left.

**Correction to the brief, recorded honestly:** the brief said the old
vault should retain 3e14 shares of the filming burner (0x7abd…).
Live reads prove otherwise — this vault never held them: pre-redeem
totalShares was exactly 2e15 = dev shares, and `sharesOf(0x7abd…)` in
this vault reads 0. The 3e14 burner shares live in the STILL-EARLIER
flagship vault `0x108513e6439664fdeE9050e1ccc208e8c1b61441`
(totalShares 3e14, `sharesOf(0x7abd…)` 3e14 — verified live this run),
from the previous migration. Nothing was attempted for that address;
the 0.0003 stays there, redeemable by its holder at any time.

## 6. Step (d) — sync the fresh adapter, then seed through the public flow

Critical order held: the fresh adapter was synced FIRST (its
lastEmittedAt was 0; the new swap read `priceStale() == true` and the
seed deposit would have reverted `StalePrice` before then). Sync tx
`0x8b28837ddfbc61aed415ed7c38661816da6c1097c92161bb2d52be3ba0f4db09`
(16:07:43 UTC): emission landed, lastEmittedAt 0 → **1795795648**,
lastPrice 0 → **$1,669.62997167** (same live feed round as the old
sync, consistent); new swap `priceStale()` true → **false**. Only then
the seed:

- Wrap 0.002 ETH → `0xc13ec3ed59d7d6ddc57533e75dfdd6599af18c2b1e4fcb101963815ba65deb1e`
- Approve exact → `0xaee9c5e833df3ef96558594e4327115e84ed9bf67522b675993c5f8a4d3119e4`
- Deposit → `0x575884b9a75c40a88e24a9bfa9f42c281dd10917c000afaa0b6f0da79fd2b0c9`

Read back: sharesOf(dev) **2e15 (exactly 1:1)**, totalShares 2e15,
managedRisk 2e15, managedSafe 0, closed false, billing 0.0001 ETH; desk
1,000 mUSDC / 0 WETH; swap `priceStale() == false`. New brain:
**updates 1, lastAction 0 (HOLD)**, balance 2.1776105 lREACT.

Two brief-wording corrections, recorded honestly (the numbers, not the
brief, are the authority):
- The brief's step-(d) verify said "new brain updates 0". The brain
  necessarily ingests the required pre-seed sync emission (its
  subscription was live from deploy), so **updates 1, lastAction 0** is
  the correct post-sync state — warm-up HOLD on a single price, exactly
  as the previous migration read updates 1 / HOLD after its first
  window.
- First-react cost on the new brain: 0.0223895 (2.20 − 2.1776105).
  Deploy gas (~0.1921 lREACT) was paid from **dev Lasna**, not from the
  brain.

## 7. Fuel math

- Attached 2.20 lREACT; measured burn 0.0295521/reaction → runway at
  attach ≈ **74 reactions**. Remaining after react #1: 2.1776105 /
  0.0295521 ≈ **73.7 reactions**.
- First-react cost on the new brain: 0.0223895 (warm-up, no callback —
  below the 0.0295521 average, which includes callbacks).
- The liveness watch alarms on low brain fuel (below one firing cycle,
  0.08 lREACT) and on `priceStale() == true` / adapter age > 3600 s.
- Old brain stranded total grows: 2.1603304 lREACT joins the stranded
  total (previously ~11.5287155 on the V5 brain + ~1.1635 across older
  retired brains; the step-(a) react spent 0.0172802 first).

## 8. Spend (this migration)

- Sepolia ETH: **0.02** faucet + ~0.00000025 gas (dev Sepolia
  0.450115385558882778 → 0.430115131278603070).
- Base Sepolia ETH: **~0.0021248 gross** (dev 0.022043580874645480 →
  0.019918760446845059) — of which 0.002 WETH is now the dev seed in
  the vault (shares 2e15) and 0.0001 ETH is the vault billing fund;
  net gas ~0.0000248 ETH.
- Lasna lREACT: **2.20 attached** to the brain + **~0.1921 deploy
  gas** (dev Lasna 1.2254590 + 2.1 faucet − 2.20 attach − 0.1921 gas =
  0.9333596). Brain holds 2.1776105 lREACT after its first react.
- Dev WETH after: 0.01265 (0.01065 + 0.002 redeemed − 0.002 seeded via
  wrap/deposit; the wrap/deposit legs net to zero on WETH).

## 9. Final re-audit on the new flagship set

- **F1 (mock oracle) — N/A, verified live:** the new brain's
  `oracle()` reads back as the fresh Chainlink adapter (live read); no
  mock oracle exists anywhere in the set. Unit proofs in the suite
  (`test/Release8Regression.t.sol`):
  `testF1_StrangerCannotPushPrice`,
  `testF1_PumpedPriceCannotStealViaDeposit`,
  `testF1_DeviationGuardTripsAt60PassesAt40`.
- **F2 (stale fill) — PROVEN at code level + on identical code live:**
  unit proofs `testF2_StalePriceRefusesFill`,
  `testF2_StalePriceRevertsDeposit`, `testF2_NeverPushedIsStale`,
  `testF2_FreshPriceStillFills`; live proof on the R8 live set (same
  code) 27 Nov 08:37–08:39 UTC — both swap directions refused at
  priceAge 3896 s. On the NEW set the wiring is verified live
  (`priceSource` = fresh adapter, `priceUpdatedAt` answers,
  `priceStale() == false`); a live stale-fill test on the new set
  itself was NOT run — it would need a callback (vault-gated) or a
  3600 s unsynced wait, and no EXIT was fired on the new brain for
  this. Stated plainly, not assumed.
- **F3 (repeat EXIT) — PROVEN by unit test, not by live firing:**
  `testF3_RepeatExitIsCooldownGated` (12 callbacks → 2),
  `testF3_ExitFiresAgainAfterCooldown`,
  `testL3_CooldownStillGatesAfterReset`. No EXIT was fired on the new
  flagship brain (updates 1, lastAction 0 HOLD).
- **F4 (zero price brick) — PROVEN by source + unit test:** the
  adapter's `sync()` returns silently on `answer <= 0`; the brain's
  `react()` consumes but ignores `price == 0`;
  `testF4_ZeroPriceIgnoredBrainKeepsWorking`,
  `testF4_ZeroFirstPriceIsIgnored`. No zero round exists on the live
  feed to test against (feed live at ~$1,670) — stated, not assumed.
- **F5 —** `testF5_UnknownActionReverts` (suite green).
- **AH-2 (post-EXIT latch) — PROVEN by unit test + live on identical
  code, NOT by live firing on this set:**
  `testAH2_BleedCallbacksCollapse` (20 → 3 callbacks),
  `testAH2_LatchClearsOnTranche1AndFreshExitProtects`,
  `testAH2_LatchClearsOnTranche2AndFreshTrimFires`,
  `testAH2_SuppressedExitVotesStillDecide`. Live on the V6 live set
  (identical code): bleed leg 0 callbacks, latch fired at EXIT@56
  (`PostExitLatch(true, 56)` in the Lasna logs, V6-DRIVE.md). On THIS
  set the latch state reads `exitLatched() == false` (no EXIT yet) —
  the latch mechanism itself was not fired live here. Stated plainly.
- **AH-3 (sane-price floor) — PROVEN by unit test + live on identical
  code:** `testAH3_OneWeiPriceConsumedNotIngested`,
  `testAH3_SwapRefusesSubDollarFill`; live on the V6 live set the
  1-wei push was consumed without ingesting. On THIS set the bounds
  read back live (`MIN_SANE_PRICE` 1e18, `MAX_SANE_PRICE`
  1_000_000e18) but no sub-dollar print was pushed live here.
- **AH-4 (absurd price) — PROVEN by unit test + live on identical
  code:** `testAH4_AbsurdPriceCannotBrickCallback`; live on the V6
  live set the 2^200 price returned 0 with `InsanePriceRefused`, no
  revert. On THIS set the bound reads back live; no absurd print was
  pushed live here.
- **AH-5 (20% deposit band) — PROVEN by unit test + live on identical
  code:** `testAH5_Pump20PercentTheftIsSmall`,
  `testAH5_Dump20PercentVictimLossIsSmall`,
  `testAH5_Walk12StepsTheftIsSmall`,
  `testAH5_BandEdgeRevertsBeyond20Percent`; live on the V6 live set
  +21% reverts `PriceDeviation`, +20% passes (V6-DESIGN.md §8). On
  THIS set the band reads back live (2000 bps); the seed deposit
  landed at deviation 0 (settled price = just-synced live price).
- **AH-6 (single-use wiring) — PROVEN live on THIS set by read-back:**
  `vaultLocked() == true` on brain + swap after the single wiring;
  `testAH6_SetVaultSecondCallReverts`,
  `testAH6_RedirectionAttemptKeepsProtection` in the suite. A second
  `setVault` call was NOT attempted live on this set (it would revert
  by design; the unit test proves the revert).
- **`forge test`: 219/219, 29 suites, 0 failed** (re-run by this run).
- **Sourcify: all four new contracts exact_match** — independently
  re-verified via the v2 API this run (adapter 60083429, swap 60083430,
  brain 60083432, vault 60083435).
- **Old flagship set drained:** dev redeemed 0.002 to the wei; old
  vault holds 0; old brain's 2.1603304 lREACT is stranded testnet
  fuel (no withdraw path — not attempted).

## 10. Repoint (local files only — NOT pushed; the parent pushes after review)

| File | Change |
|---|---|
| `docs/index.html` | Brain/vault headings + `R5`/`V5`/`S5` consts → new V6 set; `R5_DEPLOY` 9365765 → `R6_DEPLOY` 9388176, `V5_DEPLOY` 64246191 → `V6_DEPLOY` 64367922; test row 205/205 → 219/219; "previous flagship (Release 6, the pre-fix contracts)" → "(fixed-code V5, migrated 27 Nov 09:13 UTC)". Rehearsal entries (R5R/V5R, V5 code) kept their V5 names. JS `node --check` OK. Old flagship addresses 0×, new 5×. |
| `docs/app.html` | `VAULT`/`SWAP` consts + both display addresses → new set; headings V5 → V6. JS `node --check` OK. Old flagship addresses 0×, new 4×. |
| `docs/agent.json` | Brain/vault/swap/adapter → new set (address + explorer + Sourcify links each); names V5/V2 → V6/V3; `sentinel_verify` description "(fixed-code set, migrated 27 Nov 2026)" → "(V6 set, migrated 27 Nov 2026)"; version 1.2.0 → 1.3.0. Valid JSON. Old flagship addresses 0×, new 12× (address + explorer + Sourcify per contract). |
| `agent/server.mjs` | `R5`/`V5`/`S5` consts + deploy blocks → new set; version 1.2.0 → 1.3.0; `sentinel_verify` comment "three flagship contracts" → "four flagship contracts". `node --check` OK. Old flagship addresses 0×, new 3×. |
| `README.md` | Flagship table → new 4-contract set (incl. adapter row, heartbeat 3600) + deploy txs; seed paragraph updated to the new set's facts (one emission $1,669.62997167, HOLD, 2.1776105 lREACT); heading "(2026-11-25, migrated to the fixed code 2026-11-27)" → "(…, migrated to V6 2026-11-27)"; test count 205/205 → 219/219 (table + Release 6 regression suites named). The Release 2 adapter row is HISTORY and was left alone. |

Live curl check of the GitHub Pages site is NOT possible yet — the
repointed files are local only until the parent pushes. After the push,
verify: `https://badutitem.github.io/sentinel-reactive/` and
`/app.html` return 200 with the new addresses present and the old
flagship addresses 0×. (The live site still serves the old files until
then — expected, not a failure.)

## 11. Final state summary (16:12 UTC, all live reads)

- New flagship brain 0x155a8bA9…356f: updates 1, lastAction 0, balance
  2.1776105 lREACT, exitLatched false. New vault 0xB6afd71a…7192:
  totalShares 2e15, managedRisk 2e15, managedSafe 0, closed false,
  protectionCount 0, billing 0.0001 ETH. New swap 0x77478B3b…1958: desk
  1,000 mUSDC / 0 WETH, priceStale false. Fresh adapter 0x9d48DA37…890:
  lastPrice $1,669.62997167, lastEmittedAt 1795795648, heartbeat 3600.
- Old flagship brain 0x162DdFa4…343A9: updates 2, lastAction 0, balance
  2.1603304 (stranded). Old vault 0xD61E27bC…b5e9: totalShares 0,
  managedRisk 0, managedSafe 0. Old adapter 0xcc99348d…030d: lastPrice
  $1,669.62997167, lastEmittedAt 1795795297.
- R7 live: brain updates 56, vault 0 — untouched. R8 live: brain
  updates 57, vault 0 — untouched. V6 live: brain updates 56, vault 0
  — untouched.
- Dev final: Base ETH 0.019918760446845059, WETH 0.01265, Lasna
  0.933359599970060650 lREACT, Sepolia ETH 0.430115131278603070.

## 12. What remains open (needs the user's separate word)

- **GitHub push** of the repointed files + this record + the new driver
  scripts (`tools/deploy_flagship_v6.sh`, `tools/verify_flagship_v6.sh`)
  — NOT done by this run.
- **DoraHacks edit** — NOT touched. The page still shows the old (V5)
  flagship set + 205/205; it needs the new V6 set + 219/219.
- **Watch repoint (for the parent):** the `sentinel-liveness-watch`
  cron must move to the new flagship set — brain
  `0x155a8bA966fd179980c4BeB21354D908bBbB356f`, vault
  `0xB6afd71a0c87c43aA02C3256F89e54044c537192`, swap
  `0x77478B3b48F5C05b59BE5F2EA421F02550CD1958`, adapter
  `0x9d48DA37bd27B261753b2E39602E4bF4E77Db890`. Tripwire: brain lREACT
  < 0.35 (existing rule). With AH-2 in mind, the watch should also
  alarm on a fast brain-balance fall, not just the absolute floor —
  the new brain holds 2.1776105 lREACT (~73.7 reactions).
- The 0.0003 filming-burner question — the shares live in vault
  `0x108513e6439664fdeE9050e1ccc208e8c1b61441` (verified live this run),
  not in the retired V5 vault; still needs the user's answer (his
  wallet, or lost burner?).
- Manual live-browser pass for the demo app (the agent cannot drive a
  live browser).
- Files changed in this run (for the parent's push): `README.md`,
  `docs/index.html`, `docs/app.html`, `docs/agent.json`,
  `agent/server.mjs`, `FLAGSHIP-MIGRATION-V6.md` (this file),
  `tools/deploy_flagship_v6.sh`, `tools/verify_flagship_v6.sh`. No
  `src/` change. Nothing pushed by this run.
