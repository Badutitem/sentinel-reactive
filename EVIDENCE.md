# Sentinel — Evidence Pack

One page where every public claim about Sentinel can be checked: contract
addresses, verification links, the transaction chains that prove the live
loop, rehearsal results, model metrics with their method, test counts, fuel
status, and the honest limits. Compiled 2026-11-19 from the deploy records
in [DEVLOG.md](DEVLOG.md) and the phase reports; on-chain figures in the
fuel section were read back live on that date.

Explorers: Base Sepolia — https://sepolia.basescan.org ·
Reactive Lasna — https://lasna.reactscan.net ·
Sourcify lookup — https://sourcify.dev/#/lookup/&lt;address&gt;

## 1. Deployed contracts — three trios, all Sourcify-verified (exact match)

### Trio #1 — Demo A (MockPriceOracle origin, model v1, 2026-11-13)

| Contract | Chain | Address | Deploy tx |
|----------|-------|---------|-----------|
| `MockPriceOracle` | Base Sepolia (84532) | `0xB828F2F6266E4A1705224ac0b1fCDFE0415351ee` | `0xa0a8dd8bd29002e56ab153076ec5363cba7da2580675d1e4646ce70640669121` |
| `SentinelReactive` | Lasna (5318007) | `0xB828F2F6266E4A1705224ac0b1fCDFE0415351ee` | `0x1349cd6d58fdda0c2a15fee36549d3b25e566988e374ca782445c268b058e563` |
| `SentinelVault` | Base Sepolia (84532) | `0x6f723a2F0E4A45111F42A74448426AAAAb3d7641` | `0x389f8694cbc967cd6076355271a430ffd19633ee7ec9c8ec00b28af670ea547f` |

Phase-2 real-asset upgrade (same lineage, 2026-11-15):

| Contract | Chain | Address | Deploy tx |
|----------|-------|---------|-----------|
| `MockUSDC` | Base Sepolia (84532) | `0x96E467Ff7958851d307D28118EBAAD333CAb85B2` | `0xb6e416a3d303dbcb721634d09a2c57bfdbe379d0acfa623d10c2eb6e04dd7876` |
| `SentinelSwap` | Base Sepolia (84532) | `0x2C1d278d31d52Ec8405cF33E319ba0eB8C6b0d1F` | `0x31a88186cb276fe19e046283b8d745982b7775e5602d25648dd0c779dc08e3ea` |
| `SentinelVaultV2` | Base Sepolia (84532) | `0x29c0b2FAc813e59E23E12b8f6699bF17d4512192` | `0x1907efc0c1b346ec1d1405b8ae8321022f14502dd401d1fedf6e264139826922` |

### Trio #2 — Demo B (real Chainlink ETH/USD origin, model v1, 2026-11-15)

| Contract | Chain | Address | Deploy tx |
|----------|-------|---------|-----------|
| `ChainlinkPriceAdapter` | Base Sepolia (84532) | `0xAb9c7a5178B444cd1C1fD705e5eBeCf4b9A1C25F` | `0xba16d14ade1d586fcbc3d309e898587cac2fcec188a53b4aace5ea3799d60a66` |
| `SentinelSwap` (#2) | Base Sepolia (84532) | `0x6E270B88133155E4c21d71029EF3Fe47Ce9e813D` | `0x76eb9e283e5942dbf2bad37aba7073e25ff4e7690bc5b4a80d78b0be19e7a498` |
| `SentinelReactive` (#2) | Lasna (5318007) | `0x92ea50b0De053BE2D7FA6F73853aC403364c9330` | `0xd1728c9618599bdefa0698d3cd1dd3a5174d0c3259bd6543242daab45842429d` |
| `SentinelVaultV2` (#2) | Base Sepolia (84532) | `0x41e86278264C0C4FB83e5328329ff6F459Ba3dF4` | `0xdb2c6b1e77b9c2eba4ab5e149018ed0430ec08027b228bb2e1be467cafe5f5fe` |

### Trio #3 — model v2, anchor-aware (Chainlink origin, 2026-11-15) — the current live set

| Contract | Chain | Address | Deploy tx |
|----------|-------|---------|-----------|
| `SentinelReactiveV2` | Lasna (5318007) | `0x175205677bCEee3dED7F6559D653515710212d33` | `0xf4f9a3d5de9486e88f8f1379881337ca9d8af42bc02bd81c75b3e626b89fcaba` |
| `SentinelSwap` (#3) | Base Sepolia (84532) | `0x5B72Abb91A8923768E3569959517fCE3f69CF19A` | `0xfa4b3295d2625f936f410344562bb4d9e4e82250a6850c853321fd7fc91f6e37` |
| `SentinelVaultV2` (#3) | Base Sepolia (84532) | `0x2942cc16F61516FDB24cF009dD07ca366a99abBc` | `0xd3649b186a297f4de33b7b86a01f8571eab32c8cf9c71dfab41fe0a102837cf7` |

Verification: every contract above is Sourcify **exact match** — look any
address up at https://sourcify.dev/#/lookup/&lt;address&gt; (chains 84532
and 5318007).

## 2. Live-loop proof (origin tx → reactive tx → callback tx)

**Phase 1 rehearsal** (30 oracle pushes → 30 reactive txs → 2 callbacks,
full loop ≈ 2 s):

- Calm: 7 decisions, all HOLD, zero callbacks, position untouched.
- Grind → **TRIM**: origin `0x7aba9f0d8cb303763c1c5298b17193f4c32cfbf9dbe819c5649ba1170f2cded9`
  → reactive `0x9142977c5df4a28d149d62218849bd1ec36abfda5e05546789a4c6486aa3448e`
  → callback `0xb5914403cbd5b49baa10abdd9436fde3f8f0ca6f08ba972318e3e9e664b20eaa`
- Crash → **EXIT**: origin `0x1bc65058749df45c25215642d520657fe6a7a2148d2ff3c41f237dba77bc7086`
  → reactive `0x42cf48c375a3453ff09410d8fecc5b7f64ebad8e8925f8596213e0b9ce1400c2`
  → callback `0x1d506a0077b046cf043e303635f5f118800f7b0c7661a172207918c6946d40d7`

**Phase 2 rehearsal** (real ERC20 transfers inside the callbacks):

- Grind → **TRIM**: origin `0xa1c46ea2b9fbd2bc70ee0e4fd946cec200a643582a287f12171b377018f31c4a`
  → reactive `0x00fc5e4537786544f1a9a6ca6a8d7ad17d8c63d836e6fa05bccf441fd2d30d10`
  → callback `0xf8dabf14c32a5bd234f58ff14e9a8328f717707377acf2989c77fb1e07232072`
- Crash → **EXIT**: origin `0xbed70db574e02bd3912b4cfa74f5e86cca004800620104effd766e9374a13995`
  → reactive `0xfe39a88434271543356c988fa70fd256946a68d6cba0ee19a49fe3492715af60`
  → callback `0xa55c9079d19bb55ff6e69f992bc2e7fea56a8aa12747d3b1ed9f7f9f0e3c14d2`

**Phase 2B — first real Chainlink price in the model:** adapter first
`sync()` `0x5c82ed22b9d4f957f1bfd0246284451b7a0db29887fa005f37323bf73c5da80f`
emitted $1,835.12571218; reactive #2 ingested it in
`0xfc4e70a88736c6d4abb46910575f84cc62e928b32af38770c07c8e3bc6546026`.
The ~90-minute live window then produced 22 Decision events, all HOLD on a
real −1.4% slide (first `0xaee9b392ee899d16211bbfdf1e5cd08d1832919ab34449939c70278c5641f65d`,
most-stressed `0xd1b009add072e00304faa2091c72ac1d3a041317cf0d2acdf16f7ca8141216a3`,
last `0x42f7dd4451ffdcfc2be273fe7909efc0bae5fb0f77c2e623c1a0f03aafd7747d`).

**Phase 3 (trio #3) live window:** 13 syncs → 8 emissions → 6 Decisions,
all HOLD on a flat $1,812–$1,818 tape (correct output; no firing can be
forced on this trio), with the anchor verified bit-exact on-chain (peak
tracked the $1,815.1845 high, decayed to the wei on the next print, live
anchorDrawdown feature 556 = 0.0556%).

## 3. Rehearsal results

- Phase 1 (mock position): **1,000 → 500** on TRIM, **→ 0** on EXIT, vault
  closed; end state `protectionCount = 2`, zero service debt.
- Phase 2 (real tokens): TRIM sold **0.005 WETH → 14.1 MockUSDC**
  (position 0.01 → 0.005 WETH); EXIT sold **0.015 WETH → 35.1 MockUSDC**
  (position re-armed to 0.015 WETH between stages), vault closed. Swap
  accounting reconciles exactly (1,000 − 14.1 − 35.1 = 950.8 MockUSDC
  reserve; 0.02 WETH held).
- Phase 2B: vault #2 armed and untouched through 22 live HOLDs —
  **0.0093 WETH** position preserved; HOLDs cost no callbacks.

## 4. Model metrics — with method

Method: weights trained off-chain (`tools/train.py`, numpy only, seeded —
re-running reproduces the shipped weights) on 540 synthetic price series
(six families: calm / uptrend / chop / grind-down / crash / V-recovery;
24,051 train / 6,001 held-out windows, split by series so held-out series
are genuinely unseen), labelled by a hand-written stop-loss policy ladder.
The trainer's integer reference implementation was proven bit-for-bit
against the Solidity behaviour before quantisation (×1000).

- **Model v1 (trios #1–#2):** held-out accuracy, float model 97.10%;
  shipped quantized integer model **97.47%** — per class HOLD 96.9% /
  TRIM 99.1% / **EXIT 100%**. These figures measure agreement with the
  labelling policy on unseen *synthetic* series, not trading performance.
- **Model v2 (trio #3):** held-out fidelity **95.41%** against teacher v2
  — a different, larger policy (v1 ladder + anchor clauses), so this is
  *not* a like-for-like comparison with 97.47%. What v2 buys, measured on
  the same rigs: synthetic slow-family EXIT windows 0.0% → 58.5% (grind),
  73.3% (slow-grind), 24.5% (staircase); June 2022 real-data collapse
  EXITed at −28.6% from peak, 139 hours before the trough; zero false
  EXITs in the Sep 2023 chop and Feb 2024 uptrend. Full method:
  [ANCHOR.md](ANCHOR.md), [BASELINE.md](BASELINE.md),
  [BACKTEST.md](BACKTEST.md).

## 5. Tests — 73 passing (2026-11-19)

`forge test`: **73/73 pass, 0 failed** (11 suites). The original 66 cover
the model (exact logits), both vaults, both reactives (bit-exact feature /
anchor parity against the Python mirror), the swap desk, the Chainlink
adapter, and two end-to-end loops.

Added 2026-11-19 (`test/SentinelAdversarial.t.sol`, 7 tests, no contract
logic changed — every assertion was measured against the shipped contract
first):

| Test | Measured behaviour pinned |
|------|---------------------------|
| `testStaleFeedCannotManufactureExit` | After a real TRIM, 30 frozen re-deliveries of the crashed price: never an EXIT vote, never a second callback; anchorDD decays 7.6% → 5.3% and the vote returns to HOLD |
| `testFrozenFeedFromStartIsInert` | One price repeated 20×: HOLD throughout, zero callbacks |
| `testWhipsawSquareWaveNoFlap` | 100 ↔ 92 square wave, 40 updates: **zero** TRIM/EXIT votes, zero callbacks — no flap exists at this amplitude |
| `testWhipsawSawtoothBoundedCallbacks` | 92 ↔ 85 sawtooth after a TRIM: 1 further TRIM vote, 0 EXIT votes, callbacks stay at 1 (cooldown bounds firing) |
| `testReplayedLogIngestedButCannotDoubleFire` | A replayed log **is ingested** as a fresh update (no dedup — see limits), but an exact replay of the firing log cannot double-fire: the cooldown keys on the log's own origin timestamp |
| `testSlowGrindReachesExit` | −0.5%/step grind: no EXIT for 51 updates; first EXIT at update 52 with anchorDD 18.50% — the anchor band, not any window feature, fires it |
| `testRearmAfterExitNewHigh` | After EXIT + recovery to a new high, the anchor re-peaks (asserted) and the next cycle's first protection callback fires at T0+1020 — deep inside the first cycle's 3600 s cooldown — proving the EXIT state reset re-arms the guardian |

## 6. Fuel status (read on-chain, 2026-11-19)

| Balance | Value |
|---------|-------|
| Trio #3 reactive (`0x1752…2d33`) callback fuel, Lasna | **0.0349808 lREACT** (≈ 1 react at the observed ~0.030 lREACT/update — thin) |
| Vault #3 position, Base Sepolia | **0.00004 WETH** (+ 0.00004 ETH callback billing) — dust, by funding exhaustion, not by design |
| Dev wallet, Lasna | 0.0006592 lREACT |
| Dev wallet, Ethereum Sepolia | 0.000149 ETH |
| Dev wallet, Base Sepolia | 0.000046 ETH |

**Top-up status: BLOCKED on dev-wallet funding (2026-11-19).** The
established route is fully on-chain (Sepolia faucet contract
`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`, `request(address)` at
1 ETH → 100 lREACT, then a plain Lasna transfer to the reactive contract),
but the dev wallet holds 0.000149 Sepolia ETH — below the ~0.005 ETH a
round needs (→ ~0.5 lREACT, which would bring trio #3 to ≥ 0.5 lREACT).
One user refund of ≥ 0.01 Sepolia ETH to the dev wallet
`0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94` unblocks it; no redeploy or
rewiring is involved. The web faucet (faucet.reactive.network) is also
unreachable from the build VM. Until then the trio-#3 guardian is live but
fuel-thin: it ingests while solvent and silently receives nothing while
in debt (network semantics).

## 7. Honest limits

- **Fixed-price swap desk, not a DEX.** `SentinelSwap` fills at the
  trio's price-source price against a seeded MockUSDC reserve; MockUSDC
  is a test token, not Circle's USDC. The tokens and transfers are real;
  the market is simulated.
- **Vertical capitulations still exit near the trough.** In the August
  2024 backtest, v2's first EXIT lands 4.1% above the trough and v2
  finishes *below* v1 on that episode because the market V-recovered.
  Drawdown-based exits cannot fix this; it is measured, not hidden
  ([BACKTEST.md](BACKTEST.md)).
- **Model v2's whipsaw trade-off.** On the mild ±2% synthetic sawtooth
  family v2 TRIMs on 9.3% of windows (15.52 transitions/series) vs v1's
  1.6% / 2.05 — a decision-boundary shift from the bleed-recovery
  training data, not the anchor feature (anchorDD ≤ 4.2% there). The
  adversarial suite above shows the on-chain firing consequence is
  bounded by the cooldown, but the vote-level flap is real. V-dip
  trough-selling is likewise inherited from the teacher (60/60 series).
- **Post-recovery blind window (found 2026-11-19).** If a fresh decline
  starts immediately after a sharp V-recovery to a new high, the
  recovery prices still fill the 9-price window and the model votes
  HOLD for the first steps: measured, seven −3% steps (≈ −19% from the
  new peak) before the window is a clean decline and protection engages
  (then straight to EXIT). The state machine re-arms correctly on EXIT —
  the delay is the model's window semantics, and a position opened at a
  local top right after a crash-recovery is the least-protected shape
  this system has.
- **No replay deduplication.** `react()` ingests a redelivered log as a
  fresh update (window and anchor advance twice). A replay cannot
  double-fire a callback (cooldown keys on the log's origin timestamp,
  and escalations still need a higher action), but a replayed *newer*
  price would shift the window like any update. The Reactive Network
  delivers each log once in production; the contract does not defend
  against a duplicating relayer beyond the cooldown.
- **Repeated EXIT votes re-fire by design.** After an EXIT, the
  fired-state resets, so a continuing crash votes and fires EXIT again
  on later updates (the vault treats a callback on a closed position as
  a counted no-op). The cost is callback fees, never missed protection —
  but it is a real operating cost in a long crash.
- **Dust position on trio #3.** 0.00004 WETH (see §6) — the trio is
  fully wired and live-proven; the size is a funding artefact.
- **Anchor cadence sensitivity.** The anchor decays per *update*, not
  per second; its bands were tuned at hourly cadence (half-life ≈ 693
  updates). A different update cadence silently changes the effective
  horizon.
- **Synthetic training data; rule-ladder teacher.** See §4 — the metrics
  measure policy agreement on synthetic series; the real-data replay
  ([BACKTEST.md](BACKTEST.md)) is evaluation only, never training.
- **Testnet only, narrow by construction.** Base Sepolia + Lasna, one
  token, one immutable oracle, behaviour frozen into shipped weights.
