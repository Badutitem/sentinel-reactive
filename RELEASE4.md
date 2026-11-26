# Release 4 — the repair release (2026-11-19)

Release 4 ships the three weaknesses documented on 2026-11-19 (see
EVIDENCE.md §5/§7 as of the 73-test state) as a new contract set. Two
repairs are in the new reactive contract and are live. The third — a
retrained model v3 for the post-recovery blind window — was attempted
three times, failed its validation gates all three times, and was
**descoped**: Release 4 runs the shipped model v2 weights, and the blind
window remains an open, documented limitation (§3 below). Nothing in
Releases 1–3 was modified.

New reactive contract: `src/SentinelReactiveV3.sol` — the V2 body plus
repairs 1 and 3, importing `SentinelModelV2` unchanged. Vault and swap
are redeployed unchanged (`SentinelVaultV2`, `SentinelSwap`) so the new
release's rehearsal is clean. Test count: **93/93** (73 previous + 20 new).

## 1. Repair 1 — replay deduplication (SHIPPED)

**Weakness.** `SentinelReactiveV2.react()` ingested a redelivered log
as a fresh update: window and anchor advanced twice for one real price.
Only the timestamp cooldown prevented a double fire.

**Fix.** The reactive now records the identity of every processed
origin log — `keccak256(abi.encode(chainId, originContract, txHash,
logIndex))` from the `LogRecord` — in a `mapping(bytes32 => bool)`,
checked immediately after the topic0/chainId gates and marked *before*
any processing. A replay returns before the price window, the anchor,
the counters or any callback logic is touched. Public observability:
`duplicatesIgnored()` counter.

**Tests** (`test/SentinelReactiveV3.t.sol`, 6 dedup tests + re-pinned
adversarial case (c) in `test/SentinelAdversarialV3.t.sol`):

- the same log delivered 3× advances `updates` exactly once;
- a replay of the exact log that fired a TRIM cannot re-fire, advance
  the window or move the anchor — `duplicatesIgnored == 1`;
- the same tx hash at a different log index is a *different* log and
  is processed;
- a burst of 5 distinct logs interleaved with 5 replays yields exactly
  5 updates and 5 ignored duplicates, with the anchor equal to the
  no-replay run's anchor;
- the adversarial stale-feed suite re-pins case (c) from "ingested but
  cannot double-fire" (v2 behaviour) to "ignored entirely".

**Live note.** The Reactive Network delivers each log once, so the
dedup path cannot be force-tested on the live network: both Release 4
reactives read `duplicatesIgnored == 0` after their live runs, exactly
as expected. The proof of this repair is the unit suite.

## 2. Repair 3 — whipsaw hardening: TRIM suppression (SHIPPED)

**Weakness.** Model v2 votes TRIM on 9.3% of mild-sawtooth windows
(vote-level flap measured in EVIDENCE.md §7); firing was bounded only
by the timestamp cooldown.

**Fix (decision layer, in `SentinelReactiveV3`).** After a TRIM
callback fires at update *N*, TRIM votes are suppressed for the next
**10 updates** (`TRIM_SUPPRESS_UPDATES`): they emit `TrimSuppressed`
and cannot request a callback — **unless** EXIT conditions are met on
that same update (anchor drawdown `features[6] >= 180000`, i.e. ≥ 18%,
**and** negative momentum `features[4] < 0`), in which case the TRIM
fires as the on-ramp to escalation. An EXIT vote is never suppressed,
and a fired EXIT resets the suppression state together with the
fired-state (the existing re-arm semantics).

**Tests.**

- `testRepeatedCrossingsCannotRefireTrimInsideSuppressionWindow`: a
  −0.5%/step grind votes TRIM at updates 8, 19, 30, 41 — all
  suppressed-or-cooldown-blocked after the first fire (callback count
  stays 1 across 30 repeat votes) — until update 51, where anchorDD
  reaches 18.18% with negative momentum and the bypass fires TRIM #2;
  the next update's EXIT vote fires immediately (escalation).
- `testExitVoteIsNeverSuppressed`: a −2%/step bleed inside an active
  suppression window still escalates TRIM → EXIT.
- All pre-existing whipsaw suites pass unchanged (square wave: zero
  votes; sawtooth: bounded callbacks).

**Live evidence (rehearsal release, §5).** During the −2%/step bleed the
reactive emitted exactly **7 `TrimSuppressed` events** (updates 8–14)
and requested exactly one TRIM callback; no repeat TRIM reached the
vault. The suppression rule is visible on Lasna:
react txs `0x701d60e1…`, `0xe5eba41c…`, `0xe00a2a60…`, `0x2bbf2f0d…`,
`0x61787e57…`, `0x5ecd34cb…`, `0x3d0362ee…`.

## 3. Repair 2 — model v3 for the V-recovery blind window (DESCOPED)

**Weakness.** After a sharp V-recovery to a new high, a fresh decline
is voted HOLD for 7 steps at −3%/step (≈ −19% from the peak) before
protection engages — the recovery prices still fill the 9-price window.

**Diagnosis first.** The teacher (policy ladder v2) labels the exact
adversarial recovery path TRIM from decline step 1 and EXIT at step 7:
the labels are right; the shipped v2 *model* underfits that region.
So v3 was a pure retraining task — same 7 features, same teacher, plus
new training mass on the failing shape: dedicated fresh-peak decline
scenario families (`peak_decline_flat`, `peak_decline_v` — a V-recovery
to a new high, then an immediate decline at −0.5%…−6%/step, flat and
re-dip variants) and the deterministic adversarial recovery path pinned
as training anchors with jittered variants (`tools/train.py`,
additive v3 section; the v2 flow is untouched).

**Validation gates (from the work order) and results.** Held-out =
teacher fidelity on unseen series; "v2 set" = v2's own 6,001-window
held-out set, "v3 set" = the v3 split (7,951 windows incl. the new
families). v2's measured held-out EXIT-class recall is 99.40% (its
canonical EXIT *calls* are 100% precise — no false EXITs); the gate
below uses recall ≥ v2's measured value on the same set.

| Gate | v2 (shipped) | v3 attempt 1 | v3 attempt 2 | v3 attempt 3 |
|------|--------------|--------------|--------------|--------------|
| Recovery: TRIM/EXIT ≤ 3 steps after fresh peak (−3%/step) | step 8 ✗ | step 5 ✗ | **step 1 ✓** | **step 1 ✓** |
| Held-out accuracy (v2 set) ≥ 95.41% | 95.41% | 95.05% ✗ | 94.24% ✗ | 93.64% ✗ |
| Held-out accuracy (v3 set) ≥ 95.41% | — | 94.03% ✗ | 93.59% ✗ | 92.30% ✗ |
| EXIT recall (v2 set) ≥ 99.40% | 99.40% | — | 98.89% ✗ | 99.66% ✓ |
| 5-episode real-data backtests no worse than v2 | baseline | not run (gate failed upstream) | not run | not run |
| Full adversarial suite | pass | (contract unchanged; suite is model-agnostic) | | |

Attempt 1: width 12, from scratch, natural family mix. Attempt 2:
width 16, peak-decline families duplicated ×2, recovery anchors +
variants — closed the recovery gap completely but dragged HOLD recall
to ~90% (the boundary moved toward TRIM everywhere). Attempt 3:
fine-tune from the shipped v2 weights (width 12, 3,500 epochs) —
recovery step 1 and EXIT recall recovered, held-out fidelity fell
further.

**Conclusion.** Every configuration that closes the recovery gap pays
1–2 points of held-out fidelity: in the 7-feature space, the
fresh-peak-decline region genuinely overlaps the benign post-rally
HOLD region, and capacity or emphasis shifts move errors rather than
removing them. Per the work order's rule, **model v3 was not
deployed**. Release 4 ships the v2 weights; the blind window stays on
the honest-limits list, now also pinned by
`test/SentinelAdversarialV3.t.sol` case (e) so any future model change
must confront it explicitly. The plausible real fix is representational
— an 8th feature (e.g. return-order or steps-since-peak) — which is a
new model architecture, out of this repair's scope. Training code for
all three attempts is retained in `tools/train.py` /
`tools/backtest_v3.py`; the failed v3 weights artifacts were deleted so
nothing in the repo presents them as shippable.

## 4. Deployments — all Sourcify exact_match

| Contract | Chain | Address | Deploy tx |
|----------|-------|---------|-----------|
| `SentinelReactiveV3` (#4 main) | Lasna (5318007) | `0xcE8615E0b19Ce81793aE34E6d7B8C33C440d2AA3` | `0xf484254377619ad7f06aadfb34f63539f63ea73c8501350c568b1c8c630f15d9` |
| `SentinelSwap` (#4) | Base Sepolia (84532) | `0xfc25B4e4961e1c6588CC1Ac7BbbdeCC3E88BBf05` | `0x874d0f04982758b105a898f8dafd00fb57975981a7ba95d188227517fcb3d85c` |
| `SentinelVaultV2` (#4) | Base Sepolia (84532) | `0xBd5d3146D62d4c6A6360483908e0429A1E6f9d06` | `0xe6a9f3a5c60ac56368ac007639fff3b2c2dbb31bbc3aa50b316421972d9e2096` |
| `MockPriceOracle` (#4R) | Base Sepolia (84532) | `0xA9aCa38557E2ec428F1b398BfF8725D69a87f63a` | `0xf2c7e5ec1a54f9ed0ef962c9502dc0b963318a8b82c4089aaed54bea8f20276c` |
| `SentinelReactiveV3` (#4R) | Lasna (5318007) | `0xC497213aBFCfa0Dee320121B9245D93D3d9952B8` | `0xfe65a16c4ed201632757732374c9e25f9638741651908b0b7886fc21d52aae28` |
| `SentinelSwap` (#4R) | Base Sepolia (84532) | `0x05111b776E3A20BB634424168207F5c5e606B4B5` | `0x0d2f9b9476f0366f08f0fdb2e71b32ef51dc7a05dbd3e5d69f2dd784de1c6985` |
| `SentinelVaultV2` (#4R) | Base Sepolia (84532) | `0x57298806AC7197f2e16715e0454BBe22ddC250d3` | `0x8ee8f14f524c1ce6d5a8514703591239a88d545e67bbdf4442717324459c4838` |

Sourcify: every contract above is `exact_match` (creation + runtime),
verified via the Sourcify v2 API on 2026-11-19 —
[sourcify.dev lookup](https://sourcify.dev/#/lookup/0xcE8615E0b19Ce81793aE34E6d7B8C33C440d2AA3).
The main reactive subscribes to the Release 2 Chainlink adapter
(`0xAb9c7a5178B444cd1C1fD705e5eBeCf4b9A1C25F`, token WETH) exactly like
Releases 2–3; the rehearsal reactive subscribes to its own
`MockPriceOracle`. Both reactives were funded ≥ 1 lREACT (main 1.05,
rehearsal 1.10) and both vaults hold a live position (main #4:
0.0001 WETH; rehearsal: 0.0002 WETH at start).

## 5. Live rehearsal proof (Release 4R, mock origin)

Driven by `tools/rehearse_v3.sh` (27 pushes, each awaited on-chain).
Full per-push log: rehearsal transcript in the build workspace.

| Stage | Pushes | Result |
|-------|--------|--------|
| A — calm ×5 ($100 → $100.10) | updates 1–5 | HOLD ×5, 0 callbacks |
| B — bleed −2%/step ×10 (→ $81.789) | updates 6–15 | **TRIM fired** at update 7 (position 0.0002 → 0.0001 WETH); 7 repeat TRIM votes **suppressed** (updates 8–14); **EXIT fired** at update 15 (position → 0, vault closed) |
| Re-arm | owner deposit tx `0x7e655c0a…` | position 0.0002 WETH restored, `closed = false` |
| C — recovery ×4 (→ $104.00, new high) | updates 16–19 | TRIM fired on the recovery's first step ($83.70 — the window still showed the bleed and anchorDD ≈ 15%; see note), then HOLD through the new high |
| C — decline −3%/step ×8 (→ $81.51) | updates 20–27 | HOLD ×7 (the still-open blind window, live), **EXIT fired at step 8** — position → 0, vault closed |

Callbacks (Lasna react tx → Base Sepolia callback tx):

| # | Action | React tx (Lasna) | Callback tx (Base) | Fill |
|---|--------|------------------|--------------------|------|
| 1 | TRIM | `0x32a5473e7857ad0155b03a6e212dd0dcce132d07cb1a58d874c000f38d04ca35` | `0x2ec7cb8b8019faba58caf841b879f69481a7dc67c03c6969e9f69a2197cadfe8` | 0.0001 WETH → 0.0096136 mUSDC @ $96.136 |
| 2 | EXIT | `0xfd79580d3a42caea7fbb28e5398796cf409c8de07df86a9590494e82b07b08e5` | `0x4a27b3100906ad234abf8170b0d09283eb505c7b9033b8bf410fec013c7b1e88` | 0.0001 WETH → 0.0081789 mUSDC @ $81.789 |
| 3 | TRIM | `0x34162ec62b123b99680e8c39fb1fe45e3415aa3caf294ca1f7924ed64548fb43` | `0x3d9c60e582e526605b8a899eacca9d2e4caf4fa00cc196b2e5cd6abec984fc96` | 0.0001 WETH → 0.00837 mUSDC @ $83.70 |
| 4 | EXIT | `0x1ac5c60547d5d4b651efad4f6d3cb767b02def7d0c906cdead1e3b47eec07b2a` | `0x2f6c33716fff76a2d083fc944be212ff441670b279399f3f261ce29d8a8a94dd` | 0.0001 WETH → 0.008151 mUSDC @ $81.51 |

**Reconciliation (read on-chain after the run).** Vault #4R: WETH 0,
mUSDC **0.0343135** — exactly the sum of the four fills
(0.0096136 + 0.0081789 + 0.00837 + 0.008151); `protectionCount = 4`,
`closed = true`. Swap #4R: WETH 0.0004 (all four fills), reserve
999.9656865 mUSDC = 1,000 − 0.0343135. Reactive #4R: `updates = 27`
(one per push), `duplicatesIgnored = 0`, `lastTrimFiredUpdate = 0`
(reset by the final EXIT). Balances moved WETH → USDC on every fire.

**Deviation note.** The offline mirror predicted no vote on stage C's
first recovery step; that simulation used the 14-push bleed variant.
On the shipped 10-push stream the model voted TRIM at $83.70 — inside
the teacher's anchor-TRIM band (anchorDD ≈ 15%) and consistent with
the guardian's design (at that print the tape still showed a crash in
progress). It is recorded here rather than smoothed over; the
rehearsal's claims (TRIM/EXIT firing, suppression, re-arm, blind
window, reconciliation) are unaffected.

## 6. Live window — Release 4 main (real Chainlink feed)

2026-11-19, ~13 min driver window (`tools/drive_chainlink.sh`, the
Release 2 adapter poked every 75 s; emissions gated by the adapter's
10 bps deadband / 60 s min-interval / 300 s heartbeat):

| Sync tx (Base Sepolia) | Emitted price | React tx (Lasna) |
|------------------------|---------------|------------------|
| `0xd8303e1d7cb3917389f811e612b64bbd7466835d3da911adb828e2cb61fab110` | $1,770.91 | `0xd5262af620db776b3ef29eff217d8b02dfdebe168969876b9a3d3e52cb60ee44` |
| `0x401ed273bb66aba490295ca520310bb8fb18cb78ceea1d37f2c23031c9daf972` | $1,775.53614611 | `0xd590c8d64ab0c1362c57c1062125d0fb4286324f6f2aa6870a239c672009c144` |

Reactive #4 read back after the window: `updates = 2`,
`lastAction = 0` (HOLD — the window is still warming up; decisions
start at the third price), `duplicatesIgnored = 0`, and the anchor
initialised to $1,770.91 then **re-anchored to the higher second print
$1,775.53614611, read on-chain to the wei** — the V3 contract's anchor
tracking verified live on real Chainlink data, same as Release 3's
proof. Release 3's reactive ingested the same two emissions in parallel
(untouched, still running). No firing was forced on the main release —
its firing proof is the rehearsal release above, same contract code.

## 7. Fuel after the runs (read on-chain, 2026-11-19)

| Balance | Value |
|---------|-------|
| Release 4 reactive (main), Lasna | **1.010342 lREACT** (of 1.05 funded; 2 reacts) |
| Release 4R reactive (rehearsal), Lasna | **0.1856625 lREACT** (of 1.10 funded; 27 reacts ≈ 0.0339/react) |
| Release 3 reactive, Lasna | 1.46745 lREACT (also ingested this window's emissions) |
| Vault #4 position / billing, Base Sepolia | 0.0001 WETH / 0.0001 ETH (untouched) |
| Dev wallet, Lasna | 0.2296481 lREACT |
| Dev wallet, Ethereum Sepolia | 0.950149 ETH |
| Dev wallet, Base Sepolia | 0.0093168 ETH |

Funding route used (all on-chain, no web faucet): user-sent Sepolia
ETH → faucet contract `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`
`request(devWallet)` at 0.02 ETH → ~2.1 lREACT on Lasna (tx
`0x87711812…`), plus 0.01 ETH bridged Sepolia → Base Sepolia via the
official L1StandardBridge (tx `0x833539a2…`) for the Base-side gas and
positions.
