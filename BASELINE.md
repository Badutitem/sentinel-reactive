# Sentinel — Rule Ladder vs Trained MLP: Baseline Comparison

**The question this answers:** the MLP's training labels come from a deterministic
policy ladder in `tools/train.py` (drawdown ≥ 21% → EXIT, ≥ 3% → TRIM, with a
recovery exception). So why not just code the rule? This experiment feeds
identical price windows to both deciders and measures where they actually
differ — including adversarial series the training set never contained.

**Short answer:** on the training distribution the two are near-identical
(89–100% agreement per scenario), and on genuine crashes they are tied. The
model earns its keep exactly where a single-threshold rule is structurally
blind: threshold-straddling whipsaw (16× less decision flapping, false TRIMs
19.3% → 1.6% of windows) and post-crash recovery (it learned the "never sell
the bounce" exception that no window-only rule can express). It also has real
losses: it under-trims slow bleeds with sharp recoveries, and on V-shaped dips
it sells the bottom slightly *more* often than the rule — because the teacher
policy itself demands an exit there. Details and full numbers below; nothing
is cherry-picked.

---

## Method

**Deciders.** Both see exactly the windows `SentinelReactive` sees: the last
≤ 9 prices, one decision per price update starting at the 3rd price
(`WINDOW = 9`, `MIN_UPDATES = 3`).

- **RULE** — the raw ladder as a pure function of the window features:
  window drawdown ≥ 21% → EXIT, ≥ 3% → TRIM, else HOLD. This is the strongest
  honest form of "just code the rule": the two teacher clauses that need
  generator metadata (flat series are always HOLD; V-recoveries are HOLD
  after the trough) cannot be expressed by any contract that only sees the
  window, so they are not in the rule.
- **MLP** — the deployed model, bit-for-bit: weights parsed out of the shipped
  `src/model/SentinelWeights.sol` (quantized integers, ×1000 / biases ×1e6),
  inferred through `train.py`'s own `forward_int_vec`, which mirrors
  `SentinelModel.predict` (truncating division, ReLU, first-max argmax).
  Sanity checks before measuring: the shipped weights pass `train.py`'s
  canonical acceptance vectors through this path, and the vectorized forward
  pass matches the scalar `forward_int` on random vectors.

**Reference labels ("policy").** `train.py`'s `label_window()` with generator
metadata. Caveat, stated plainly: on *ladder-kind* series (grind, crash,
staircase, …) the RULE **is** the ladder, so its policy accuracy is 100% by
construction — there, the interesting numbers are the MLP's fidelity and the
outcome metrics. On *flat*/*vshape* series the policy encodes intent the raw
ladder cannot express, which is precisely the gap being tested.

**Series.** 60 series per type; decisions pooled over 48,056 windows total.

- *Standard* (fresh seed 777001 — never used in training; `train.py`'s own
  generators): calm, uptrend, chop, grind, crash, vrecovery.
- *Adversarial* (seed 424242; new generators written for this experiment):
  - `whipsaw_trim` — sawtooth (2 down / 2 up steps of ~1.4–2.0%) straddling
    the 3% TRIM threshold; no trend, no crash. Intent: HOLD.
  - `whipsaw_exit` — violent sawtooth (4 down / 4 up steps of ~5.5–8.0%,
    calibrated so within-window drawdown spans ~17–25%) straddling the 21%
    EXIT threshold. Intent: do not flap in and out of EXIT.
  - `bleed_recovery` — 5 cycles of a 10-step bleed (−0.6…−1.4%/step) followed
    by a sharp 2-step bounce (+3…+5%/step); net −15…−25%. A genuine decline
    with recovery legs.
  - `vdip` — 3-step flash plunge (−6…−10%/step) that then fully recovers to
    ≥ 99% of the pre-dip price. Any EXIT before recovery completes sells a
    dip that came back.
  - `flat_spikes` — flat ±0.3% noise with 3–5 isolated single-step spikes
    (−8% / −14% / −22%) that revert completely on the next step.
  - `staircase` — a genuine crash in three −8.5% legs separated by calm
    plateaus; ends ≈ −24% and stays down.
  - `slow_grind` — −0.8…−1.1%/step drift for 85 steps (≈ −50% total).

**Metrics.** Per type: rule↔MLP agreement, policy accuracy, decision mix
(HOLD/TRIM/EXIT share of windows), decision flapping (transitions per series;
HOLD↔TRIM oscillations; EXIT reversals = an EXIT later followed by HOLD in
the same series). Outcome metrics: false-action rate on benign series,
premature EXITs on recovered dips, first-EXIT delay vs the policy's first
EXIT step and missed-EXIT rate on genuine crashes.

---

## Results — standard scenarios (fresh seed)

Policy accuracy is pooled over all windows of the type (19,121 windows in
total). Pooled across all six standard scenarios: **RULE 96.89% — MLP 97.40%**.

| Scenario | Windows | Policy acc. RULE | Policy acc. MLP | Agreement | TRIM windows R / M | EXIT windows R / M | Transitions/series R / M |
|---|---|---|---|---|---|---|---|
| calm | 3,760 | 99.79% | 99.84% | 99.9% | 0.2% / 0.2% | 0.0% / 0.0% | 0.08 / 0.05 |
| uptrend | 3,544 | 100.00% | 100.00% | 100.0% | 0.0% / 0.0% | 0.0% / 0.0% | 0.00 / 0.00 |
| chop | 3,976 | 93.96% | 95.75% | 97.9% | 6.0% / 4.3% | 0.0% / 0.0% | 3.45 / 3.17 |
| grind | 4,336 | 100.00%\* | 98.75% | 98.8% | 92.8% / 94.0% | 0.0% / 0.0% | 2.32 / 2.18 |
| crash | 1,657 | 100.00%\* | 98.85% | 98.8% | 16.3% / 15.4% | 28.9% / 29.9% | 3.88 / 3.92 |
| vrecovery | 1,848 | 81.22% | 86.47% | 92.6% | 15.3% / 8.7% | 19.3% / 20.1% | 3.90 / 3.37 |

\* 100% by construction (the rule is the labelling ladder on these kinds).

First-EXIT timing on the crash kinds (57 of 60 series reach a policy EXIT in
both crash and vrecovery): **missed-EXIT rate 0.0% for both deciders** in both
scenarios; mean first-EXIT delay vs the policy step: RULE +0.00 steps (by
construction), MLP **−0.11 steps** (crash) / **−0.16 steps** (vrecovery) —
the MLP fires a hair *earlier* than the drawdown crossing in a few series,
an effect too small to claim as an advantage.

## Results — adversarial scenarios

Policy accuracy here is the mean of per-series accuracies (shown only where
the scenario defines policy intent). 60 series per type.

| Scenario | Windows | Agreement | Key numbers (RULE → MLP) |
|---|---|---|---|
| whipsaw_trim | 5,220 | 82.3% | TRIM windows **19.3% → 1.6%**; transitions/series **32.83 → 2.05**; policy acc. 80.7% → **98.4%** |
| whipsaw_exit | 5,220 | 46.1% | EXIT windows **5.7% → 0.8%**; EXIT reversals/series **3.12 → 0.63**; transitions/series 23.45 → 20.60; but HOLD↔TRIM oscillations **13.45 → 19.33** (MLP worse) |
| bleed_recovery | 4,260 | 77.6% | Policy acc. 100.0%\* → **77.6%** (MLP worse); HOLD windows 43.6% → 65.6%; TRIM 56.4% → 34.4%; EXITs on recovery-leg windows: 0 / 0 of 600 |
| vdip | 1,455 | 87.9% | Policy acc. 88.1% → **99.8%**; TRIM windows 20.5% → 8.6%; premature-EXIT series **52/60 → 55/60** (MLP worse) |
| flat_spikes | 5,340 | **100.0%** | Identical on every window: TRIM 2.8%, EXIT 1.7%, transitions 8.00/series, spike-window action rate 11.1% for both |
| staircase | 2,400 | 97.5% | Policy acc. 100.0%\* → 97.5%; EXIT windows 0.0% / 0.0% |
| slow_grind | 5,040 | 99.9% | Policy acc. 100.0%\* → 99.9%; EXIT windows 0.0% / 0.0% |

\* 100% by construction (ladder-kind series).

**Premature EXITs on V-dips (vdip).** Of 60 dips that fully recovered, the
RULE fired EXIT during the dip in 52 series and the MLP in **55 series** —
and in every firing series, both deciders' first EXIT landed exactly at the
trough price (mean first-EXIT price 0.00% above the trough). Neither decider
can know a dip will recover; the teacher policy itself orders an EXIT the
moment window drawdown crosses 21%, which on a 3-step plunge is the trough
step. The MLP reproduces that flaw faithfully and, via its other features,
triggers it in 3 more series than the raw threshold does. Where the MLP does
win on vdip is the stand-down afterwards: it stops firing much sooner during
the recovery (TRIM share 8.6% vs 20.5%; policy accuracy 99.8% vs 88.1%).

**Reverted spikes (flat_spikes).** A −22% single-step spike that reverts the
next step produces exactly one window with drawdown ≥ 21% (the spike step
itself; after reversion the window peak equals the recovered price, so
drawdown collapses). Both deciders EXIT on that window and HOLD around it —
the MLP's extra features change **nothing** here (100.0% agreement, identical
metrics to two decimal places).

## Overall disagreement structure (48,056 windows)

```
            mlp=HOLD  mlp=TRIM  mlp=EXIT
rule=HOLD      27401        94         0
rule=TRIM       4797     14432        53
rule=EXIT          9       271       999
```

Overall agreement 89.1%. Disagreement is overwhelmingly one-directional:
4,797 windows where the rule says TRIM and the model says HOLD (the model is
systematically more conservative about trimming), against only 94 windows of
the reverse. The model also talks the rule out of 280 of its 1,279 EXIT
windows (271 → TRIM, 9 → HOLD — mostly the whipsaw_exit sawtooth) while
adding 53 EXITs of its own on rule-TRIM windows.

---

## Honest conclusions

### Where the MLP genuinely wins

1. **Threshold whipsaw (the decisive win).** When price saws across the 3%
   TRIM threshold, the rule TRIMs on 19.3% of windows and changes its mind
   32.8 times per series — in the deployed system each spurious TRIM is a
   real callback that halves a position. The MLP, which also sees momentum,
   mean-return and price-vs-mean, recognises the sawtooth and TRIMs on 1.6%
   of windows with 2.05 transitions/series. No retuning of the single
   threshold fixes this: lowering sensitivity just moves the flapping to a
   different amplitude.
2. **Recovery stand-down.** The teacher's "never sell the bounce" clause
   exists only in the model. On V-recoveries the MLP's policy accuracy is
   86.5% vs the rule's 81.2% (pooled), and on vdip 99.8% vs 88.1%, with
   roughly half the rule's TRIM share during recoveries. A window-only rule
   keeps de-risking into a recovery because window drawdown stays ≥ 3% long
   after the price has turned.
3. **EXIT discipline under violent oscillation.** Around the 21% threshold
   the rule spends 5.7% of windows in EXIT and reverses out of it 3.12 times
   per series; the MLP spends 0.8% and reverses 0.63 times.
4. **Small but real:** fewer false TRIMs in ordinary chop (4.3% vs 6.0% of
   windows), and — despite the rule *being* the teacher on half the scenario
   kinds — higher pooled policy accuracy on the standard suite
   (97.40% vs 96.89%).

### Where they are equal

- **Calm and uptrend:** identical for all practical purposes (≥ 99.9%
  agreement, near-zero actions from both).
- **Genuine fast crashes:** both fire EXIT, neither ever misses one
  (0.0% missed in 114 crash-kind series), and first-EXIT timing differs by
  ≈ 0.1 steps. On the scenario the system exists for, the model adds no
  speed.
- **Reverted single-step spikes:** literally identical decisions on all
  5,340 windows. The model's extra features do not help it distinguish a
  one-step spike from the first step of a real crash — at the spike step,
  there is genuinely nothing in the window that does.

### Where the MLP loses

1. **Slow bleeds with sharp recoveries.** On `bleed_recovery` the MLP's
   policy fidelity is 77.6% against the rule's (definitional) 100%: it
   HOLDs 65.6% of windows the ladder would TRIM on 56.4% of. The bounces
   teach it to wait — but the series really does end down 15–25%, so the
   waiting is under-protection. This is the model's clearest behavioural
   deficit.
2. **V-dip bottoms.** The MLP EXITs in 55 of 60 recovered dips vs the
   rule's 52 — it inherits the teacher's "exit at ≥ 21% window drawdown"
   order, which on a fast plunge means selling the exact trough, and its
   feature sensitivity adds 3 more series. (Both deciders are wrong here
   together; the flaw is in the policy, and the model amplifies it
   slightly rather than correcting it.)
3. **HOLD↔TRIM stability at the EXIT-threshold sawtooth.** The MLP's total
   transitions are lower than the rule's (20.60 vs 23.45/series), but its
   HOLD↔TRIM oscillations are higher (19.33 vs 13.45/series): its
   HOLD/TRIM boundary is less stable in that regime even as its EXIT
   boundary is far more stable.
4. **Ladder fidelity.** On ladder-defined series the MLP is a 97.5–98.8%
   approximation of a function the rule computes exactly. If the intended
   policy were *only* the ladder, the model would be strictly worse.

### The shared blind spot (neither decider's fault — the feature's)

Drawdown is measured from the peak of the **9-price window**. Any decline
slower than ≈ 2.6%/step sustained can therefore never reach 21% window
drawdown: in `grind`, `slow_grind` (≈ −50% total) and `staircase`
(≈ −24% total), **EXIT windows are 0.0% for the rule, the MLP, and the
teacher labels alike** — protection caps out at TRIM no matter how much
value bleeds away. This is a property of the feature set, not of the
decider, and no amount of training fixes it. If EXIT-on-slow-bleed is
desired, the contract needs a longer-horizon anchor (e.g. drawdown vs a
slow EMA or a position-entry price) — that is a feature change, orthogonal
to the rule-vs-model question.

### Bottom line for "why not just code the rule?"

Because the intended policy was never just the ladder. The ladder is what
the rule computes; the policy also says *don't fire on sawtooth noise* and
*don't sell the bounce* — clauses that need more than one number from the
window, and whose absence costs the rule 17.7 points of false-TRIM windows
and 16× the flapping in whipsaw, plus continued firing through recoveries.
The learned model is the mechanism that carries those clauses on-chain.
The honest price of that mechanism: ~1–2 points of fidelity on the ladder
itself, a tendency to under-trim bouncy bleeds, and a faithfully inherited
flaw — exiting V-dip troughs — that only a policy change, not a better
model, can fix.

---

## Reproducibility

- Experiment script: appended below in full (also kept with the run output
  during the session). Run: `python3 baseline_experiment.py` (numpy only;
  it imports `tools/train.py` for the reference features/inference and
  parses the shipped `SentinelWeights.sol` — it does not modify the
  project).
- Seeds: standard 777001, adversarial 424242, 60 series per type.
- Sanity gates printed by the script before measuring:
  `[sanity] deployed weights pass canonical acceptance: True` and
  `[sanity] forward_int_vec == forward_int on 64 random vectors`.
- One calibration disclosure: the first `whipsaw_exit` draft (steps of
  5.0–6.5%) peaked at ≈ 20% within-window drawdown and never crossed the
  EXIT threshold it was meant to straddle; step sizes were raised to
  5.5–8.0% (drawdown span ≈ 17–25%) and the experiment re-run. All numbers
  above are from the final run.

## Appendix — experiment script (`baseline_experiment.py`)
```python
#!/usr/bin/env python3
"""
Sentinel baseline experiment: deterministic rule ladder vs the trained,
quantized on-chain MLP, on identical price windows.

Deciders (both see exactly the windows SentinelReactive sees: last <= 9
prices, decisions from the 3rd price on):
  RULE : the raw policy ladder as a pure function of the window features --
         drawdown >= 21% -> EXIT, drawdown >= 3% -> TRIM, else HOLD.
         (This is "just code the rule": the ladder minus the two clauses
         that need generator metadata -- flat-series HOLD and the V-recovery
         exception -- which no window-only contract can express as-is.)
  MLP  : the deployed quantized integer model, inferred through train.py's
         forward_int_vec with the weights parsed out of the shipped
         src/model/SentinelWeights.sol -- the exact contract inference path.

Reference labels ("policy"): train.py's label_window() with generator
metadata where the scenario defines it. On 'ladder'-kind series the RULE is
the ladder, so its policy accuracy is 100% by construction -- the interesting
numbers there are the MLP's generalization and the outcome metrics. On
'flat'/'vshape' series the policy encodes intent the raw ladder cannot
express (always HOLD / never sell the bounce).

Outcome metrics (independent of the policy labels) are computed per series
type: false-action rate on benign series, premature EXITs on dips that
recovered, first-EXIT delay / missed EXITs on genuine crashes, and decision
flapping (transitions per series, TRIM<->HOLD oscillations, EXIT reversals).

Seeds are fresh (never used in training): 777001 for the standard scenarios
(train.py's own generators), 424242 for the adversarial generators below.
Only dependency: numpy. Read-only w.r.t. the project; prints a report.
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
# Import the project's own reference implementation so features + inference
# are bit-identical to training and to the Solidity mirror.
sys.path.insert(0, "/home/hatch/workspace/bounty-new/reactive/project/tools")
import train as T  # noqa: E402

HOLD, TRIM, EXIT = T.HOLD, T.TRIM, T.EXIT
NAMES = T.ACTION_NAMES
SCALE = T.SCALE
WEIGHTS = T.parse_weights_sol(T.WEIGHTS_SOL)


# ---------------------------------------------------------------------------
# Deciders
# ---------------------------------------------------------------------------

def rule_decisions(F):
    """F: (N,6) int64 feature array. Pure drawdown ladder on f[3]."""
    dd = F[:, 3]
    out = np.full(len(F), HOLD, dtype=np.int64)
    out[dd >= 30_000] = TRIM          # drawdown >= 3%
    out[dd >= 210_000] = EXIT         # drawdown >= 21%
    return out


def mlp_decisions(F):
    pred, _, _ = T.forward_int_vec(F, *WEIGHTS)
    return pred


# ---------------------------------------------------------------------------
# Adversarial generators (returns -> prices via train.py's _walk).
# Each returns (prices, meta) with meta carrying construction landmarks.
# ---------------------------------------------------------------------------

def gen_whipsaw_trim(rng):
    """Sawtooth straddling the 3% TRIM threshold: 2 down / 2 up steps of
    ~1.4-2.0%, so the within-window drawdown oscillates across 3%.
    No trend, no crash -- the intent is HOLD throughout."""
    rets, drift = [], rng.choice([0.0, -0.0004])
    while len(rets) < 88:
        m = rng.uniform(0.014, 0.020)
        rets += [-m + drift, -m * rng.uniform(0.7, 1.0) + drift,
                 m + drift, m * rng.uniform(0.7, 1.0) + drift]
    return T._walk(rng, rets), {}


def gen_whipsaw_exit(rng):
    """Violent sawtooth straddling the 21% EXIT threshold: 4 down / 4 up
    steps of ~5-6.5%, so the within-window drawdown swings across 21%.
    The price ends roughly where the pattern started cycling; nothing is
    'crashing' after the pattern begins -- the intent is: do not flap."""
    rets = list(rng.normal(0.0005, 0.003, 8))
    while len(rets) < 88:
        m1 = rng.uniform(0.055, 0.080)
        m2 = rng.uniform(0.055, 0.080)
        rets += [-m1, -m1 * 0.9, -m1 * 0.8, -m1 * 0.7,
                 m2, m2 * 0.9, m2 * 0.8, m2 * 0.7]
    return T._walk(rng, rets), {}


def gen_bleed_recovery(rng):
    """Slow bleed punctuated by sharp recoveries: 5 cycles of
    10 steps at -0.6..-1.4% then a 2-step +3..+5%/step bounce.
    Net result is a real decline (~-15..-25%) -- but each bounce is a
    recovery leg on which a fresh EXIT sells into strength."""
    rets = list(rng.normal(0.0005, 0.003, 6))
    recovery_steps = set()
    for _ in range(5):
        rets += list(rng.uniform(-0.014, -0.006, 10))
        base = len(rets)
        rets += list(rng.uniform(0.030, 0.050, 2))
        recovery_steps.update({base, base + 1})  # price indices shift by +1
    rets += list(rng.normal(-0.002, 0.004, 6))
    prices = T._walk(rng, rets)
    # returns index i produces price index i+1; mark decision steps whose
    # *price* index is a recovery price (the step that lands the bounce).
    rec_price_idx = {i + 1 for i in recovery_steps}
    return prices, {"recovery_price_idx": rec_price_idx}


def gen_vdip(rng):
    """V-shaped flash dip that fully recovers: calm, 3-step plunge of
    -6..-10%/step, then +4..+9%/step until price is back >= 99% of the
    pre-dip level, then calm. Any EXIT before recovery completes sells
    a dip that came back."""
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
    """Flat noise (+/-0.3%) with 3-5 isolated single-step spikes down
    (-8%, -14% or -22%) that revert completely on the next step.
    A reverted spike sits in the 9-price window for 9 windows, holding
    the window drawdown high long after the price has recovered."""
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
    """A genuine crash in steps: three -8.5% legs (3 steps each) with
    8-step calm plateaus between them; ends ~-24% and stays down.
    Policy: EXIT once drawdown >= 21% (third leg). Tests whether a
    decider stays committed on the plateaus or relaxes."""
    rets = list(rng.normal(0.0005, 0.003, 8))
    for leg in range(3):
        rets += list(rng.uniform(-0.032, -0.026, 3))
        if leg < 2:
            rets += list(rng.normal(0.0, 0.003, 8))
    rets += list(rng.normal(-0.001, 0.003, 8))
    return T._walk(rng, rets), {}


def gen_slow_grind(rng):
    """A genuine slow crash: -0.8..-1.1%/step drift for 85 steps
    (~-50% total). Tests first-EXIT delay on a bleed with no drama."""
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
# Per-series evaluation
# ---------------------------------------------------------------------------

def evaluate_series(prices, kind, trough_idx, meta):
    """Runs both deciders over the on-chain window stream of one series.
    Returns per-step arrays + the policy labels (None where undefined)."""
    steps = list(range(2, len(prices)))
    F = np.array([T.features_from_window(prices[max(0, t - 8):t + 1])
                  for t in steps], dtype=np.int64)
    rule = rule_decisions(F)
    mlp = mlp_decisions(F)
    policy = None
    if kind is not None:
        policy = np.array([T.label_window(kind, trough_idx, t,
                                          [int(x) for x in F[i]])
                           for i, t in enumerate(steps)], dtype=np.int64)
    return steps, F, rule, mlp, policy


def transitions(d):
    return int((d[1:] != d[:-1]).sum()) if len(d) > 1 else 0


def th_oscillations(d):
    """Adjacent HOLD<->TRIM transitions (the classic threshold flap)."""
    if len(d) < 2:
        return 0
    a, b = d[:-1], d[1:]
    return int((((a == HOLD) & (b == TRIM)) | ((a == TRIM) & (b == HOLD))).sum())


def exit_reversals(d):
    """EXIT decisions that are later followed by a HOLD in the same series
    (the decider 'un-exits' -- indecision after the strongest signal)."""
    seen_exit = False
    count = 0
    for x in d:
        if x == EXIT:
            seen_exit = True
        elif x == HOLD and seen_exit:
            count += 1
            seen_exit = False
    return count


def first_idx(d, action):
    idx = np.nonzero(d == action)[0]
    return int(idx[0]) if len(idx) else None


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------

def pct(x):
    return f"{100.0 * x:5.1f}%"


def run_block(title, series_list):
    """series_list: list of dicts with steps/rule/mlp/policy/meta/prices."""
    n_series = len(series_list)
    n_win = sum(len(s["rule"]) for s in series_list)
    agree = np.mean([np.mean(s["rule"] == s["mlp"]) for s in series_list])
    out = {"title": title, "n_series": n_series, "n_windows": n_win,
           "agree": float(agree)}
    for name in ("rule", "mlp"):
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
            "trans_per_series": float(np.mean(trans)),
            "th_osc_per_series": float(np.mean(osc)),
            "exit_reversals_per_series": float(np.mean(rev)),
            "action_rate": float((dist[1] + dist[2]) / max(dist.sum(), 1)),
            "exit_rate": float(dist[2] / max(dist.sum(), 1)),
        }
    if all(s["policy"] is not None for s in series_list):
        for name in ("rule", "mlp"):
            accs = [np.mean(s[name] == s["policy"]) for s in series_list]
            out[f"{name}_policy_acc"] = float(np.mean(accs))
    # first-EXIT delay vs policy (series where the policy ever says EXIT)
    delays = {"rule": [], "mlp": []}
    missed = {"rule": 0, "mlp": 0}
    n_policy_exit = 0
    for s in series_list:
        if s["policy"] is None:
            continue
        pe = first_idx(s["policy"], EXIT)
        if pe is None:
            continue
        n_policy_exit += 1
        for name in ("rule", "mlp"):
            fe = first_idx(s[name], EXIT)
            if fe is None:
                missed[name] += 1
            else:
                delays[name].append(fe - pe)
    if n_policy_exit:
        out["n_policy_exit_series"] = n_policy_exit
        for name in ("rule", "mlp"):
            out[f"{name}_exit_delay_mean"] = (
                float(np.mean(delays[name])) if delays[name] else None)
            out[f"{name}_missed_exit_frac"] = missed[name] / n_policy_exit
    return out


def print_block(b):
    print(f"\n== {b['title']}  ({b['n_series']} series, {b['n_windows']} windows)")
    print(f"   rule<->mlp agreement: {pct(b['agree'])}")
    for name in ("rule", "mlp"):
        d = b[name]["dist"]
        print(f"   {name:4s} dist H/T/E: {pct(d[0])} / {pct(d[1])} / {pct(d[2])}"
              f" | transitions/series {b[name]['trans_per_series']:.2f}"
              f" | H<->T osc {b[name]['th_osc_per_series']:.2f}"
              f" | EXIT reversals {b[name]['exit_reversals_per_series']:.2f}")
        if f"{name}_policy_acc" in b:
            print(f"        policy accuracy: {pct(b[f'{name}_policy_acc'])}")
    if "n_policy_exit_series" in b:
        for name in ("rule", "mlp"):
            dl = b[f"{name}_exit_delay_mean"]
            print(f"   {name:4s} first-EXIT delay vs policy: "
                  f"{'n/a' if dl is None else f'{dl:+.2f} steps'}"
                  f" | missed-EXIT series: {pct(b[f'{name}_missed_exit_frac'])}"
                  f" (of {b['n_policy_exit_series']})")


def main():
    # Sanity: the shipped weights must pass the canonical acceptance checks
    # through this exact inference path before we measure anything.
    ok, _ = T.acceptance(*WEIGHTS, verbose=False)
    print(f"[sanity] deployed weights pass canonical acceptance: {ok}")
    assert ok
    # forward_int_vec must equal forward_int on random features.
    rngc = np.random.default_rng(0)
    Ftest = rngc.integers(-300_000, 300_001, size=(64, 6)).astype(np.int64)
    vec, _, _ = T.forward_int_vec(Ftest, *WEIGHTS)
    one = [T.forward_int([int(x) for x in row], *WEIGHTS)[0] for row in Ftest]
    assert (vec == np.array(one)).all(), "vectorized != scalar inference"
    print("[sanity] forward_int_vec == forward_int on 64 random vectors")

    blocks = []
    all_pairs = np.zeros((3, 3), dtype=np.int64)  # rule x mlp confusion

    # ---- standard scenarios, fresh seed, train.py's own generators ----
    rng = np.random.default_rng(777001)
    for scenario in T.SCENARIOS:
        series_list = []
        for _ in range(60):
            prices, kind = T.gen_series(rng, scenario)
            trough = int(np.argmin(prices)) if kind == "vshape" else -1
            steps, F, rule, mlp, policy = evaluate_series(prices, kind,
                                                          trough, {})
            series_list.append({"steps": steps, "rule": rule, "mlp": mlp,
                                "policy": policy, "meta": {}, "prices": prices})
            for r, m in zip(rule, mlp):
                all_pairs[r, m] += 1
        blocks.append(run_block(f"standard/{scenario}", series_list))

    # ---- adversarial scenarios ----
    rng = np.random.default_rng(424242)
    adv_extra = {}
    for name, (gen, kind) in ADVERSARIAL.items():
        series_list = []
        extra = {"vdip_premature": {"rule": 0, "mlp": 0},
                 "vdip_trough_exit": {"rule": 0, "mlp": 0},
                 "vdip_exit_price_above_trough": {"rule": [], "mlp": []},
                 "spike_action_rate": {"rule": [], "mlp": []},
                 "recovery_exit_windows": {"rule": 0, "mlp": 0},
                 "recovery_windows": 0}
        for _ in range(60):
            prices, meta = gen(rng)
            trough = meta.get("trough_idx", -1)
            steps, F, rule, mlp, policy = evaluate_series(
                prices, kind, trough, meta)
            s = {"steps": steps, "rule": rule, "mlp": mlp, "policy": policy,
                 "meta": meta, "prices": prices}
            series_list.append(s)
            for r, m in zip(rule, mlp):
                all_pairs[r, m] += 1
            step_of = {t: i for i, t in enumerate(steps)}
            if name == "vdip":
                lo, hi = meta["dip_start"], meta["rec_complete"]
                trough_price = prices[meta["trough_idx"]]
                for dname, d in (("rule", rule), ("mlp", mlp)):
                    zone = [d[step_of[t]] for t in steps if lo <= t <= hi]
                    if EXIT in zone:
                        extra["vdip_premature"][dname] += 1
                        fe = steps[int(np.nonzero(d == EXIT)[0][0])]
                        extra["vdip_exit_price_above_trough"][dname].append(
                            (prices[fe] - trough_price) / trough_price)
                    t_idx = meta["trough_idx"]
                    if t_idx in step_of and d[step_of[t_idx]] == EXIT:
                        extra["vdip_trough_exit"][dname] += 1
            if name == "flat_spikes":
                # windows whose newest price is a spike or within 8 steps
                # after one (the spike is inside the 9-price window)
                hot = set()
                for sp in meta["spike_price_idx"]:
                    hot.update(range(sp, sp + 9))
                for dname, d in (("rule", rule), ("mlp", mlp)):
                    hw = [d[step_of[t]] for t in steps if t in hot]
                    extra["spike_action_rate"][dname].append(
                        float(np.mean([x != HOLD for x in hw])) if hw else 0.0)
            if name == "bleed_recovery":
                rec = meta["recovery_price_idx"]
                extra["recovery_windows"] += len([t for t in steps if t in rec])
                for dname, d in (("rule", rule), ("mlp", mlp)):
                    extra["recovery_exit_windows"][dname] += sum(
                        1 for t in steps
                        if t in rec and d[step_of[t]] == EXIT)
        blocks.append(run_block(f"adversarial/{name}", series_list))
        adv_extra[name] = extra

    for b in blocks:
        print_block(b)

    print("\n== overall rule x mlp confusion (windows, all series)")
    print("            mlp=HOLD  mlp=TRIM  mlp=EXIT")
    for r in range(3):
        print(f"   rule={NAMES[r]:4s} " + "  ".join(
            f"{all_pairs[r, c]:8d}" for c in range(3)))
    tot = all_pairs.sum()
    print(f"   total windows {tot}, overall agreement "
          f"{pct(np.trace(all_pairs) / tot)}")

    print("\n== adversarial outcome extras")
    e = adv_extra["vdip"]
    for dname in ("rule", "mlp"):
        apt = e["vdip_exit_price_above_trough"][dname]
        print(f"   vdip {dname:4s}: premature-EXIT series "
              f"{e['vdip_premature'][dname]}/60, EXIT exactly at trough step "
              f"{e['vdip_trough_exit'][dname]}/60, mean first-EXIT price "
              f"above trough: "
              f"{'n/a' if not apt else f'{100 * float(np.mean(apt)):.2f}%'}")
    e = adv_extra["flat_spikes"]
    for dname in ("rule", "mlp"):
        print(f"   flat_spikes {dname:4s}: action rate inside spike windows "
              f"(spike step + next 8): {pct(float(np.mean(e['spike_action_rate'][dname])))}")
    e = adv_extra["bleed_recovery"]
    print(f"   bleed_recovery: recovery-leg windows total "
          f"{e['recovery_windows']}; EXIT decisions on those windows: "
          f"rule {e['recovery_exit_windows']['rule']}, "
          f"mlp {e['recovery_exit_windows']['mlp']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```
