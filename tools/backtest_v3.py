#!/usr/bin/env python3
"""
Sentinel backtest comparator: v1 vs v2 vs v3 (candidate) on the same 5
real Binance ETHUSDT hourly episodes as BACKTEST.md / ANCHOR.md §4,
same pipeline (decisions from the 3rd price over the last <= 9 closes;
1,000 USD position at the first close; decisions execute at the close
that produced them; no gas/slippage; cooldown never binds at 1h).

Step 1 reproduces BACKTEST.md's v1 table exactly (pipeline proof).
Step 2 prints v2 (shipped, Release 3) and v3 (candidate weights in
src/model/SentinelWeightsV3.sol) side by side and evaluates the Release
#4 gate: v3 no worse than v2 — operationalised as
  * calm episodes (sep2023, feb2024): v3 EXIT windows == 0 (hard);
  * crash episodes: v3 fires >= 1 EXIT; first EXIT no more than 6
    steps later than v2's; first-fire and full-semantics final values
    no more than 1% (relative) below v2's; max drawdowns no more than
    1 percentage point above v2's.
Klines: /tmp/klines_<episode>.json (close prices x1e8), fetched from
data-api.binance.vision for the episode windows in ANCHOR.md.
"""
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train as T

HOLD, TRIM, EXIT = T.HOLD, T.TRIM, T.EXIT
ROOT = Path(__file__).resolve().parent.parent
W1 = T.parse_weights_sol(T.WEIGHTS_SOL)
W2 = T.parse_weights_v2_sol(ROOT / "src" / "model" / "SentinelWeightsV2.sol")
_W3_PATH = ROOT / "src" / "model" / "SentinelWeightsV3.sol"
if not _W3_PATH.exists():
    sys.exit("SentinelWeightsV3.sol not in tree: the v3 candidate was NOT "
             "shipped (see RELEASE4.md). Regenerate it with "
             "`python3 tools/train.py v3` to rerun this comparator.")
W3 = T.parse_weights_v2_sol(_W3_PATH)

EPISODES = {
    "may2021": ("May 2021 crash", datetime(2021, 5, 8, tzinfo=timezone.utc)),
    "jun2022": ("Jun 2022 collapse", datetime(2022, 6, 6, tzinfo=timezone.utc)),
    "aug2024": ("Aug 2024 crash", datetime(2024, 7, 24, tzinfo=timezone.utc)),
    "sep2023": ("Sep 2023 chop", datetime(2023, 9, 1, tzinfo=timezone.utc)),
    "feb2024": ("Feb 2024 uptrend", datetime(2024, 2, 1, tzinfo=timezone.utc)),
}
CRASH_EPISODES = ("may2021", "jun2022", "aug2024")
CALM_EPISODES = ("sep2023", "feb2024")

PUBLISHED = {
    "may2021": ((432, 165, 2), 84.3, (734, 57.3), (868, 24.3), (1086, 5.4)),
    "jun2022": ((378, 125, 0), 90.5, (659, 52.7), (836, 27.7), (998, 4.2)),
    "aug2024": ((463, 64, 0), 97.3, (770, 35.8), (870, 19.4), (962, 4.0)),
    "sep2023": ((713, 6, 0), 99.9, (1013, 7.0), (978, None), (944, None)),
    "feb2024": ((687, 8, 0), 99.3, (1480, 5.4), (1375, None), (1297, None)),
}


def simulate(prices, decisions):
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
    mlp3, _, _ = T.forward_int_vec_v2(F7, *W3)
    dd = F6[:, 3]
    rule1 = np.full(len(steps), HOLD, dtype=np.int64)
    rule1[dd >= 30_000] = TRIM
    rule1[dd >= 210_000] = EXIT
    out = {}
    for tag, dec in (("mlp1", mlp1), ("mlp2", mlp2), ("mlp3", mlp3)):
        counts = tuple(int((dec == k).sum()) for k in range(3))
        dmap = {t: int(dec[i]) for i, t in enumerate(steps)}
        sims = simulate(prices, dmap)
        fe = next((i for i, t in enumerate(steps) if dec[i] == EXIT), None)
        fe_info = None
        if fe is not None:
            t = steps[fe]
            fe_info = {
                "t": t,
                "when": (start + timedelta(hours=t + 1)).strftime("%d %b %H:00"),
                "price": prices[t] / 1e8,
                "below_peak_pct": 100 * (max(prices) - prices[t]) / max(prices),
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
        ok = (m["counts"] == pub[0]
              and abs(100 * r["agree1"] - pub[1]) < 0.15
              and abs(m["sims"][0][0] - pub[2][0]) <= 2
              and abs(100 * m["sims"][0][1] - pub[2][1]) <= 0.15
              and abs(m["sims"][1][0] - pub[3][0]) <= 2
              and (pub[3][1] is None or abs(100 * m["sims"][1][1] - pub[3][1]) <= 0.15)
              and abs(m["sims"][2][0] - pub[4][0]) <= 2
              and (pub[4][1] is None or abs(100 * m["sims"][2][1] - pub[4][1]) <= 0.15))
        all_ok &= ok
        print(f"{name}: counts {m['counts']} agree {100 * r['agree1']:.1f}% "
              f"-> {'MATCH' if ok else 'MISMATCH'}")
    print("v1 reproduction:", "ALL MATCH" if all_ok else "FAILED")
    if not all_ok:
        return 1

    print("\n=== STEP 2: v2 (shipped) vs v3 (candidate) ===")
    gate_ok = True
    for name in EPISODES:
        r = results[name]
        print(f"\n{EPISODES[name][0]} ({r['n_windows']} windows)")
        for tag in ("mlp2", "mlp3"):
            m = r[tag]
            print(f"  {tag:5s} H/T/E {m['counts'][0]}/{m['counts'][1]}/"
                  f"{m['counts'][2]} | FF {fmt_sim(m['sims'][1])} | "
                  f"FULL {fmt_sim(m['sims'][2])}")
            if m["first_exit"]:
                fe = m["first_exit"]
                print(f"        first EXIT {fe['when']} UTC @ ${fe['price']:,.0f} "
                      f"({fe['below_peak_pct']:.1f}% below peak, t={fe['t']})")
        v2, v3 = r["mlp2"], r["mlp3"]
        if name in CALM_EPISODES:
            ok = v3["counts"][2] == 0
            gate_ok &= ok
            print(f"  GATE calm: v3 EXIT windows = {v3['counts'][2]} "
                  f"({'PASS' if ok else 'FAIL'})")
        else:
            checks = []
            checks.append(("v3 fires EXIT", v3["counts"][2] >= 1))
            if v2["first_exit"] and v3["first_exit"]:
                checks.append(("first EXIT <= v2 + 6 steps",
                               v3["first_exit"]["t"] <= v2["first_exit"]["t"] + 6))
            for si, label in ((1, "first-fire"), (2, "full")):
                checks.append((f"{label} final >= v2 - 1%",
                               v3["sims"][si][0] >= 0.99 * v2["sims"][si][0]))
                checks.append((f"{label} maxDD <= v2 + 1pp",
                               v3["sims"][si][1] <= v2["sims"][si][1] + 0.01))
            for label, ok in checks:
                gate_ok &= ok
                print(f"  GATE {label}: {'PASS' if ok else 'FAIL'}")
    print("\nBACKTEST GATE (v3 no worse than v2):",
          "PASS" if gate_ok else "FAIL")
    return 0 if gate_ok else 2


if __name__ == "__main__":
    sys.exit(main())
