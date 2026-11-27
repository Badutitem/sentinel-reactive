# Sentinel — Release 6 (brain V6) Design (design gate, Gate 1)

**Status:** DESIGN ONLY. Nothing is deployed, no `src/` file is edited yet,
no DoraHacks page is touched, nothing is pushed to git, no video is
uploaded. The patch phase implements this document exactly, then
re-verifies. Scope (user approval 27 Nov 2026 17:35 WIB, "Gas — desain +
bangun brain V6"): design + build + on-chain rehearsal of a NEW parallel
set. **Live deploy and flagship migration are OUT of scope** — they need
the user's separate word after the rehearsal report.

**Supersession record.** Scope freeze 26 Nov ("Release 7 = last") was
superseded 27 Nov 03:25 WIB ("Gas — perbaiki semua", Release 8). The
27 Nov 16:00 WIB "fokus pemeliharaan" (maintenance only) still stands:
V6 is maintenance — it fixes the six attacker-hunt findings (AH-2..AH-6
plus the AH-1 parameter fix already adopted in the migration) and adds
no feature, no model change, no new release behaviour beyond the fixes.

**Sources.** `~/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/attacker-hunt-2026-11-27.md`
(the truth source for the fixes), `.../reaudit-remaining-bugs-2026-11-27.md`,
`FIX-DESIGN.md` (Release 8 pattern), `RELEASE8-REHEARSAL.md` +
`RELEASE8-DRIVE.md` (rehearsal/drive pattern). Codebase
`~/workspace/bounty-new/reactive/project/` (`src/` + `test/`).
Suite baseline verified by this design pass: **205/205 passing**
(190 Release 8 + 15 AttackerHunt, re-run this session).

**Rules for the patch phase.** Minimal, surgical changes only. V6 is a new
generation built from the fixed Release 8 code plus the patches in this
document only. **The production files are NOT modified:**
`src/SentinelReactiveV5.sol`, `src/SentinelSwapV2.sol`,
`src/SentinelVaultV5.sol` and `src/ChainlinkPriceAdapter.sol` stay exactly
as they are (the flagship runs V5/V2/V5). New files only:
`src/SentinelReactiveV6.sol` (from V5), `src/SentinelSwapV3.sol` (from
V2), `src/SentinelVaultV6.sol` (from V5). Regression tests go in a NEW
file, `test/Release6Regression.t.sol`. Existing tests are NOT modified.
Each regression test must FAIL on the old code and PASS on V6; the patch
phase demonstrates the fail-before run (the AttackerHunt PoCs already
record the old-code behaviour — H12 20 callbacks, H2 dust sale, H3
revert, H4a/b/c theft, H5a/b redirection — and the new tests assert the
opposite on V6).

## 0. Generation naming

| New contract | From | Why this name |
|---|---|---|
| `SentinelReactiveV6` | `SentinelReactiveV5` | Brain generation 6; the AH-2 latch and AH-3 floor live here. |
| `SentinelSwapV3` | `SentinelSwapV2` | Desk generation 3; the AH-3/AH-4 price bounds live here. |
| `SentinelVaultV6` | `SentinelVaultV5` | Vault generation 6; the AH-5 20% band lives here. |

Each file keeps its own lineage number, as before (brain V5 / swap V2 /
vault V5). The mock oracle and Chainlink adapter are unchanged and shared.

## 1. Fixes

### AH-2 — MEDIUM — Repeat-EXIT no-op callbacks on a sustained gentle bleed

**Root cause.** The Release 8 F3 fix keeps `_lastFiredAction = EXIT` and
`_lastFiredTs` across the EXIT, so repeat EXITs are cooldown-gated at
300 s. At live cadence (hourly origin spacing, or the Chainlink
heartbeat's exactly-300 s spacing) the cooldown always passes, so every
repeat EXIT fires. PoC `testH12_GentleBleedProbe`: −1%/update × 40
updates → **20 callbacks (2 TRIM + 18 EXIT)**, ≈ 2.16 lREACT ≈ 98% of a
2.20 budget, ~17 of them no-ops after the vault closed. No attacker
needed. The brain cannot read the vault's `closed` flag cross-chain,
so the suppression must be brain-local state.

**Fix — post-EXIT latch (brain-local).** File:
`src/SentinelReactiveV6.sol`.

1. Add storage `bool public exitLatched;` (false at birth) and event
   `event PostExitLatch(bool latched, uint256 updates);`.
2. In `react()`, in the EXIT branch, alongside the F3 fired-state
   recording (`_lastFiredAction = EXIT; _lastFiredTs = originTs;
   lastTrimFiredUpdate = 0;`): set `exitLatched = true;` and emit
   `PostExitLatch(true, updates);`.
3. In `react()`, after the re-risk episode evaluation and after the
   HOLD/vault check, before the TRIM-suppression check: if
   `exitLatched && (action == TRIM || action == EXIT)` return (vote
   stands — the `Decision` event was already emitted — only the
   callback is withheld, same pattern as `TrimSuppressed`).
4. Clear the latch in `_evaluateEpisode()` at exactly three points,
   each emitting `PostExitLatch(false, updates)`:
   - **tranche-1 fire** (action 3): the position is partially
     restored (half the safe balance bought back into risk), so the
     restored half deserves protection again;
   - **tranche-2 close** (action 4): the position is fully restored,
     a new cycle starts;
   - **episode cancel** (pre-tranche-1, anchor above `episodeAnchor`):
     the market recovered strongly, the episode is over.
   Clearing is idempotent (setting an already-false latch emits
   nothing — guard the emit with `if (exitLatched)`).
5. The latch does NOT touch re-risk evaluation: `_evaluateEpisode`
   runs before the protection gate on every ingested update while an
   episode is open, exactly as today. Tranche callbacks fire while
   latched — the latch gates protection votes only.

**Why clear on tranche-1 (deliberate trade-off, recorded).** The
alternative — latch until tranche-2 only — would leave the tranche-1
buyback (real user money back at risk) unprotected through a second
crash leg. Clearing on tranche-1 bounds the cost instead: each new
EXIT requires a preceding recovery (tranche-1), i.e. each cycle moves
real funds, so it is genuine protection work, not no-op burn. In a
sustained monotonic bleed no tranche ever fires, so the latch holds
for the whole bleed — that is the AH-2 case, and it is fully closed.

**Expected numbers (H12 replay on V6).** Callbacks **20 → 3** (2 TRIM
+ 1 EXIT). Fuel: 40 reacts × 0.0295521 + 3 callbacks × 0.0486971 ≈
**1.33 lREACT vs 2.16 before (−39%)**. Honest floor, stated plainly:
the 40 reactions themselves cost ≈ 1.18 lREACT and no suppression can
avoid that — every subscribed log is billed. The fix bounds callback
spend, not react spend. The regression test asserts the callback count
(3) and the latch state, not a fuel number (fuel is a live-network
measurement, proven in Gate 3).

**Replay impact, checked.** June 56-push: EXIT fires once, at update
56, the last push — the latch is set and never read again. Identical.
V5R pattern (EXIT@15, RERISK@18, RERISK_FINAL@19, TRIM@25): the
latch sets at 15, clears at tranche-1 (18), the episode closes at 19,
TRIM@25 fires normally. Identical. Aug stretch: the EXIT@21 no-op
callback disappears (latched — no tranche-1 before update 21); the
re-risk cycle (RERISK@97, RERISK_FINAL@102) is unaffected. One fewer
callback, by design. The stretch is NOT re-driven on-chain for V6
(scope: June core + bleed + attacks); the stretch behaviour is pinned
by a forge test instead (§4).

### AH-3 — LOW — Near-zero price cliff (1-wei print fires EXIT, sells for dust)

**Root cause.** The F4 guard blocks exactly 0 but admits 1 wei; the
brain ingests it and fires EXIT. PoC `testH2_OneWeiPriceDumpsPositionForDust`:
10 WETH sold for 10 wei mUSDC. Pusher-gated (mock sets); impossible via
Chainlink.

**Fix — `MIN_SANE_PRICE`, brain + swap (defence in depth).**
Files: `src/SentinelReactiveV6.sol`, `src/SentinelSwapV3.sol`.

1. Brain: add constant `uint256 internal constant MIN_SANE_PRICE =
   1e18;` ($1 at the pipeline's 18-decimal USD scale) alongside
   `MAX_SANE_PRICE`. In `react()`, replace the F4 guard with:
   `if (price < MIN_SANE_PRICE || price > MAX_SANE_PRICE) return;`
   — consumed (marked seen) but never ingested, exactly like the
   zero/absurd path today.
2. Swap: add the same two constants (`MIN_SANE_PRICE = 1e18`,
   `MAX_SANE_PRICE = 1_000_000e18`) and event
   `event InsanePriceRefused(uint256 price);`. In `swapRiskForSafe`
   and `swapSafeForRisk`, after the zero-amount early return and the
   staleness check, after reading `price`: if `price == 0` return 0
   (unchanged); if `price < MIN_SANE_PRICE || price >
   MAX_SANE_PRICE` emit `InsanePriceRefused(price)` and `return 0`.
   The bound check sits BEFORE any multiplication on `price` (the
   overflow in AH-4 happens in `riskIn * price * safeUnit`).
3. Vault: NO new bound. The deposit path already band-checks the
   price against `lastSettledPrice` before `_poolRiskEq()` ever
   multiplies on it, and `executeProtection` reads `refPrice` only
   for the anchor update (guarded by `refPrice > 0`) while the swap
   itself now refuses insane fills. Adding a third bound would be
   decoration, not defence.

**Bound justification.** The pipeline scale is 18-decimal USD
(driver pushes kline × 1e10; the adapter normalises Chainlink
8-decimal answers × 1e10). Lowest legitimate price ever ingested is
$1,283.46 (June) — three orders of magnitude above the $1 floor — and
the live feed is ~$1,730. A $1 floor admits every plausible ETH price
and rejects the 1-wei cliff by 18 orders of magnitude. Scale note
(recorded as a residual risk): the constant is scale-dependent; a
future feed at a different scale would need it revisited — the
pipeline has exactly one scale today, so this is a note, not a
change.

**Regression tests:** 1-wei print consumed, `updates` does not
advance, no callback, brain keeps working on the next sane print;
$1 exactly passes (boundary is inclusive); swap refuses a 1-wei
fill (returns 0, emits `InsanePriceRefused`) and a $0.50 fill, and
still fills at $1.

### AH-4 — LOW — Absurd price bricks the in-flight callback (swap overflow)

**Root cause.** `swapRiskForSafe` multiplies `riskIn * price *
safeUnit` with no bound; a 2^200 print between decision and callback
overflows, `executeProtection` reverts, the position rides the crash
unprotected for 300 s. PoC `testH3_AbsurdPriceBricksCallbackAndBrainWontRefire`.
Pusher-gated; Chainlink answers cannot reach overflow scale.

**Fix — bound the reference price in the swap, fail-soft.**
File: `src/SentinelSwapV3.sol`. This is the AH-3 swap bound (§AH-3
point 2) applied to the top as well: `price > MAX_SANE_PRICE`
emits `InsanePriceRefused` and returns 0 in BOTH directions — never
a revert, so a callback can never be bricked by an insane price.
The reverse direction needs it too: its shortfall branch computes
`inventory * price * safeUnit`, which overflows the same way.

**Regression tests:** the H3 scenario on V6 — EXIT callback lands
(`protectionCount` 1, `managedRisk` 0) instead of reverting; both
swap directions return 0 on a 2^200 price and fill normally once the
price is sane again.

### AH-5 — LOW — Within-band deposit theft (band 50% → 20%)

**Root cause.** The Release 8 deviation guard allows a single print
50% from the last settled price. PoCs (all pusher-gated):
(a) pump to exactly 1.5× → depositor gains **+0.625 WETH (+12.5%)**,
Alice −0.625; (b) dump to $1,020 → victim loses **−1.213 WETH
(−24.3%)**; (c) 12-step +50% walk to ~130× → attacker **+2.5535
WETH (+41.2% on 6.2 deposited)**, Alice −25.5%.

**Fix — narrow the band.** File: `src/SentinelVaultV6.sol`.
Change `MAX_DEPOSIT_DEVIATION_BPS` from 5000 to **2000** (20%) and
the guard math to the constant (no magic fractions):
`if (price > lastSettledPrice * (10000 + 2000) / 10000 ||
price * 10000 < lastSettledPrice * (10000 - 2000)) revert
PriceDeviation(price, lastSettledPrice);`
Boundary is inclusive at exactly ±20% (strict `>` / `<`), matching
the old guard's inclusive-edge behaviour at 1.5×.

**Band justification.** Largest single hourly step in the June 2022
stream is ~8%; 20% keeps 2.5× headroom and never trips on the June
replay (deposits land at the just-settled price, deviation 0 — see
Gate 3). The walk to 100× now needs ~25 steps (1.2^25 ≈ 95.4) instead
of 12, each needing a settled deposit. The band is a speed bump, not
a wall — the allowlist + key hygiene is the real control (stated in
FIX-DESIGN §1 and unchanged here).

**Key separation is OPERATIONAL, not code.** Separating the pusher
key from the owner/dev key is a deploy-time step: the deploy script
creates a dedicated pusher key, `allowPusher`s it on the oracle, and
the driver uses ONLY that key for pushes. This design records it as
a deploy-runbook step (§5); it is NOT claimed as done until the
Gate 3 deploy actually does it. (Live today: the R8 oracle owner and
its only pusher are the same dev EOA — the V6 rehearsal is the first
set that separates them.)

**Regression tests:** repeat H4a/H4b/H4c on V6 and record the new
numbers — (a) pump to the new boundary (+20%) must mint near-fair
shares and the theft must be a small fraction of +12.5%; (b) dump
to −20% likewise; (c) 12-step +20% walk must net far below +41.2%;
a +21% single print must revert `PriceDeviation`; a +20% print
must pass.

### AH-6 — LOW — Owner `setVault` redirections silently disable protection

**Root cause.** `swap.setVault(attacker)` bricks the real vault's
callbacks (`NotVault`); `reactive.setVault(attacker)` sinks the
brain's callbacks to the attacker while the brain keeps burning fuel.
PoCs `testH5a` / `testH5b`. Owner-key-gated; the single-EOA risk
itself was already accepted (audit L4). What is NEW is the
mechanism: silent protection disablement via two one-line calls.

**Fix — single-use wiring lock (constructor-immutable-equivalent).**
Files: `src/SentinelReactiveV6.sol`, `src/SentinelSwapV3.sol`.

1. Add storage `bool public vaultLocked;`, error
   `error VaultAlreadySet(address vault);`, and keep the `VaultSet`
   event.
2. `setVault`: owner-only as today; first call sets `vault`,
   sets `vaultLocked = true`, emits `VaultSet`; any later call
   reverts `VaultAlreadySet(vault)` — even by the owner, even to
   the same address. The deploy flow (deploy → wire → read back)
   is unchanged; after wiring, no redirection is possible, ever.
3. The vault needs no change: `SentinelVaultV6` (like V5) takes
   `reactive_` and `swap_` as constructor immutables and has no
   `setVault` at all.

**Why this shape, and what was rejected (recorded).**
- *True constructor-immutable wiring* (pass the vault address into
  the brain/swap constructors) was considered and REJECTED: the
  vault's own constructor needs the brain and swap addresses
  (callback-sender + desk immutables), so the vault must be deployed
  last — the brain and swap would need the vault's address before
  it exists, i.e. CREATE-address prediction with strict nonce
  discipline. Our deploy history is full of resume/interruption
  incidents (R7 incident 1, R8 attack-script aborts) that would
  break a prediction-based deploy. The security property that
  matters — no post-deploy redirection — is fully achieved by the
  lock, with zero deploy fragility.
- *Multisig/timelock owner* was considered and REJECTED for this
  generation: it does not remove the mechanism (a multisig owner
  could still redirect, just slower) and adds deployment/ops
  complexity for a testnet entry. It remains the right answer before
  any mainnet-shaped deployment, and the single-EOA owner risk stays
  an accepted risk (L4) for everything else (desk drain, oracle
  allowlist, vault surplus rescue).
- The liveness watch keeps its `VaultSet` alarm: the event can now
  fire exactly once per contract, at deploy — any `VaultSet` after
  deploy is impossible by construction, and the alarm stays as the
  tripwire for the older sets.

**Regression tests:** `setVault` twice reverts `VaultAlreadySet`
on both contracts (brain + swap); the H5a/H5b scenarios on V6 —
`setVault(attacker)` after wiring reverts, the real vault's
callbacks keep working, `protectionCount` advances.

## 2. What is NOT changed

- Model, weights, features, anchor decay, `MIN_UPDATES`, cooldown
  300 s, TRIM suppression (10 updates), re-risk variant B (tranches,
  97% reclaim, 3-update minimum), staleness bound 3600 s, deviation
  guard structure (only the constant moves), surplus cap, callback
  auth, dedup, `pay()`/fuel mechanics, MCP, Live Proof, demo app.
- No change to any V5/V2/V5 file, no change to the mock oracle or
  the Chainlink adapter (AH-1 was already fixed by the migration's
  3600 s heartbeat — parameter-only, no code).
- No DoraHacks, README, docs or video change in this run (no push,
  no page edit — the parent owns those steps).

## 3. Release 6 set design (Gate 3 target)

A fresh parallel set, same pattern as Release 8: fresh
`MockPriceOracle`, fresh `SentinelSwapV3` (priceSource = the fresh
oracle), fresh `SentinelReactiveV6` (mock origin), fresh
`SentinelVaultV6`, all built from the V6 code. The R7/R8/flagship
sets are NEVER touched.

**Deploy script.** Copy `tools/deploy_release8.sh` to
`tools/deploy_release6.sh` and change: (a) rebuild from the V6 code
(contract names above); (b) gate: dev Lasna balance at least 2.40
lREACT before any deploy (2.20 attach + ~0.18 deploy gas — same as
R8; dev holds 1.8146 at design time, so ONE faucet round first);
(c) after the oracle deploy, read back `pricePushers(dev) == true`
and `owner() == dev`; (d) NEW — deploy a dedicated pusher key and
`allowPusher` it (AH-5 key separation, §1), and the driver pushes
with that key only; (e) after wiring, read back the new getters:
`swap.MIN_SANE_PRICE() == 1e18`, `swap.MAX_SANE_PRICE() ==
1_000_000e18`, `vault.MAX_DEPOSIT_DEVIATION_BPS() == 2000`,
`swap.vaultLocked() == true`, `reactive.vaultLocked() == true`,
`reactive.exitLatched() == false`, `vault.lastSettledPrice() == 0`;
(f) keep every R8 read-back gate (wiring, flagship untouched — new
flagship brain `0x162DdFa4…`, vault `0xD61E27bC…`, desk seed, billing)
unchanged. The flagship set is never touched by this script.

**Funding.** Brain: attach **2.20 lREACT** (same as R8; the June
consumption is expected at/below the R8 1.947808 — the latch can only
remove callbacks, and June has no repeat EXIT; +13.0% headroom over
1.947808, above the 10% rule). Desk: seed exactly 1,000 mUSDC.
Vault: users A/B/C deposit totalling 0.0065 WETH, billing 0.0001 ETH
(same as the R8 June core). Driver: reuse the R8 June push table
(56 tokens) and driver, pointed at the V6 oracle address. No new
price series: the replay must be bit-identical to the R8 June core
so the mirror predictions apply unchanged.

**June replay — expected end state (must match the R8 June core
exactly).** Brain `updates` 56, `lastAction` 2 (EXIT),
`protectionCount` 6 on the vault, vault `closed` true,
`totalShares` 0, `managedRisk` 0, `managedSafe` 0, desk
990.74943675 mUSDC / 0.006325 WETH, conservation to the wei
(users 0.000175 WETH + desk 0.006325 = 0.0065; users 9.25056325
mUSDC + desk 990.74943675 = 1,000). Why the patches change nothing
here, patch by patch: AH-2 latch (EXIT fires once, at update 56,
the last push — the latch is set and never read); AH-3/4 bounds
(no zero, 1-wei or absurd prices in the stream; all June prices
$1,283–$1,679 sit 3 orders above the $1 floor and 6 orders below
the $1M ceiling); AH-5 band (deposits land at the just-settled
price, deviation 0); AH-6 lock (wiring happens once, at deploy).
Any deviation from the R8 June-core end state is a patch
regression, not a new result. The patch phase must also run the
offline mirror (`tools/rerisk_variants.py`) against the patched
contract behaviour for the June stream and confirm the identical
callback sequence (the mirror models pre-F3 EXIT reset and has no
latch — June has EXIT only at the last push, so the prediction
applies unchanged).

**Bleed scenario (AH-2, Gate 3 second leg).** After the June core
and final redemption (vault empty, brain at updates 56), run the
H12 shape on-chain: 40 fresh pushes, −1% per update, hourly origin
spacing, starting from a sane price. Expected: **3 callbacks total
for the bleed leg** (the June leg's 6 stay in the past; count the
bleed leg separately from the pre-bleed `callbackCount`), `updates`
96, `lastAction` EXIT, `exitLatched` true. Fuel for the bleed leg
is read from the brain balance delta. NOTE: the bleed leg runs on
the SAME brain after the June core (updates 56 → 96), because the
latch behaviour needs a live brain with real history; the vault is
empty at that point, so bleed callbacks are no-ops by construction
— which is exactly the point (they must not even be requested).
The June-core final state (§above) is recorded BEFORE the bleed leg
starts, so the two legs never mix in the record.

**Attack re-runs (Gate 3 third leg, all must FAIL as required).**
On the V6 set, from a stranger address: AH-3 1-wei push (allowlisted
pusher only — stranger reverts `NotPusher`; then the dev pusher
pushes 1 wei and the brain consumes it without ingesting,
`updates` unchanged); AH-4 2^200 push then an EXIT callback attempt
(swap returns 0, `InsanePriceRefused`, no revert, position intact);
AH-5a/b/c deposit attempts at the new band edges (record the new
theft numbers); AH-6 `setVault(attacker)` on both contracts
(reverts `VaultAlreadySet`, wiring unchanged). The pre-drive
F1a/F1b/F4 checks from the R8 rehearsal are NOT re-run (unchanged
code paths, already proven on identical code); the record says so.

**Pre-run forge gate.** Before any live push, the patch phase adds a
forge test replaying the exact June deposit/fill sequence through
the V6 vault (deposits at run start, TRIM/EXIT fills at the recorded
prices) and asserts no deposit reverts on the deviation guard or
the staleness check. If a legit June deposit trips either guard, the
guard parameters are wrong and the design (not the test) must be
revisited. (In practice the June deposits sit at deviation 0 — this
gate is a tripwire, not an expectation.)

**Acceptance criteria for Release 6.** (1) Full forge suite green
including `test/Release6Regression.t.sol`; (2) the June replay end
state matches the R8 June core exactly (§3); (3) the bleed leg shows
3 callbacks, not 20; (4) all attack re-runs fail as required;
(5) Sourcify `exact_match` for all four V6 contracts; (6) wiring
read-backs pass (brain oracle/vault, vault swap/callback sender,
swap priceSource/vault, all in-set; `vaultLocked` true on brain +
swap); (7) no deposit was taken into the V6 vault before the replay
completed; (8) the flagship set is untouched at every step
(checked before and after: flagship brain updates 1, vault shares
2e15).

## 4. Test plan for the patch phase

**New file.** `test/Release6Regression.t.sol` with the tests named
below. Each must FAIL on the old code and PASS on V6; the patch
phase demonstrates the fail-before run by running the same
scenarios against the V5/V2/V5 contracts (the AttackerHunt PoCs
already do this — H12 20 callbacks, H2 dust sale, H3 revert,
H4a/b/c theft, H5a/b redirection — and the new tests assert the
opposite on V6). No existing test file is modified; the AttackerHunt
PoCs stay as the V5 behaviour record.

- `testAH2_BleedCallbacksCollapse`: the H12 scenario on V6
  (−1% × 40, hourly). Before (V5): 20 callbacks. After (V6):
  exactly 3 (2 TRIM + 1 EXIT), `exitLatched` true, `updates` 40.
- `testAH2_LatchClearsOnTranche1AndFreshExitProtects`: crash →
  EXIT (latched) → recovery prints firing tranche 1 (latch
  clears) → second crash leg fires EXIT again (protection for the
  restored half works). Pins the §1 trade-off.
- `testAH2_LatchClearsOnTranche2AndFreshTrimFires`: V5R shape —
  EXIT, tranche 1, tranche 2, then a fresh TRIM vote fires.
  Pins the re-risk cycle surviving the latch.
- `testAH2_SuppressedExitVotesStillDecide`: while latched, EXIT
  votes still emit `Decision` (votes stand, only callbacks are
  withheld).
- `testAH3_OneWeiPriceConsumedNotIngested`: 3 calm prints, 1-wei
  print, then sane prints. Before (V5): EXIT + dust sale. After
  (V6): `updates` stays 3 through the 1-wei print, no callback,
  later prints ingest normally, `lastAction` HOLD.
- `testAH3_SwapRefusesSubDollarFill`: swap returns 0 +
  `InsanePriceRefused` at 1 wei and at $0.50, fills normally at
  $1.00 exactly (boundary inclusive).
- `testAH4_AbsurdPriceCannotBrickCallback`: the H3 scenario on
  V6 — EXIT callback lands, `protectionCount` 1, `managedRisk`
  0; both swap directions return 0 at 2^200 and fill normally
  once sane.
- `testAH5_Pump20pcTheftIsSmall`: H4a at the new +20% boundary —
  record the new theft (expect a small fraction of the old +12.5%).
- `testAH5_Dump20pcHaircutIsSmall`: H4b at −20% — record the new
  haircut (expect a small fraction of the old −24.3%).
- `testAH5_Walk12StepsAt20pcIsSmall`: H4c with +20% steps — record
  the new net (expect far below the old +41.2%).
- `testAH5_BandEdge21pcReverts20pcPasses`: +21% deposit reverts
  `PriceDeviation`; +20% passes.
- `testAH6_SetVaultSecondCallReverts`: brain + swap `setVault`
  twice — second call reverts `VaultAlreadySet` on both; wiring
  still points at the real vault.
- `testAH6_RedirectionAttemptKeepsProtection`: H5a/H5b shapes on
  V6 — `setVault(attacker)` reverts, the next TRIM/EXIT callback
  executes, `protectionCount` advances.
- `testV6_JuneCoreMirrorExact`: the 56 June closes fed through
  the V6 brain (mock system) — callback sequence TRIM@9/21/32/44/55,
  EXIT@56, 30 suppressed, 0 cooldown blocks. Pins the replay
  before any live spend.

**Count.** Baseline is 205/205. After the patch phase the count is
205 + (regression tests added, 14 named above). No test retires:
V5 behaviour is preserved in its own files, and the V6 tests are
additive. Expected final count: **219**.

## 5. Deploy runbook notes (Gate 3)

- Faucet: 1 round (+2.0–2.1 lREACT) before deploy; dev Lasna
  1.8146 at design time, gate 2.40.
- Pusher key: generate a DEDICATED pusher key for the V6 oracle
  (new burner-style keypair, stored ONLY in the burners env file,
  never in the repo); `allowPusher` it; the June/bleed drivers push
  with that key only; the dev key never pushes. Record both
  addresses in the rehearsal record.
- Pacing: June pushes ≥ 42 s apart (mirror floor 40 s); bleed
  pushes ≥ 42 s apart wall-clock (origin spacing is hourly in the
  log data, wall-clock pacing is the driver's floor).
- Staleness: all fills land minutes after their emission, far
  inside 3600 s; deposits happen within 3600 s of a push.
- Flagship checks before/after every step: brain updates 1,
  vault shares 2e15, brain oracle = Chainlink adapter
  `0xcc99348d…`. Any change ABORTS the run.

## 6. Residual risks (stated, not hidden)

1. **React spend is the AH-2 floor.** A 40-hour bleed still costs
   ~1.18 lREACT in reactions alone. If a future brain runs a
   multi-day bleed at hourly cadence, funding must cover reacts,
   not just callbacks. The liveness watch keeps its balance alarm.
2. **Sawtooth markets.** Each recovery-then-crash cycle can cost
   one EXIT + two re-risk callbacks. That is genuine protection
   work (each cycle moves real funds), but it is not zero.
3. **The $1 floor is scale-dependent.** One pipeline scale exists
   today (18-decimal USD). A future feed at another scale needs
   the constant revisited.
4. **The 20% band is a speed bump.** A compromised pusher with ~25
   settled deposits can still walk the price ~100×. The allowlist
   + key separation is the real control; the band buys time and
   alarms.
5. **Single-EOA owner remains.** The lock removes redirection only.
   Desk drain, oracle allowlist changes, vault surplus rescue and
   all other owner powers are unchanged accepted risks (L4).
6. **Latch vs a re-armed vault.** The brain cannot see deposits.
   If a vault is re-armed by a deposit while latched (and no
   tranche/cancel intervenes), the next crash leg's first EXIT vote
   is withheld; protection resumes after the first tranche-1 or
   cancel, or after the latch clears on the next recovery. Worst
   case is one withheld vote per latched period, never a permanent
   blind spot — and the June/V5R/stretch shapes all clear the latch
   through their normal re-risk cycles.

## 7. Open decisions the patch phase must NOT decide alone

1. **Live deploy of the V6 set.** This run builds + rehearses a
   parallel set only. Deploying V6 as a live set needs the user's
   word.
2. **Flagship migration to V6.** Redeem the flagship vault,
   deposit into V6, re-point the app / Live Proof / MCP — needs
   explicit user approval, as before.
3. **Multisig/timelock owner.** Deferred to a mainnet-shaped
   deployment; not part of V6.
4. **Pusher-key custody.** The dedicated V6 pusher key is a testnet
   driver key. Whether the flagship's pusher is ever separated from
   the dev key is an ops decision for the parent/user, not this run.

## 8. Addendum — live-run corrections (2026-11-27, Gate 3)

Two design predictions were wrong on the live set; the code was right
in both cases. The record below corrects the predictions, not the code.

1. **Bleed callback count: 3 predicted, 0 observed — and 0 is
   correct.** §3 predicted 3 bleed callbacks (the fresh-brain H12
   shape: 2 TRIM + 1 EXIT). On the post-June brain the June episode
   anchor (~$1,594) carries over, so the bleed votes EXIT from push 1
   and the latch suppresses ALL 40. The bleed script's final
   assertion aborted on the stale "9" and was corrected to 6
   (June 6 + bleed 0) in `tools/rehearse_release6_bleed.sh`.
   Fuel matched the prediction anyway: 1.3106 lREACT (vs ~1.33
   predicted) — the bleed is dominated by the 40 reactions, not the
   callbacks.
2. **AH-5 live check needs a mixed pool.** The attack script's AH-5
   section aborted on the post-June vault because managedSafe == 0,
   so the band guard correctly does not engage (there is nothing to
   reprice) — the +21% deposit reverted for missing allowance, not
   for PriceDeviation. The live band proof moved to the recovery leg
   (Phase B), which rebuilt a mixed pool first: +21% reverts
   PriceDeviation on-chain, +20% succeeds. See V6-REHEARSAL.md §5.
3. **Tranche-1 fired organically during the AH-5 attack.** The
   attack's own price pushes ($1,283.46, then $1,552.99 >= 97% of the
   $1,593.96 June anchor) fired tranche-1 at update 100 — latch
   cleared live, reriskCount 0->1, prot 6->7 — before the recovery
   leg ran. The recovery leg's Phase R was therefore skipped and the
   leg started at Phase D. The latch-clear is proven live by this
   accident, not by a staged recovery.
