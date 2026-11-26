# Sentinel Release 7 — design (live firing record on real June 2022 data)

Status: **design only — NOT deployed, nothing pushed to git, no public
page edited.** Written 2026-11-26 (WIB) from read-only research and
mirror runs. Naming: **Release 7** throughout. (Mapping, one line only:
Release 7 is the set formerly sketched as "trio #6"; do not use that
name anywhere else.)

Deadline: **5 Dec 2026 20:00 UTC / 6 Dec 03:00 WIB** (Reactive Omni
Buildathon, Build 51122, track Reactive Meets AI).

## 1. Goal + the gap it closes

The live system (Release 6) is real and healthy, but it has never
fired. Its brain, `SentinelReactiveV5`
`0x37EeF5e3179E55c0e96E1528180B55Fa20DC150B` on Lasna, subscribes to the
real Chainlink ETH/USD feed and, re-read live for this design on
26 Nov ~21:37 WIB, stands at `updates = 3`, `lastAction = 0` (HOLD),
balance 11.5613437 lREACT — the same three HOLD updates recorded at
the flagship window (FLAGSHIP-V5.md), with the guard never firing
because the real price never dropped enough. The flagship vault holds
its 0.002 WETH owner seed, `protectionCount = 0`. Release 7 closes
exactly that gap: a **fresh, parallel** brain + vault + desk + oracle
set that produces a **live firing record — TRIM then EXIT callbacks
executing on-chain with real token transfers** — before the deadline,
**without touching the flagship set and without faking its feed**.
The flagship keeps the real Chainlink feed; Release 7 replays real
historical prices through a mock oracle on its own set, labelled as a
replay. The firing proof for the vault code itself already exists
(V5R rehearsal, 31 pushes, wei-exact); what Release 7 adds is the
same proof driven by **real market data** instead of a synthetic
series.

## 2. Feed decision

### 2a. Chosen: MockPriceOracle replaying a real historical volatile ETH series

**The series.** Binance ETHUSDT hourly closes, June 2022 crash,
cached at `tools/data/klines_jun2022.json` (505 closes, 1e8-scaled
ints, 2022-06-06 00:00 UTC start). Release 7 replays a contiguous
window of it:

- **Window: klines indices 120–175, 56 pushes.**
- Start: **11 Jun 2022 00:00 UTC, $1,679.28** (index 120, the window
  maximum — the window is a monotone decline, max drawdown −23.57%).
- End: **13 Jun 2022 07:00 UTC, $1,283.46** (index 175).
- Push values are the raw cached ints scaled ×1e10 to the pipeline's
  18-decimal USD convention (`price18 = kline × 1e10`), exactly as
  `tools/rehearse_vaultv5.sh` pushes `int(round(p * 10**18))`. The
  model is scale-invariant; the desk is not — the ×1e10 is load-bearing
  and the driver must assert it per push.

**Mirror prediction (actually run, not asserted).** A full-brain
simulator (`/tmp/r7_mirror.py`, kept out of the repo pending the
deploy decision) replicates `SentinelReactiveV5.react()` exactly —
ring window 9, anchor stream, MIN_UPDATES 3, TRIM suppression (10
updates, EXIT bypass at anchorDD ≥ 18% + momentum < 0), 300 s cooldown
on origin timestamps, fired-state reset on EXIT, variant-B episode
machine — over the shipped `SentinelWeightsV2` via
`tools/train.py` (`forward_int_v2`, `features7_from_window`,
`anchor_stream`). Mirror validation first: on the full episodes the
simulator's vote counts reproduce ANCHOR.md §4 **exactly** — Jun 2022
H/T/E 213/148/142, May 2021 276/219/104, Aug 2024 408/107/12. Only
then was the window prediction trusted. Predicted sequence for
indices 120–175 (votes H/T/E 18/35/1; 30 TRIM votes suppressed by
the anti-flap window; 0 cooldown blocks; 0 same-update double-fires;
identical at 35 s, 40 s and 60 s push spacing):

| Update | Closes time (UTC) | Price | Action | AnchorDD | Note |
|---|---|---|---|---|---|
| 1–8 | 11 Jun 00:00–07:00 | $1,679.28 → $1,667.46 | HOLD ×8 | — | calm stage, no callbacks |
| 9 | 11 Jun 08:00 | $1,578.19 | **TRIM** | 5.5% | window-drawdown TRIM; episode anchor $1,670.70 |
| 21 | 11 Jun 20:00 | $1,523.34 | **TRIM** | 7.7% | ratchet; anchor $1,650.76 |
| 32 | 12 Jun 07:00 | $1,471.26 | **TRIM** | 9.9% | ratchet; anchor $1,632.69 |
| 44 | 12 Jun 19:00 | $1,479.59 | **TRIM** | 8.3% | ratchet; anchor $1,613.21 |
| 55 | 13 Jun 06:00 | $1,324.35 | **TRIM** | 17.0% | last TRIM, just below the 18% EXIT band |
| 56 | 13 Jun 07:00 | $1,283.46 | **EXIT** | 19.5% | anchor EXIT band crossed; vault closes |

The driver **stops after update 56**. Six callbacks, all with real
fills (position open throughout; each TRIM sells half the remaining
risk, EXIT sells the rest — predicted fills in §3). No RERISK in this
window: the price never recovers to 97% of the $1,593.96 EXIT episode
anchor inside it, and the window ends at the EXIT by design.

**Why this window and not a shorter one.** June windows starting
later are cheaper but thinner: [156..178] is 23 pushes with TRIM@11 +
EXIT@21 (plus post-EXIT repeat fires TRIM@22 + EXIT@23 if all 23 pushes
are made — a driver must stop at EXIT@21, as the core does at update
56), but it cold-starts mid-crash ($1,463.09) with no meaningful
calm stage and the anchor never sees the $1,679 level. [120..175]
keeps an 8-push HOLD calm stage, the full 11→13 Jun decline leg
(−23.6%), and five ratchet TRIMs — the on-chain ratchet semantics
ANCHOR.md §4 evaluates, not a single TRIM. May 2021 [252..276]
(25 pushes, TRIM@14 + EXIT@24, plus EXIT@25 after) and Aug 2024 [280..296] (17 pushes,
TRIM@8 + EXIT@15, plus TRIM@17 after) are recorded fallbacks if fuel runs short; both
cold-start deeper into their crashes and are weaker stories.

**RERISK: honestly absent from the June core.** The full 505-push
June stream does contain 5 RERISK + 1 RERISK_FINAL, but reaching them
costs ~400 pushes (~12 lREACT) — not viable. The viable real-data
re-risk is the **Aug 2024 stretch window [280..382], 103 pushes**:
TRIM@8 ($2,688.92), EXIT@15 ($2,268.21), then a real two-way cycle —
RERISK@97 ($2,585.83, tranche 1) and RERISK_FINAL@102 ($2,640.90,
tranche 2). It is a **stretch, not the core**: it needs a second fresh
set (a brain cannot continue from June prices into August ones), costs
~3.35 lREACT, and carries 7 no-op callbacks on the closed vault
(TRIM@17/27/41/55/68/79, EXIT@21) whose only function is walking the
episode anchor down to a reclaimable level — each still burns a react
plus callback gas, and the run's record must list them as no-ops, not
hide them. Decision on the stretch is deferred until the June core
has landed. The two-way capability itself is already proven by #5R
(synthetic); Release 7 core does not re-prove it.

**Cadence (ANCHOR.md §6), addressed head-on.** No downsampling: the
replay uses contiguous hourly closes, one push per close. The anchor
decay is per *update* (×999/1000), so the anchor horizon in
update-space is identical to the hourly backtest the constants were
tuned at (half-life ≈ 693 updates). What compression changes is wall
time only: 56 hours of market time become ~40 minutes of driving, and
the 300 s cooldown reads origin (block) timestamps, not market time.
That difference is inert here **by measurement**: the simulated
sequence is identical at 35 s, 40 s and 60 s push spacing, with zero
cooldown blocks — TRIM suppression (10 updates) dominates the
cooldown at any spacing ≥ 35 s. What the replay proves is that the
contract logic fires on this exact price path; what it does **not**
prove is wall-clock behaviour (that the brain would have fired at
those UTC times live). The public wording (§2c) says exactly that.

### 2b. Evaluated and rejected: a live Chainlink feed of a more volatile asset

Feeds checked live on Base Sepolia (read-only `latestRoundData`,
26 Nov ~21:37 WIB):

- **ETH/USD** `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` (the
  flagship adapter's own feed, confirmed by reading the adapter's
  `feed()`): answer $1,697.58664063, round updated ~5 minutes before
  the read. The flagship anchor is $1,680.87 — the feed has moved
  roughly +1% in the two days since the flagship window.
- **LINK/USD** `0xb113F5A928BCfF189C998ab20d753a47F9dE5A61`: live,
  answer $9.22094315, round updated ~5 minutes before the read.
- **BTC/USD on Base Sepolia**: no feed address verified in this pass
  (the one candidate address checked is not a Base Sepolia Chainlink
  aggregator); no BTC/USD address is claimed here. It does not affect
  the verdict.

**Verdict: rejected — it cannot guarantee a firing before the
deadline, and that must be said plainly.** The brain fires EXIT only
at anchor drawdown ≥ 18% (with negative momentum) or window drawdown
≥ 21%. No live feed — ETH, LINK, or anything else — can be made to
fall 18% on demand before 5 Dec; the market decides. Waiting on a
live feed also burns the remaining 9 days on hope: the flagship has
already waited through its whole live window for a move that never
came. Switching assets would additionally need a new adapter, a new
risk asset in the vault/desk (the whole system is WETH-shaped in
every prior run; LINK token exists on Base Sepolia but nothing else
is wired for it), and a fresh validation of the model on that asset's
volatility regime. The live-feed option stays open only as the
flagship's own ongoing watch (the 48 h liveness cron), not as
Release 7's firing plan.

### 2c. Exact honesty wording for the public page

> "Release 7 replays real Binance ETH hourly closes from the June
> 2022 crash (11–13 June 2022) through a mock price oracle. The
> prices are genuine historical market data; the timing is a replay,
> not a live market feed — the brain ingests one historical close per
> push, in order, at the project's own pace. The guard's decisions,
> callbacks and token transfers are live on-chain; the price path is
> history. The live system (Release 6) keeps its real Chainlink feed
> and was not touched."

## 3. System

**Fresh set, same code, no new contracts.** `SentinelReactiveV5`,
`SentinelVaultV5`, `SentinelSwapV2`, `MockPriceOracle` — byte-identical
to the V5R/flagship deployments. No new contract code: nothing in the
design requires it (the mock origin, the desk pricing off
`latestPrice`, and the vault's closed-vault no-op behaviour already
cover every step of the run).

| Contract | Chain | Address |
|---|---|---|
| MockPriceOracle (fresh) | Base Sepolia | TBD at deploy |
| SentinelReactiveV5 (fresh brain, mock origin, cooldown 300 s) | Lasna | TBD at deploy |
| SentinelSwapV2 (fresh desk) | Base Sepolia | TBD at deploy |
| SentinelVaultV5 (fresh vault) | Base Sepolia | TBD at deploy |

Reused shared contracts: WETH
`0x4200000000000000000000000000000000000006`, MockUSDC
`0x96E467Ff7958851d307D28118EBAAD333CAb85B2`, callback proxy
`0x476F44b11F5C942c58f4c8E3d0300E5710743585` (same as V5R/flagship).

**Wiring (flagship order, proven):** deploy desk with vault =
`address(0)` → deploy brain on Lasna with attach (constructor args
`84532, <oracle>, <WETH>, 84532, 300`) → deploy vault (constructor
args `<proxy>, <brain>, <WETH>, <MockUSDC>, <desk>`) → `swap.setVault`
→ `reactive.setVault` → verify both by read. Then seed: desk exactly
**1,000 mUSDC** (mint); vault callback billing **0.0001 ETH**; brain
attach **2.00 lREACT** (see §7 — one faucet round is needed first).

**Users / deposits (V5R burner pattern, same three burners, same
amounts — the keys already exist in the goal's
`hidden_files/vaultv5-rehearsal-burners.env`, mode 600; the burners
still hold 0.0069–0.0085 Base ETH each from V5R, enough for wraps and
gas, top up only if a read says otherwise):**

- **A: 0.003 WETH before push 1** (first deposit, 1:1,
  3,000,000,000,000,000 shares).
- **B: 0.002 WETH after TRIM@9 lands** (mixed pool; pool risk-eq at
  $1,578.19 is exactly 0.003 → 2,000,000,000,000,000 shares, same as
  V5R's B).
- **A partial redeem: 1,000,000,000,000,000 shares after TRIM@32
  lands** (mid-episode exit, pro-rata of the then-current
  composition).
- **C: 0.0015 WETH after TRIM@44 lands** (mixed pool at $1,479.59 →
  1,457,221,886,906,302 shares, floored formula).
- **Final redemption: A, B, C `redeemAll` in order after EXIT@56.**

**Predicted fills at live size** (integer-wei desk math,
`safeOut = riskIn × price / 1e18`, computed from the mirror prices —
the same standard as #5R: series validated on the mirror at live
position size before a single push):

| Step | Action | Fill | Managed totals after |
|---|---|---|---|
| TRIM@9 $1,578.19 | sell 0.0015 WETH | +2.367285 mUSDC | risk 0.0015, safe 2.367285 |
| TRIM@21 $1,523.34 | sell 0.00175 WETH | +2.665845 mUSDC | risk 0.00175, safe 5.03313 |
| TRIM@32 $1,471.26 | sell 0.000875 WETH | +1.2873525 mUSDC | risk 0.000875, safe 6.3204825 |
| A partial redeem | 1e15 shares | +0.000175 WETH +1.2640965 mUSDC | risk 0.0007, safe 5.056386 |
| TRIM@44 $1,479.59 | sell 0.00035 WETH | +0.5178565 mUSDC | risk 0.00035, safe 5.5742425 |
| TRIM@55 $1,324.35 | sell 0.000925 WETH | +1.22502375 mUSDC | risk 0.000925, safe 6.79926625 |
| EXIT@56 $1,283.46 | sell 0.000925 WETH | +1.1872005 mUSDC | risk 0, safe 7.98646675, closed |
| Final redeemAll A | 2e15 shares | +2.926934955370680890 mUSDC | safe 5.05953179462931911 |
| Final redeemAll B | 2e15 shares | +2.926934955370680890 mUSDC | safe 2.13259683925863822 |
| Final redeemAll C | 1,457,221,886,906,302 shares | +2.132596839258638220 mUSDC (full-redemption remainder) | 0 / 0 / 0 |

A and B hold equal shares at the end and receive identical final
payouts (the fairness property, as in V5R). Conservation (predicted):
WETH — users 0.000175 + desk 0.006325 = 0.0065 deposited;
mUSDC — users 9.25056325 + desk 990.74943675 = 1,000 seeded.
Desk seed is ample: the largest single fill is 2.665845 mUSDC
against a 1,000 mUSDC reserve.

## 4. Invariants

INV-1..INV-7 as in VAULTV5-DESIGN.md §9, unchanged (backing;
clean reset; exact reconciliation; fraction stability; no rounding
theft; donation neutrality; interface parity with V4). The rehearsal
must assert INV-1 at every snapshot and INV-3/INV-4 across the full
run, exactly as V5R did.

**INV-8 (firing proof — new for Release 7):** the run's TRIM and EXIT
callbacks execute on-chain with real token transfers: each fired
callback moves vault managed totals by the desk fill at the pushed
price (risk down, safe up, recomputed from the desk formula to the
wei); the EXIT callback leaves `managedRisk = 0`, `closed = true`,
and the full redemption sequence afterwards pays out exactly the
managed totals, to the wei, per asset. The RERISK half of INV-8
(tranche callbacks with real buys) is **not** claimed for the June
core — the June window supports no re-risk — and is deferred to the
Aug stretch (§2a), where it would be asserted the same way.

## 5. Test plan

No new contract code, so **no new tests are required**. The gate is
the existing suite, unregressed:

- Local gate before any transaction: `forge build --force` +
  `forge test` → **165/165 pass**. Verified for this design on
  26 Nov ~21:40 WIB: 24 suites, 165 passed, 0 failed, 0 skipped.
- The series validation is the mirror run (§2a), not a Foundry test:
  the full-brain simulator reproduces ANCHOR.md §4 vote counts
  exactly before the window prediction is trusted. A Foundry test
  pinning the 56-price sequence would duplicate the mirror and is
  explicitly **not** a gate — if the deploy team wants one later it
  is nice-to-have, not blocking.
- The driver (new `tools/rehearse_release7.sh`, §6) is dry-run
  against the mirror's expected update/action table before broadcast:
  every push asserts `updates` increments by exactly 1 and
  `lastAction` matches the prediction.

## 6. Rehearsal plan

New driver `tools/rehearse_release7.sh`, adapted from
`tools/rehearse_vaultv5.sh` (same helpers: `push` with react
confirmation, `wait_prot`, `snap` with INV-1 assertion, `fail` =
abort with state preserved). Transcript to the goal's `hidden_files/`
(not /tmp — V5R's sibling driver lost its /tmp transcript to a
service restart once; the release driver logs to the goal directory
from the first line). Differences from V5R, all deliberate:

1. **Price source:** pushes read `tools/data/klines_jun2022.json`
   indices 120–175 (assert the file hash matches the mirror run's
   input before starting; the repo copy survived — the /tmp klines
   did not).
2. **Scale:** each push sends `kline × 1e10` (18-decimal USD);
   assert the pushed value equals the cached int × 1e10.
3. **Pacing:** pushes spaced to keep origin-timestamp gaps ≥ 40 s
   (the mirror is spacing-invariant at 35–60 s; 40 s is the floor
   the design validated — do not push faster without re-running the
   mirror). Expected drive time ~40 minutes for 56 pushes.
4. **Stages and expected gates** (any mismatch aborts):
   - Stage A (updates 1–8, $1,679.28 → $1,667.46): HOLD ×8,
     `protectionCount = 0`. Snapshot after update 8.
   - Stage B (updates 9–56): TRIM@9 → wait `protectionCount = 1`,
     snapshot, B deposits; TRIM@21 → count 2; TRIM@32 → count 3,
     snapshot, A partial redeem; TRIM@44 → count 4, snapshot, C
     deposits; TRIM@55 → count 5; EXIT@56 → count 6,
     `closed = true`. Snapshot after every callback.
   - **Stop.** No update 57 is ever pushed — this is the load-bearing
     rule of the run (see §9, risk R-2).
   - Final redemption A → B → C (`redeemAll`), snapshot after each;
     final snapshot must read totalShares 0, managedRisk 0,
     managedSafe 0, raw vault balances 0/0.
5. **Reconciliation checks** (independent recomputation from recorded
   states, as in V5R §4): share mints from the design formula
   (A 1:1, B 2e15, C 1,457,221,886,906,302); every fill from the desk
   formula at the pushed price; partial redeem pro-rata; final
   payouts summing to the pre-sequence managedSafe to the wei; WETH
   and mUSDC conservation (§3). The predicted table in §3 is the
   oracle for these checks — a deviation of even 1 wei aborts the
   run's claim, it does not get rounded away.
6. **Incident logging:** every anomaly goes in the run record in
   V5R §7 style (tooling-side vs contract-side, chain impact or
   none), including transient RPC failures and any cooldown wait that
   engages. If the driver process dies, resume only by rebuilding
   state from chain reads (updates, oracle `PriceUpdated` history,
   vault counters) and pushing only the not-yet-pushed indices — a
   price is never pushed twice (oracle history count and reactive
   `updates` must agree before resuming).

## 7. Deploy plan + cost estimate

Deploy order (flagship-proven): oracle → desk (vault `address(0)`)
→ brain on Lasna (attach at deploy) → vault → `swap.setVault` →
`reactive.setVault` → verify by reads → seed desk 1,000 mUSDC →
fund vault billing 0.0001 ETH → deploy Sourcify verification
(`exact_match`, creation + runtime, as for every prior set).

**Balances read for this design (26 Nov ~21:37 WIB):** dev wallet
`0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94` — Base Sepolia
0.064233236539342257 ETH; Lasna 0.702646799986753522 lREACT; Sepolia
0.69014664227270493 ETH. (Private key lives in
`project/.env.local` as `PRIVATE_KEY`; it is read by the deploy
scripts and never printed or copied anywhere.)

**June core cost estimate** (derived from measured V5R/flagship
numbers; labelled estimate, not measured — the run itself is what
measures it):

| Item | Estimate | Derivation |
|---|---|---|
| lREACT, 56 reacts | ~1.655 | 56 × 0.0295521 measured burn/reaction |
| lREACT, 6 callback requests | ~0.170 | 6 × ~0.0283 (V5R residual: (1.085725 − 31×0.0295521)/6) |
| lREACT, brain attach | **2.00** | round-up of ~1.83 consumed, same headroom style as V5R (1.40 attach vs 1.086 used) |
| lREACT, deploy + setVault gas | ~0.18 | measured twice (V5R 0.1801715; flagship 0.18017 inside 1.33017) |
| lREACT, total needed | ~2.18 | attach 2.00 + deploy gas 0.18 |
| Sepolia ETH, faucet round | 0.02 | 1 round `request(dev)` → +2.1 lREACT (dev 0.7026 + 2.1 = 2.80 ≥ 2.18 ✓) |
| Base Sepolia ETH burned (gas) | ~0.009 (range 0.008–0.011) | V5R burned 0.0065383 for 31 pushes + same fixed shape (3 Base deploys, wiring, ~13 user txs); +25 pushes at ~0.0001 each |
| Base Sepolia ETH principal (not burned) | 0.0001 billing + 0.0065 WETH deposits | billing mostly unspent (V5R's 6 callbacks drew 0.0000078); deposits return via redemption |
| Sepolia ETH total | 0.02000000002 | 1 faucet round incl. its gas |

Dev Base balance 0.0642 ETH covers the ~0.009 burn ~7× over; no
bridge is needed. **Aug stretch (if approved later):** second fresh
set, 103 pushes → ~3.35 lREACT consumed (attach 3.50), 2 faucet
rounds (0.04 Sepolia ETH), Base burn ~0.014, drive time ~80 min.
Total worst case (core + stretch): ~0.06 Sepolia ETH, ~0.023 Base
ETH burned, ~5.5 lREACT — all inside current balances plus faucet
rounds.

**Minimal-spend rules:** no spend beyond this table without a fresh
decision; the faucet round happens only after `forge test` 165/165
and the mirror re-run pass; the brain attach is 2.00, not more;
burner top-ups only if a pre-run balance read says a burner cannot
cover its wraps + gas.

## 8. Drafted Release 7 page-section text

(Short, public-facing, Release naming, honesty wording from §2c.
Only measured or mirror-predicted numbers appear; mirror numbers
are labelled as the pre-run prediction until the run lands.)

> **Release 7 — the guard fires on real crash data.**
>
> Release 6 proved the live system holds calmly on the real
> Chainlink feed. Release 7 proves it fires. We replayed real
> Binance ETH hourly closes from the June 2022 crash — 11 June
> 00:00 UTC ($1,679.28) to 13 June 07:00 UTC ($1,283.46), 56 closes
> in order — through a mock price oracle into a fresh brain, vault
> and desk. The prices are genuine historical market data; the
> timing is a replay, not a live market feed. The decisions,
> callbacks and token transfers are live on-chain.
>
> The mirror predicted the sequence before a single push, and the
> chain reproduced it update for update: five TRIMs as the fall
> deepened (11 Jun 08:00, 11 Jun 20:00, 12 Jun 07:00, 12 Jun 19:00,
> 13 Jun 06:00), then EXIT at 13 Jun 07:00 as the anchor drawdown
> crossed 18%. Three users held shares through the episode — one
> redeemed part-way, one joined mid-fall — and all three redeemed in
> full afterwards, reconciled to the wei. [Tx hashes, addresses and
> final counters to be filled from the run record; nothing here is
> claimed before it lands.]

## 9. Open questions / risks

- **R-1 — lREACT shortfall (gate, not a risk to discover later).**
  Dev Lasna holds 0.7026 lREACT; the run needs ~2.18. One faucet
  round (+2.1) is required *before* deploy. Gate: after the round,
  dev Lasna ≥ 2.18 lREACT or the deploy does not start. If the
  faucet contract ever refuses, the run is blocked, not improvised.
- **R-2 — the repeat-EXIT hazard (the run's sharpest edge).** After
  an EXIT fires, the contract resets its fired-state, so *every*
  further EXIT vote fires immediately — and in June 2022 EXIT votes
  persist for ~200 updates. The full 505-push stream would fire 142
  EXIT callbacks, nearly all no-ops on a closed vault, at ~0.03
  lREACT each. The driver MUST stop after update 56; the run's
  abort rule is inverted here — continuing is the failure mode.
  Mitigation: the stage table (§6) ends at EXIT@56 with no further
  push defined, and the driver asserts `updates` before every push.
  [Release 8 fix: the fired state is now KEPT across the EXIT
  (`_lastFiredAction = EXIT`, `_lastFiredTs = originTs`), so repeat
  EXIT votes are cooldown-gated at 300 s instead of firing
  immediately. Accepted cost: a genuinely new position's first TRIM
  can wait up to 300 s. See FIX-DESIGN.md §1 F3.]
- **R-3 — no RERISK in the core.** If the judges read "firing
  record" as needing the way back in too, June alone does not
  deliver it. The Aug stretch (§2a) is the honest answer; deciding
  it after the core lands keeps the core's cost and story clean.
  Do not claim a re-risk the June run never performed.
- **R-4 — mock oracle is anyone-can-push.** A stray `setPrice` from
  anyone would advance `updates` and desync the mirror. Mitigation:
  the run is one continuous ~40-minute session; the driver checks
  `updates` increments by exactly 1 per push and aborts on any
  mismatch; the oracle is fresh and unpublished until the run ends.
- **R-5 — push spacing floor.** The mirror was validated at 35–60 s
  spacing. Faster pushing was not simulated; the driver keeps gaps
  ≥ 40 s. If RPC slowness stretches gaps, that is safe (sequence is
  spacing-invariant upward); if anything pushes faster, stop and
  re-run the mirror first.
- **R-6 — cold-start anchor.** The window's anchor starts at
  $1,679.28, not the $1,911.43 episode peak, so the first EXIT lands
  at the 13 Jun 07:00 close @ $1,283.46 — six closes after ANCHOR.md
  §4's full-episode first EXIT (the 13 Jun 01:00 close @ $1,364.36,
  displayed as 02:00 in ANCHOR's +1h labelling). This is the
  correct behaviour for a fresh deployment and is stated, not
  hidden; anyone comparing against §4 must use the window-start
  anchor, not the episode peak.
- **R-7 — flagship separation.** The Release 7 brain subscribes to
  the fresh mock oracle; the flagship brain and its Chainlink
  adapter are untouched. A wiring mistake that pointed the new brain
  at the flagship adapter (or vice versa) would corrupt both
  records — the deploy checklist verifies the subscribed oracle
  address by read on both brains before the first push.
- **R-8 — paused cron.** `sentinel-trio6-volatile-0112` stays
  paused (verified `enabled: false` in the cron list for this
  design). Release 7 is a manual, driven run, not that cron's job;
  do not unpause it as part of this release.
- **Open question for the user:** approve the June core as the
  Release 7 scope (56 pushes, ~1.83 lREACT, no RERISK), or approve
  core + Aug stretch up front (~5.2 lREACT total, second fresh set)?
  The design recommends core now, stretch decided after the core
  lands — but the stretch's fresh set would need its own deploy
  window before 5 Dec either way.

## Appendix — mirror artefacts (for the deploy run to re-verify)

- Simulator: `/tmp/r7_mirror.py` (full `react()` replica) and
  `/tmp/r7_scan.py` (window scanner). Both import
  `tools/train.py` and the shipped `SentinelWeightsV2.sol`; neither
  modifies the repo. Before deploy, copy them into the goal's
  `hidden_files/` (they are /tmp files and do not survive a VM
  restart) and re-run against `tools/data/klines_jun2022.json`
  indices 120–175, expecting votes H/T/E 18/35/1 and the six
  callbacks in §2a.
- Data: `tools/data/klines_jun2022.json` (repo copy; the /tmp klines
  are already gone after a restart — always use the repo copy).
- Baseline: `forge test` 165/165 (24 suites), re-verified 26 Nov
  ~21:40 WIB for this design.
- Balances at design time (26 Nov ~21:37 WIB): dev Base 0.0642332
  ETH, dev Lasna 0.7026468 lREACT, dev Sepolia 0.6901466 ETH;
  flagship brain updates 3, lastAction 0, 11.5613437 lREACT.
- Live-feed checks at design time: ETH/USD
  `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` $1,697.58664063;
  LINK/USD `0xb113F5A928BCfF189C998ab20d753a47F9dE5A61` $9.22094315;
  both rounds fresh within ~5 minutes of the read.
