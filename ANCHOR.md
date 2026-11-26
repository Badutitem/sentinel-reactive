# ANCHOR.md — Sentinel model v2: the long-horizon anchor fix

Status: **offline candidate, validated 2026-11-16. NOT wired into any
contract, NOT deployed, no transactions.** The shipped model remains
SentinelWeights.sol (v1). The candidate weights live in
`src/model/SentinelWeightsV2.sol`; the training path is
`python3 tools/train.py v2` (v1's path is untouched and still
reproduces v1 exactly).

**Gate verdict up front: PASS on the flaw it was built to fix, with ONE
failed criterion** — mild-sawtooth TRIM flapping did not return to
v1's level (9.3% of windows / 15.52 transitions per series vs v1's
1.6% / 2.05). Everything else passes, including the hard requirement
(zero false EXITs in the Sep 2023 chop and Feb 2024 uptrend episodes).
Section 6 has the per-criterion table; section 7 is the plain list of
what v2 still cannot do. Do not read the headline as an unqualified
pass.

---

## 1. The flaw being fixed

BASELINE.md and BACKTEST.md established it from two directions.
Feature 3 (drawdown) is measured from the peak of the last 9 prices, so
any decline slower than ≈2.6%/step never reaches the 21% EXIT band:

- Synthetic: EXIT windows were **0.0%** in grind, slow_grind (≈−50%
  total) and staircase series — for the hand-coded rule, for the v1
  MLP, and for the v1 teacher itself. The policy literally had no way
  to say EXIT there.
- Real data: on 2,749 hourly windows across 5 episodes the v1 model
  fired EXIT exactly **twice** (both in the May 2021 vertical crash).
  In the Jun 2022 collapse (−52.7%) and the Aug 2024 crash (−35.8%)
  the maximum 9-hour window drawdown was 15.7% / 16.7% — the EXIT band
  was never approached. Protection capped out at the TRIM ratchet.

## 2. Design

### 2.1 Feature 7 — anchorDrawdown from a leaky peak

One new state variable, updated on **every** price the subscription
sees (before that price's features are computed):

```
anchorPeak ← max(p, anchorPeak × 999 // 1000)        # per price update
anchorDrawdown = (anchorPeak − p) × 1_000_000 // anchorPeak
```

- Initialised to the first price seen. No knowledge of position
  arming, entry price or wall-clock time is needed — the state is a
  pure function of the price stream.
- All arithmetic is integer multiply/divide on non-negative values
  (floor division = Solidity uint division), in the same 1e6 feature
  scale as the existing window drawdown. The Python mirror in
  train.py (`anchor_update`, `features7_from_window`) is the exact
  computation a future contract must perform; the 6 v1 features are
  unchanged and keep their order, anchorDrawdown is index 6.
- Why leaky: a running (non-leaking) peak remembers the all-time high
  forever, so after any crash the drawdown feature would sit elevated
  for the life of the subscription and every later dip would look like
  a rout. The leak (×0.999/step, half-life ≈ 693 steps) gives
  long-but-finite memory: a market that recovers and holds new levels
  sees its anchorDrawdown decay back to ≈0.

### 2.2 Why decay 999/1000 (and not the 998/1000 first sketched)

Measured on the 5 real backtest episodes + synthetic families before
any constant was fixed (anchor stream computed at three decays):

| decay | Jun 2022 max anchorDD | Aug 2024 max anchorDD | May 2021 max | Sep 2023 max | Feb 2024 max | synth. chop p99 |
|---|---|---|---|---|---|---|
| 998/1000 | 26.7% | 20.0% | 32.8% | 2.2% | 3.3% | 4.3% |
| **999/1000** | **37.9%** | **24.7%** | **44.7%** | **3.5%** | **4.4%** | **5.6%** |
| 1999/2000 | 45.1% | 29.0% | 51.1% | 4.2% | 4.9% | 6.8% |

At 998/1000 the Aug 2024 peak (20.0%) sits only ~2 points above the
18% EXIT band — too thin a margin for the model to reproduce reliably.
At 999/1000 the crash-side margin roughly doubles (24.7% vs the 18%
band) while the calm side stays ≥4× below the band (worst real benign
peak 4.4%; note anchorDD can never exceed the drawdown from the true
running peak, so calm-episode safety is structurally bounded by the
episode's own max drawdown). 1999/2000 buys little crash-side and
costs calm-side margin. **Decay = 999/1000.**

### 2.3 Teacher v2 — exact label rules

`label_window_v2` in train.py. The v1 ladder is kept verbatim; two
anchor clauses are inserted (evaluation order matters):

```
1. kind == flat                                            -> HOLD
2. kind == vshape, past the trough, last return > -2%      -> HOLD   (recovery stand-down, v1 clause)
3. window drawdown >= 21%                                  -> EXIT   (v1)
4. anchorDrawdown >= 18% AND window momentum < 0           -> EXIT   (NEW: slow-bleed rout)
5. window drawdown >= 3%                                   -> TRIM   (v1)
6. anchorDrawdown >= 10%                                   -> TRIM   (NEW: sustained bleed / post-fall overhang)
7. otherwise                                               -> HOLD
```

Why these constants:

- **Anchor EXIT band 18%** — below the window EXIT band (21%) because
  the anchor measures a longer horizon: a sustained 18% fall from a
  decayed peak is a rout by any slow measure. It sits >4× above every
  benign anchorDD observed (real chop max 3.5%, real uptrend max
  4.4%, synthetic chop p99 5.6%) and below the anchorDD peaks of all
  three real crashes (Jun 2022 37.9%, Aug 2024 24.7%, May 2021 44.7%),
  and it is reached in the synthetic slow bleeds (grind windows ≥18%:
  ~60% of the series' second half; slow_grind ~74%; staircase's final
  leg ~25%).
- **The momentum gate on clause 4** — EXIT is terminal, so the anchor
  alone may not fire it: the window must still be falling (price below
  the window's first price). A bounce inside a bleed (anchorDD still
  ≥18%, momentum positive) is labelled TRIM via clause 6, not EXIT.
  The vshape stand-down (clause 2) still takes precedence over
  everything, exactly as in v1.
- **Anchor TRIM band 10%** — catches the sustained bleed and the
  post-fall overhang the 9-price window can no longer see (after a
  plunge, window drawdown collapses within 9 steps while the position
  is still deep underwater; v1 labelled those windows HOLD). ~1.8×
  above synthetic chop p99, never reached in either real calm episode
  (max 4.4%). Ungated, mirroring v1's window TRIM, which also fires
  regardless of direction on ladder series.

### 2.4 Architecture — 7 → 12 → 3, and why the width changed

Input 6 → 7 (the anchor feature). The hidden layer started at v1's 8
and was raised to **12** on training evidence, per the design brief's
own condition: at width 8 the v2 float model underfit its training set
(95.7% train accuracy after 4,000 epochs, vs v1's ~97%+ on an easier
task) and crash-scenario fidelity sat at ~90–93% — the anchor bands
and the sawtooth veto (section 3.1) compete with the old window
boundaries for the same units. At width 12, crash fidelity recovered
to 94.2–94.7% and pooled standard-suite fidelity to 97.01% (best of
all runs). Quantization is v1's scheme unchanged (weights ×1000,
biases ×1e6, straight-through QAT rounds available; the final run
passed acceptance at quantization round 0, no QAT needed).

### 2.5 Training setup

- Seed 20261116 (v1: 20261113). Same generator families as v1 (calm,
  uptrend, chop, grind, crash, V-recovery) **plus** slow_grind,
  staircase and bleed_recovery promoted from BASELINE.md's adversarial
  appendix into training, **plus** a new sawtooth family (section 3.1).
  90 series per family, 900 series total; split by series
  (i % 5 == 4 held out), same as v1.
- 43,433 train / 10,443 held-out windows. Class counts (train):
  HOLD 25,717 / TRIM 8,387 / EXIT 9,329 — the anchor clauses give EXIT
  real mass in slow series, where v1's teacher had almost none.
- Canonical anchors upweighted ×3 as in v1: the 5 pinned vectors
  extended with their anchor values, the CALM/CRASH paths labelled by
  teacher v2 itself (under v2 the crash path's 6th step is an anchor
  EXIT — anchorDD ≈19.4% with negative momentum — where v1's ladder
  still said TRIM), and two deterministic sawtooth paths pinned HOLD.
- Acceptance (`acceptance_v2`) pins: the 5 vectors, the calm path
  (HOLD×3), the crash path (= teacher v2's own sequence), a
  deterministic −1.1%/step × 70 slow bleed that MUST reach EXIT and end
  in EXIT (51 of 69 steps EXIT), and a +0.8%/step uptrend that must
  never act. All pass with the shipped integer weights.
- **Held-out fidelity: 95.41%** vs teacher v2 (per class: HOLD 93.8%,
  TRIM 95.6%, EXIT 99.4%). V1's headline was **97.47%** vs teacher v1.
  These are **different teachers** — v2's policy has strictly more
  decision surface (two extra bands, four extra families) — so the two
  numbers are reported side by side with that caveat and are NOT a
  like-for-like quality comparison.

## 3. Validation 1 — baseline suite rerun (synthetic)

Methodology identical to BASELINE.md (standard seed 777001,
adversarial seed 424242, 60 series per type, decisions from the 3rd
price over the last ≤9 prices), extended with the two extra deciders:
RULE_V2 (teacher v2 as a pure feature function) and MLP_V2 (the
candidate weights). Each model is scored against **its own** teacher.

**Pipeline proof:** the rerun reproduces BASELINE.md's published v1
numbers exactly — pooled standard-suite fidelity RULE_V1 **96.89%**,
MLP_V1 **97.40%** (and every per-scenario v1 figure matches). The v2
column is therefore measured on a verified rig. Pooled standard
fidelity: RULE_V2 94.79%, **MLP_V2 97.01%** (each vs its own teacher;
the pure v2 rule scores lower than the pure v1 rule for the same
structural reason as in v1 — a memoryless rule cannot express the
recovery stand-down, and the anchor bands widen that gap on
vrecovery).

Behavioural metrics that matter (MLP_V1 → MLP_V2):

| scenario | metric | v1 MLP | v2 MLP | read |
|---|---|---|---|---|
| grind | EXIT windows | 0.0% | **58.5%** | the fix |
| slow_grind | EXIT windows | 0.0% | **73.3%** | the fix |
| staircase | EXIT windows | 0.0% | **24.5%** | the fix (final leg) |
| grind/slow/stair | missed policy EXITs | n/a (policy had none) | **0.0%**, delay ≤ +0.25 steps | faithful |
| bleed_recovery | fidelity vs own teacher | 77.6% | **94.9%** | v1's clearest deficit, closed by the anchor TRIM band |
| bleed_recovery | EXITs on recovery-leg windows | 0 | **0** | stand-down holds |
| vrecovery | fidelity / TRIM share | 86.0% / 8.7% | **89.8% / 6.6%** | stand-down preserved, slightly calmer |
| crash | fidelity vs own teacher | 98.8% | 94.2% | v2's teacher EXITs more (49.4% of windows); model tracks with 0% missed EXITs, delay −0.15 |
| chop | TRIM windows | 4.3% | 5.4% | ≈ unchanged |
| calm / uptrend | any action | 0.2% / 0.0% | 0.1% / 0.0% | unchanged |
| flat_spikes | action rate in spike windows | 11.1% | 11.1% | identical (inherited) |
| vdip | premature-EXIT series | 55/60 | 60/60 (= teacher v2's own 60/60) | NOT fixed — see §6 |
| vdip | first-EXIT price vs trough | +0.00% | +0.54% | exits a hair earlier, same character |
| whipsaw_exit | EXIT windows / transitions / EXIT reversals | 0.8% / 20.60 / 0.63 | 3.2% / **4.77** / 1.87 | flapping much better than v1; slightly more EXIT |
| whipsaw_trim | TRIM windows / transitions | **1.6% / 2.05** | 9.3% / 15.52 | **REGRESSED — the failed criterion (§3.1)** |

### 3.1 The whipsaw_trim regression — diagnosis and tuning history

The ±2% / 4-step sawtooth is engineered so window drawdown straddles
the 3% TRIM line; the teacher's intent (kind = flat) is HOLD
throughout, and v1's MLP learned to suppress the rule's TRIMs almost
perfectly (1.6% of windows vs the rule's 19.3%).

First, what it is **not**: the anchor feature is innocent here. In
whipsaw_trim series anchorDD never exceeds **4.2%** — every one of
v2's false TRIMs fires at anchorDD < 10%, far below both anchor bands.
The cause is a decision-boundary shift: v2's training adds
bleed_recovery, whose bounce windows (window drawdown 3–8%, last
return just flipped positive) are labelled TRIM and whose 7-feature
vectors overlap the sawtooth's. The feature set does not encode the
*order* of returns inside the window beyond its endpoints, so
"sawtooth mid-cycle" and "bleed bounce" are intrinsically hard to
separate; v1's near-perfect veto was partly a gift of its poorer
training mix (it had never seen a bleed).

What was tried (8 training runs, all seed 20261116):

| run | change | held-out fid. | whipsaw_trim TRIM / trans | note |
|---|---|---|---|---|
| 1 | naive v2 (no sawtooth family) | 96.76% | 15.4% / 26.18 | whipsaw_exit also bad: EXIT 17.5%, reversals 5.72 |
| 2 | + sawtooth family (legs 3–6 steps) | 93.87% | 8.9% / 14.90 | long legs put all-down windows labelled HOLD → crash fidelity fell to 89.7% |
| 3 | sawtooth legs capped at 4 steps + slight drift | 95.17% | 8.3% / 14.03 | every window now contains both legs |
| 4 | epochs 2000 → 4000 | 95.45% | 7.6% / 12.77 | not an undertraining problem |
| 5 | hidden width 8 → 12 | 95.57% | 10.2% / 17.28 | crash fidelity 94.7% — width kept for that |
| 6 | + canonical sawtooth path anchors | 95.53% | 10.1% / 16.95 | no further movement |
| 7 | sawtooth at double series count | 94.30% | 7.0% / 11.55 | best whipsaw, worst global fit — rejected |
| 8 | **final: width 12 + 4000 epochs + sawtooth ×1 (per-cycle amplitude) + path anchors** | **95.41%** | **9.3% / 15.52** | best pooled standard fidelity (97.01%) and crash/vrecovery balance |

The whipsaw_trim figure moves in a 7–10% band across all reasonable
configurations — run variance on an ambiguous boundary, not a knob
that was left unturned. The final configuration was chosen on its
overall profile, not on this one number. Net position vs the rule:
v2 still suppresses ~2× of the rule's flapping (19.3% → 9.3% of
windows, 32.83 → 15.52 transitions); it does not match v1's ~12×
suppression. On the violent sawtooth (whipsaw_exit) the sawtooth
family worked outright: transitions 20.60 → 4.77 and HOLD↔TRIM
oscillations 19.33 → 1.03 vs v1, at the cost of more EXIT windows
(3.2% vs 0.8%) and EXIT reversals (1.87 vs 0.63).

Methodology note: v2's training includes a sawtooth *family* with a
deliberately different parameterization from the baseline's whipsaw
generators (period 4–8 vs 4/8 fixed, amplitudes 1.0–2.5% / 4.0–9.0%,
near-compensating legs, per-cycle amplitude redraws). The baseline
families remain held-out *instances*, but they are no longer an
unseen *phenomenon* for v2, and v2's whipsaw numbers should be read
with that disclosure attached.

## 4. Validation 2 — backtest on the 5 real episodes

Same pipeline as BACKTEST.md (Binance ETHUSDT hourly closes, decisions
from the 3rd price, 1,000 USD position at the first close, decisions
execute at the close that produced them, no gas/slippage, cooldown
never binds at 1h cadence). The anchor stream starts at each episode's
first close — the cold-start a real subscription would have.

**Pipeline proof:** the rerun reproduces BACKTEST.md's v1 table
**exactly** on all 5 episodes — decision counts, ladder agreement, and
every simulated final value and max drawdown (e.g. May 2021 full
semantics 1,086 / 5.4%, Jun 2022 998 / 4.2%, Aug 2024 962 / 4.0%).
(One data note: BACKTEST.md's Aug 2024 window starts 24 Jul 00:00
UTC; an initial fetch one day early produced a different series and
was corrected before any v2 number was taken from it.)

Results (final values in USD on the 1,000 start; max drawdown of the
value path in brackets):

| episode | model | H/T/E | first EXIT | first-fire | full semantics |
|---|---|---|---|---|---|
| May 2021 (−57.3% B&H dd) | B&H | — | — | 734 [57.3%] | — |
| | v1 | 432/165/2 | 19 May 13:00 @ $2,365 (−45.4% vs peak) | 868 [24.3%] | 1,086 [5.4%] |
| | **v2** | 276/219/**104** | **19 May 05:00 @ $2,932 (−32.3%)** | **948 [17.3%]** | 1,092 [5.4%] |
| Jun 2022 (−52.7%) | B&H | — | — | 659 [52.7%] | — |
| | v1 | 378/125/0 | never | 836 [27.7%] | 998 [4.2%] |
| | **v2** | 213/148/**142** | **13 Jun 02:00 @ $1,364 (−28.6% vs peak, 139h before the $904 trough)** | **851 [18.3%]** | 954 [8.4%] |
| Aug 2024 (−35.8%) | B&H | — | — | 770 [35.8%] | — |
| | v1 | 463/64/0 | never | 870 [19.4%] | 962 [4.0%] |
| | **v2** | 408/107/**12** | **5 Aug 02:00 @ $2,319 (−33.2% vs peak, 4.1% above the $2,228 trough)** | 799 [20.2%] | 923 [7.9%] |
| Sep 2023 chop | B&H | — | — | 1,013 [7.0%] | — |
| | v1 | 713/6/0 | never | 978 [6.4%] | 944 [5.9%] |
| | **v2** | 717/2/**0** | never | 978 [6.4%] | 958 [6.4%] |
| Feb 2024 uptrend | B&H | — | — | 1,480 [5.4%] | — |
| | v1 | 687/8/0 | never | 1,375 [3.9%] | 1,297 [3.9%] |
| | **v2** | 688/7/**0** | never | 1,375 [3.9%] | 1,321 [3.9%] |

Reading, without varnish:

- **Jun 2022 is the design working as intended.** The anchor EXIT
  fires on 13 Jun at −28.6% from the peak, 139 hours before the
  trough; first-fire max drawdown falls from 27.7% (v1) to 18.3%, and
  the first-fire final improves (851 vs 836). Under full ratchet
  semantics v1's denser early TRIM cadence happens to do better
  (998 / 4.2% vs 954 / 8.4%) — v2's win in this episode is the EXIT
  and the first-fire path, not the ratchet.
- **May 2021 improves on every line**: EXIT 8 hours and ~13 points of
  drawdown earlier than v1's only-ever EXITs, first-fire 948 [17.3%]
  vs 868 [24.3%].
- **Aug 2024 is the honest counter-case.** v2 EXITs — the band is
  finally reached — but the crash's final leg was near-vertical, so
  the anchor crosses 18% only at the capitulation itself: first EXIT
  $2,319, 4.1% above the trough, 11 hours before the trough close.
  The episode then recovered to $2,666, so exiting there locked in
  the bottom: v2 finishes *below* v1 on both semantics (799 vs 870
  first-fire; 923 vs 962 full). Teacher v2 as a pure rule fires its
  first EXIT at the same candle — this is a property of the policy
  (any drawdown-triggered EXIT is late in a vertical leg), faithfully
  reproduced by the model, not a fit failure.
- **The calm episodes cost nothing.** Zero EXITs in Sep 2023 and Feb
  2024 (the hard requirement), TRIM counts at or below v1's (2 vs 6;
  7 vs 8), and full-semantics finals slightly *above* v1's (958 vs
  944; 1,321 vs 1,297). The anchor's calm-side margin (bands ≥4× above
  the worst observed benign anchorDD) holds on real data, not just in
  the constant-choosing table.
- The model tracks its teacher closely on real data: MLP_V2 and
  RULE_V2 produce identical first EXITs in all three crash episodes.

## 5. Gate verdict

| # | criterion | verdict | numbers |
|---|---|---|---|
| 1 | EXIT reachable and sensible in grind / slow_grind / staircase | **PASS** | EXIT windows 0.0% → 58.5% / 73.3% / 24.5%; missed policy EXITs 0.0%; first-EXIT delay ≤ +0.25 steps |
| 2 | Backtest: EXIT fires in Jun 2022 and Aug 2024 | **PASS** | Jun 2022: 13 Jun 02:00 @ $1,364, −28.6% vs peak, 139h pre-trough. Aug 2024: 5 Aug 02:00 @ $2,319, −33.2% vs peak (late by construction — §4) |
| 3 | HARD: zero false EXITs in Sep 2023 chop + Feb 2024 uptrend | **PASS** | 0 and 0 EXIT windows; TRIM counts ≤ v1's |
| 4 | Whipsaw TRIM flapping not materially regressed vs v1 (1.6% / 2.05) | **FAIL (partial)** | whipsaw_trim 9.3% / 15.52 — ~2× better than the rule (19.3% / 32.83), ~6× worse than v1's MLP. Cause and 8 runs of tuning history in §3.1. (whipsaw_exit flapping itself improved vs v1: 4.77 vs 20.60 transitions.) |
| 5 | Recovery stand-down preserved | **PASS** | vrecovery TRIM share 6.6% (v1: 8.7%), fidelity 89.8% (v1: 86.0%); bleed_recovery recovery-leg EXITs 0; bleed fidelity 77.6% → 94.9% |
| 6 | V-dip trough-selling | **NOT FIXED (known, inherited)** | premature-EXIT series 60/60 = teacher v2's own count; first EXIT +0.54% above trough (v1: +0.00%, 55/60). The anchor does not address this flaw and was not designed to |
| 7 | Held-out fidelity reported honestly | **DONE** | v2: 95.41% vs teacher v2. v1: 97.47% vs teacher v1. Different teachers — not a direct comparison (§2.5) |

**Overall: the anchor fix passes its design gate with one failed
criterion (#4).** Whether the whipsaw_trim trade is acceptable is a
product decision for the wiring phase, not something this report
decides by relabelling it a pass.

## 6. What v2 still cannot do

- **Vertical capitulations.** When the final leg of a crash is fast,
  every drawdown-based EXIT — window or anchor — fires near the
  trough (Aug 2024: 4.1% above it) and can finish below a TRIM-only
  path if the market V-recovers. The anchor fixes *slow* bleeds; it
  does not make EXITs early in fast ones.
- **V-dips.** A clean plunge-and-recover still gets sold at or near
  the trough (60/60 synthetic dips), exactly as v1 did — the flaw is
  in the teacher both models share (the stand-down only applies once
  the recovery has started, and at the trough window it hasn't).
  Fixing it needs a policy change (e.g. a vol-scaled EXIT band or a
  confirmation delay), not a feature.
- **The mild ±2% sawtooth.** Flapping is halved vs the naive v2 and
  ~2× better than the rule, but ~5–6 TRIM episodes per 90 steps
  remain, vs ~1 for v1 (§3.1). A future feature that encodes return
  order inside the window (e.g. up-step fraction, or window peak vs
  anchor peak gap) is the most promising direction; it was outside
  this phase's one-feature scope.
- **Cadence dependence.** The decay is per *update*, not per hour.
  All bands were tuned at hourly cadence (half-life ≈ 693 updates ≈
  29 days hourly, ≈ 2.4 days at 5-minute updates). A different update
  cadence silently changes the effective horizon; the constants must
  be re-derived if the cadence changes.
- **State discipline (for the wiring phase).** The anchor is streaming
  state: it must be updated on *every* price the subscription
  receives, including during cooldown and while no position is open,
  or the feature desyncs from its training semantics. A missed update
  is not detectable from the feature vector alone.
- **No re-entry.** EXIT remains terminal in the vault semantics, as
  in v1; nothing in v2 speaks to getting back in.
- **The Jun 2022 ratchet nuance.** Under full on-chain semantics
  (every TRIM executes), v1's denser early TRIM cadence beat v2 in
  that one episode (998 vs 954). V2's protection edge is the EXIT
  itself and the first-fire path.

## 7. Files

- `tools/train.py` — v2 section appended (clearly delimited, additive;
  v1 functions unmodified; `python3 tools/train.py` still reproduces
  v1, `python3 tools/train.py v2` trains the candidate). Verified
  after all edits: shipped v1 weights still pass v1 acceptance, the
  Release 1 mirror check still passes.
- `src/model/SentinelWeightsV2.sol` — candidate weights (7→12→3),
  generated, not wired anywhere. Header carries the training metrics.
- `tools/vectors_v2.json` — v2 canonical vectors + metrics.
- This file. Experiment scripts are reproduced in the appendices so
  every number above can be regenerated end-to-end.

---

## Appendix A — anchor constant evidence script

The measurements behind §2.2 (decays × real episodes + synthetic families).

```python
#!/usr/bin/env python3
"""Anchor-drawdown evidence: for candidate decays, where does anchorDD go
on (a) the 5 real backtest episodes and (b) synthetic scenario families?
Constants for the v2 label policy get chosen from this output."""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, "/home/hatch/workspace/bounty-new/reactive/project/tools")
import train as T

SCALE = T.SCALE
DECAYS = [(998, 1000), (999, 1000), (1999, 2000)]
BANDS = [0.12, 0.15, 0.18, 0.21, 0.25, 0.30]


def anchor_dd_stream(prices, num, den):
    """anchorPeak_t = max(p_t, anchorPeak_{t-1} * num/den); returns the
    1e6-scaled anchor drawdown after each price."""
    peak = prices[0]
    out = []
    for p in prices:
        decayed = peak * num // den
        if p > decayed:
            peak = p
        else:
            peak = decayed
        out.append((peak - p) * SCALE // peak)
    return out


# --- adversarial generators (ported from BASELINE.md appendix) -------------

def gen_slow_grind(rng):
    rets = list(rng.normal(rng.uniform(-0.011, -0.008), 0.003, 85))
    return T._walk(rng, rets)


def gen_staircase(rng):
    rets = list(rng.normal(0.0005, 0.003, 8))
    for leg in range(3):
        rets += list(rng.uniform(-0.032, -0.026, 3))
        if leg < 2:
            rets += list(rng.normal(0.0, 0.003, 8))
    rets += list(rng.normal(-0.001, 0.003, 8))
    return T._walk(rng, rets)


def gen_bleed_recovery(rng):
    rets = list(rng.normal(0.0005, 0.003, 6))
    for _ in range(5):
        rets += list(rng.uniform(-0.014, -0.006, 10))
        rets += list(rng.uniform(0.030, 0.050, 2))
    rets += list(rng.normal(-0.002, 0.004, 6))
    return T._walk(rng, rets)


# --- real episodes -----------------------------------------------------------

EPISODES = ["may2021", "jun2022", "aug2024", "sep2023", "feb2024"]
print("=== REAL EPISODES: anchorDD behaviour ===")
for name in EPISODES:
    prices = json.loads(Path(f"/tmp/klines_{name}.json").read_text())
    peak_price = max(prices)
    print(f"\n{name}: {len(prices)} prices, start {prices[0]/1e8:.2f} "
          f"peak {peak_price/1e8:.2f} trough {min(prices)/1e8:.2f} "
          f"end {prices[-1]/1e8:.2f}")
    for num, den in DECAYS:
        dd = anchor_dd_stream(prices, num, den)
        line = f"  decay {num}/{den}: max anchorDD {max(dd)/1e4:.2f}%"
        for band in BANDS:
            hits = [t for t in range(2, len(prices)) if dd[t] >= band * SCALE]
            if hits:
                t0 = hits[0]
                below = 100 * (peak_price - prices[t0]) / peak_price
                line += (f" | >={band:.2f} first t={t0} "
                         f"({len(hits)} win, price {prices[t0]/1e8:.0f}, "
                         f"{below:.1f}% below ep-peak)")
            else:
                line += f" | >={band:.2f} never"
        print(line)

# --- synthetic families ------------------------------------------------------

print("\n=== SYNTHETIC: anchorDD over decision steps (t>=2) ===")
rng = np.random.default_rng(424242)
fams = {}
for sc in ("calm", "uptrend", "chop", "grind"):
    fams[sc] = [T.gen_series(rng, sc)[0] for _ in range(60)]
fams["slow_grind"] = [gen_slow_grind(rng) for _ in range(60)]
fams["staircase"] = [gen_staircase(rng) for _ in range(60)]
fams["bleed_recovery"] = [gen_bleed_recovery(rng) for _ in range(60)]

for num, den in DECAYS:
    print(f"\n-- decay {num}/{den} --")
    for sc, series in fams.items():
        alldd, maxes, frac = [], [], {}
        for prices in series:
            dd = anchor_dd_stream(prices, num, den)
            seg = dd[2:]
            alldd += seg
            maxes.append(max(seg))
            for band in BANDS:
                frac[band] = frac.get(band, 0) + sum(
                    1 for x in seg if x >= band * SCALE) / len(seg) / 60
        alldd = np.array(alldd)
        print(f"  {sc:15s} p50 {np.percentile(alldd,50)/1e4:6.2f}%  "
              f"p95 {np.percentile(alldd,95)/1e4:6.2f}%  "
              f"p99 {np.percentile(alldd,99)/1e4:6.2f}%  "
              f"mean series-max {np.mean(maxes)/1e4:6.2f}%  "
              f"frac>=.18 {frac[0.18]:.3f}  frac>=.25 {frac[0.25]:.3f}")
```

## Appendix B — baseline rerun script (v1 vs v2)

```python
#!/usr/bin/env python3
"""
Sentinel anchor experiment: v1 (shipped 6-feature MLP + window ladder)
vs v2 (7-feature anchor MLP + teacher-v2 ladder), on identical series.

Methodology mirrors BASELINE.md exactly (same seeds: standard 777001,
adversarial 424242; 60 series per type; decisions from the 3rd price over
the last <= 9 prices). Four deciders:
  RULE_V1 : window ladder on f[3] (drawdown >= 21% EXIT, >= 3% TRIM)
  MLP_V1  : shipped SentinelWeights.sol via train.py forward_int_vec
  RULE_V2 : teacher v2 as a pure feature function (label_window_v2 with
            kind='ladder' — no generator metadata), incl. the anchor state
  MLP_V2  : candidate SentinelWeightsV2.sol via forward_int_vec_v2
Policies: each model is scored against ITS OWN teacher (label_window /
label_window_v2 with generator metadata), as in BASELINE.md.
Read-only w.r.t. the project except it parses the two weights files.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, "/home/hatch/workspace/bounty-new/reactive/project/tools")
import train as T

HOLD, TRIM, EXIT = T.HOLD, T.TRIM, T.EXIT
NAMES = T.ACTION_NAMES
SCALE = T.SCALE
ROOT = Path("/home/hatch/workspace/bounty-new/reactive/project")
W1 = T.parse_weights_sol(T.WEIGHTS_SOL)
W2 = T.parse_weights_v2_sol(ROOT / "src" / "model" / "SentinelWeightsV2.sol")


# ---------------------------------------------------------------------------
# Adversarial generators — verbatim from BASELINE.md's appendix.
# ---------------------------------------------------------------------------

def gen_whipsaw_trim(rng):
    rets, drift = [], rng.choice([0.0, -0.0004])
    while len(rets) < 88:
        m = rng.uniform(0.014, 0.020)
        rets += [-m + drift, -m * rng.uniform(0.7, 1.0) + drift,
                 m + drift, m * rng.uniform(0.7, 1.0) + drift]
    return T._walk(rng, rets), {}


def gen_whipsaw_exit(rng):
    rets = list(rng.normal(0.0005, 0.003, 8))
    while len(rets) < 88:
        m1 = rng.uniform(0.055, 0.080)
        m2 = rng.uniform(0.055, 0.080)
        rets += [-m1, -m1 * 0.9, -m1 * 0.8, -m1 * 0.7,
                 m2, m2 * 0.9, m2 * 0.8, m2 * 0.7]
    return T._walk(rng, rets), {}


def gen_bleed_recovery(rng):
    rets = list(rng.normal(0.0005, 0.003, 6))
    recovery_steps = set()
    for _ in range(5):
        rets += list(rng.uniform(-0.014, -0.006, 10))
        base = len(rets)
        rets += list(rng.uniform(0.030, 0.050, 2))
        recovery_steps.update({base, base + 1})
    rets += list(rng.normal(-0.002, 0.004, 6))
    prices = T._walk(rng, rets)
    rec_price_idx = {i + 1 for i in recovery_steps}
    return prices, {"recovery_price_idx": rec_price_idx}


def gen_vdip(rng):
    rets = list(rng.normal(0.0005, 0.003, 10))
    rets += list(rng.uniform(-0.10, -0.06, 3))
    prices = T._walk(rng, rets)
    pre_dip = prices[10]
    guard = 0
    while prices[-1] < 0.99 * pre_dip and guard < 25:
        r = float(rng.uniform(0.04, 0.09))
        prices.append(max(1, int(round(prices[-1] * (1.0 + r)))))
        guard += 1
    rec_complete = len(prices) - 1
    tail = T._walk(rng, list(rng.normal(0.0005, 0.003, 8)), p0=prices[-1])
    prices += tail[1:]
    trough_idx = int(np.argmin(prices[:rec_complete + 1]))
    return prices, {"trough_idx": trough_idx, "dip_start": 11,
                    "rec_complete": rec_complete, "pre_dip": pre_dip}


def gen_flat_spikes(rng):
    n = 90
    rets = list(rng.normal(0.0, 0.003, n))
    spots = []
    cand = int(rng.integers(14, 20))
    while cand < n - 12 and len(spots) < 5:
        spots.append(cand)
        cand += int(rng.integers(14, 22))
    for s in spots:
        size = float(rng.choice([0.08, 0.14, 0.22]))
        rets[s] = -size
        rets[s + 1] = size / (1.0 - size) + float(rng.normal(0.0, 0.002))
    return T._walk(rng, rets), {"spike_price_idx": {s + 1 for s in spots}}


def gen_staircase(rng):
    rets = list(rng.normal(0.0005, 0.003, 8))
    for leg in range(3):
        rets += list(rng.uniform(-0.032, -0.026, 3))
        if leg < 2:
            rets += list(rng.normal(0.0, 0.003, 8))
    rets += list(rng.normal(-0.001, 0.003, 8))
    return T._walk(rng, rets), {}


def gen_slow_grind(rng):
    rets = list(rng.normal(rng.uniform(-0.011, -0.008), 0.003, 85))
    return T._walk(rng, rets), {}


ADVERSARIAL = {
    "whipsaw_trim": (gen_whipsaw_trim, "flat"),
    "whipsaw_exit": (gen_whipsaw_exit, None),
    "bleed_recovery": (gen_bleed_recovery, "ladder"),
    "vdip": (gen_vdip, "vshape"),
    "flat_spikes": (gen_flat_spikes, "flat"),
    "staircase": (gen_staircase, "ladder"),
    "slow_grind": (gen_slow_grind, "ladder"),
}


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

def evaluate_series(prices, kind, trough_idx):
    steps = list(range(2, len(prices)))
    peaks = T.anchor_stream(prices)
    F6 = np.array([T.features_from_window(prices[max(0, t - 8):t + 1])
                   for t in steps], dtype=np.int64)
    F7 = np.array([T.features7_from_window(prices[max(0, t - 8):t + 1],
                                           peaks[t])
                   for t in steps], dtype=np.int64)
    dd = F6[:, 3]
    rule1 = np.full(len(steps), HOLD, dtype=np.int64)
    rule1[dd >= 30_000] = TRIM
    rule1[dd >= 210_000] = EXIT
    mlp1, _, _ = T.forward_int_vec(F6, *W1)
    rule2 = np.array([T.label_window_v2("ladder", -1, t,
                                        [int(x) for x in F7[i]])
                      for i, t in enumerate(steps)], dtype=np.int64)
    mlp2, _, _ = T.forward_int_vec_v2(F7, *W2)
    pol1 = pol2 = None
    if kind is not None:
        pol1 = np.array([T.label_window(kind, trough_idx, t,
                                        [int(x) for x in F6[i]])
                         for i, t in enumerate(steps)], dtype=np.int64)
        pol2 = np.array([T.label_window_v2(kind, trough_idx, t,
                                           [int(x) for x in F7[i]])
                         for i, t in enumerate(steps)], dtype=np.int64)
    return steps, rule1, mlp1, rule2, mlp2, pol1, pol2


def transitions(d):
    return int((d[1:] != d[:-1]).sum()) if len(d) > 1 else 0


def th_oscillations(d):
    if len(d) < 2:
        return 0
    a, b = d[:-1], d[1:]
    return int((((a == HOLD) & (b == TRIM)) | ((a == TRIM) & (b == HOLD))).sum())


def exit_reversals(d):
    seen, count = False, 0
    for x in d:
        if x == EXIT:
            seen = True
        elif x == HOLD and seen:
            count += 1
            seen = False
    return count


def first_idx(d, action):
    idx = np.nonzero(d == action)[0]
    return int(idx[0]) if len(idx) else None


DECIDERS = ("rule1", "mlp1", "rule2", "mlp2")


def run_block(title, series_list):
    n_win = sum(len(s["mlp1"]) for s in series_list)
    out = {"title": title, "n_series": len(series_list), "n_windows": n_win}
    for name in DECIDERS:
        dist = np.zeros(3)
        trans, osc, rev = [], [], []
        for s in series_list:
            d = s[name]
            for k in range(3):
                dist[k] += (d == k).sum()
            trans.append(transitions(d))
            osc.append(th_oscillations(d))
            rev.append(exit_reversals(d))
        out[name] = {
            "dist": (dist / max(dist.sum(), 1)).tolist(),
            "trans": float(np.mean(trans)),
            "osc": float(np.mean(osc)),
            "rev": float(np.mean(rev)),
        }
    if all(s["pol1"] is not None for s in series_list):
        for name, pol in (("rule1", "pol1"), ("mlp1", "pol1"),
                          ("rule2", "pol2"), ("mlp2", "pol2")):
            accs = [np.mean(s[name] == s[pol]) for s in series_list]
            out[f"{name}_acc"] = float(np.mean(accs))
        for name, pol in (("mlp1", "pol1"), ("mlp2", "pol2")):
            delays, missed, npe = [], 0, 0
            for s in series_list:
                pe = first_idx(s[pol], EXIT)
                if pe is None:
                    continue
                npe += 1
                fe = first_idx(s[name], EXIT)
                if fe is None:
                    missed += 1
                else:
                    delays.append(fe - pe)
            if npe:
                out[f"{name}_exit_delay"] = (
                    float(np.mean(delays)) if delays else None)
                out[f"{name}_missed"] = missed / npe
                out["n_pol_exit"] = npe
    return out


def pct(x):
    return f"{100.0 * x:5.1f}%"


def print_block(b):
    print(f"\n== {b['title']}  ({b['n_series']} series, {b['n_windows']} windows)")
    for name in DECIDERS:
        d = b[name]["dist"]
        line = (f"   {name:6s} H/T/E {pct(d[0])}/{pct(d[1])}/{pct(d[2])}"
                f" | trans {b[name]['trans']:.2f} | H<->T osc {b[name]['osc']:.2f}"
                f" | EXIT rev {b[name]['rev']:.2f}")
        if f"{name}_acc" in b:
            line += f" | own-teacher acc {pct(b[f'{name}_acc'])}"
        print(line)
    for name in ("mlp1", "mlp2"):
        if f"{name}_exit_delay" in b:
            dl = b[f"{name}_exit_delay"]
            print(f"   {name:6s} first-EXIT delay vs own policy: "
                  f"{'n/a' if dl is None else f'{dl:+.2f}'} steps"
                  f" | missed-EXIT {pct(b[f'{name}_missed'])}"
                  f" (of {b['n_pol_exit']} series)")


def main():
    ok1, _ = T.acceptance(*W1, verbose=False)
    ok2, _ = T.acceptance_v2(*W2, verbose=False)
    print(f"[sanity] v1 weights pass v1 acceptance: {ok1}; "
          f"v2 weights pass v2 acceptance: {ok2}")
    assert ok1 and ok2
    rngc = np.random.default_rng(0)
    Ftest = rngc.integers(-300_000, 300_001, size=(64, 7)).astype(np.int64)
    vec, _, _ = T.forward_int_vec_v2(Ftest, *W2)
    one = [T.forward_int_v2([int(x) for x in row], *W2)[0] for row in Ftest]
    assert (vec == np.array(one)).all()
    print("[sanity] forward_int_vec_v2 == forward_int_v2 on 64 random vectors")

    blocks = []
    pooled_std = {"rule1": [], "mlp1": [], "rule2": [], "mlp2": []}

    rng = np.random.default_rng(777001)
    for scenario in T.SCENARIOS:
        series_list = []
        for _ in range(60):
            prices, kind = T.gen_series(rng, scenario)
            trough = int(np.argmin(prices)) if kind == "vshape" else -1
            steps, r1, m1, r2, m2, p1, p2 = evaluate_series(prices, kind,
                                                            trough)
            series_list.append({"steps": steps, "rule1": r1, "mlp1": m1,
                                "rule2": r2, "mlp2": m2, "pol1": p1,
                                "pol2": p2})
            # pooled standard-suite fidelity: window-weighted, as BASELINE
            for nm, d, p in (("rule1", r1, p1), ("mlp1", m1, p1),
                             ("rule2", r2, p2), ("mlp2", m2, p2)):
                pooled_std[nm].append(float((d == p).sum()))
        blocks.append(run_block(f"standard/{scenario}", series_list))

    tot_win = sum(b["n_windows"] for b in blocks)
    print(f"\n== pooled standard suite ({tot_win} windows), window-weighted "
          f"fidelity vs OWN teacher")
    total_windows = tot_win
    for nm in pooled_std:
        print(f"   {nm:6s} {100.0 * sum(pooled_std[nm]) / total_windows:.2f}%")

    rng = np.random.default_rng(424242)
    adv_extra = {}
    for name, (gen, kind) in ADVERSARIAL.items():
        series_list = []
        extra = {"vdip_premature": {d: 0 for d in DECIDERS},
                 "vdip_exit_above_trough": {d: [] for d in DECIDERS},
                 "spike_action_rate": {d: [] for d in DECIDERS},
                 "recovery_exit_windows": {d: 0 for d in DECIDERS},
                 "recovery_windows": 0}
        for _ in range(60):
            prices, meta = gen(rng)
            trough = meta.get("trough_idx", -1)
            steps, r1, m1, r2, m2, p1, p2 = evaluate_series(prices, kind,
                                                            trough)
            s = {"steps": steps, "rule1": r1, "mlp1": m1, "rule2": r2,
                 "mlp2": m2, "pol1": p1, "pol2": p2}
            series_list.append(s)
            step_of = {t: i for i, t in enumerate(steps)}
            dec = {"rule1": r1, "mlp1": m1, "rule2": r2, "mlp2": m2}
            if name == "vdip":
                lo, hi = meta["dip_start"], meta["rec_complete"]
                trough_price = prices[meta["trough_idx"]]
                for dn, d in dec.items():
                    zone = [d[step_of[t]] for t in steps if lo <= t <= hi]
                    if EXIT in zone:
                        extra["vdip_premature"][dn] += 1
                        fe = steps[int(np.nonzero(d == EXIT)[0][0])]
                        extra["vdip_exit_above_trough"][dn].append(
                            (prices[fe] - trough_price) / trough_price)
            if name == "flat_spikes":
                hot = set()
                for sp in meta["spike_price_idx"]:
                    hot.update(range(sp, sp + 9))
                for dn, d in dec.items():
                    hw = [d[step_of[t]] for t in steps if t in hot]
                    extra["spike_action_rate"][dn].append(
                        float(np.mean([x != HOLD for x in hw])) if hw else 0.0)
            if name == "bleed_recovery":
                rec = meta["recovery_price_idx"]
                extra["recovery_windows"] += len([t for t in steps
                                                  if t in rec])
                for dn, d in dec.items():
                    extra["recovery_exit_windows"][dn] += sum(
                        1 for t in steps
                        if t in rec and d[step_of[t]] == EXIT)
        blocks.append(run_block(f"adversarial/{name}", series_list))
        adv_extra[name] = extra

    for b in blocks:
        print_block(b)

    print("\n== adversarial outcome extras")
    e = adv_extra["vdip"]
    for dn in DECIDERS:
        apt = e["vdip_exit_above_trough"][dn]
        print(f"   vdip {dn:6s}: premature-EXIT series "
              f"{e['vdip_premature'][dn]}/60, mean first-EXIT price above "
              f"trough: {'n/a' if not apt else f'{100 * float(np.mean(apt)):.2f}%'}")
    e = adv_extra["flat_spikes"]
    for dn in DECIDERS:
        print(f"   flat_spikes {dn:6s}: action rate inside spike windows "
              f"{pct(float(np.mean(e['spike_action_rate'][dn])))}")
    e = adv_extra["bleed_recovery"]
    print(f"   bleed_recovery: recovery-leg windows {e['recovery_windows']}; "
          f"EXITs on them: " + ", ".join(
              f"{dn} {e['recovery_exit_windows'][dn]}" for dn in DECIDERS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

## Appendix C — backtest rerun script (v1 reproduction + v2)

Episode klines: Binance ETHUSDT 1h closes from data-api.binance.vision,
cached as 1e8-scaled integer arrays (start times: 2021-05-08, 2022-06-06,
2024-07-24, 2023-09-01, 2024-02-01, all 00:00 UTC; lengths 601/505/529/721/697).

```python
#!/usr/bin/env python3
"""
Sentinel backtest rerun: v1 (shipped) vs v2 (anchor candidate) on the
same 5 real Binance ETHUSDT hourly episodes as BACKTEST.md, same
pipeline (decisions from the 3rd price over the last <= 9 closes;
1,000 USD position at the first close; decisions execute at the close
that produced them; no gas/slippage; cooldown never binds at 1h).

Step 1 reproduces BACKTEST.md's v1 table exactly (pipeline proof).
Step 2 runs v2 (7 features, anchor stream from the episode's first
price) plus teacher v2 as a pure rule, for diagnosis.

Simulations: buy-and-hold; first-fire (only the first TRIM halves and
the first EXIT closes are executed); full on-chain semantics (every
TRIM halves what remains, EXIT closes for good).
"""
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np

sys.path.insert(0, "/home/hatch/workspace/bounty-new/reactive/project/tools")
import train as T

HOLD, TRIM, EXIT = T.HOLD, T.TRIM, T.EXIT
ROOT = Path("/home/hatch/workspace/bounty-new/reactive/project")
W1 = T.parse_weights_sol(T.WEIGHTS_SOL)
W2 = T.parse_weights_v2_sol(ROOT / "src" / "model" / "SentinelWeightsV2.sol")

EPISODES = {
    "may2021": ("May 2021 crash", datetime(2021, 5, 8, tzinfo=timezone.utc)),
    "jun2022": ("Jun 2022 collapse", datetime(2022, 6, 6, tzinfo=timezone.utc)),
    "aug2024": ("Aug 2024 crash", datetime(2024, 7, 24, tzinfo=timezone.utc)),
    "sep2023": ("Sep 2023 chop", datetime(2023, 9, 1, tzinfo=timezone.utc)),
    "feb2024": ("Feb 2024 uptrend", datetime(2024, 2, 1, tzinfo=timezone.utc)),
}

# BACKTEST.md published v1 results: counts H/T/E, ladder agreement %,
# (BH final, BH maxDD%), (first-fire final, maxDD%), (full final, maxDD%)
PUBLISHED = {
    "may2021": ((432, 165, 2), 84.3, (734, 57.3), (868, 24.3), (1086, 5.4)),
    "jun2022": ((378, 125, 0), 90.5, (659, 52.7), (836, 27.7), (998, 4.2)),
    "aug2024": ((463, 64, 0), 97.3, (770, 35.8), (870, 19.4), (962, 4.0)),
    "sep2023": ((713, 6, 0), 99.9, (1013, 7.0), (978, None), (944, None)),
    "feb2024": ((687, 8, 0), 99.3, (1480, 5.4), (1375, None), (1297, None)),
}


def simulate(prices, decisions):
    """decisions: dict t -> action for t >= 2. Returns (bh, ff, full)
    each as (final_value, max_drawdown_fraction)."""
    p = [x / 1e8 for x in prices]
    n = len(p)
    bh = [1000.0 * x / p[0] for x in p]

    def run(first_fire):
        units = 1000.0 / p[0]
        cash = 0.0
        values = []
        trim_done = exit_done = False
        for t in range(n):
            values.append(cash + units * p[t])
            d = decisions.get(t, HOLD)
            if units <= 0.0:
                continue
            if d == EXIT and not (first_fire and exit_done):
                cash += units * p[t]
                units = 0.0
                exit_done = True
            elif d == TRIM and not (first_fire and trim_done):
                cash += 0.5 * units * p[t]
                units *= 0.5
                trim_done = True
        return values

    def stats(values):
        peak, mdd = values[0], 0.0
        for v in values:
            peak = max(peak, v)
            mdd = max(mdd, (peak - v) / peak)
        return values[-1], mdd

    return stats(bh), stats(run(True)), stats(run(False))


def analyse(name, prices):
    start = EPISODES[name][1]
    steps = list(range(2, len(prices)))
    peaks = T.anchor_stream(prices)
    F6 = np.array([T.features_from_window(prices[max(0, t - 8):t + 1])
                   for t in steps], dtype=np.int64)
    F7 = np.array([T.features7_from_window(prices[max(0, t - 8):t + 1],
                                           peaks[t])
                   for t in steps], dtype=np.int64)
    mlp1, _, _ = T.forward_int_vec(F6, *W1)
    mlp2, _, _ = T.forward_int_vec_v2(F7, *W2)
    dd = F6[:, 3]
    rule1 = np.full(len(steps), HOLD, dtype=np.int64)
    rule1[dd >= 30_000] = TRIM
    rule1[dd >= 210_000] = EXIT
    rule2 = np.array([T.label_window_v2("ladder", -1, t,
                                        [int(x) for x in F7[i]])
                      for i, t in enumerate(steps)], dtype=np.int64)
    out = {}
    for tag, dec in (("mlp1", mlp1), ("mlp2", mlp2), ("rule2", rule2)):
        counts = tuple(int((dec == k).sum()) for k in range(3))
        dmap = {t: int(dec[i]) for i, t in enumerate(steps)}
        sims = simulate(prices, dmap)
        fe = next((i for i, t in enumerate(steps) if dec[i] == EXIT), None)
        fe_info = None
        if fe is not None:
            t = steps[fe]
            ep_peak = max(prices)
            ep_trough = min(prices)
            trough_t = int(np.argmin(prices))
            fe_info = {
                "t": t,
                "when": (start + timedelta(hours=t + 1)).strftime(
                    "%d %b %H:00"),
                "price": prices[t] / 1e8,
                "below_peak_pct": 100 * (ep_peak - prices[t]) / ep_peak,
                "above_trough_pct": 100 * (prices[t] - ep_trough) / ep_trough,
                "steps_vs_trough": t - trough_t,
            }
        out[tag] = {"counts": counts, "sims": sims, "first_exit": fe_info}
    out["agree1"] = float((mlp1 == rule1).mean())
    out["n_windows"] = len(steps)
    return out


def fmt_sim(s):
    return f"final {s[0]:7.0f}  maxDD {100 * s[1]:5.1f}%"


def main():
    print("=== STEP 1: v1 reproduction vs BACKTEST.md ===")
    all_ok = True
    results = {}
    for name in EPISODES:
        prices = json.loads(Path(f"/tmp/klines_{name}.json").read_text())
        r = analyse(name, prices)
        results[name] = r
        pub = PUBLISHED[name]
        m = r["mlp1"]
        ok_counts = m["counts"] == pub[0]
        ok_agree = abs(100 * r["agree1"] - pub[1]) < 0.15
        ok_bh = abs(m["sims"][0][0] - pub[2][0]) <= 2 and \
            abs(100 * m["sims"][0][1] - pub[2][1]) <= 0.15
        ok_ff = abs(m["sims"][1][0] - pub[3][0]) <= 2 and \
            (pub[3][1] is None or abs(100 * m["sims"][1][1] - pub[3][1]) <= 0.15)
        ok_full = abs(m["sims"][2][0] - pub[4][0]) <= 2 and \
            (pub[4][1] is None or abs(100 * m["sims"][2][1] - pub[4][1]) <= 0.15)
        ok = ok_counts and ok_agree and ok_bh and ok_ff and ok_full
        all_ok &= ok
        print(f"{name}: counts {m['counts']} (pub {pub[0]}) agree "
              f"{100 * r['agree1']:.1f}% (pub {pub[1]}) | BH {fmt_sim(m['sims'][0])}"
              f" | FF {fmt_sim(m['sims'][1])} | FULL {fmt_sim(m['sims'][2])}"
              f"  -> {'MATCH' if ok else 'MISMATCH'}")
    print("v1 reproduction:", "ALL MATCH" if all_ok else "FAILED")

    print("\n=== STEP 2: v2 on the same episodes ===")
    for name in EPISODES:
        r = results[name]
        print(f"\n{EPISODES[name][0]} ({r['n_windows']} windows)")
        for tag in ("mlp1", "mlp2", "rule2"):
            m = r[tag]
            print(f"  {tag:6s} H/T/E {m['counts'][0]}/{m['counts'][1]}/"
                  f"{m['counts'][2]} | FF {fmt_sim(m['sims'][1])} | "
                  f"FULL {fmt_sim(m['sims'][2])}")
            if m["first_exit"]:
                fe = m["first_exit"]
                print(f"         first EXIT {fe['when']} UTC @ "
                      f"${fe['price']:,.0f} — {fe['below_peak_pct']:.1f}% "
                      f"below episode peak, {fe['above_trough_pct']:.1f}% "
                      f"above trough, {fe['steps_vs_trough']:+d} steps "
                      f"vs trough")
    print("\n=== HARD GATE: v2 EXITs in calm episodes ===")
    for name in ("sep2023", "feb2024"):
        n = results[name]["mlp2"]["counts"][2]
        print(f"  {name}: mlp2 EXIT windows = {n} "
              f"({'PASS' if n == 0 else 'FAIL'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

---

## Wiring phase (2026-11-16)

The candidate is now wired into a contract — still **not deployed, no
transactions**. The shipped v1 system is untouched: `SentinelReactive.sol`,
`SentinelModel.sol`, `SentinelWeights.sol` and every Release 1 contract/test
are byte-identical to before (git confirms only additions).

**Files added**

- `src/model/SentinelModelV2.sol` — the 7 → 12 → 3 forward pass over
  `SentinelWeightsV2`, a parallel library mirroring v1's
  SentinelModel/SentinelWeights split (same fixed-point scheme: features
  ×1e6, weights ×1000, truncating signed division).
- `src/SentinelReactiveV2.sol` — v1's reactive contract with exactly the
  changes this report prescribes:
  - anchor state updated on **every** ingested price (inside `_push`,
    before the warmup return — so warmup and cooldown prices count, per
    §6's state discipline), initialised to the first price, decay
    `anchorPeak = max(p, anchorPeak × 999 // 1000)` in unsigned integer
    math identical to `anchor_update` in train.py;
  - feature vector = the six v1 features in their original order, with
    `anchorDrawdown` appended at index 6, computed against the anchor
    state after the newest price — identical to `features7_from_window`;
  - the cooldown state-leak fix: when an EXIT callback fires, the
    fired-state resets to its initial values (`_lastFiredAction = HOLD`,
    `_lastFiredTs = 0`) instead of being recorded, so a dead position's
    EXIT can no longer suppress the next position's first TRIM. The
    residual manual-withdraw case (a close this contract cannot observe)
    is documented in a comment at the firing site, as is the accepted
    trade-off: repeat EXIT votes against an already-closed position fire
    immediately rather than after the cooldown — the vault counts them
    as no-ops, so the cost is callback fees, never missed protection.
  - Constructor signature, subscription shape, events, callback payload
    and `setVault` flow are v1's unchanged, so the existing
    SentinelVaultV2 can be pointed at it with no vault redeploy beyond
    its own immutable-sender wiring.
- `test/SentinelReactiveV2.t.sol` — 13 tests in two suites
  (`SentinelReactiveV2Test`, `SentinelReactiveV2EndToEndTest`).

**Tests: 66/66 pass** — the 53 pre-existing tests unchanged and green,
plus 13 new:

- *Parity (a):* crash-path and slow-bleed (−1.1%/step) series assert all
  7 features, all 3 logits and the anchor peak bit-exactly against
  values generated by running train.py's own mirror
  (`features7_from_window`, `forward_int_v2`, `anchor_stream`) on the
  same series — including the first-EXIT step of the slow bleed
  (anchorDD 182258, just over the 18% band) and the crash path's first
  six features matching v1's pinned values unchanged.
- *Decay (b):* 100 flat updates after a −10% step reproduce the mirror's
  iterated integer decay at steps 1/10/50/100 exactly
  (9_990_000_000 → 9_047_921_427; anchorDD ends at 5296).
- *End-to-end (c):* a −2%/step bleed (31 hourly prices, 1e18 scale)
  through MockPriceOracle + SentinelVaultV2: v2 fires 29 callbacks
  (9 TRIMs, then EXITs from step 11) and the delivered callbacks close
  the vault — 10 WETH out, exactly 545_484_319_382_437_181_277 mUSDC in
  at the final print. A v1 reactive fed the identical stream is asserted
  at every step to never vote EXIT (it ends still TRIMming).
- *Cooldown reset (d):* A/B on one stream (crash → recovery → fresh
  −2.5%/step decline, cooldown 3600 s, prices 60 s apart): v1 fires
  [TRIM, EXIT] and then blocks its own TRIM votes in the second decline
  (the leak); v2 fires [TRIM, EXIT, EXIT, EXIT, TRIM] — the post-EXIT
  TRIM lands at T0+1140, deep inside the old cooldown — and that TRIM
  re-arms the cooldown, blocking its own repeats.
- *Initialisation (e):* `anchorPeak` is 0 before any price, equals the
  first price after it, and the decay rule applies from the second
  price on; ignored (non-matching) logs provably never touch the anchor.

**Deviations from this report's spec:** none in the anchor arithmetic,
feature order, label-facing semantics or state discipline. Two
implementation choices worth recording: (1) the forward pass lives in
its own library file (`SentinelModelV2.sol`) rather than inside the
reactive contract, mirroring v1's file split; (2) `_features()` guards
the anchor division with `anchorPeak == 0 → 0` — reachable only if the
first price ever seen is 0, a case where the Python mirror is likewise
undefined (it would divide by zero); it exists so a degenerate log can
never revert `react()` and bill the contract.

**Constructor arguments for the later deployment** (contract deploys on
Reactive Lasna, funded with lREACT at deploy, then vault, then
`setVault` — v1's order):

```
SentinelReactiveV2(
  originChainId_   = 84532,                                            // Base Sepolia
  oracle_          = 0xAb9c7a5178B444cd1C1fD705e5eBeCf4b9A1C25F,       // ChainlinkPriceAdapter
  token_           = 0x4200000000000000000000000000000000000006,       // WETH
  destChainId_     = 84532,                                            // Base Sepolia
  cooldownSeconds_ = 300
)
```

The adapter emits the identical `PriceUpdated(address,uint256,uint256)`
signature keyed to WETH, so the subscription topic0/topic1 wiring is the
same shape as the mock-oracle demos. Deployment, funding and any live
run are a separate phase, not done here.

---

## Deployment (Release 3) — 2026-11-15

The v2 candidate is now **deployed and live-run**. Full record:
`phase3-deploy-report.md` beside the phase-2B report in the goal's
hidden_files; raw logs `phase3-driver.log`, `phase3-watcher.log`,
`phase3-watcher-r2.log` alongside it. Release 1 and Release 2
untouched.

**Release 3 (all Sourcify exact_match, creation + runtime):**

| Contract | Chain | Address | Deploy tx |
|---|---|---|---|
| `SentinelReactiveV2` | Lasna 5318007 | `0x175205677bCEee3dED7F6559D653515710212d33` | `0xf4f9a3d5de9486e88f8f1379881337ca9d8af42bc02bd81c75b3e626b89fcaba` |
| `SentinelSwap` #3 | Base Sepolia 84532 | `0x5B72Abb91A8923768E3569959517fCE3f69CF19A` | `0xfa4b3295d2625f936f410344562bb4d9e4e82250a6850c853321fd7fc91f6e37` |
| `SentinelVaultV2` #3 | Base Sepolia 84532 | `0x2942cc16F61516FDB24cF009dD07ca366a99abBc` | `0xd3649b186a297f4de33b7b86a01f8571eab32c8cf9c71dfab41fe0a102837cf7` |

Constructor args exactly as this report's wiring section prescribed
(oracle = the existing Release 2 adapter
`0xAb9c7a5178B444cd1C1fD705e5eBeCf4b9A1C25F`, token = WETH, cooldown
300). Wiring: `swap#3.setVault` `0xdddf77d0…b7fa49`,
`reactiveV2.setVault` `0x44501d4f…508a01d9`, desk seeded with 1,000
mUSDC (`0xd5f36ac5…da5751`), vault #3 armed with a 0.00004 WETH
position (`0xf3b5e1a4…92d892902`) + 0.00004 ETH callback billing —
both value transfers scaled down ~250× from Release 2 because the dev
wallet's Base Sepolia balance was 0.000139 ETH in total (report
§8.3). Reactive funded with **0.272 lREACT** (0.20 at deploy + 0.072
top-up `0xd4177f3e…96fec15`): the Lasna deploy alone charged
0.1438852 lREACT of gas (1,438,852 × 100 gwei) and the RPC's
upfront `gas × price + value` check made a single ≈0.40 attach
impossible against the 0.4234 balance (report §8.1).

**Live window 18:20–19:06 UTC (~46 min, fuel-shortened):** 13 syncs →
8 emissions → 8 reacts (`updates` 0 → 8) → **6 Decisions, all HOLD**,
0 callbacks — the correct output for the tape (real Chainlink ETH/USD:
$1,814.94 open, $1,812.17–$1,818.21 range, $1,818.21 close). Reactive
#2 cross-reconciles (updates 24 → 32 on the same shared emissions).
Decision txs (Lasna): `0xc4cca454…a68aafeec5`, `0xc6c9e1c7…26e5194936f9`,
`0x8f5f0a81…f7470cf63b92d8f`, `0xf141b153…6abdf5a681b907b6`,
`0x7912343e…7297a7c3ed36e6cdd9584217c958f096` — full hashes in the
report. First ingestion: sync `0x25bb0a53…f33ff7` → V2 `PriceSeen`
`0x5bc2290e…d642a1`.

**The anchor, live and bit-exact:** `anchorPeak` initialised to the
first price (1814940000000000000000); tracked the $1,815.1845 high;
at update 5 decayed to `1815184512350000000000 × 999 // 1000 =
1813369327837650000000` — read back on-chain to the wei — and yielded
a live anchorDrawdown feature of **556** (0.0556%) on the dip to
$1,812.3599; then decayed onto the repeated print and re-anchored to
each new high, ending at the final price. The §6 state discipline
held throughout: the anchor advanced on every ingested price,
warmup and heartbeat re-emissions included.

**Fuel accounting:** 0.272 → **0.0349808 lREACT remaining** (0.2370192
over 8 reacts ≈ 0.0296/react; first inference react 0.0428,
steady-state ≈0.030–0.034 — pricier than v1's ≈0.0266 average). The
window was closed at the fuel floor by choice, not by failure.
Vault #3 final: 0.00004 WETH / 0 mUSDC / 0.00004 ETH, `closed` false,
`protectionCount` 0; swap #3 reserve 1,000 mUSDC intact.

**Noted honestly:** v2's TRIM logit sat at ≈7.31–7.40 all window
(v1's was ≈1.3–2.3 on comparable prints in Release 2) — a different
raw calibration from the wider network; HOLD's margin never went
below ≈6.0 and EXIT stayed ≤ −16.1, so argmax behaviour on live data
matched v1's exactly. A longer v2 window, or a dust-position top-up,
needs only dev-wallet refunds (Sepolia ETH for a faucet round;
Base Sepolia ETH for the position) — no redeploy.
