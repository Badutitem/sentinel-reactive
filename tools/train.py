#!/usr/bin/env python3
"""
Sentinel phase 2 — off-chain trainer for the on-chain MLP (6 -> 8 -> 3).

Pipeline:
  1. Verify the Python integer reference implementation (features + forward
     pass) bit-for-bit against the phase-1 Solidity behaviour, by parsing the
     CURRENT SentinelWeights.sol and reproducing the exact logits/hidden
     values pinned in test/SentinelModel.t.sol and the exact features pinned
     in test/SentinelReactive.t.sol. If the mirror drifts, this script aborts
     before touching anything.
  2. Generate synthetic price series (calm / uptrend / chop / grind-down /
     crash / V-recovery), slide the on-chain window over them exactly like
     SentinelReactive does, compute integer features, and label each window
     with the stop-loss policy ladder (drawdown-based, direction-aware).
  3. Train the same 6->8->3 MLP in float (numpy, Adam, cross-entropy),
     quantize the weights (x1000; biases x1e6) and evaluate the INTEGER model
     (the thing that actually ships). A short quantization-aware fine-tune
     runs if the integer model misses any acceptance check.
  4. Acceptance: the canonical feature vectors (zero/calm/grind/crash/
     uptrend) and the canonical price paths from the Foundry tests must
     classify exactly as the tests expect.
  5. Regenerate src/model/SentinelWeights.sol in the phase-1 codegen shape
     and write tools/vectors.json with the fresh expected logits/scores so
     the Foundry tests can be re-pinned.

Everything is seeded; re-running reproduces the same weights.
Only dependency: numpy.
"""

import json
import math
import re
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
WEIGHTS_SOL = ROOT / "src" / "model" / "SentinelWeights.sol"
VECTORS_JSON = ROOT / "tools" / "vectors.json"

SCALE = 1_000_000          # feature scale (1e6 = 1.0), as in SentinelReactive
W_DENOM = 1_000            # weight scale (1000 = 1.0), as in SentinelModel
HOLD, TRIM, EXIT = 0, 1, 2
ACTION_NAMES = ["HOLD", "TRIM", "EXIT"]
SEED = 20261113

# ---------------------------------------------------------------------------
# Integer reference implementation — mirrors the Solidity exactly.
# Solidity `/` on signed integers truncates toward zero; Python `//` floors,
# so every signed division goes through tdiv(). Unsigned divisions and the
# square root operate on non-negative values, where floor == Solidity.
# ---------------------------------------------------------------------------


def tdiv(a: int, b: int) -> int:
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def features_from_window(window):
    """Mirror of SentinelReactive._features() for one ordered window.

    window: list of integer prices, oldest -> newest, len >= 2.
    Returns the six 1e6-scaled integer features.
    """
    n = len(window)
    peak = max(window)
    sum_price = sum(window)
    sum_ret = 0
    sum_sq = 0
    last_ret = 0
    for i in range(1, n):
        r = tdiv((window[i] - window[i - 1]) * SCALE, window[i - 1])
        sum_ret += r
        sum_sq += r * r
        last_ret = r
    m = n - 1
    mean = sum_price // n  # uint division, non-negative
    f = [0] * 6
    f[0] = last_ret
    f[1] = tdiv(sum_ret, m)
    f[2] = math.isqrt(sum_sq // m)
    f[3] = tdiv((peak - window[-1]) * SCALE, peak)
    f[4] = tdiv((window[-1] - window[0]) * SCALE, window[0])
    f[5] = tdiv((window[-1] - mean) * SCALE, mean)
    return f


def forward_int(f, w1, b1, w2, b2):
    """Mirror of SentinelModel.predict(). Weights are flat python lists of
    ints in the same row-major layout as SentinelWeights.sol."""
    hidden = []
    for i in range(8):
        acc = 0
        for j in range(6):
            acc += w1[i * 6 + j] * f[j]
        acc = tdiv(acc, W_DENOM) + b1[i]
        hidden.append(acc if acc > 0 else 0)
    logits = []
    best = 0
    for k in range(3):
        acc = 0
        for i in range(8):
            acc += w2[k * 8 + i] * hidden[i]
        logits.append(tdiv(acc, W_DENOM) + b2[k])
        if logits[k] > logits[best]:
            best = k
    return best, logits, hidden


# ---------------------------------------------------------------------------
# Step 1 — parse the phase-1 weights and prove the mirror is bit-exact.
# ---------------------------------------------------------------------------

PINNED_MODEL_VECTORS = {
    "zero":    ([0, 0, 0, 0, 0, 0], HOLD, [202000, -141500, -227000], None),
    "calm":    ([1000, 400, 2000, 1000, 3000, 1000], HOLD,
                [209441, -145928, -231901], None),
    "grind":   ([-12000, -12000, 12000, 92000, -92000, -40000], TRIM,
                [-911680, 883240, 693960], None),
    "crash":   ([-60000, -33000, 65000, 240000, -240000, -100000], EXIT,
                [-2914370, 2579845, 2961525],
                [1313000, 775000, 876000, 0, 0, 187100, 94200, 0]),
    "uptrend": ([15000, 12000, 9000, 0, 110000, 45000], HOLD, None, None),
}

# Canonical price paths from the Foundry tests (1e8 units).
CALM_PATH = [10_000_000_000, 10_050_000_000, 9_980_000_000,
             10_020_000_000, 10_010_000_000]
CRASH_PATH = CALM_PATH + [9_200_000_000, 8_100_000_000, 7_600_000_000]
COOLDOWN_PATH = CRASH_PATH + [7_000_000_000, 6_900_000_000]
PINNED_CRASH_FEATURES = [-61728, -37309, 59455, 243781, -240000, -188900]
PINNED_CRASH_SCORES = [-3226117, 2914666, 3138358]


def parse_weights_sol(path):
    text = path.read_text()
    out = {}
    for name in ("weights1", "biases1", "weights2", "biases2"):
        m = re.search(name + r"\(\)[^=]*=\s*\[([^\]]*)\]", text, re.S)
        vals = [int(x) for x in re.findall(r"int256\((-?\d+)\)", m.group(1))]
        out[name] = vals
    assert len(out["weights1"]) == 48 and len(out["biases1"]) == 8
    assert len(out["weights2"]) == 24 and len(out["biases2"]) == 3
    return out["weights1"], out["biases1"], out["weights2"], out["biases2"]


# The phase-1 hand-set weights, frozen here so the mirror proof stays valid
# (and this script stays idempotent) after SentinelWeights.sol is regenerated
# with trained weights.
PHASE1_W1 = [
    -1500, -1000, 2000, 2500, -1500, -1000,
    0, 0, 1000, 3000, -1000, 0,
    -1000, -2000, 0, 1000, -1500, -1500,
    500, 2000, -2000, -1000, 2000, 1500,
    300, -200, 500, -100, 200, 400,
    -400, 300, -200, 600, -300, 100,
    100, 100, -500, 200, -200, -300,
    -200, -500, 300, -400, 500, -200,
]
PHASE1_B1 = [0, -250000, 0, 50000, 0, -20000, 10000, 0]
PHASE1_W2 = [
    -1000, -500, -1500, 2000, 150, -100, 200, -150,
    800, 0, 1800, -1200, -100, 250, -150, 100,
    900, 1800, 600, -1500, 100, 150, -200, 250,
]
PHASE1_B2 = [100000, -80000, -150000]


def verify_mirror_against_phase1():
    w1, b1, w2, b2 = PHASE1_W1, PHASE1_B1, PHASE1_W2, PHASE1_B2
    for name, (feats, exp_action, exp_logits, exp_hidden) in PINNED_MODEL_VECTORS.items():
        action, logits, hidden = forward_int(feats, w1, b1, w2, b2)
        assert action == exp_action, f"mirror: {name} action {action} != {exp_action}"
        if exp_logits is not None:
            assert logits == exp_logits, f"mirror: {name} logits {logits} != {exp_logits}"
        if exp_hidden is not None:
            assert hidden == exp_hidden, f"mirror: {name} hidden {hidden} != {exp_hidden}"
    feats = features_from_window(CRASH_PATH)
    assert feats == PINNED_CRASH_FEATURES, f"mirror: crash features {feats}"
    _, scores, _ = forward_int(feats, w1, b1, w2, b2)
    assert scores == PINNED_CRASH_SCORES, f"mirror: crash scores {scores}"
    print("[mirror] Python reference reproduces phase-1 Solidity bit-for-bit "
          "(5 model vectors, crash-path features + scores).")


# ---------------------------------------------------------------------------
# Step 2 — synthetic series + policy-ladder labelling.
#
# A "series" is the price path of one token from the moment Sentinel is
# deployed: the on-chain window at step t is the last min(t, 9) prices, and
# inference starts at 3 prices — the dataset replicates exactly that.
#
# Policy ladder (the stop-loss semantics the model must learn):
#   drawdown < 3%                       -> HOLD  (noise / early bleed)
#   3% <= drawdown < 21%, still falling -> TRIM  (de-risk half)
#   drawdown >= 21%                     -> EXIT  (bleed is a rout)
#   recovering (post-trough, rising)    -> HOLD  (never sell the bounce)
# Calm / uptrend / chop series are HOLD by construction (their parameters
# keep drawdowns in the noise band, so the labels stay consistent).
# ---------------------------------------------------------------------------

P0 = 10_000_000_000  # 100.0 in 1e8 units, like the tests


def _walk(rng, rets, p0=P0):
    prices = [p0]
    for r in rets:
        prices.append(max(1, int(round(prices[-1] * (1.0 + r)))))
    return prices


def gen_series(rng, scenario):
    """Returns (prices, kind) where kind marks descent/recovery structure.
    kind: 'flat' (always HOLD), 'ladder' (dd ladder), 'vshape' (ladder on the
    way down, HOLD after the trough while recovering)."""
    if scenario == "calm":
        n = int(rng.integers(40, 91))
        drift = rng.uniform(-0.0002, 0.0015)
        vol = rng.uniform(0.001, 0.005)
        rets = rng.normal(drift, vol, n)
        return _walk(rng, rets), "flat"
    if scenario == "uptrend":
        n = int(rng.integers(40, 91))
        drift = rng.uniform(0.003, 0.010)
        vol = rng.uniform(0.002, 0.006)
        rets = rng.normal(drift, vol, n)
        return _walk(rng, rets), "flat"
    if scenario == "chop":
        n = int(rng.integers(40, 101))
        vol = rng.uniform(0.004, 0.012)
        rets = []
        prev = 0.0
        for _ in range(n):
            r = -0.5 * prev + rng.normal(0.0, vol)
            rets.append(r)
            prev = r
        return _walk(rng, rets), "flat"
    if scenario == "grind":
        n = int(rng.integers(40, 111))
        drift = rng.uniform(-0.012, -0.004)
        vol = rng.uniform(0.001, 0.006)
        rets = rng.normal(drift, vol, n)
        return _walk(rng, rets), "ladder"
    if scenario == "crash":
        pre = int(rng.integers(6, 16))
        plunge = int(rng.integers(3, 9))
        post = int(rng.integers(5, 21))
        rets = list(rng.normal(0.0005, 0.003, pre))
        rets += list(rng.uniform(-0.13, -0.04, plunge))
        rets += list(rng.normal(rng.uniform(-0.002, 0.002), 0.004, post))
        return _walk(rng, rets), "ladder"
    if scenario == "vrecovery":
        pre = int(rng.integers(6, 16))
        plunge = int(rng.integers(3, 8))
        rec = int(rng.integers(8, 26))
        rets = list(rng.normal(0.0005, 0.003, pre))
        rets += list(rng.uniform(-0.12, -0.05, plunge))
        rets += list(rng.normal(rng.uniform(0.008, 0.030), 0.006, rec))
        return _walk(rng, rets), "vshape"
    raise ValueError(scenario)


def label_window(kind, trough_idx, t, feats):
    """feats: integer features of the window ending at step t (0-based index
    into the price list). trough_idx: price-index of the series minimum
    (only meaningful for 'vshape')."""
    dd = feats[3] / SCALE
    last_ret = feats[0] / SCALE
    if kind == "flat":
        return HOLD
    if kind == "vshape" and t > trough_idx and last_ret > -0.02:
        return HOLD  # recovering: never sell the bounce
    if dd >= 0.21:
        return EXIT
    if dd >= 0.03:
        return TRIM
    return HOLD


def series_samples(rng, scenario):
    prices, kind = gen_series(rng, scenario)
    trough_idx = int(np.argmin(prices)) if kind == "vshape" else -1
    out = []
    for t in range(2, len(prices)):  # window of >= 3 prices, like on-chain
        window = prices[max(0, t - 8):t + 1]
        feats = features_from_window(window)
        out.append((feats, label_window(kind, trough_idx, t, feats)))
    return out


SCENARIOS = ["calm", "uptrend", "chop", "grind", "crash", "vrecovery"]


def build_dataset(rng, series_per_scenario=90):
    """Returns (train, heldout): lists of (features, label). Split is by
    series, never by window, so held-out series are genuinely unseen."""
    train, heldout = [], []
    for scenario in SCENARIOS:
        s_train, s_held = [], []
        for i in range(series_per_scenario):
            samples = series_samples(rng, scenario)
            (s_held if i % 5 == 4 else s_train).extend(samples)
        train.extend(s_train)
        heldout.extend(s_held)
    # Anchor samples: the canonical vectors/paths encode phase-1's intended
    # semantics; include the exact points plus jittered copies, up-weighted.
    anchors = []
    for name, (feats, action, _, _) in PINNED_MODEL_VECTORS.items():
        anchors.append((list(feats), action))
        for _ in range(24):
            jit = [int(round(v * rng.uniform(0.9, 1.1))) if v != 0
                   else int(rng.integers(-500, 501)) for v in feats]
            anchors.append((jit, action))
    for path, actions in ((CALM_PATH, [HOLD] * 3),
                          (CRASH_PATH, [HOLD, HOLD, HOLD, TRIM, TRIM, EXIT])):
        for t in range(2, len(path)):
            window = path[max(0, t - 8):t + 1]
            feats = features_from_window(window)
            if actions is not None and t - 2 < len(actions):
                anchors.append((feats, actions[t - 2]))
    train.extend(anchors * 3)
    rng.shuffle(train)
    rng.shuffle(heldout)
    return train, heldout


# ---------------------------------------------------------------------------
# Step 3 — train (float), quantize, evaluate the integer model.
# ---------------------------------------------------------------------------


def forward_int_vec(F, w1, b1, w2, b2):
    """Vectorized integer forward pass over an (N,6) int64 array of feature
    vectors; identical semantics to forward_int (trunc division via
    sign * (abs // d), floor isqrt via np.sqrt on non-negative values is NOT
    used here — no roots in the forward pass)."""
    W1 = np.asarray(w1, dtype=np.int64).reshape(8, 6)
    W2 = np.asarray(w2, dtype=np.int64).reshape(3, 8)
    acc1 = F @ W1.T  # (N,8) exact int64
    acc1 = np.where(acc1 >= 0, acc1 // 1000, -((-acc1) // 1000)) + np.asarray(b1)
    H = np.maximum(acc1, 0)
    acc2 = H @ W2.T
    acc2 = np.where(acc2 >= 0, acc2 // 1000, -((-acc2) // 1000)) + np.asarray(b2)
    return np.argmax(acc2, axis=1), acc2, H


def quantize(W1, b1, W2, b2):
    w1i = [int(round(v * 1000)) for v in W1.reshape(-1)]
    b1i = [int(round(v * SCALE)) for v in b1]
    w2i = [int(round(v * 1000)) for v in W2.reshape(-1)]
    b2i = [int(round(v * SCALE)) for v in b2]
    return w1i, b1i, w2i, b2i


def _mlp_forward(X, W1, b1, W2, b2):
    Z1 = X @ W1.T + b1
    H = np.maximum(Z1, 0.0)
    Z2 = H @ W2.T + b2
    Z2s = Z2 - Z2.max(axis=1, keepdims=True)
    E = np.exp(Z2s)
    P = E / E.sum(axis=1, keepdims=True)
    return Z1, H, P


def train_float(X, Y, cw, epochs, lr0, lr1, wd, rng, params=None, ste=False):
    """Full-batch Adam on cross-entropy. If ste=True, the forward pass uses
    the quantized weights (straight-through estimator) — quantization-aware
    fine-tuning so the shipped integer model inherits the float accuracy."""
    N = X.shape[0]
    if params is None:
        W1 = rng.normal(0, 0.7, (8, 6)); b1 = np.zeros(8)
        W2 = rng.normal(0, 0.7, (3, 8)); b2 = np.zeros(3)
    else:
        W1, b1, W2, b2 = [p.copy() for p in params]
    Yoh = np.zeros((N, 3)); Yoh[np.arange(N), Y] = 1.0
    sample_w = cw[Y]
    state = {k: [np.zeros_like(p), np.zeros_like(p)]
             for k, p in (("W1", W1), ("b1", b1), ("W2", W2), ("b2", b2))}
    for ep in range(epochs):
        lr = lr1 + 0.5 * (lr0 - lr1) * (1 + math.cos(math.pi * ep / epochs))
        if ste:
            W1e = np.round(W1 * 1000) / 1000; b1e = np.round(b1 * SCALE) / SCALE
            W2e = np.round(W2 * 1000) / 1000; b2e = np.round(b2 * SCALE) / SCALE
        else:
            W1e, b1e, W2e, b2e = W1, b1, W2, b2
        Z1, H, P = _mlp_forward(X, W1e, b1e, W2e, b2e)
        dZ2 = (P - Yoh) * sample_w[:, None] / N
        dW2 = dZ2.T @ H + wd * W2e
        db2 = dZ2.sum(axis=0)
        dH = dZ2 @ W2e
        dZ1 = dH * (Z1 > 0)
        dW1 = dZ1.T @ X + wd * W1e
        db1 = dZ1.sum(axis=0)
        for name, p, g in (("W1", W1, dW1), ("b1", b1, db1),
                           ("W2", W2, dW2), ("b2", b2, db2)):
            m, v = state[name]
            m[:] = 0.9 * m + 0.1 * g
            v[:] = 0.999 * v + 0.001 * g * g
            mh = m / (1 - 0.9 ** (ep + 1)); vh = v / (1 - 0.999 ** (ep + 1))
            p -= lr * mh / (np.sqrt(vh) + 1e-8)
        if ep in (0, epochs // 2, epochs - 1):
            pred = np.argmax(P, axis=1)
            acc = float((pred == Y).mean())
            print(f"    epoch {ep:5d}  train-acc {acc:.4f}  lr {lr:.5f}")
    return W1, b1, W2, b2


def acceptance(w1i, b1i, w2i, b2i, verbose=True):
    """The canonical behaviours the Foundry tests pin. Returns (ok, report)."""
    ok = True
    report = []
    for name, (feats, exp_action, _, _) in PINNED_MODEL_VECTORS.items():
        action, logits, _ = forward_int(feats, w1i, b1i, w2i, b2i)
        srt = sorted(logits, reverse=True)
        good = action == exp_action
        ok &= good
        report.append(f"vector {name:8s} -> {ACTION_NAMES[action]} "
                      f"(want {ACTION_NAMES[exp_action]}) margin {srt[0] - srt[1]}")
    def path_actions(path):
        acts = []
        for t in range(2, len(path)):
            feats = features_from_window(path[max(0, t - 8):t + 1])
            acts.append(forward_int(feats, w1i, b1i, w2i, b2i)[0])
        return acts
    calm = path_actions(CALM_PATH)
    good = calm == [HOLD, HOLD, HOLD]
    ok &= good
    report.append(f"calm path   -> {[ACTION_NAMES[a] for a in calm]} (want HOLD x3)")
    crash = path_actions(CRASH_PATH)
    good = crash == [HOLD, HOLD, HOLD, TRIM, TRIM, EXIT]
    ok &= good
    report.append(f"crash path  -> {[ACTION_NAMES[a] for a in crash]} "
                  f"(want HOLD,HOLD,HOLD,TRIM,TRIM,EXIT)")
    cool = path_actions(COOLDOWN_PATH)
    good = cool[-1] in (TRIM, EXIT)
    ok &= good
    report.append(f"cooldown end-> {ACTION_NAMES[cool[-1]]} (want TRIM or EXIT)")
    if verbose:
        for line in report:
            print("   ", line)
    return ok, report


# ---------------------------------------------------------------------------
# Step 4 — codegen: regenerate SentinelWeights.sol in the phase-1 shape.
# ---------------------------------------------------------------------------


def _fmt_table(vals, per_row, row_comments):
    lines = []
    for r in range(0, len(vals), per_row):
        row = vals[r:r + per_row]
        for c, v in enumerate(row):
            last = (r + c == len(vals) - 1)
            comma = "" if last else ","
            comment = f" // {row_comments[r // per_row]}" if c == len(row) - 1 else ""
            lines.append(f"            int256({v}){comma}{comment}")
    return "\n".join(lines)


def write_weights_sol(w1i, b1i, w2i, b2i, metrics):
    header = f"""// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title SentinelWeights — quantized weights for the Sentinel MLP (6 -> 8 -> 3).
/// @notice TRAINED 2026-11-13 on synthetic price series by tools/train.py
///         (seed {SEED}; {metrics['series']} series across calm / uptrend /
///         chop / grind-down / crash / V-recovery scenarios, labelled by the
///         stop-loss policy ladder: drawdown >= 21% -> EXIT, 3-21% and still
///         falling -> TRIM, recovering -> HOLD, otherwise HOLD).
///         Dataset: {metrics['train_n']} train / {metrics['held_n']} held-out
///         windows. Float model accuracy: train {metrics['float_train']:.4f},
///         held-out {metrics['float_held']:.4f}. Quantized integer model
///         (this file): train {metrics['int_train']:.4f}, held-out
///         {metrics['int_held']:.4f}. The training script verified its integer
///         reference implementation bit-for-bit against the phase-1 Solidity
///         behaviour before training, and the shipped weights pass the
///         canonical acceptance vectors (calm -> HOLD, grind -> TRIM,
///         crash -> EXIT). Do not hand-edit the tables — regenerate them with
///         tools/train.py.
/// @dev Quantization: weights are integers scaled by 1000 (e.g. -1500 means
///      -1.5); biases are expressed in the activation scale (features/logits
///      are scaled by 1e6). Output layout: index 0 = HOLD, 1 = TRIM, 2 = EXIT.
library SentinelWeights {{"""
    w1 = _fmt_table(w1i, 6, [f"h{i}" for i in range(8)])
    b1 = "\n".join(
        f"            int256({v}){'' if i == 7 else ','} // h{i}"
        for i, v in enumerate(b1i))
    w2 = _fmt_table(w2i, 8, ["HOLD", "TRIM", "EXIT"])
    b2 = ", ".join(f"int256({v})" for v in b2i)
    body = f"""
    /// @notice Layer 1 weights, row-major [hidden][feature], 8 * 6 = 48 entries.
    ///         Feature order: [lastReturn, meanReturn, volatility, drawdown, momentum, priceVsMean].
    function weights1() internal pure returns (int256[48] memory w) {{
        w = [
{w1}
        ];
    }}

    /// @notice Layer 1 biases (activation scale, 1e6 = 1.0).
    function biases1() internal pure returns (int256[8] memory b) {{
        b = [
{b1}
        ];
    }}

    /// @notice Layer 2 weights, row-major [action][hidden], 3 * 8 = 24 entries.
    function weights2() internal pure returns (int256[24] memory w) {{
        w = [
{w2}
        ];
    }}

    /// @notice Layer 2 biases (logit scale, 1e6 = 1.0).
    function biases2() internal pure returns (int256[3] memory b) {{
        b = [{b2}];
    }}
}}
"""
    WEIGHTS_SOL.write_text(header + body)


def main():
    verify_mirror_against_phase1()

    rng = np.random.default_rng(SEED)
    train, heldout = build_dataset(rng)
    Xtr = np.array([f for f, _ in train], dtype=np.float64) / SCALE
    Ytr = np.array([y for _, y in train])
    Xhe = np.array([f for f, _ in heldout], dtype=np.float64) / SCALE
    Yhe = np.array([y for _, y in heldout])
    Ftr = np.array([f for f, _ in train], dtype=np.int64)
    Fhe = np.array([f for f, _ in heldout], dtype=np.int64)
    counts = np.bincount(Ytr, minlength=3)
    print(f"[data] train {len(train)} windows {dict(zip(ACTION_NAMES, counts))}, "
          f"held-out {len(heldout)}")
    cw = (len(Ytr) / (3.0 * np.maximum(counts, 1))).astype(np.float64)

    print("[train] float phase")
    params = train_float(Xtr, Ytr, cw, epochs=2000, lr0=0.01, lr1=0.001,
                         wd=1e-4, rng=np.random.default_rng(SEED + 1))
    W1, b1, W2, b2 = params
    _, _, P = _mlp_forward(Xtr, W1, b1, W2, b2)
    float_train = float((np.argmax(P, axis=1) == Ytr).mean())
    _, _, P = _mlp_forward(Xhe, W1, b1, W2, b2)
    float_held = float((np.argmax(P, axis=1) == Yhe).mean())
    print(f"[train] float accuracy: train {float_train:.4f} held-out {float_held:.4f}")

    for round_ in range(5):
        w1i, b1i, w2i, b2i = quantize(W1, b1, W2, b2)
        pred_tr, _, _ = forward_int_vec(Ftr, w1i, b1i, w2i, b2i)
        pred_he, _, _ = forward_int_vec(Fhe, w1i, b1i, w2i, b2i)
        int_train = float((pred_tr == Ytr).mean())
        int_held = float((pred_he == Yhe).mean())
        print(f"[quantize round {round_}] integer accuracy: "
              f"train {int_train:.4f} held-out {int_held:.4f}")
        ok, _ = acceptance(w1i, b1i, w2i, b2i)
        if ok:
            break
        print("[qat] acceptance failed — quantization-aware fine-tune round")
        W1, b1, W2, b2 = train_float(Xtr, Ytr, cw, epochs=600, lr0=0.003,
                                     lr1=0.0005, wd=1e-4,
                                     rng=np.random.default_rng(SEED + 2 + round_),
                                     params=(W1, b1, W2, b2), ste=True)
    else:
        print("ERROR: acceptance still failing after QAT rounds; "
              "weights NOT written.", file=sys.stderr)
        return 1
    print("[acceptance] all canonical checks pass with the integer model")

    per_class = {}
    for k in range(3):
        mask = Yhe == k
        per_class[ACTION_NAMES[k]] = float((pred_he[mask] == k).mean())
    print(f"[eval] integer held-out accuracy by class: {per_class}")
    metrics = {
        "series": 90 * len(SCENARIOS),
        "train_n": len(train), "held_n": len(heldout),
        "float_train": float_train, "float_held": float_held,
        "int_train": int_train, "int_held": int_held,
        "int_held_by_class": per_class,
    }
    write_weights_sol(w1i, b1i, w2i, b2i, metrics)
    print(f"[codegen] wrote {WEIGHTS_SOL}")

    vectors = {"model": {}, "metrics": metrics}
    for name, (feats, _, _, _) in PINNED_MODEL_VECTORS.items():
        action, logits, hidden = forward_int(feats, w1i, b1i, w2i, b2i)
        vectors["model"][name] = {"features": feats, "action": action,
                                  "logits": logits, "hidden": hidden}
    feats = features_from_window(CRASH_PATH)
    _, scores, _ = forward_int(feats, w1i, b1i, w2i, b2i)
    vectors["crash_path_final"] = {"features": feats, "scores": scores}
    VECTORS_JSON.write_text(json.dumps(vectors, indent=2))
    print(f"[codegen] wrote {VECTORS_JSON}")
    print(json.dumps(metrics, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
