# Re-risk variants — evaluation record (COMPLETE: verdict in the final section)

Status as of 2026-11-19: the evaluation harness is built and its mirror
is validated bit-for-bit; the **synthetic half of the evaluation is
complete**; the **real-episode half could not run** in the first pass
because the repo's kline caches were gone (see "Blocker" below) and
that pass ran under a no-network constraint. Under the pre-registered
winner rule — which requires real + synthetic scenarios at equal
weight — **no winner was crowned in that pass. V1 (the shipped trio #5
candidate rule) stood.** The synthetic numbers below are reported in
full because they are real measurements, but they are explicitly NOT
the verdict: the synthetic set is adversarially weighted (three of its
five scenarios are failure/chop environments), and the five real
episodes are the missing counterweight.

**Update, later the same day:** the five kline caches were restored
(`tools/data/klines_*.json`, now committed to this repo), the full
10-scenario matrix was run, and the pre-registered rule was applied.
**Variant B (scale-in) won and has been installed** as
`SentinelReactiveV5` / `SentinelVaultV4`. The complete real-episode
table and the verdict computation are in the "Final verdict" section
at the end of this document; the installed design is documented in
TRIO5-DESIGN.md's addendum. Everything above the final section is the
first-pass record, kept verbatim.

## The variants

All variants share the shipped V4 machine — v2 model, anchor, TRIM
suppression, cooldown/escalation, desk math — and differ ONLY in the
episode trigger:

| Variant | Trigger (all require >= 3 updates since the de-risk) | Spend |
|---|---|---|
| OFF | re-risk disabled (baseline) | — |
| V1 (shipped) | price >= 97% of episode anchor | 100% |
| B scale-in | tranche 1 at >= 97% of episode anchor; tranche 2 when the running anchor sets a new high above the episode anchor | 50% / rest |
| C exit-price | price >= the last de-risk's fill price | 100% |
| D momentum | V1 reclaim AND model feature 4 (window momentum) > 0 on 2 consecutive inference updates | 100% |
| E differentiated | TRIM episodes: >= 95% of anchor; EXIT episodes: >= 99% of anchor | 100% |

Design decisions where the variant spec left room (applied identically
in the mirror and, if B ever wins, in its contract):

- **B's tranche interaction with the cancel rule.** V1 checks cancel
  (new anchor high) *before* reclaim, so a print above the anchor kills
  the episode. In B the reclaim check runs first once the 3-update
  minimum has passed — a print above the anchor satisfies >= 97%, so
  tranche 1 fires on it; tranche 2 then fires on the *next* new anchor
  high. A runaway high that arrives *before* the minimum still cancels
  (V1 behaviour). Tranche 2 has no cancel: the episode stays open until
  it fires or a fresh de-risk refreshes the episode.
- **C's reference price** is the price at which the episode-opening
  de-risk callback fired — which is exactly the desk fill price
  whenever the vault had anything to sell (callbacks are delivered at
  the firing print). A repeat EXIT on an already-closed vault fills
  nothing but still refreshes the episode and its reference price,
  exactly as the shipped contract refreshes `episodeAnchor`.
- **D's streak** counts consecutive inference updates (updates >= 3)
  with feature 4 > 0 across the whole stream, evaluated at the firing
  update — the natural on-chain implementation (a stored streak updated
  after every inference).

## Harness and mirror validation

`tools/rerisk_variants.py` mirrors the full stack: `forward_int_v2`
over the parsed shipped weights (tools/train.py), the V4 anchor /
suppression / cooldown / episode semantics, and SentinelSwapV2 /
SentinelVaultV3 integer math at 18/18 decimals. Before any scenario
ran, the mirror had to reproduce, bit-for-bit:

- the bleed stream's TRIM@6 / EXIT@7 and episode anchor 9_999_850_397;
- the crash-parity stream's third EXIT@8 and anchor 9_989_850_546;
- scenario (a) RERISK@11, (b) no-fire, (c) grind TRIM@8 with anchor
  9_930_209_650 and RERISK@11, (e) cancel@8 — all from
  SentinelReactiveV4.t.sol;
- the end-to-end suite's desk-exact balances (460 / 865 USDC stages,
  8_826_530_612_244_897_959 wei after the buyback,
  653_163_265_306_122_448_966 wei final) from
  SentinelReactiveV4EndToEnd.t.sol;
- the adversarial square wave's exact 11-callback sequence
  (TRIM, EXIT, then RERISK/EXIT/EXIT x3).

**Result: ALL PASS.** Conventions: hourly streams (3600 s; the 300 s
cooldown never binds), callbacks delivered at the firing print, $1,000
starting position, desk seeded 1,000,000 USDC / 0 risk as in the
end-to-end setup.

## Synthetic results (complete; every cell reported)

Final equity in USD; delta vs the OFF (no-rerisk) run of the same
scenario; re-risk callbacks fired; % of the original position held
after the first episode's buyback(s).

### succ_V — drop to 68, recover through the band, end at 132 (B&H $1,320.00)
| variant | final | delta vs OFF | re-risks | recovered |
|---|---|---|---|---|
| OFF | 880.00 | — | 0 | — |
| V1 | 880.00 | +0.00 | 0 | — |
| B | 1,091.88 | +211.88 | 2 | 82.7% |
| C | 1,370.00 | +490.00 | 1 | 100.0% |
| D | 880.00 | +0.00 | 0 | — |
| E | 880.00 | +0.00 | 0 | — |

The shipped rule's known sharp edge, measured: the recovery printed 96
at update 16 — 0.6% below the 97% band of the refreshed episode anchor
(99.60) — and 103 at update 17, which pushed the anchor above the
episode anchor and **cancelled** the episode before any reclaim could
fire (cancel runs before reclaim in V1, and D/E inherit that order).
B's reclaim-first order fired tranche 1 on the 103 print and tranche 2
on the next new high; C had already fired at update 14 (price 83 >= the
$68 trough fill) and rode the whole recovery.

### fail_V — drop, reclaim above every trigger, second EXIT, end at 60 (B&H $600.00)
| variant | final | delta vs OFF | re-risks | recovered |
|---|---|---|---|---|
| OFF | 880.00 | — | 0 | — |
| V1 | 613.74 | −266.26 | 1 | 90.3% |
| B | 746.87 | −133.13 | 1 | 45.1% |
| C | 710.00 | −170.00 | 1 | 100.0% |
| D | 613.74 | −266.26 | 1 | 90.3% |
| E | 603.23 | −276.77 | 1 | 88.7% |

Every variant fired and every variant paid for it; B paid exactly half
of V1's cost (tranche 1 only — the recovery peaked at 99.2, below the
episode anchor, so tranche 2 never fired). E fired one update later
than V1 (99% threshold) at a worse price and lost slightly more.

### square_wave — the Foundry adversarial stream, 3 cycles (B&H $740.00)
| variant | final | delta vs OFF | re-risks | recovered |
|---|---|---|---|---|
| OFF | 865.00 | — | 0 | — |
| V1 | 372.42 | −492.58 | 3 | 88.3% |
| B | 584.57 | −280.43 | 3 | 44.1% |
| C | 372.42 | −492.58 | 3 | 88.3% |
| D | 493.20 | −371.80 | 2 | 88.3% |
| E | 653.16 | −211.84 | 1 | 88.3% |

C is indistinguishable from V1 here: its lower threshold is crossed on
the same prints (the 3-update minimum, not the price level, is the
binding constraint). E's 99% threshold fired in only one of three
cycles — the cheapest failure mode on this stream. D's momentum gate
blocked one of three buybacks.

### slow_grind — −0.8%/step x85, no reclaim ever (B&H $509.31)
All variants: final $899.82, delta +0.00, 0 re-risks. Protection alone
did the work (B&H lost ~49%); no trigger ever came close.

### chop_trigger — EXIT, then 30 prints chopping 96.6–98.9 (B&H $975.00)
| variant | final | delta vs OFF | re-risks | recovered |
|---|---|---|---|---|
| OFF | 865.00 | — | 0 | — |
| V1 | 857.96 | −7.04 | 1 | 88.0% |
| B | 861.48 | −3.52 | 1 | 44.0% |
| C | 870.36 | +5.36 | 1 | 89.3% |
| D | 857.09 | −7.91 | 1 | 87.9% |
| E | 865.00 | +0.00 | 0 | — |

E never fired: the chop peaked at 98.9, just under its 99% EXIT-episode
threshold (98.99 against this episode's anchor). Everything else is
within ±$8 of doing nothing.

### Synthetic aggregates (NOT the verdict — see Blocker)
Mean delta vs OFF over the 5 synthetic scenarios; worst failure cost =
max over {fail_V, square_wave} of (OFF final − variant final):

| variant | mean delta (synthetic only) | worst failure cost |
|---|---|---|
| V1 | −153.18 | 492.58 |
| B | −41.04 | 280.43 |
| C | −33.44 | 492.58 |
| D | −129.19 | 371.80 |
| E | −97.72 | 276.77 |

On synthetics alone every variant is net-negative against never
re-risking — three of the five scenarios are failure/chop environments
by construction, and the one clean success (succ_V) is where the
shipped rule's cancel-first order hurt it most. This is precisely the
bias the real episodes exist to counterweight; drawing a winner from
this half of the table would be cherry-picking by omission.

## Blocker: the real episodes are missing

The five real episodes live only as `/tmp/klines_<episode>.json`
(Binance ETHUSDT 1h closes x1e8; starts 2021-05-08, 2022-06-06,
2024-07-24, 2023-09-01, 2024-02-01 00:00 UTC; lengths 601 / 505 / 529 /
721 / 697 — ANCHOR.md Appendix C, BACKTEST.md). They were never
committed to this repo, `/tmp` did not survive, and this evaluation ran
under an explicit no-network constraint, so they were not refetched.

**To finish the evaluation exactly as pre-registered:** restore the
five cache files (same source as BACKTEST.md: `GET
data-api.binance.vision/api/v3/klines?symbol=ETHUSDT&interval=1h`,
closes x1e8 as integer JSON arrays at `/tmp/klines_<episode>.json`),
then re-run `python3 tools/rerisk_variants.py` — it picks the episodes
up automatically, prints the full 10-scenario matrix, and the winner
rule (mean delta vs OFF across all 10 scenarios, ties broken by worst
failed-V cost; winner must beat V1 on the mean) can then be applied
and the winner installed. Until then: no contract changes, test count
unchanged at **120/120**, and V1 remains the trio #5 candidate rule.

## Honest limits

- The synthetic streams are five hand-built paths, not a distribution;
  their aggregate is shown for completeness, not as an estimate of
  real-world expectancy.
- Repeat EXIT callbacks on an already-closed vault (a shipped V2
  behaviour) refresh episodes in the mirror exactly as on-chain; in
  grind-style drops the operative episode is the trough print's, which
  is why several thresholds above key off anchors/fills near the lows.
- Desk fills are fixed-price with no slippage or spread, both
  directions — the standing testnet-desk caveat applies to every
  number here.
- Callbacks are modelled as delivered at the firing print; a one-print
  delivery lag would worsen every variant's fills slightly and is not
  modelled.

## Final verdict (2026-11-19, full 10-scenario matrix)

The five kline caches were restored from the same source as
BACKTEST.md (Binance ETHUSDT 1h closes x1e8) and now live in this repo
at `tools/data/klines_<episode>.json` (lengths 601 / 505 / 529 / 721 /
697, as in ANCHOR.md Appendix C). `tools/rerisk_variants.py` was
re-run unchanged — mirror validation ALL PASS again — producing the
complete 10-scenario matrix. The synthetic half is in the sections
above; the real-episode half is here in full.

### Real episodes (complete; every cell reported)

Final equity in USD; delta vs the OFF (no-rerisk) run of the same
episode; re-risk callbacks fired; % of the original position held
after the first episode's buyback(s).

### may2021 — crash and dead-cat cascade (OFF $1,101.85 | B&H $733.84)
| variant | final | delta vs OFF | re-risks | recovered |
|---|---|---|---|---|
| V1 | 932.80 | −169.06 | 8 | 98.3% |
| B | 955.95 | −145.91 | 11 | 97.7% |
| C | 852.83 | −249.03 | 28 | 98.3% |
| D | 1,024.09 | −77.76 | 4 | 97.9% |
| E | 908.17 | −193.68 | 10 | 98.3% |

### jun2022 — crash, repeated dead-cat reclaims (OFF $948.05 | B&H $659.01)
| variant | final | delta vs OFF | re-risks | recovered |
|---|---|---|---|---|
| V1 | 838.03 | −110.01 | 5 | 97.6% |
| B | 873.98 | −74.07 | 6 | 73.8% |
| C | 897.50 | −50.54 | 15 | 99.9% |
| D | 866.49 | −81.55 | 3 | 97.6% |
| E | 817.93 | −130.12 | 7 | 98.7% |

### aug2024 — crash, repeated dead-cat reclaims (OFF $919.67 | B&H $769.59)
| variant | final | delta vs OFF | re-risks | recovered |
|---|---|---|---|---|
| V1 | 799.03 | −120.64 | 8 | 98.0% |
| B | 825.78 | −93.89 | 11 | 96.9% |
| C | 837.46 | −82.21 | 15 | 100.0% |
| D | 803.36 | −116.31 | 7 | 98.0% |
| E | 789.28 | −130.39 | 10 | 99.7% |

### sep2023 — quiet grind up, shallow dips (OFF $978.06 | B&H $1,012.82)
| variant | final | delta vs OFF | re-risks | recovered |
|---|---|---|---|---|
| V1 | 1,011.19 | +33.13 | 1 | 99.8% |
| B | 1,003.49 | +25.43 | 2 | 99.1% |
| C | 1,011.19 | +33.13 | 1 | 99.8% |
| D | 1,004.61 | +26.55 | 1 | 99.2% |
| E | 1,011.19 | +33.13 | 1 | 99.8% |

### feb2024 — sustained rally with dips (OFF $1,375.46 | B&H $1,479.57)
| variant | final | delta vs OFF | re-risks | recovered |
|---|---|---|---|---|
| V1 | 1,472.26 | +96.80 | 2 | 99.6% |
| B | 1,465.02 | +89.56 | 3 | 99.0% |
| C | 1,472.26 | +96.80 | 2 | 99.6% |
| D | 1,472.32 | +96.86 | 1 | 99.4% |
| E | 1,472.26 | +96.80 | 2 | 99.6% |

### The verdict computation

Pre-registered rule: mean delta vs OFF across all 10 scenarios (real
+ synthetic at equal weight); ties broken by worst failed-V cost over
{fail_V, square_wave}; the winner must beat V1 on the mean.

| variant | mean delta, synthetic (5) | mean delta, real (5) | **mean delta, all 10** | worst failure cost |
|---|---|---|---|---|
| V1 | −153.18 | −53.96 | −103.57 | 492.58 |
| **B** | −41.04 | −39.78 | **−40.41** | 280.43 |
| C | −33.44 | −50.37 | −41.91 | 492.58 |
| D | −129.19 | −30.44 | −79.82 | 371.80 |
| E | −97.72 | −64.85 | −81.29 | 276.77 |

**B wins the rule outright** — best mean over the 10 scenarios, and
the margin over C (−40.41 vs −41.91) is not a tie, so the tie-break
was never invoked. B also beats the incumbent V1 by 63.16 of mean
delta. Recorded for honesty, not as a re-litigation: on the real
episodes alone, D's mean (−30.44) is better than B's (−39.78) — D's
momentum gate is genuinely good at refusing dead cats — but the rule
was registered over all 10 scenarios before any of these numbers
existed, and under that rule B is the winner. Changing the rule after
seeing the table would be exactly the cherry-picking the
pre-registration existed to prevent.

### The plain statement

**Every variant — including the winner — is negative on average
against never re-risking across the 10 scenarios.** B is not a
profitable rule on this evidence; it is the *least-cost* one, and the
cheapest way to own the two-way capability. Where re-risk paid and
where it cost, for B specifically:

- **Paid:** sep2023 (+25.43) and feb2024 (+89.56) — the two real
  episodes whose recoveries were real: shallow dips in a continuing
  uptrend, where the reclaim bought strength that kept rising. The
  synthetic succ_V is the same shape (+211.88, the scenario B's
  reclaim-first ordering exists for).
- **Cost:** may2021 (−145.91), jun2022 (−74.07) and aug2024 (−93.89)
  — the three real crash episodes, all built from repeated dead-cat
  reclaims: the market bounced through the 97% band again and again
  (B fired 11, 6 and 11 re-risk callbacks across those episodes) and
  each buyback met another leg down. Scale-in halves the first
  mistake — tranche 2 only spends after a new anchor high, which a
  dead cat rarely prints — which is why B's crash costs are roughly
  half of V1's in the synthetic failure scenarios; it does not, and
  by construction cannot, refuse the reclaim itself.

B is installed with those numbers on the table: the feature exists
because a one-way stop-loss is structurally incomplete against
two-way rivals, and B is the measured-cheapest honest way to close
that gap — not because the backtest says re-risk makes money. On
crash paths it does not.

### Installation

B is installed copy-forward, V1's files untouched:
`src/SentinelReactiveV5.sol` (B episode machine; dedup, TRIM
suppression and the v2 weights bit-identical to V4) and
`src/SentinelVaultV4.sol` (action 3 = tranche 1, half spend; action 4
= tranche 2, spend the rest; actions 1/2 byte-identical in
behaviour). `SentinelSwapV2` needed no change. Full suite after
installation: **144/144 tests, 23 suites** (120 pre-existing + 24
new). The installed design, its end-to-end numbers and its
square-wave bound are documented in TRIO5-DESIGN.md's addendum.
Still LOCAL ONLY — not deployed.
