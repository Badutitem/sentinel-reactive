# Trio #5 candidate — the re-risk (re-entry) release

**DEPLOYED 2026-11-19** — trio #5 (variant B, per the addendum at
the bottom of this document) is live on Lasna + Base Sepolia, all
contracts Sourcify exact_match, with a full live rehearsal and a
Chainlink ingestion window. Deployment record: [TRIO5.md](TRIO5.md).
The "not deployed" statements in the body below are the design-time
record and are superseded by TRIO5.md.

Status at design time: built and fully tested locally on 2026-11-19.
**Nothing in this document was deployed at the time of writing.**
Trios #1–#4 were the live system; this was the candidate fifth
trio, closing the one structural gap the trio #4 system had against
two-way rivals (Guardian Vault): after a de-risk, Sentinel could
never get back in. Trio #5 adds the way back in.

New contracts (copy-forward style; the deployed-version files are
untouched):

| Contract | Based on | What changes |
|---|---|---|
| `src/SentinelSwapV2.sol` | `SentinelSwap` | Adds `swapSafeForRisk` — the reverse direction at the same reference price |
| `src/SentinelVaultV3.sol` | `SentinelVaultV2` | Adds `ACTION_RERISK = 3`; constructor grants the desk max allowances on BOTH assets |
| `src/SentinelReactiveV4.sol` | `SentinelReactiveV3` | Adds the re-risk episode machine; dedup, TRIM suppression and the shipped v2 model weights are bit-identical |

## The trigger rule

Re-risk is **rule-based, not model-based**. The neural model, its
weights and its features are untouched; the trigger watches the same
price stream the model pipeline already ingests.

- **Episode open.** When a TRIM or EXIT callback *fires* (not merely
  votes), a de-risk episode opens: `episodeAnchor` = the anchor price
  in effect at that moment, `episodeStartUpdate` = the update count,
  `episodeActive = true`, `reriskUsed = false`. A later fired TRIM/EXIT
  refreshes the episode — the freshest de-risk is the one whose
  recovery is measured.
- **Reclaim (fire).** On each subsequent update while an episode is
  active and unused: if **at least 3 updates** have passed since the
  de-risk AND the **current price ≥ 97% of `episodeAnchor`**, exactly
  ONE re-risk callback is requested — `executeProtection(address(0), 3)`,
  the same callback ABI as actions 1/2. The episode closes
  (`reriskUsed = true`, `episodeActive = false`).
- **Cancel.** If a new anchor high forms above `episodeAnchor` first
  (the running leaky peak exceeds it — only possible when a price
  prints above the episode anchor), the episode cancels silently, with
  an `EpisodeCancelled` event and no callback. Rationale: the market
  fully recovered on its own terms; the position's remaining risk
  (post-TRIM) is already riding the new high, and buying back *above*
  the anchor the de-risk was measured against is not the trade the
  episode was opened for. The cancel check runs before the reclaim
  check, so a print above the anchor cancels even though it also
  satisfies the 97% reclaim.
- **After a re-risk**, normal protection continues unchanged; a later
  fired TRIM/EXIT opens a fresh episode with its own single re-risk.
- The re-risk callback is **not** subject to the timestamp cooldown
  (it is bounded by construction: one per episode, and episodes open
  only on de-risk fires, which are themselves cooldown- and
  suppression-gated) and does **not** touch the protection fired-state.

## The vault side

On action 3, `SentinelVaultV3` spends its **entire** safe balance
through `SentinelSwapV2.swapSafeForRisk`, which pulls the safe asset
via `transferFrom` (the vault's constructor-granted max safe
allowance) and pays risk out of the desk's own risk inventory — the
inventory the desk accumulated from earlier TRIM/EXIT fills. If risk
actually changes hands: `closed = false`, `reriskCount++`,
`ReRisked(safeSpent, riskBought)`. The desk mirrors the forward swap's
safety contract in reverse: **never reverts** on short inventory
(partial fill, spending only the covered part of the safe balance,
`RiskShortfall` event), and with no reference price (price == 0) it
moves nothing and returns 0 — in which case the vault's counters,
`closed` flag and balances are all left untouched.

## State machine (reactive side)

```
                 TRIM/EXIT callback fires
   (no episode) ─────────────────────────► EPISODE OPEN
        ▲                                   (anchor, startUpdate)
        │                                        │
        │              price print pushes        │  >= 3 updates passed
        │              anchorPeak >              │  AND price >= 97% of
        │              episodeAnchor             │  episodeAnchor
        │                                        ▼
        └────────────── CANCELLED            RE-RISK FIRES (action 3)
             (silent, event only)            episode closes, reriskCount++
```

## Test results

Measured on the Python mirror of the V4 firing semantics
(`tools/train.py` `forward_int_v2` over the shipped v2 weights plus a
mirror of the episode machine) before any number was pinned.

- Before: **93/93 tests, 14 suites** (the trio #4 state).
- After: **120/120 tests, 19 suites** — all 93 pre-existing tests pass
  unmodified; 27 new tests:

| Suite | Tests | Covers |
|---|---|---|
| `SentinelSwapV2Test` | 9 | Forward carry-over; reverse full fill; partial fill on low inventory; empty-inventory no-op; price-0 no-op; zero amount; onlyVault both directions; 6-decimal safe normalisation; exact same-price round trip |
| `SentinelVaultV3Test` | 9 | TRIM/EXIT unchanged; re-risk after EXIT at a changed price (exact desk math); re-risk after TRIM; partial fill on short desk inventory; no-safe-balance no-op; zero-price leaves closed position untouched; protection works again after re-risk; both callback guards |
| `SentinelReactiveV4Test` | 7 | Crash-path parity + episode opens; dedup intact and cannot advance an episode; (a) reclaim fires exactly one action-3; (b) 90% recovery never fires; (c) instant reclaim waits out the 3-update minimum (fires at the 3rd update); (d) no second fire in the same episode; (e) new anchor high cancels |
| `SentinelReactiveV4EndToEndTest` | 1 | Full cycle below |
| `SentinelAdversarialV4Test` | 1 | Square wave bound below |

**Square wave (adversarial).** Three full cycles of *crash to EXIT →
reclaim to 98 → crash again*. The machine's bound is structural — one
re-risk per episode, and an episode must be re-opened by a fresh fired
de-risk — so N cycles can produce at most N re-risks. Measured:
**exactly 3 re-risks** (at updates 10, 20, 30) inside 11 total
callbacks (TRIM, EXIT, then RERISK/EXIT/EXIT per cycle). The wave
saturates the bound exactly and never breaks it: no double-fires, no
skipped reclaims, no re-risk without a preceding fired EXIT.

**End-to-end** (10 WETH position, staged deliveries, each fill priced
at its stage's oracle print):

| Stage | Action | Price | Vault after |
|---|---|---|---|
| 1 | TRIM (sells 5 WETH) | $92 | 5 WETH + 460 USDC |
| 2 | EXIT (sells 5 WETH) | $81 | 0 WETH + **865 USDC**, closed |
| 3 | RERISK (spends all 865) | $98 | **8.826530612244897959 WETH** + 0 USDC, open |
| 4 | EXIT (sells all) | $74 | 0 WETH + **653.163265306122448966 USDC**, closed |

## Honest limits

- **Re-risk buys strength, not the dip — and that costs money when the
  recovery fails.** The reclaim only fires at ≥ 97% of the episode
  anchor, so by construction the re-entry price is *higher* than the
  price the position exited at whenever the exit happened deep. In the
  end-to-end above: the vault exited at a blended **$86.50**/WETH
  (460 @ $92 + 405 @ $81) and bought back at **$98** — 21.0% above the
  last exit fill, 13.3% above the blended exit — recovering
  **8.8265 of the original 10 WETH (88.3%)**. The recovery then failed:
  the second EXIT at $74 left **653.16 USDC**, versus the **865 USDC**
  the vault would still hold had it simply stayed out — the re-risk
  round trip cost **211.84 USDC (−24.5%)** on this path. The feature
  only pays when the reclaim is real and price keeps rising after
  re-entry; on a failed V it is strictly worse than staying out. That
  is the deliberate trade: Sentinel re-enters on *confirmed* recovery,
  never on a falling knife.
- **Fixed-price desk, both ways.** Both swap directions price off the
  same reference print with no slippage, spread or liquidity model —
  the standing testnet-desk caveat, now in both directions. A real DEX
  path would fill worse on both legs.
- **All-in re-entry.** A re-risk spends the *entire* safe balance;
  there is no partial re-entry sizing. After a TRIM, the "safe balance"
  is only the trimmed half's proceeds, so the buyback is bounded by
  what the de-risk produced.
- **Desk inventory caps the buyback.** The reverse fill is limited to
  the risk the desk actually holds; a desk that was drained by other
  fills partially fills the re-risk and the unspent safe stays in the
  vault (pinned by test, with the shortfall event).
- **One re-risk per episode.** A second dip after a successful re-risk
  is handled by protection (TRIM/EXIT fire as usual), but a new
  buyback budget only exists once that new de-risk has fired and its
  own episode reclaims.
- **Cancel is final for the episode.** A single print above the
  episode anchor — even before the 3-update minimum — cancels the
  episode; if price later settles back into the band, no re-risk
  fires until a fresh de-risk opens a new episode.
- **Same-update interaction.** If a reclaim and a fresh protection
  vote land on the same update, the re-risk is requested first and
  the protection fire then opens a new episode; delivered in order,
  the vault buys back and immediately de-risks again. Bounded and
  coherent, but it spends two callbacks on one print.
- **The model's blind window is unchanged.** Trio #5 does not touch
  the model, so the documented post-recovery blind window (TRIO4.md)
  carries over verbatim — stage 4 of the end-to-end shows it live:
  HOLD at $90 and $80 before the EXIT engages at $74.
- **Not deployed.** No Sourcify records, no live loop, no fuel claims
  exist for trio #5. Deployment, rehearsal and verification are a
  separate, explicitly-approved step.

---

## Addendum (2026-11-19) — variant B (scale-in) installed; supersedes the V1 rule above

The document above describes the trio #5 candidate as originally
built, with the single-shot V1 trigger (100% buyback at the 97%
reclaim). The re-risk variant evaluation (RERISK-VARIANTS.md) then
ran the pre-registered 10-scenario matrix — five synthetic streams
plus the five restored real episodes — and **variant B, scale-in,
won**: mean delta vs no-rerisk −40.41 across all 10 scenarios, best
of the five triggers, against V1's −103.57. The plain caveat from
that verdict applies to everything below: **every variant, B
included, is negative on average against never re-risking** — B is
the least-cost way to own the two-way capability, not a profitable
rule on this evidence. It paid in the real recoveries (sep2023
+25.43, feb2024 +89.56) and cost in the real crashes (may2021
−145.91, jun2022 −74.07, aug2024 −93.89 — repeated dead-cat
reclaims). B is what trio #5 now ships; V1's contracts remain in the
tree untouched as the evaluated-and-replaced candidate.

New contracts (copy-forward; the V1 files above are unmodified):

| Contract | Based on | What changes |
|---|---|---|
| `src/SentinelReactiveV5.sol` | `SentinelReactiveV4` | The episode machine becomes variant B (below); dedup, TRIM suppression and the shipped v2 model weights are bit-identical |
| `src/SentinelVaultV4.sol` | `SentinelVaultV3` | Action 3 becomes tranche 1 (spends HALF the safe balance); new action 4 is tranche 2 (spends the entire remainder); actions 1/2 byte-identical in behaviour |
| `src/SentinelSwapV2.sol` | — | Unchanged — the two-way desk already served both spends |

### The B trigger, as shipped

- **Episode open** — unchanged from V1: a fired TRIM/EXIT opens the
  episode (`episodeAnchor`, `episodeStartUpdate`), and a fresher
  fired de-risk refreshes it — now also resetting both tranche flags.
- **Tranche 1 (action 3, half spend).** On each subsequent update
  while the episode is open and tranche 1 has not fired: once **at
  least 3 updates** have passed AND the **current price ≥ 97% of
  `episodeAnchor`**, the tranche-1 callback is requested. The episode
  **stays open** (V1 closed it here).
- **Tranche 2 (action 4, spend the rest).** Once tranche 1 has
  fired, when the **running anchor exceeds `episodeAnchor`** — the
  leaky peak sets a new high above the level the de-risk was
  measured against — the tranche-2 callback is requested and the
  episode closes. There is no cancel after tranche 1; the episode
  ends by firing tranche 2 or by being refreshed by a fresh de-risk.
- **Cancel (pre-tranche-1 only), with B's ordering.** The reclaim
  check runs **before** the cancel check: a print above the anchor
  also satisfies the 97% reclaim, so once the 3-update minimum has
  passed, such a print fires tranche 1 instead of cancelling. Only a
  runaway high that arrives *before* the minimum (or while price
  sits below the band) still cancels the episode silently. This is
  the ordering that captured succ_V in the evaluation: V1 cancelled
  at the 103 print (update 17) and never re-entered; B fired tranche
  1 on that print and tranche 2 on the next new high (update 18).
- The tranche callbacks are, like V1's re-risk, **not** subject to
  the timestamp cooldown (bounded by construction: at most two per
  episode) and do not touch the protection fired-state.
- The contract mirrors `tools/rerisk_variants.py` variant B
  bit-for-bit; where any document and the mirror disagree, the
  mirror is law.

### Vault side

On action 3, `SentinelVaultV4` spends **half** its current safe
balance (`safeBal / 2`, floor) through the unchanged
`SentinelSwapV2.swapSafeForRisk`; on action 4 it spends the **entire
remaining** safe balance. Each tranche that actually moves risk
clears `closed`, increments `reriskCount` and emits
`ReRisked(safeSpent, riskBought)` with the desk-exact filled amount;
a tranche that buys nothing (empty safe balance, zero reference
price, empty desk inventory) leaves counters, flags and balances
untouched, exactly as V3 pinned.

### Test results (B installation)

- Before: **120/120 tests, 19 suites** (the V1 trio #5 candidate).
- After: **144/144 tests, 23 suites** — all 120 pre-existing tests
  pass unmodified; 24 new tests, every expectation measured on the
  evaluation mirror (variant B) before being pinned:

| Suite | Tests | Covers |
|---|---|---|
| `SentinelVaultV4Test` | 11 | TRIM/EXIT unchanged; tranche 1 spends exactly half after EXIT and after TRIM; tranche 2 spends the rest (both tranches together restore V1's 8 WETH at the pinned prices); tranche-final standalone spends everything; tranche-1 partial fill on short desk inventory; no-safe-balance and zero-price no-ops for both tranches; protection works again after both tranches; both callback guards on both tranche actions |
| `SentinelReactiveV5Test` | 11 | Crash-path parity + episode opens; dedup intact; (a) tranche 1 on the reclaim, episode stays open; tranche 2 on the new anchor high; (b) 90% recovery fires neither tranche; (c) instant reclaim waits out the minimum, flat prints never fire tranche 2; (d) no double-fire, no tranche 2 without a new high; (e) pre-minimum anchor high still cancels; (f) above-anchor print after the minimum fires tranche 1, not cancel; the full succ_V stream (tranches at updates 17/18, no cancel); (g) EXIT after a completed re-risk opens a fresh episode whose tranche 1 fires at update 24 |
| `SentinelReactiveV5EndToEndTest` | 1 | Full two-episode cycle below |
| `SentinelAdversarialV5Test` | 1 | Square wave bound below |

**Square wave (adversarial), tranches counted honestly.** The same
three-cycle wave as the V1 suite. Its reclaim legs top out at 98 —
inside the band, never above a cycle's episode anchor — so tranche
2's condition never occurs on this stream: measured **3 re-risk
events, all tranche 1** (updates 10, 20, 30), **0 tranche 2**, inside
the same 11 total callbacks V1 produced. The structural bound
carries over (at most one tranche 1 per episode; episodes open only
on fired de-risks) and the wave saturates it exactly.

**End-to-end** (10 WETH position, staged deliveries, each fill
priced at its stage's oracle print; mirror-measured, desk-exact):

| Stage | Action | Price | Vault after |
|---|---|---|---|
| 1 | TRIM (sells 5 WETH) | $92 | 5 WETH + 460 USDC |
| 2 | EXIT (sells 5 WETH) | $81 | 0 WETH + **865 USDC**, closed |
| 3 | TRANCHE 1 (spends 432.5) | $98 | **4.413265306122448979 WETH** + 432.5 USDC, open |
| 4 | TRANCHE 2 (spends 432.5) | $101 | **8.695443523944231157 WETH** + 0 USDC, open |
| 5 | EXIT (sells all) | $62 | 0 WETH + **539.117498484542331734 USDC**, closed |
| 6 | EXIT again (counted no-op; refreshes the episode) | $58 | unchanged |
| 7 | TRANCHE 1 of the new episode (spends 269.558749242271165867) | $99 | **2.722815648911829958 WETH** + 269.558749242271165867 USDC, open |

Against V1's end-to-end: the same 865 USDC of proceeds is fully
back in by stage 4 (8.6954 WETH restored vs V1's 8.8265 — slightly
less, because tranche 2 paid the higher $101 confirmation price),
but only half of it was exposed at the $98 reclaim; had the recovery
failed after stage 3, the unspent 432.5 USDC would still have been
in the vault. That halved first mistake is the entire point of the
variant, and the evaluation's failure scenarios price it: fail_V
cost B −133.13 against V1's −266.26; the square wave −280.43
against −492.58.

### Honest limits (B-specific deltas to the list above)

- **"All-in re-entry" no longer applies** — scale-in replaces it:
  half at the reclaim, half only on a new anchor high. The flip side
  is a new exposure: if the price reclaims, tranche 1 fires, and the
  recovery then rolls over *without* ever printing a new anchor
  high, the vault sits half-in through the next decline until
  protection acts — the state the square wave parks in every cycle.
- **"Cancel is final" is now pre-tranche-1 only.** After tranche 1
  there is no cancel: a slow bleed from inside the band leaves the
  episode open (and half the proceeds invested) until tranche 2, a
  fresh de-risk, or the position cycle's end resolves it.
- **Tranche 2 can fire on the update right after tranche 1.** The
  tranche-2 condition is the running (leaky) anchor exceeding the
  episode anchor; when tranche 1 fired on an above-anchor print,
  the anchor is already above it and tranche 2 follows on the next
  update. The two tranches are then effectively one buyback split
  across two prints — measured behaviour (succ_V: updates 17/18),
  not an accident.
- Everything else in the honest-limits list above — fixed-price
  desk both ways, desk inventory caps, one re-risk budget per
  episode, the same-update interaction, the model's unchanged blind
  window, **not deployed** — carries over verbatim.
