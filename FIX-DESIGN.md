# Sentinel — Release 8 Fix Design (design gate, Phase 1)

**Status:** DESIGN ONLY. Nothing is deployed, no `src/` file is edited, no
DoraHacks page is touched, nothing is pushed to git, no video is uploaded.
The patch phase implements this document exactly, then re-verifies.

**Supersession record (read first).** On 26 Nov 2026 the user froze scope:
"Release 7 = last". On **27 Nov 2026 03:25 WIB the user approved the full
fix: "Gas — perbaiki semua"**. That explicit approval **supersedes the
26 Nov scope freeze**. The fixed set is therefore a new generation named
**Release 8**, not a Release 7 patch. Release 7 stays as it is (live set
complete, vault empty, brain at 0.0528998 lREACT); Release 8 is built fresh
alongside it. No Release 7 contract is modified in place (all are immutable
anyway); no Release 7 state is reused (fresh oracle, fresh brain, fresh
vault, fresh desk).

**Sources.** `~/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/sentinel-full-audit-2026-11-27.md`
plus the four lane files in the same folder. Codebase
`~/workspace/bounty-new/reactive/project/` (`src/` + `test/`).
Suite baseline verified by this design pass: **180/180 passing**
(174 audit baseline + 6 new lead-triage tests in
`test/AuditLeads.t.sol`, see §7).

**Rules for the patch phase.** Minimal, surgical changes only. No redesigns,
no new features. The fixed set reuses production V5 code plus the patches
in this document only. Every patch below names the file, the function, the
exact new/changed lines in words precise enough to implement, the invariant
it restores, and the regression test that fails before and passes after.
Regression tests go in a NEW file, `test/Release8Regression.t.sol`.
Existing tests are NOT modified, except the retiring PoCs named in §8.

## 1. Findings with PoC — fix specs

### F1 — HIGH — Permissionless `MockPriceOracle` (deposit theft + fake-crash misfire)

**Root cause.** `MockPriceOracle.setPrice` is `external` with no access
control, and it is the single price truth for brain + desk + deposits in
every mock-origin set. The vault has no defence (no deviation band, no
staleness check), so any pushed price reprices the pool instantly.

**Fix, part A — allowlist the oracle (primary control).**
File: `src/MockPriceOracle.sol`.

1. Add storage: `address public owner;` and
   `mapping(address => bool) public pricePushers;`.
2. Add events `PusherAllowed(address indexed pusher)` and
   `PusherRevoked(address indexed pusher)`, and errors
   `error NotOwner(address caller);` and
   `error NotPusher(address caller);`.
3. Constructor: `owner = msg.sender; pricePushers[msg.sender] = true;`
   and emit `PusherAllowed(msg.sender)`. The deployer (dev wallet) is
   therefore a pusher with no driver change.
4. Add `allowPusher(address pusher_)` and `revokePusher(address pusher_)`,
   both owner-only (`if (msg.sender != owner) revert NotOwner(msg.sender);`),
   setting/clearing the mapping and emitting the matching event.
5. First line of `setPrice`: 
   `if (!pricePushers[msg.sender]) revert NotPusher(msg.sender);`.
6. Rewrite the NatSpec: delete "Anyone can push a price with `setPrice`".
   New text: pushes are restricted to allowlisted pusher addresses; the
   deployer is allowlisted at construction.

**Fix, part B — deposit-time deviation guard vs the last settled price
(defence in depth).** File: `src/SentinelVaultV5.sol`. A compromised or
fat-fingered pusher key must not be able to reprice the pool in one print.

1. Add storage `uint256 public lastSettledPrice;` (0 = no settlement yet),
   constant `uint256 public constant MAX_DEPOSIT_DEVIATION_BPS = 5000;`
   (50% band), and error
   `error PriceDeviation(uint256 price, uint256 anchor);`.
2. In `deposit()`, after the `ZeroAmount` check and only when
   `totalShares > 0 && managedSafe > 0` (the pool is mixed, so the price
   matters): read `price` from `swap.priceSource()` exactly as
   `_poolRiskEq()` does; if `lastSettledPrice != 0` and
   (`price > lastSettledPrice * 3 / 2` or
   `price * 2 < lastSettledPrice`) revert `PriceDeviation(price,
   lastSettledPrice)`. Run the F2 staleness check (§F2) before this check.
3. After a successful deposit, if `managedSafe > 0 && price > 0`, set
   `lastSettledPrice = price` (the deposit itself settles at that price).
4. In `executeProtection()`, read the reference price once before the swap
   calls; after the trade, if value actually moved (`safeIn > 0` on a
   TRIM/EXIT fill, `riskOut > 0` on a RERISK fill) and `price > 0`, set
   `lastSettledPrice = price`. A zero fill does NOT move the anchor.
5. Deliberately NO deviation guard on protection fills: a genuine crash
   exit must never be blocked by a band. The guard binds deposits only.

**Band justification.** Largest single-interval move in the June 2022
stream is under 20% (the 2000 to 1620 leg is multi-step; the largest
single hourly step is about 8%). A 50% band never trips on the June replay
or any plausible single-interval ETH move, while the F1a attack (100x pump)
trips it by a 20x margin. Residual risk, stated honestly: a pusher key that
is itself compromised can walk the price up 50% per settlement (each step
needs a settled trade or deposit to move the anchor). The allowlist is the
primary control; the guard bounds a single print.

**Invariant restored.** INV-5 (no rounding theft) holds unconditionally
again: deposit share-minting values the safe leg at a price that is either
pusher-allowlisted or within 50% of the last price the desk actually
settled at.

**Regression tests** (`test/Release8Regression.t.sol`, patch phase writes
them; each fails on current code, passes on fixed code):
- `testF1_StrangerCannotPushPrice`: pranked stranger calls
  `setPrice` and it reverts `NotPusher`; `latestPrice` unchanged.
- `testF1_PumpedPriceCannotStealViaDeposit`: the F1a scenario with the
  attacker prank replaced by a reverting `setPrice`; attacker deposit at
  the true price mints exactly the fair shares.
- `testF1_DeviationGuardTripsAt60PassesAt40`: mixed pool, anchor set by a
  TRIM fill at 2000; owner (allowed pusher) pushes 3200 (+60%) and a
  deposit reverts `PriceDeviation`; owner pushes 2800 (+40%) and the same
  deposit succeeds and mints the correct shares.
- `testF1_AllowlistedDriverStillWorks`: deployer `setPrice` succeeds and
  the June replay push sequence ingests (updates advance).

**Existing-suite impact.** Every existing test calls `setPrice` from the
test contract itself (the deployer, hence an allowed pusher), so no
existing test breaks. Only the AuditLane1 F1a/F1b PoCs retire (§8).

### F4 — HIGH — One zero price permanently bricks the brain

**Root cause.** `SentinelReactiveV5._features()` divides by `p[i-1]`,
`p[0]`, `mean` and `peak` with no zero guard. One ingested 0 makes every
later `react()` revert, and the revert rolls back `_push` and the
`_seenLogs` write, so the 0 never rotates out.

**Fix.** File: `src/SentinelReactiveV5.sol`.

1. Add constant `uint256 internal constant MAX_SANE_PRICE = 1_000_000e18;`
   ($1,000,000 at the 1e18 price scale).
2. In `react()`, after the dedup mark (`_seenLogs[logKey] = true;`) and
   after decoding `(price, originTs)`, before `_push(price)`, insert:
   `if (price == 0 || price > MAX_SANE_PRICE) return;`
   Placement matters: the poison log is marked seen (consumed, never
   redelivered into a revert loop) and never enters the window, and no
   `PriceSeen` event is emitted for it. `updates` does not advance for it.
3. Defence in depth in `_features()`: at the top, after computing
   `peak`, `mean` and the ordered window, if any divisor can be zero
   (`peak == 0 || p[0] == 0 || mean == 0`, which also covers a zero
   inside the window via `p[i-1]`), return the zero-initialised feature
   array immediately. This branch is unreachable in a fresh Release 8
   deploy (the `react()` guard admits no zero); it exists so no future
   path that pushes a zero can re-brick the brain.

**Bound justification.** Highest price ever ingested by any set is
$2,707.67 (Aug stretch). $1,000,000 is about 370x that, far above any
plausible ETH price, and about 58 orders of magnitude below the `int256`
wrap threshold (2^255 at 1e18 scale is about $5.8e58). With the bound,
`anchorPeak * 999` peaks near 1e27 and `sumPrice` near 9e24: no overflow
anywhere in `_features()` or `_updateAnchor()`.

**Invariant restored.** Liveness: one bad print can never wedge the brain;
every later sane print ingests normally. The flagship is already immune
(the adapter rejects `answer <= 0`); this gives the mock path the same
filter inside the brain itself.

**Regression tests:**
- `testF4_ZeroPriceIgnoredBrainKeepsWorking`: the F4 PoC scenario (3 calm
  prints, one 0, then 90/95/100/50). Before: all four follow-ups revert,
  `updates` stuck at 4. After: the 0 is ignored, all four ingest,
  `updates` reaches 8, `duplicatesIgnored` stays 0 for the 0 log because
  it was consumed (marked seen) rather than reverted.
- `testF4_HugePriceIgnoredBrainKeepsWorking`: same shape with price
  `2^255` (the L8 case, §7). Before: reverts. After: ignored, brain keeps
  working.
- `testF4_ZeroFirstPriceIsIgnored`: a 0 as the very first ingested log is
  ignored and the next sane price initialises the anchor normally.

### F2 — MEDIUM — Stale Chainlink price is still traded

**Root cause.** `ChainlinkPriceAdapter.sync()` silently refuses stale
rounds, and `latestPrice()` returns the last emitted price forever.
Neither the swap nor the vault checks the age of the price they consume,
so a halted feed means the desk and deposit pricing keep trading at a
frozen price indefinitely.

**Fix — consumption-side staleness bound of 3600 s.** Files:
`src/SentinelSwapV2.sol`, `src/SentinelVaultV5.sol`,
`src/ChainlinkPriceAdapter.sol`, `src/MockPriceOracle.sol`.

1. Extend `IPriceSource` (defined in `SentinelSwapV2.sol`) with
   `function priceUpdatedAt(address token) external view returns (uint256);`.
2. `MockPriceOracle`: implement it as
   `return updatedAtOf[token];` (the mapping already exists).
3. `ChainlinkPriceAdapter`: implement it as
   `return token_ == token ? lastEmittedAt : 0;`.
4. `SentinelSwapV2`: add `uint256 public constant MAX_PRICE_AGE = 3600;`,
   error `error StalePrice(uint256 ageSeconds);`, event
   `event StalePriceRefused(uint256 ageSeconds, uint256 boundSeconds);`,
   and views `priceAge()` (returns `block.timestamp -
   priceSource.priceUpdatedAt(riskAsset)`, where a never-updated source
   yields the full `block.timestamp`, i.e. stale) and `priceStale()`
   (returns `priceAge() > MAX_PRICE_AGE`).
5. In `swapRiskForSafe` and `swapSafeForRisk`, after the zero-amount
   early return and before reading the price: if stale, emit
   `StalePriceRefused(age, MAX_PRICE_AGE)` and `return 0`. A stale fill
   REFUSES (returns 0, no trade) rather than reverting: this preserves the
   never-brick-callbacks invariant (a reverting swap would revert the
   vault's protection callback with it, burning billing and desyncing
   counters). The vault side then executes as a no-op fill, exactly as a
   shortfall fill does today.
6. `SentinelVaultV5.deposit()`: after the `ZeroAmount` check and only
   when `totalShares > 0 && managedSafe > 0`, if `swap.priceStale()`
   revert `StalePrice(swap.priceAge())` (define the same error in the
   vault). A user deposit CAN revert safely (the user retries later), so
   deposits fail closed while callbacks fail soft. The check is skipped
   when `managedSafe == 0` because then the price is irrelevant to the
   mint (first deposit is 1:1; `_poolRiskEq` returns `managedRisk`
   without consulting the price).
7. On-chain staleness signal for the liveness watch: the swap's public
   `priceStale()` view and the adapter's public `lastEmittedAt`. The
   watch alarms when `priceStale()` is true, or when
   `block.timestamp - adapter.lastEmittedAt > 3600`, or when the brain's
   debt is nonzero (§7, Lane 2 L-2), or when brain balance is below one
   firing cycle (0.08 lREACT). No new event is needed for alarming; the
   `StalePriceRefused` event is the on-chain record of each refused fill.

**Bound justification (3600 s).** 3600 is the adapter's own `maxStaleness`
(live value): the adapter refuses to relay a feed round older than this,
so a consumer trading on older data would use a price the relay itself
deems unfit. Normal cadence gives 12x headroom: the adapter heartbeat is
300 s, so a poked `sync()` emits at least every 300 s. The bound therefore
trips only on a genuine outage or keeper failure, never in normal
operation. The alternative (7200 s) was rejected: it would let the desk
trade on data the adapter itself refuses to emit.

**Operational consequence, stated plainly.** The flagship adapter's
`lastEmittedAt` is about 45 h old at audit time. Release 8 is a parallel
set, not a flagship redeploy, so this bites at migration time, not at the
R8 replay: before any flagship funds move to Release 8 contracts, a fresh
`sync()` emission must land and `priceStale()` must read false, or the
migrated desk will refuse every fill and deposit until it does. The
migration runbook must include that check.

**Run-book constraint for the R8 replay.** While deposits or fills are
live, wall-clock gaps between oracle pushes must stay under 3600 s. The
R7 driver already paces pushes minutes apart; the patch phase must confirm
the R8 driver's wall-clock pacing from the R7 live driver log before the
run, and must schedule replay deposits within 3600 s of a push.

**Invariant restored.** No trade and no deposit ever executes on a price
older than the relay's own staleness tolerance. A halted feed halts
trading instead of mispricing it.

**Regression tests:**
- `testF2_StalePriceRefusesFill`: the F2 PoC scenario (adapter synced at
  $2000, feed halts, warp +30 days). Before: desk fills 1 WETH for
  exactly 2000 mUSDC. After: `swapRiskForSafe` returns 0 and emits
  `StalePriceRefused`; `swapSafeForRisk` likewise returns 0.
- `testF2_StalePriceRevertsDeposit`: mixed pool (TRIM done), warp past
  the bound with no fresh push; `deposit` reverts `StalePrice`. A fresh
  push clears it and the same deposit succeeds.
- `testF2_FreshPriceStillFills`: bound minus one second (age 3599):
  fills and deposits behave exactly as before (no behaviour change
  inside the bound).
- `testF2_NeverPushedIsStale`: a fresh swap whose source never pushed
  reports `priceStale() == true` and refuses fills (fail closed from
  deploy, not from first push).

### F3 — MEDIUM — Repeat-EXIT callbacks are unthrottled

**Root cause.** On EXIT, `react()` resets `_lastFiredAction = HOLD` and
`_lastFiredTs = 0`. Every subsequent EXIT vote is then an "escalation"
(2 > 0) and fires immediately regardless of the 300 s cooldown: one
callback per price update for as long as the crash persists.

**Fix.** File: `src/SentinelReactiveV5.sol`, in `react()`, the EXIT branch.
Replace the two reset lines with fired-state recording, keeping only the
TRIM-suppression reset (suppression belongs to the closed cycle):

```solidity
// BEFORE (v2, kept until now):
_lastFiredAction = SentinelModelV2.HOLD;
_lastFiredTs = 0;
lastTrimFiredUpdate = 0;
// AFTER (Release 8):
_lastFiredAction = SentinelModelV2.EXIT;
_lastFiredTs = originTs;
lastTrimFiredUpdate = 0;
```

Note the audit's one-line fix direction ("keep `_lastFiredTs`") is NOT
sufficient on its own: with `_lastFiredAction` reset to HOLD, an EXIT vote
(2 > 0) is still an escalation and bypasses the cooldown entirely. Both
lines must change. Also rewrite the comment block above the branch (the v2
"COOLDOWN STATE-LEAK FIX" rationale) to record the new trade-off, and
update `RELEASE7-DESIGN.md` §9 R-2 to match.

**Accepted cost (recorded, per the task).** A genuinely new position's
first TRIM can wait up to 300 s: after an EXIT, `_lastFiredAction` stays
EXIT, so a later TRIM vote (1 > 2 is false) is not an escalation and must
wait out the cooldown. Accepted because the alternative is unbounded
callback spend (142 EXIT votes in the full June stream is about 4.3
lREACT of no-op callbacks; about 385 sustained-crash callbacks drain the
11.56 lREACT flagship brain to debt, and a brain in debt receives nothing).

**Replay impact, checked.** The June 56-push replay is unchanged: EXIT
fires once, at update 56, the last push; there is no repeat EXIT inside
the stream. The V5R rehearsal is unchanged: EXIT@15, then TRIM@25 fired
342 s later in origin time, which is past the 300 s cooldown (margin
42 s). The Aug stretch (103 pushes, 2 EXIT votes, hourly origin spacing)
is unchanged because the EXIT votes are over 3600 s apart. The patch phase
must re-run the offline mirror (`tools/rerisk_variants.py`) against the
patched contract behaviour for all three streams and confirm identical
callback sequences.

**Invariant restored.** Every callback request after the first in a crash
is cooldown-gated at 300 s; callback spend during a sustained crash is
bounded by (crash duration / 300 s), not by (number of price updates).

**Regression tests:**
- `testF3_RepeatExitIsCooldownGated`: the F3 PoC scenario (bleed to EXIT,
  then 10 crash prints 1 s apart). Before: 12 callbacks, 11 EXIT. After:
  callback count stays 2 (TRIM + EXIT).
- `testF3_ExitFiresAgainAfterCooldown`: same setup, then one more crash
  print at originTs EXIT + 301 s. After: exactly one more EXIT callback
  (count 3), proving the gate is a cooldown, not a blanket suppression.
- `testF3_NewPositionFirstTrimWaits`: after EXIT, a TRIM vote at +100 s
  produces no callback; the same vote at +301 s fires. This pins the
  accepted cost.

### F5 — INFO — Unvalidated action code inflates `protectionCount`

**Fix.** File: `src/SentinelVaultV5.sol`, in `executeProtection()`, first
line after the modifiers:
`if (action_ < ACTION_TRIM || action_ > ACTION_RERISK_FINAL) revert UnknownAction(action_);`
with new error `error UnknownAction(uint8 action);`. Actions 0 and 5-255
now revert; 1-4 behave exactly as before. (V4 is NOT patched: V4 is
retired, see §2.)

**Invariant restored.** `protectionCount` counts executed protection
actions only; every `ProtectionExecuted` event corresponds to a real
action code.

**Regression tests:**
- `testF5_UnknownActionReverts`: actions 9 and 0 revert; `protectionCount`
  stays 0; balances unchanged.
- `testF5_KnownActionsStillWork`: actions 1-4 execute exactly as before
  (covered by the existing V5 suite, which must stay green).

## 2. Low / Info items

### F-1 (Lane 2) — LOW — VaultV4 #5 holds third-party deposits with no exit

**Fix: retire #5 and return the funds pro-rata (owner action, no code).**
Vault `0xb13BF7Ff153e7f6304735EC4199B006Fd4857Ac9` holds 0.00075 WETH +
1.261916653305 mUSDC from 0.0015 WETH of deposits. V4 has no redeem
function and its `withdraw()` is uncapped, so the owner returns the funds
with 16 `withdraw(asset, to, amount)` calls (8 recipients x 2 assets).
The split is exact to the wei with zero dust (both totals divide evenly
by 15):

| Recipient | Share of 0.0015 WETH | WETH out (wei) | mUSDC out (wei) |
|---|---|---|---|
| dev `0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94` | 0.0001 (1/15) | 50000000000000 | 84127776887 |
| `0xE87CB61c3a6982da8521B3755086480Efc9Cd02B` | 0.0005 (5/15) | 250000000000000 | 420638884435 |
| `0xe838C1C226Ba73Db9d1D67beB297707706e8f552` | 0.0002 (2/15) | 100000000000000 | 168255553774 |
| `0x037ee69B4c304634ab41deF2aCf6d53FF64Fd6F6` | 0.0002 (2/15) | 100000000000000 | 168255553774 |
| `0xc19F088ceDEe249224EE1374853fb977FD689eba` | 0.0002 (2/15) | 100000000000000 | 168255553774 |
| `0xb04094327f20155D619675Be8C5ce12E769fd278` | 0.0001 (1/15) | 50000000000000 | 84127776887 |
| `0x7b6345f38C16D48ACC011fbF9FBa793f0f1fa3E7` | 0.0001 (1/15) | 50000000000000 | 84127776887 |
| `0x40CEd1D9c528E2E3491bdD9001918E4e429944f3` | 0.0001 (1/15) | 50000000000000 | 84127776887 |

Deposit totals are from the Lane 2 Blockscout table (10 deposits, 21 Nov
2026) plus the dev 0.0001 seed recorded in `RELEASE5.md`. Verification:
after the 16 calls, read back `positionSize` and `safeBalance` on #5;
both must read 0. Then publish a retirement note (repo + Live Proof page):
V4 #5 is retired, no further deposits. Honest limit: V4 has no pause, so
a deposit after the note is technically still possible; the note plus the
zero balance is the mitigation. Fallback, only on explicit user say-so:
single drain of both balances to the dev wallet (2 calls) instead of the
pro-rata return. The patch phase must NOT choose the fallback on its own.

### F-1 (Lane 4) — LOW — Live Release 7 brain out of firing fuel

**Fix: operational, in the Release 8 spec (§5).** The live R7 brain stays
as it is (run complete, vault empty, no top-up needed). Rule going
forward, enforced by the pre-deposit checklist and the watch, not by code
(the vault cannot read the brain's balance: different chain): no deposits
into any vault whose brain holds less than one firing cycle (about 0.08
lREACT). The watch alarms when brain balance is below 0.08 lREACT or
debt is nonzero (see §7, Lane 2 L-2 for the debt read). The R8 brain is
attached 2.20 lREACT (§5).

### L-1 (Lane 3) — LOW — MCP manifest pointed at the old #5R set

**Status: ALREADY FIXED in the working tree (verified this design pass).**
`agent/server.mjs:57-58` now point at the V5R set
(`0xaf030D808133C36E571c87C3A3fD2B7F511971E0` /
`0xf874c4E680EBBD65315a130A521399f43171dad2`), with a note at lines 59-60
that #5R is superseded; `docs/agent.json` contracts[3..4] carry the same
V5R addresses. Remaining for the patch phase: (a) run
`sentinel_verify` live and confirm it returns the V5R addresses;
(b) bump `agent/package.json` version 1.0.0 to 1.1.0 (still open, one
line); (c) publish the files and re-check the live manifest (see the
publish note in §6). No code change beyond the version bump.

### L-2 (Lane 3) — LOW — Live Proof page omitted the Release 7 live set

**Status: ALREADY FIXED in the working tree (verified this design pass).**
`docs/index.html` now carries a Release 7 section (lines about 145-174)
with the live addresses, 56 pushes, 6 protections, closed vault,
labelled as the parallel mock-oracle live-firing set. Remaining: publish
and re-check live. The live crawl from 26 Nov 20:06 UTC still shows the
old text ("feed simply hasn't fallen yet", no R7 section), so the local
fix is NOT yet public. The republish from the repo also resolves the two
wording-line drift lines on the live page.

### L-3 (Lane 3) — LOW — Stale test count 165/165

**Status: ALREADY FIXED in the working tree for the audit count**
(`docs/index.html` line 206 reads 174/174). Rule for the patch phase:
never hand-copy the number. After the regression suites land, run
`forge test`, take the total from its output, and write that number into
the page. Current count at design time is 180 (174 + 6 lead tests); the
patch-phase count will be 180 + the number of new regression tests.

### L-4 (Lane 3) — LOW — Event timestamps labelled UTC but rendered local

**Status: ALREADY FIXED in the working tree (verified this design pass).**
`docs/index.html` line 323 `fmtTs` now passes `timeZone: "UTC"`.
Remaining: publish, then verify with the audit's own check
(`TZ=Asia/Jakarta node -e` on the page's `fmtTs`, expecting true UTC).

### Lane 2 F-2 — INFO — #5 TRIM baseline stale

**Fix: doc edit in `FLAGSHIP-V5.md`.** Record the #5 brain as it reads
live: `updates` 6 (record said 3), `lastAction` 1 (TRIM, record said 0
HOLD), `anchorPeak` $1,798.18 (decayed from $1,803.58), `episodeActive`
true, balance 0.9440675 lREACT (record 1.0758959); vault 0.00075 WETH +
1.261916653305 mUSDC, `protectionCount` 1, `lastProtectionAt`
1795561402 (24 Nov 23:03:22 UTC). Verified by this design pass that this
record is still absent from the file.

### Lane 2 F-3 — INFO — V5R brain / swap / oracle not on Sourcify

**Fix: submit the three contracts to Sourcify v2** (same source and
compiler settings as the verified June-core counterparts; byte-level
equivalence already proven in Lane 2): brain
`0xaf030D808133C36E571c87C3A3fD2B7F511971E0`, swap
`0xF25B97c6c3738b8a91a9c3eE2E1518e3ffB0A34a`, oracle
`0x4a3022010e253bc2dc49c2cb03ce0e5c544630b3` (Lasna 5318007 for the brain,
Base Sepolia 84532 for swap/oracle). Verification: all three return
`exact_match`. This also makes the `sentinel_verify` description ("all
Sourcify exact-match") true.

### Lane 4 F-2 / F-3 — INFO — Rebuilt `RELEASE7-REHEARSAL.md` slips

**Status: ALREADY FIXED in the working tree (verified this design pass).**
Line 524 now reads "152 drive events + 1 deploy-time VaultSet", and the
§6 drive-gas rows now carry the "includes the set deploy gas in the row
below; do not add the two rows" label. No further action; the patch phase
greps to confirm.

### Lane 4 F-4 — INFO — Stranded lREACT on retired brains

**Fix: none (platform property, no withdraw path by Reactive design).**
Recorded as a funding rule for Release 8 (§5): attach close to what the
run needs, plus at least 10% headroom, because the remainder is
unrecoverable. About 1.1635 lREACT sits stranded across retired brains;
faucet testnet funds, $0.

## 3. Promoted leads — fix specs

Two leads were proven by new PoC tests written for this design pass
(`test/AuditLeads.t.sol`, 6/6 passing; full suite 180/180). They are
promoted to findings and fixed in Release 8 with the same spec format
as §1.

### L3 (Lane 1) — PROMOTED — TRIM suppression is cycle-blind

**Proof.** `testLeadL3_TrimSuppressionIsCycleBlind`: TRIM fires at update
6, tranche 1 fires at update 9, tranche 2 fires at update 10 (episode
closed, `reriskCount` 2, full re-risk complete). A fresh crash leg votes
TRIM at updates 11-13 (mirror-confirmed; anchor drawdown 4.9%/9.7%/13.6%,
under the 18% EXIT bypass), but no TRIM callback fires: the suppression
window is still anchored at `lastTrimFiredUpdate` 6, and the episode
close never reset it. The vault stays exposed through a genuine second
dip.

**Fix.** File: `src/SentinelReactiveV5.sol`, in `_evaluateEpisode()`,
the tranche-2 close branch (`if (!tranche2Fired && anchorPeak >
episodeAnchor)`): add `lastTrimFiredUpdate = 0;` alongside
`tranche2Fired = true; episodeActive = false;`. Only the tranche-2 close
resets suppression: a tranche-2 close means the position is fully
bought back, so a new cycle starts and a fresh TRIM must be allowed. An
episode CANCEL (pre-tranche-1) does NOT reset it: the position is still
de-risked and no new cycle has started.

**Cooldown interplay, checked.** The reset cannot bypass the cooldown:
a fresh TRIM vote after the reset still needs `originTs >=
_lastFiredTs + 300` unless it is an escalation. In the PoC the reset
happens at update 10 and the fresh TRIM votes at updates 11-13 with
hourly origin spacing, so the cooldown has long passed and the TRIM fires
at update 11.

**Invariant restored.** Suppression is per position cycle, not per
brain lifetime: once the position is fully restored, the next crash leg
is protected like the first.

**Regression tests:**
- `testL3_FreshTrimFiresAfterFullRerisk`: the L3 PoC scenario. Before:
  callback count stays 3 through update 13. After: a TRIM callback fires
  at update 11 (count 4, action TRIM).
- `testL3_CooldownStillGatesAfterReset`: same scenario with the fresh
  leg compressed inside 300 s of origin time: no callback until the
  cooldown passes.

**Replay impact.** June replay unchanged (`reriskCount` 0, no episode
closes). V5R unchanged (its episode opened on EXIT, and EXIT already
resets `lastTrimFiredUpdate` to 0). Aug stretch: `reriskCount` 2 with
`lastTrimFiredUpdate` 79; the patch phase must re-run the offline mirror
for the stretch stream and confirm the callback sequence is unchanged.

### L8 (Lane 1) — PROMOTED — Extreme-price `int256` wrap in `_features`

**Proof.** `testLeadL8_ExtremePriceRevertsReact`: after 3 calm prints, a
single `2^255` print makes `react()` revert (`int256(2^255)` wraps to
`int256.min` and the return computation overflows). Unlike F4 this does
NOT brick the brain: the revert rolls back the push, the log is never
consumed, and the next sane price ingests normally. Impact is a
per-log grief, not a permanent wedge, and only through the mock oracle
(the adapter rejects absurd answers by construction: a Chainlink answer
is bounded by the feed).

**Fix.** The F4 upper bound (§1, `MAX_SANE_PRICE = 1_000_000e18`) closes
L8 with no additional code: an absurd print is ignored at the top of
`react()` (consumed, never ingested) instead of reverting inside
`_features()`. No separate fix is specified.

**Regression test.** `testF4_HugePriceIgnoredBrainKeepsWorking` (§1 F4)
covers L8: before, the `2^255` print reverts; after, it is ignored and
the brain keeps working.

## 4. Release 8 set design

**What it is.** A fresh parallel set, same pattern as the Release 7 June
core: fresh `MockPriceOracle`, fresh `SentinelSwapV2` (priceSource = the
fresh oracle), fresh `SentinelReactiveV5` (mock origin), fresh
`SentinelVaultV5`, all built from the fixed code. The R7 live oracle is
NEVER reused (permissionless, and its state predates the allowlist).

**Deploy script.** Copy `tools/deploy_release7.sh` to
`tools/deploy_release8.sh` and change: (a) rebuild from the fixed code;
(b) gate: dev Lasna balance at least 2.40 lREACT before any deploy
(2.20 attach + 0.1801715 deploy gas, rounded up; R7 gated at 2.18 for a
2.00 attach); (c) after the oracle deploy, read back
`pricePushers(dev) == true` and `owner() == dev`, and abort otherwise;
(d) after deploy, read back the new getters: `swap.MAX_PRICE_AGE() ==
3600`, `swap.priceStale() == false` (after the first push),
`vault.lastSettledPrice() == 0`; (e) keep every R7 read-back gate
(wiring, flagship untouched, desk seed, billing) unchanged. The flagship
set is never touched by this script.

**Funding.**
- Brain: attach **2.20 lREACT**. Measured June-core consumption is
  1.9471002 for 56 reacts + 6 callbacks; 2.20 is +13.0% headroom, above
  the 10% rule (§7, Lane 4 L-2: design estimates ran 6-7% low). The F3
  fix can only reduce callback count, so actual consumption is expected
  below 1.9471002; the headroom is kept anyway.
- Desk: seed exactly 1,000 mUSDC (same as R7).
- Vault: users A/B/C deposit totalling 0.0065 WETH, vault billing
  0.0001 ETH (same as the R7 June core, `RELEASE7-DEPLOY.md` §5-6).
- Driver: reuse the R7 June push table (56 tokens) and driver, pointed
  at the R8 oracle address. No new price series is introduced: the replay
  must be bit-identical to the R7 June core so the mirror predictions
  apply unchanged.

**June replay — expected end state (must match the R7 June core exactly).**
Brain `updates` 56, `lastAction` 2 (EXIT), `protectionCount` 6 on the
vault, vault `closed` true, `totalShares` 0, `managedRisk` 0,
`managedSafe` 0, desk 990.74943675 mUSDC / 0.006325 WETH, conservation
to the wei (users 0.000175 WETH + desk 0.006325 = 0.0065; users
9.25056325 mUSDC + desk 990.74943675 = 1,000). Why the patches change
nothing here, patch by patch: F1 allowlist (pusher is the dev driver);
F1 deviation guard (no mid-run deposits in the June run; the first
deposits are 1:1 into an empty pool, and TRIM fills set the anchor);
F4/L8 bounds (no zero or absurd prices in the stream); F2 (fills land
minutes after their emission, far inside 3600 s); F3 (EXIT fires once,
at update 56, the last push); L3 (no episode closes: `reriskCount` 0);
F5 (no unknown actions are sent). Any deviation from the R7 June-core
end state is a patch regression, not a new result. The patch phase must
also run the offline mirror (`tools/rerisk_variants.py`) against the
patched contract for the June, V5R and stretch streams and confirm
identical callback sequences.

**Pre-run forge gate.** Before any live push, the patch phase adds a
forge test replaying the exact June deposit/fill sequence through the
fixed vault (deposits at run start, TRIM/EXIT fills at the recorded
prices) and asserts no deposit reverts on the deviation guard or the
staleness check. If a legit June deposit trips either guard, the guard
parameters are wrong and the design (not the test) must be revisited.

**Acceptance criteria for Release 8.** (1) Full forge suite green
including `test/Release8Regression.t.sol`; (2) the June replay end state
matches the R7 June core exactly (§4); (3) Sourcify `exact_match` for
all four R8 contracts; (4) wiring read-backs pass (brain oracle/vault,
vault swap/callback sender, swap priceSource/vault, all in-set);
(5) `sentinel_verify`-style read of the R8 set returns the R8 addresses;
(6) no deposit was taken into the R8 vault before the replay completed.

## 5. Off-chain fixes (frontend + MCP + watch)

These are the Lane 3 leads with confirmed mechanisms. They are not
forge-testable (they need a live wallet/browser pass), so each fix names
its verification as a manual check the patch phase must do.

- **LD-1 wrong-chain race.** `docs/app.html:448` `sendTx()` builds
  `eth_sendTransaction` params `{from, to, data, value}` with no
  `chainId`; `ensureChain()` runs once at flow start (lines 335/419/479).
  Fix: add `chainId: "0x14a34"` to every `sendTx` params object and
  re-run `ensureChain()` immediately before each `sendTx` call.
  Verify: manual live-browser pass (connect, start a deposit, switch
  chains mid-flow, confirm the flow aborts or stays on Base Sepolia).
- **LD-2 stale shares on RPC failure.** `refreshShares()` (line 369)
  catches RPC errors internally and leaves the previous `myShares`;
  `runRedeem()` proceeds on the stale value. Fix: make `refreshShares()`
  propagate failure (throw) and abort the redeem when the fresh read
  fails. Verify: code review + manual pass with a failing RPC.
- **LD-3 receipt-timeout stale UI.** `waitReceipt()` (line 452) gives up
  after 90 x 2 s and the catch path does not re-read balances. Fix: on
  timeout, re-check the receipt once more (or schedule a re-read) instead
  of leaving stale state. Verify: manual pass.
- **LD-4 no pre-deposit share quote.** Not a bug (no wrong value is
  shown). Fix (small, included in R8): display expected shares before
  deposit, reusing the MCP `expectedShares()` formula (same
  ceil-division safe-leg valuation as `_poolRiskEq()`). Verify: manual
  pass against a live mixed-pool deposit.
- **LD-5 account switch mid-deposit.** `accountsChanged` (line 602) swaps
  the `account` variable immediately. Fix: snapshot the account at flow
  start and abort the flow if it changes mid-flow. Verify: manual pass.
- **MCP staleness warning.** `sentinel_prepare_deposit` must check
  `swap.priceStale()` (flagship swap) and return a warning when true,
  because the deposit would revert on-chain. The `expectedShares()`
  math itself is unchanged (verified against `_poolRiskEq()` in Lane 3).
- **Liveness watch (new rules).** Alarm when any of these hold:
  `swap.priceStale()` is true; `block.timestamp -
  adapter.lastEmittedAt > 3600`; `IPayable(SYSTEM).debt(brain) > 0`
  (system contract `0x8888888888888888888888888888888888888888`, see §7
  Lane 2 L-2); brain balance below 0.08 lREACT (one firing cycle).
  Keeper: poke `adapter.sync()` on the flagship; a halted feed correctly
  keeps the alarm up until the feed recovers.

## 6. Publish note — the local fixes are not live yet

`docs/` is gitignored (`.gitignore:15`), so the working-tree files are
the deploy source, not the git repo. This design pass verified that
L-1, L-2, L-3, L-4 and Lane 4 F-2/F-3 are already fixed in the local
files, but the live GitHub Pages copy (crawled 26 Nov 20:06 UTC) still
shows the old text (165/165, no Release 7 section, "feed simply hasn't
fallen yet"). The patch phase must determine how `docs/` reaches GitHub
Pages from this machine and publish the already-fixed files, then
re-check the live pages (test count, R7 section, UTC label, V5R
addresses in `agent.json`). This is an open item, not a claim: the local
fix and the live publication are two different steps, and only the first
is done.

## 7. Lead dispositions — all 21, none dropped

21 leads were listed across the four lane files. 2 were already findings
at audit time (Lane 1 L1 = Lane 2 F-1; Lane 4 L-1 = F3). The remaining
19 are triaged below. Tests cited are in `test/AuditLeads.t.sol`
(6/6 passing, full suite 180/180 at design time).

| Lead | Disposition | Evidence / fix |
|---|---|---|
| Lane 1 L1 — V4 uncapped owner withdraw | ALREADY A FINDING (Lane 2 F-1) | Fix in §2 (pro-rata retirement). |
| Lane 1 L2 — anchor decay per-update, live cadence 12-48x faster than backtest | CONFIRMED mechanism, model-validity limitation, NO R8 code fix | `testLeadL2_AnchorDecayIsPerUpdateNotPerSecond`: identical price path with 1 s vs 3600 s origin spacing gives an identical anchor (95.12e18 in both). A per-second decay is a redesign plus full revalidation at live cadence, out of minimal scope. R8 replay is unaffected (hourly pushes = validated cadence). Record as a known limitation in the R8 runbook; revisit only if the flagship moves to sub-hourly live cadence. |
| Lane 1 L3 — TRIM suppression cycle-blind | PROMOTED TO FINDING | `testLeadL3_TrimSuppressionIsCycleBlind` proves it. Fix in §3. |
| Lane 1 L4 — single-EOA owner on all contracts | CONFIRMED by design, accepted risk, NO R8 code fix | No code defect to PoC: every owner power is explicit in the constructors (vault surplus rescue, swap reserve withdraw + `setVault`, reactive `setVault`). Multisig/timelock is a deployment change, out of minimal scope. Required before any mainnet-shaped deployment. R8 keeps the dev-EOA owner like all prior sets. |
| Lane 1 L5 — vault max-approval to swap | DISMISSED as non-bug | `testLeadL5_MaxApprovalIsOnlyVaultGated`: allowance is `type(uint256).max` AND stranger `swapRiskForSafe`/`swapSafeForRisk` calls revert (`NotVault`); the desk holds no other privilege. Mitigated by the deploy read-backs (kept in the R8 script). No fix. |
| Lane 1 L6 — deposit re-arms on 1 wei | CONFIRMED behaviour, benign, NO fix | `testLeadL6_DustDepositRearmsClosedPosition`: 1 wei re-arms (`closed` false) and a TRIM on the 1-wei position moves nothing. Cost falls on the depositor (own 1 wei + gas); no victim impact, no funds path. Documented as accepted semantics. |
| Lane 1 L7 — cooldown reads origin timestamps | CONFIRMED by design, NO fix | `testLeadL7_CooldownReadsOriginTimestampsNotWallTime`: after a TRIM, 10,000 s of wall time passes with no callback (origin gap 11 s), then a print at origin +301 s fires while wall time barely moves. Origin time is the only trustworthy cross-chain timestamp; skew is bounded by `maxStaleness` (3600 s) and the 300 s cooldown is loose enough. |
| Lane 1 L8 — extreme-price `int256` wrap | PROMOTED TO FINDING | `testLeadL8_ExtremePriceRevertsReact` proves it (2^255 print reverts `react()`; not a permanent brick). Fix in §3 via the F4 upper bound. |
| Lane 2 L-1 — who are the 7 external #5 depositors | UNRESOLVABLE on-chain, NOT a code item | The 7 addresses are listed in the Lane 2 table; chain data carries no identities. Open question for the user/team: confirm whether they were team wallets. If strangers, the §2 pro-rata refund is the remediation. No fix. |
| Lane 2 L-2 — no subscription/debt getter | RESOLVED, not a gap | `IPayable.debt(address)` exists (`lib/reactive-lib-omni/src/interfaces/IPayable.sol:15`); the brain's service provider is the system contract `0x8888888888888888888888888888888888888888`. The watch reads `debt(brain)` directly. No code change; watch rule added in §5. |
| Lane 2 L-3 — Lasna reaction tx for the #5 TRIM not recovered | OPEN evidence item, NOT a bug | Firing is proven by the Base callback tx `0xa96de8c46f…` + brain/vault state. Recovery needs a Lasna log scan; low value. Patch/ops phase may recover it for the evidence file. Not blocking R8. |
| Lane 3 LD-1 — wrong-chain race mid-deposit | CONFIRMED by code reading | `app.html:448` `sendTx` has no `chainId`. Fix in §5. No forge PoC possible (needs a live wallet tx; deliberately not attempted). |
| Lane 3 LD-2 — stale shares on RPC failure | CONFIRMED by code reading | `refreshShares()` (line 369) swallows the failure; `runRedeem()` proceeds. Fix in §5. |
| Lane 3 LD-3 — receipt-timeout stale UI | CONFIRMED by code reading | `waitReceipt()` (line 452) 90 x 2 s, then throws without re-reading. Fix in §5. |
| Lane 3 LD-4 — no pre-deposit share quote | NOT A BUG; small improvement specified | No wrong value is shown. Fix in §5 (display `expectedShares()` pre-deposit). |
| Lane 3 LD-5 — account switch mid-deposit | CONFIRMED by code reading | `accountsChanged` (line 602) swaps `account` immediately. Fix in §5. |
| Lane 3 LD-6 — video + DoraHacks page not cross-checked | OPEN verification item | Needs a live browser (video content + DoraHacks build #51122 page). Not a code fix. Patch phase must check before judging. |
| Lane 4 L-1 — R-2 repeat-EXIT hazard | ALREADY A FINDING (F3) | Fix in §1. |
| Lane 4 L-2 — design fuel estimates run 6-7% low | CONFIRMED by arithmetic, process fix | June +6.4%, stretch +7.3% (estimate vs measured). Fix: carry at least 10% headroom; R8 attaches 2.20 vs 1.9471002 measured (+13.0%). No code change. |
| Lane 4 L-3 — V5R first burner batch "discarded unfunded and unused" uncorroborated | DISMISSED, inconsequential | No funds, no chain impact claimed, nothing hinges on it. No action. |
| Lane 4 L-4 — exact debt failure mode unpinned | PARTIALLY PINNED, no Sentinel-side impact | `_coverDebt()` is defined in `AbstractPayer` but never called anywhere in-repo; only the network's system contract settles debt via `pay()`. Pinned operationally: in debt means receives nothing (NatSpec + `SentinelReactiveV5` notice), a top-up restores delivery, debt is readable via `IPayable.debt()`. The internal branch (react skipped vs react-processed-but-callback-dropped) lives in the network system contract, not this repo, and no Sentinel-side decision depends on it. No fix; watch alarms on debt > 0. |

Disposition counts (21 total): already findings 2; promoted to findings
2 (L3, L8); confirmed with no code fix 4 (L2 limitation, L4 accepted
risk, L6 benign, L7 by design); dismissed as non-bug 3 (L5, Lane 4 L-3,
LD-4 as not-a-bug); resolved, not a gap 1 (Lane 2 L-2); partially pinned
1 (Lane 4 L-4); confirmed frontend, fix specified with manual
verification 4 (LD-1, LD-2, LD-3, LD-5); open / unresolvable, not code 3
(Lane 2 L-1, Lane 2 L-3, LD-6); confirmed process, no code 1 (Lane 4
L-2).

## 8. Test plan for the patch phase

**New file.** `test/Release8Regression.t.sol` with the tests named in §1
and §3 (F1 x4, F4 x3, F2 x4, F3 x3, F5 x2, L3 x2). Each must FAIL on the
current code and PASS on the fixed code; the patch phase demonstrates the
fail-before run (e.g. `git stash` the `src/` patches, run the new file,
observe failures) before landing the fix.

**Retiring PoCs (must be deleted or replaced, not "fixed" to pass).**
`test/AuditLane1.t.sol` finding PoCs (6 tests: `testF1a_…`, `testF1b_…`,
`testF2_…`, `testF3_…`, `testF4_…`, `testF5_…`) assert the buggy behaviour and will fail on the
fixed code by design. The 3 clean checks in the same file stay green and
stay. `test/AuditLeads.t.sol`: the L3 and L8 tests assert the buggy
behaviour and retire with the fix (replaced by the §3 regression tests);
the other 4 lead tests (L2, L5, L6, L7) assert UNCHANGED behaviour and
must keep passing after the fix: they are the guard against fix
overreach. No existing test file is otherwise modified.

**Suite-migration risk, checked at design time.** Only the AuditLane1 F2
test warps time far ahead (+30 days); it retires anyway. The end-to-end
suites warp `block.timestamp` to the origin timestamps and push a fresh
price at each step, so the oracle's `updatedAtOf` stays fresh and the
3600 s bound does not trip them. The patch phase confirms by running the
full suite: the only failures permitted are the retiring PoCs.

**Count.** Design-time suite is 180/180. After the patch phase the count
is 180 + (regression tests added) - (retiring PoCs removed: 6 Lane 1 +
2 leads = 8). With the 18 regression tests named in §1 and §3, the
expected final count is 180 + 18 - 8 = 190. The L-3 page number is
updated from the final `forge test` output, never hand-copied.

## 9. Open decisions the patch phase must NOT decide alone

1. **Flagship migration.** Release 8 is a parallel set. Moving the
   flagship position (0.0023 WETH, live, Chainlink-fed) onto Release 8
   contracts means: redeem the flagship vault, deposit into the R8
   vault, re-point the app / Live Proof / MCP at the R8 set, and a fresh
   `sync()` emission with `priceStale() == false` first. That migration
   needs explicit user approval; this design does not authorise it.
2. **V4 #5 refund route.** Pro-rata return (16 calls, §2) is the
   recommended default; single drain to the dev wallet is the fallback
   only on explicit user say-so.
3. **Docs publish path.** How `docs/` (gitignored) reaches GitHub Pages
   (§6). The patch phase must establish it and re-check the live pages.
4. **LD-6 video / DoraHacks cross-check.** Needs a live browser; the
   patch phase (or an agent with a browser) must view the video and the
   DoraHacks build #51122 page before judging.
5. **L-2 anchor-cadence limitation.** If the flagship ever moves to
   sub-hourly live cadence, the anchor needs a per-second decay redesign
   plus revalidation. That is future work, not Release 8.
6. **Debt-mode internal branch** (Lane 4 L-4): unpinnable from this repo;
   if a future run ever plans to operate a funded set to empty, confirm
   the behaviour against Reactive Network docs first.
7. **F2 bound re-confirmation.** 3600 s is chosen and justified against
   `maxStaleness` (§1). If the keeper behaviour differs in practice
   (nobody pokes `sync()`), the flagship desk will halt until a sync
   lands: that is the intended fail-closed behaviour, but the user must
   know the desk halts rather than trades during an outage.
