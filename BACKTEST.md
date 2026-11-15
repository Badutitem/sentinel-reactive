# Sentinel — Real-Data Backtest

**What this is.** The headline accuracy of the Sentinel model (97.47%) is measured
on held-out windows from the *same synthetic generator* that produced the training
set (`tools/train.py`), labelled by the same policy ladder the model was trained to
imitate. That number is self-referential: it proves the integer MLP reproduces its
teacher on synthetic data, nothing more. This document replays the **shipped model**
over **real market history** and reports how it actually behaves — where it fires,
where it doesn't, and what it costs when it's wrong.

**Run:** 2026-11-15. **Model under test:** the quantized integer weights in
`src/model/SentinelWeights.sol` (the exact artifact deployed on-chain), executed
through the bit-exact integer reference implementation in `tools/train.py`
(`features_from_window` + `forward_int`). Before replay, the parsed weights were
re-checked against the canonical acceptance vectors (calm → HOLD, grind → TRIM,
crash → EXIT): **pass**. The float model was *not* used.

**Data:** Binance ETH/USDT **hourly closes** (klines), fetched from the public
data mirror `data-api.binance.vision` (`api.binance.com` is geo-blocked from the
build environment; the mirror serves the identical klines payload). Prices were
converted to 1e8-scaled integers, the on-chain price format. All six features are
ratios, so the absolute scale is immaterial.

## Method — and the one big adaptation

The replay mirrors `SentinelReactive` exactly:

- The window is the **last 9 prices** (ring buffer, `WINDOW = 9`); inference starts
  at the 3rd price (`MIN_UPDATES = 3`). Features: last return, mean return, RMS
  volatility, **drawdown from the 9-price window peak**, window momentum, price vs
  window mean — all 1e6-scaled integers, truncating division, as on-chain.
- A decision (argmax of HOLD / TRIM / EXIT) is produced at **every** price update.
- The deployed cooldown is 300 s. At an hourly step (3600 s) the cooldown never
  binds, so every TRIM/EXIT decision would produce a callback on-chain;
  escalations (TRIM → EXIT) fire unconditionally at any cadence.

**The adaptation, stated plainly:** the model was trained on synthetic series in
which one step is one oracle push of no defined timescale. We replay at **1 push =
1 hour**. Every conclusion below is conditional on that cadence, and the most
important finding is *about* the cadence/window interaction: the drawdown feature
only ever sees the last 9 hours, so the 21% drawdown level associated with EXIT
requires a >21% fall **inside a single 9-hour window**. Slower collapses — however
deep in total — never present that feature value. This is a property of the
feature design, not of the trained weights: the policy ladder itself (see below)
behaves the same way.

**Comparison rule.** With no ground truth on real data, decisions are also scored
against the training label rule applied to the same windows (window drawdown
≥ 21% → EXIT, ≥ 3% → TRIM, else HOLD — `label_window` without its V-recovery
carve-out, which needs to know the future trough). Agreement is reported per
episode. It measures fidelity to the teacher, not correctness.

**Position simulations.** A 1,000 USD position opened at the episode's first
close, marked to market hourly, decisions executed at the close that produced
them (the on-chain system reacts to the price event itself). Two variants:

- **First-fire:** only the first TRIM (halve) and first EXIT (close) are acted on;
  no re-entry. The conservative reading.
- **Full on-chain semantics:** every decision is applied exactly as
  `SentinelVault.executeProtection` would at this cadence — each TRIM halves the
  remaining position, EXIT closes it permanently.

Both ignore gas/lREACT callback costs and slippage, and the vault position is a
mock counter — the simulations value the *decisions*, not a tradable strategy.

## Headline findings

1. **EXIT is nearly unreachable on real hourly data.** Across 2,749 replayed
   windows in five episodes, the model said EXIT **twice** — both in May 2021.
   In the June 2022 collapse (−52.7% peak-to-trough) and the August 2024 crash
   (−35.8%) it never fired once. The maximum 9-hour window drawdown in those
   episodes was **15.7%** and **16.7%** respectively — below the 21% line. Even
   on 19 May 2021, one of the worst days in ETH history, the window drawdown
   peaked at only **21.8%**. The policy ladder agrees with the model 84–99% of
   windows and also never EXITs in four of five episodes: at this cadence the
   EXIT class is calibrated for a violence that hourly closes rarely contain.

2. **TRIM is the real protection mechanism — and it is early.** First post-peak
   TRIM came **7 h** after the peak in June 2022, **9 h** in August 2024, and
   **12 h** in May 2021, in each case at only ~3–5% below the peak. The model
   de-risks quickly; it just almost never escalates.

3. **Under faithful on-chain semantics, repeated TRIMs compound into an
   effective exit.** Because each TRIM halves what is left, 125 TRIM windows in
   June 2022 ratchet exposure to ~0 without a single EXIT: simulated max
   drawdown **4.2%** vs 52.7% buy-and-hold, final value **998** vs 659 per 1,000.
   August 2024: max DD **4.0%** vs 35.8%, final **962** vs 770. May 2021: max DD
   **5.4%**, final **1,086** (the position was mostly out before the worst of it,
   and the two EXITs finished the job). Under first-fire-only semantics the
   protection is far weaker (final 836–870, max DD 19–28% in the crashes) — so
   the deployed system's real-world behaviour depends heavily on the
   repeat-TRIM ratchet, a property nobody designed explicitly.

4. **The false-fire bill is real but bounded — and there are no false EXITs.**
   September 2023 chop: 6 TRIM windows out of 719 (0.8%), clustered at the
   month's lows; February 2024 uptrend: 8 of 695 (1.2%), at local pullbacks.
   Cost vs buy-and-hold: chop −3.5% (first-fire) / −6.8% (full semantics);
   uptrend −7.1% / −12.4%. The full-semantics ratchet that saves the crashes is
   exactly what taxes calm markets: every wiggle halves you again.

5. **When EXIT finally fired in May 2021, it fired at the worst moment of the
   crash day.** First EXIT: 19 May 13:00 UTC close, $2,365 — already **45.4%
   below the 12 May peak**, printed during the liquidation cascade itself.
   Price fell a further 21.9% to the episode's closing trough ($1,848 on
   23 May), but the episode also *ended* 9.3% above the EXIT price. EXIT, as
   calibrated, is a capitulation signal: it confirms the rout at its most
   violent hour rather than anticipating it.

6. **The model trims into recoveries.** Post-trough, 53 of 224 windows in
   May 2021 and 31 of 196 in June 2022 were still TRIM. The synthetic
   V-recovery training labels ("never sell the bounce") relied on knowing the
   series had troughed; on real data the model has no such knowledge and keeps
   de-risking bounces that later fail — defensible in May/June (both made lower
   lows after the first trough) but a genuine behavioural gap vs the training
   story.

**Net assessment.** On real data the shipped model is a fast, disciplined
*trimmer* with a nearly decorative EXIT — the opposite emphasis from the
synthetic demo, where EXIT is the climax. Its protection in real crashes comes
from an emergent property (the TRIM ratchet), and its calm-market cost is the
mirror image of that property. The 97.47% synthetic figure should be read as
"the MLP faithfully reproduces the ladder on synthetic windows" — fidelity to
the teacher on real windows is also high (84–99%) — and **not** as evidence
about market outcomes. The honest real-data summary is the table below.

## Results at a glance

Per 1,000 USD opened at the episode's first close. "Max DD" for buy-and-hold is
the episode's peak-to-trough drawdown; for the simulations, the position's own
peak-to-trough. Decision counts are per hourly window (inference from the 3rd
price on).

| Episode | ETH start → end | Peak → trough | HOLD / TRIM / EXIT | Ladder agree | Buy & hold final (max DD) | First-fire final (max DD) | Full semantics final (max DD) |
|---|---|---|---|---|---|---|---|
| May 2021 crash (8 May – 2 Jun) | 3,523 → 2,585 | 4,333 → 1,848 (−57.3%) | 432 / 165 / **2** | 84.3% | 734 (57.3%) | 868 (24.3%) | **1,086 (5.4%)** |
| Jun 2022 collapse (6 – 27 Jun) | 1,836 → 1,210 | 1,911 → 904 (−52.7%) | 378 / 125 / 0 | 90.5% | 659 (52.7%) | 836 (27.7%) | **998 (4.2%)** |
| Aug 2024 crash (24 Jul – 15 Aug) | 3,464 → 2,666 | 3,470 → 2,228 (−35.8%) | 463 / 64 / 0 | 97.3% | 770 (35.8%) | 870 (19.4%) | **962 (4.0%)** |
| Sep 2023 chop (1 Sep – 1 Oct) | 1,653 → 1,674 | max DD 7.0% (running peak) | 713 / 6 / 0 | 99.9% | 1,013 (7.0%) | 978 (6.4%) | 944 (5.9%) |
| Feb 2024 uptrend (1 Feb – 1 Mar) | 2,284 → 3,379 | max DD 5.4% (running peak) | 687 / 8 / 0 | 99.3% | 1,480 (5.4%) | 1,375 (3.9%) | 1,297 (3.9%) |

## Episode notes

### May 2021 crash — the only EXITs on record
Peak close $4,333 on 12 May 04:00 UTC; closing trough $1,848 on 23 May 17:00
(−57.3%). The model TRIMmed speculatively *before* the peak (9–11 May, on
5%-scale pullbacks inside the rally — false fires by any post-hoc reading),
then 12 h after the peak at $4,189 and persistently through the week-long
grind down. The first EXIT printed at the 19 May 13:00 close ($2,365,
window drawdown 20.8%) — the cascade hour — with a second at 20 May 01:00
($2,231). After the 23 May trough the model kept TRIMming the failed bounces
for another week (53 non-HOLD windows post-trough); in this episode that was
mostly right, as the recovery kept failing into early June.

### June 2022 collapse — death by a thousand TRIMs
Peak $1,911 on 6 Jun 10:00; trough $904 on 18 Jun 21:00 (−52.7%). First TRIM
7 h after the peak at $1,859; 125 TRIM windows in total, in 27 clusters that
track every leg down (Celsius freeze, 3AC unwind). **Zero EXITs** — the
steepest 9-hour window drawdown of the entire collapse was 15.7% (15 Jun
09:00). A stop-loss whose terminal action requires a 21% nine-hour drawdown
does not terminate in a grind; it bleeds out by halves instead. Here, the
bleed-out happened to be the better outcome (full-semantics final 998).

### August 5, 2024 crash — a flash crash that still wasn't "EXIT-shaped"
Peak $3,470 on 24 Jul; trough $2,228 at the 5 Aug 13:00 close (−35.8%). First
TRIM 9 h after the peak ($3,363) and a continuous 16-hour TRIM run through
the crash night (4 Aug 16:00 → 5 Aug 07:00, $2,827 → $2,268). Max window
drawdown 16.7% — the fastest real crash in the set still doesn't reach the
EXIT band at hourly resolution, because the fall was spread over ~36 hours
with violent but partial hourly bounces resetting the 9-hour window peak.

### September 2023 chop — discipline, with a small leak
Range-bound month (max running-peak drawdown 7.0%). 713 of 719 windows HOLD.
All 6 TRIM windows sit at the month's two lows (11 Sep, $1,539–1,559, window
drawdown 3.5%; 21 Sep, $1,576) — i.e., the model only "protected" at the exact
bottoms, then watched the recovery from a reduced position. Cost: −3.5% to
−6.8% vs buy-and-hold depending on semantics. No EXITs, correctly.

### February 2024 uptrend — the tax on being wrong-footed
ETH +48% over the episode (max drawdown 5.4%). 8 TRIM windows in 3 clusters:
21 Feb ($2,900, a mid-rally pullback) and twice on 29 Feb near the top
($3,340–3,385). Under full semantics those three clusters compound to a
−12.4% lag vs buy-and-hold (1,297 vs 1,480) — the single worst relative
result in the set, and the honest price of the ratchet.

## Caveats

- **No ground truth exists on real data.** Nothing here is an "accuracy".
  Decisions are judged behaviourally (drawdown avoided, false-fire cost,
  timing vs peak/trough) and against the training ladder for reference.
- **Cadence is a free parameter we fixed at 1 h.** At a faster push cadence
  the 9-price window spans less time and window drawdowns shrink further
  (EXIT even rarer); at 4 h/daily pushes they grow. Any production claim
  about EXIT must name its cadence. The on-chain demo's push cadence was
  scenario-driven, not market-driven.
- **Hourly closes hide intra-hour violence.** On 19 May 2021 ETH wicked to
  ~$1,850 intraday; the 13:00 close was $2,365. A live oracle pushing
  intra-hour prices would show the model a different (worse) tape.
- **Simulations are decision valuations, not trading results:** execution at
  the decision close, no slippage, no fees, no lREACT callback cost, no
  re-entry after EXIT (the deployed vault stays closed until manually
  re-opened), position is the project's mock counter.
- **Survivorship of episodes:** the five episodes were chosen *because* they
  are canonical crashes/chop/uptrend. They are the cases a stop-loss is for,
  but they are not a random sample of market time.
- The ladder comparison reuses the training label thresholds on the same
  window features; the training set's recovery carve-out (post-trough HOLD)
  cannot be applied without future knowledge, so ladder agreement is an
  upper bound on "the model did what it was taught".

## Reproduction

Data: `GET data-api.binance.vision/api/v3/klines?symbol=ETHUSDT&interval=1h`
for the episode ranges above. Replay: import `tools/train.py`, parse
`src/model/SentinelWeights.sol` with `parse_weights_sol`, slide
`prices[max(0, t-8):t+1]` for `t >= 2`, compute `features_from_window`, decide
with `forward_int`. Simulations and metrics are deterministic functions of the
resulting decision trace, which is reproduced in the appendix.

---
## Appendix — decision traces

Every non-HOLD run of consecutive hourly decisions (UTC, decision at candle
close; prices are the closes at the run's first and last window). All windows
not listed are HOLD.

### May 2021 (8 May – 24 May shown; tail summarized)

| Window (UTC) | Decision | Closes |
|---|---|---|
| 9 May 13:00 | TRIM ×1h | $3,748 |
| 10 May 21:00 | TRIM ×1h | $3,903 |
| 11 May 00:00–04:00 | TRIM ×5h | $3,946 → $3,856 |
| 11 May 06:00 | TRIM ×1h | $3,877 |
| 12 May 16:00–22:00 | TRIM ×7h | $4,189 → $4,125 |
| 13 May 00:00–01:00 | TRIM ×2h | $3,823 → $3,896 |
| 13 May 04:00–05:00 | TRIM ×2h | $3,941 → $3,902 |
| 13 May 09:00–12:00 | TRIM ×4h | $3,829 → $3,744 |
| 13 May 16:00–17:00 | TRIM ×2h | $3,747 → $3,693 |
| 13 May 19:00–20:00 | TRIM ×2h | $3,586 → $3,652 |
| 13 May 23:00 | TRIM ×1h | $3,661 |
| 15 May 07:00–11:00 | TRIM ×5h | $3,962 → $3,844 |
| 15 May 14:00 | TRIM ×1h | $3,889 |
| 15 May 17:00–20:00 | TRIM ×4h | $3,772 → $3,751 |
| 15 May 23:00 – 16 May 00:00 | TRIM ×2h | $3,767 → $3,647 |
| 16 May 13:00 | TRIM ×1h | $3,708 |
| 16 May 15:00–22:00 | TRIM ×8h | $3,677 → $3,477 |
| 17 May 02:00–04:00 | TRIM ×3h | $3,417 → $3,240 |
| 17 May 06:00–07:00 | TRIM ×2h | $3,339 → $3,400 |
| 17 May 16:00–18:00 | TRIM ×3h | $3,285 → $3,202 |
| 17 May 22:00–23:00 | TRIM ×2h | $3,262 → $3,226 |
| 18 May 13:00–16:00 | TRIM ×4h | $3,415 → $3,346 |
| 18 May 19:00 | TRIM ×1h | $3,363 |
| 19 May 02:00–12:00 | TRIM ×11h | $3,188 → $2,721 |
| **19 May 13:00** | **EXIT ×1h** | **$2,365** |
| 19 May 19:00 | TRIM ×1h | $2,604 |
| 20 May 00:00 | TRIM ×1h | $2,439 |
| **20 May 01:00** | **EXIT ×1h** | **$2,231** |
| 20 May 21:00 | TRIM ×1h | $2,759 |
| 21 May 00:00 | TRIM ×1h | $2,769 |
| 21 May 06:00–11:00 | TRIM ×6h | $2,752 → $2,691 |
| 21 May 13:00 | TRIM ×1h | $2,650 |
| 21 May 15:00–21:00 | TRIM ×7h | $2,520 → $2,248 |
| 21 May 23:00 | TRIM ×1h | $2,380 |
| 22 May 06:00–08:00 | TRIM ×3h | $2,233 → $2,249 |
| 22 May 18:00–20:00 | TRIM ×3h | $2,286 → $2,255 |
| 23 May 06:00–17:00 | TRIM ×12h | $2,232 → $1,848 |
| 23 May 19:00 | TRIM ×1h | $1,897 |

Tail (25 May – 2 Jun): 16 further TRIM clusters totalling 52 windows, no
EXITs, as the model kept de-risking the failed recovery between $2,200 and
$2,750. Totals for the episode: 432 HOLD / 165 TRIM / 2 EXIT of 599 windows.

### June 2022

| Window (UTC) | Decision | Closes |
|---|---|---|
| 6 Jun 17:00–18:00 | TRIM ×2h | $1,859 → $1,857 |
| 7 Jun 01:00–08:00 | TRIM ×8h | $1,759 → $1,763 |
| 8 Jun 04:00 | TRIM ×1h | $1,780 |
| 10 Jun 13:00–14:00 | TRIM ×2h | $1,729 |
| 10 Jun 16:00–21:00 | TRIM ×6h | $1,727 → $1,679 |
| 10 Jun 23:00 – 11 Jun 00:00 | TRIM ×2h | $1,675 → $1,663 |
| 11 Jun 09:00–16:00 | TRIM ×8h | $1,578 → $1,518 |
| 11 Jun 18:00 | TRIM ×1h | $1,534 |
| 12 Jun 03:00–09:00 | TRIM ×7h | $1,453 → $1,471 |
| 12 Jun 23:00 – 13 Jun 15:00 | TRIM ×17h | $1,456 → $1,193 |
| 14 Jun 01:00–03:00 | TRIM ×3h | $1,173 → $1,120 |
| 14 Jun 05:00 | TRIM ×1h | $1,157 |
| 14 Jun 22:00–23:00 | TRIM ×2h | $1,169 → $1,177 |
| 15 Jun 04:00–11:00 | TRIM ×8h | $1,173 → $1,065 |
| 16 Jun 06:00–16:00 | TRIM ×11h | $1,183 → $1,114 |
| 16 Jun 23:00 – 17 Jun 01:00 | TRIM ×3h | $1,067 → $1,066 |
| 18 Jun 07:00–14:00 | TRIM ×8h | $1,020 → $1,000 |
| 18 Jun 18:00–22:00 | TRIM ×5h | $963 → $943 |
| 19 Jun 07:00–08:00 | TRIM ×2h | $955 → $956 |
| 20 Jun 03:00–08:00 | TRIM ×6h | $1,075 → $1,080 |
| 20 Jun 18:00–20:00 | TRIM ×3h | $1,097 → $1,106 |
| 21 Jun 20:00 – 22 Jun 04:00 | TRIM ×9h | $1,124 → $1,089 |
| 22 Jun 06:00–09:00 | TRIM ×4h | $1,093 → $1,081 |
| 22 Jun 21:00–23:00 | TRIM ×3h | $1,049 → $1,062 |
| 25 Jun 16:00 | TRIM ×1h | $1,184 |
| 26 Jun 20:00 | TRIM ×1h | $1,226 |
| 27 Jun 00:00 | TRIM ×1h | $1,198 |

Totals: 378 HOLD / 125 TRIM / 0 EXIT of 503 windows.

### August 2024

| Window (UTC) | Decision | Closes |
|---|---|---|
| 24 Jul 20:00 | TRIM ×1h | $3,363 |
| 24 Jul 22:00–23:00 | TRIM ×2h | $3,336 → $3,329 |
| 25 Jul 02:00–09:00 | TRIM ×8h | $3,215 → $3,177 |
| 29 Jul 17:00 | TRIM ×1h | $3,271 |
| 31 Jul 21:00 | TRIM ×1h | $3,222 |
| 1 Aug 02:00–03:00 | TRIM ×2h | $3,212 → $3,198 |
| 1 Aug 19:00 | TRIM ×1h | $3,092 |
| 2 Aug 15:00–22:00 | TRIM ×8h | $3,038 → $3,004 |
| 3 Aug 18:00–21:00 | TRIM ×4h | $2,903 → $2,894 |
| 4 Aug 16:00 – 5 Aug 07:00 | TRIM ×16h | $2,827 → $2,268 |
| 5 Aug 09:00 | TRIM ×1h | $2,325 |
| 5 Aug 13:00 | TRIM ×1h | $2,228 |
| 6 Aug 09:00 | TRIM ×1h | $2,461 |
| 7 Aug 15:00–22:00 | TRIM ×8h | $2,390 → $2,360 |
| 9 Aug 15:00–16:00 | TRIM ×2h | $2,592 → $2,558 |
| 11 Aug 21:00 | TRIM ×1h | $2,557 |
| 12 Aug 01:00–03:00 | TRIM ×3h | $2,537 → $2,551 |
| 13 Aug 10:00 | TRIM ×1h | $2,642 |
| 14 Aug 14:00–15:00 | TRIM ×2h | $2,659 → $2,654 |

Totals: 463 HOLD / 64 TRIM / 0 EXIT of 527 windows.

### September 2023 (chop) and February 2024 (uptrend) — all false fires

| Window (UTC) | Decision | Closes |
|---|---|---|
| 11 Sep 2023 15:00–17:00 | TRIM ×3h | $1,559 → $1,558 |
| 11 Sep 2023 20:00–21:00 | TRIM ×2h | $1,539 → $1,542 |
| 21 Sep 2023 14:00 | TRIM ×1h | $1,576 |
| 21 Feb 2024 10:00–12:00 | TRIM ×3h | $2,900 → $2,899 |
| 29 Feb 2024 18:00–19:00 | TRIM ×2h | $3,385 → $3,370 |
| 29 Feb 2024 22:00 – 1 Mar 00:00 | TRIM ×3h | $3,348 → $3,340 |

Totals: Sep 2023 — 713 HOLD / 6 TRIM / 0 EXIT of 719 windows;
Feb 2024 — 687 HOLD / 8 TRIM / 0 EXIT of 695 windows.
