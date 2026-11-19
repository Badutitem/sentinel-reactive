# Trio #5 — the re-risk release (2026-11-19)

Trio #5 closes the one structural gap the trio #4 system had against
two-way rivals (Guardian Vault): after a de-risk, Sentinel could never
get back in. Trio #5 adds the way back in — a **rule-based re-risk
(re-entry) machine** on top of the unchanged model v2 pipeline — and
ships the variant that won the pre-registered 10-scenario evaluation
(RERISK-VARIANTS.md): **variant B, scale-in**. Design record:
TRIO5-DESIGN.md (the addendum is the shipped spec). Nothing in trios
#1–#4 was modified; both earlier reactives ingested this trio's
Chainlink window in parallel, untouched.

New contracts (copy-forward; the deployed-version files are
untouched): `src/SentinelReactiveV5.sol` (V4 body + variant-B episode
machine; dedup, TRIM suppression and the shipped v2 weights are
bit-identical), `src/SentinelVaultV4.sol` (V3 + tranche actions),
`src/SentinelSwapV2.sol` redeployed unchanged (the two-way desk from
the trio #5 candidate). Test count: **144/144** (120 previous + 24
new).

## 1. The re-risk machine, as shipped

- **Episode open.** A fired TRIM/EXIT opens a de-risk episode
  (`episodeAnchor` = the anchor in effect, start update recorded); a
  fresher fired de-risk refreshes it and resets both tranche flags.
- **Tranche 1 (action 3, half spend).** Once ≥ 3 updates have passed
  and the current price ≥ **97% of `episodeAnchor`**, the vault buys
  back with **half** its safe balance. The reclaim check runs before
  the cancel check, so an above-anchor print after the minimum fires
  tranche 1 instead of cancelling; only a runaway high *before* the
  minimum still cancels the episode.
- **Tranche 2 (action 4, spend the rest).** After tranche 1, when the
  running anchor exceeds `episodeAnchor` (a new high above the level
  the de-risk was measured against), the vault spends the entire
  remaining safe balance and the episode closes. No cancel exists
  after tranche 1.
- The tranche callbacks are not timestamp-cooldown-gated (bounded by
  construction: at most two per episode) and do not touch the
  protection fired-state. The desk never reverts on short inventory
  (partial fill + `RiskShortfall`); a tranche that buys nothing
  leaves the vault's counters, flags and balances untouched.

**Measured cost — read this before citing the feature.** Re-risk was
evaluated against never re-risking over 5 synthetic streams + 5 real
Binance episodes (RERISK-VARIANTS.md): **every variant, B included,
is negative on average** (B −40.41 mean delta, best of five; V1
single-shot −103.57). It paid in the real recoveries (sep2023
+25.43, feb2024 +89.56) and cost in the real crashes (may2021
−145.91, jun2022 −74.07, aug2024 −93.89 — repeated dead-cat
reclaims). B is the least-cost way to own the two-way capability,
**not a profitable rule on this evidence**, and it is documented
that way everywhere in this repo.

## 2. Deployments — all Sourcify exact_match

| Contract | Chain | Address | Deploy tx |
|----------|-------|---------|-----------|
| `SentinelReactiveV5` (#5 main) | Lasna (5318007) | `0x0Fdab4F59e877B2f9f695Bd285b72831336caCd4` | `0x7cb7dc303b0748e9d0319f3054392f7a248ae823fdb5b8f5c29d4dfdd486bd33` |
| `SentinelSwapV2` (#5) | Base Sepolia (84532) | `0x80c3BF688b08ac03D3aE7396cDd96770F7ce572a` | `0xf7d4ca845fa7e13128b22b8c186e78ee7655a4302f6127ac3676133e80fe610d` |
| `SentinelVaultV4` (#5) | Base Sepolia (84532) | `0xb13BF7Ff153e7f6304735EC4199B006Fd4857Ac9` | `0x9dd848a16b79fd4354d41ed4f614ff4533b9327538354a52eb3622989b896775` |
| `MockPriceOracle` (#5R) | Base Sepolia (84532) | `0xfC2E4b2BbFD195B4e56FCd1aa22F32ED7D15E2c3` | `0x965e1dc91ef0626765c1f8b54055cc13f7dd92becc954f6595713e49fe36371e` |
| `SentinelReactiveV5` (#5R) | Lasna (5318007) | `0x1123b38e933D0a87D5846456c1ed6E94c936e3e1` | `0x994bda4d5d0446485eb6d2bd111ca46f15c355c6aac769b67fcdf74629cc98a6` |
| `SentinelSwapV2` (#5R) | Base Sepolia (84532) | `0x4357e1296f186Cb945578304EFca16219D83Ec0E` | `0xadbbcf139a64e9bcdad3af016e132d617c7298811b43f7bdb7447d1348356ca2` |
| `SentinelVaultV4` (#5R) | Base Sepolia (84532) | `0x242719F815141ad08286f29a23025b9244efd60e` | `0x4be9bc4789464f1ada2d8b608eb79ed0c49d9d0e883b5e59fe9dd546290fd9be` |

Sourcify: every contract above is `exact_match` (creation +
runtime), verified via the Sourcify v2 API on 2026-11-19. The main
reactive subscribes to the phase-2B Chainlink adapter
(`0xAb9c7a5178B444cd1C1fD705e5eBeCf4b9A1C25F`, token WETH) exactly
like trios #2–#4; the rehearsal reactive subscribes to its own
`MockPriceOracle`. Funding at deploy: main reactive 1.05 lREACT
attached (+0.10 top-up after the live window, §4), rehearsal
reactive 1.40 attached. Both vaults hold a live position (main #5:
0.0001 WETH; rehearsal: 0.0002 WETH at start) and 0.0001 ETH callback
billing; both swap desks were seeded with 1,000 mUSDC.

## 3. Live rehearsal proof (trio #5R, mock origin)

Driven by `tools/rehearse_v5.sh` (31 pushes, each awaited on-chain;
the price series was validated on the evaluation mirror at the live
position size before a single push). Callback sequence on-chain —
**identical to the mirror's prediction, update for update**:
(7, TRIM) (15, EXIT) (18, RERISK) (19, RERISK_FINAL) (25, TRIM)
(31, EXIT).

| Stage | Pushes | Result |
|-------|--------|--------|
| A — calm ×5 ($100 → $100.10) | updates 1–5 | HOLD ×5, 0 callbacks |
| B — bleed −2%/step ×10 (→ $81.789) | updates 6–15 | **TRIM** at update 7 (0.0002 → 0.0001 WETH); 7 `TrimSuppressed` events (updates 8–14); **EXIT** at update 15 (position → 0, vault closed; episode anchor 99.201310328728328781) |
| C — recovery ($90, $93, $96.5, $99.5, $103.5) | updates 16–20 | No votes at $90/$93; **tranche 1** at update 18 ($96.5 ≥ 97% of the episode anchor, 3 updates after the EXIT) — half spend; **tranche 2** at update 19 ($99.5 print lifts the anchor above the episode anchor) — rest spent; HOLD at the $103.5 new high |
| Re-arm | owner deposit tx `0x4211cd64…` | +0.0002 WETH (position 0.000381598666909677) |
| D — bleed −2%/step ×11 (→ $82.876) | updates 21–31 | **TRIM** at update 25 (position halved); 5 `TrimSuppressed` events (updates 26–30); **EXIT** at update 31 (position → 0, vault closed) |

Callbacks (Lasna react tx → Base Sepolia callback tx):

| # | Action | React tx (Lasna) | Callback tx (Base) | Fill |
|---|--------|------------------|--------------------|------|
| 1 | TRIM | `0x91feb3c144c75707800beaae45a83386da9c7ee04469c7c6c890a1a05d418cc2` | `0x695bc61d56426db30892125b7cd4a73ed652a65fd5d93d8ec6c0144f4135a54e` | 0.0001 WETH → 0.0096136 mUSDC @ $96.136 |
| 2 | EXIT | `0x5258932dae9b16561a58eaff58f20c6844e89490f2c9313036e9b027ce13b032` | `0x12ad313a59b3c9d95168f6a8acfe920c013e33767a6658137b59db66f02c5276` | 0.0001 WETH → 0.0081789 mUSDC @ $81.789 |
| 3 | RERISK (tranche 1) | `0x37f17e7cd6c9bc1c7921ef17a489f2476cd9fd8433b0bab570e1def99d4f3c9a` | `0xa73e1f2c47ac9ebaa181c46db132d224031f166bdfe7d840b3fa2af3478bdc19` | 0.00889625 mUSDC → 0.000092189119170984 WETH @ $96.5 |
| 4 | RERISK_FINAL (tranche 2) | `0x0517d54dba38cd6147e8a2c394256741bd2c9e66c4f5dc422f4e5319de3b5b93` | `0xe0bf60a30d2bf063cb40b68d338ef59469faf0578a6606ee6ccd9cf52a56fd13` | 0.00889625 mUSDC → 0.000089409547738693 WETH @ $99.5 |
| 5 | TRIM | `0x7335744027daf06bfc51001c6528122ee8bb621bc15233617fef19a678a8629e` | `0xed71abeb6d1672436f01ae11de6bd395d65eda59824f3e39dd4a947c64f21acc` | 0.000190799333454838 WETH → 0.017850442440700823 mUSDC @ $93.556 |
| 6 | EXIT | `0x91dd2bd5050d84a45e12303bd300ff70f137c89101d76243180950bb1b160cd7` | `0x9cf875168d2d2cec87cd3b9a8404385b4dd48c980785417df782a07e5d684171` | 0.000190799333454839 WETH → 0.015812685559403236 mUSDC @ $82.876 |

**Reconciliation (read on-chain after the run).** Vault #5R: WETH
0, mUSDC **0.033663108000104059** — exactly the mirror's prediction
to the wei, and exactly fills 1+2−3−4+5+6 netted through the desk.
`protectionCount = 6`, `reriskCount = 2`, `closed = true`. Swap
#5R: WETH **0.0004** — every wei of WETH ever deposited into the
vault (0.0002 initial + 0.0002 re-arm) ended in the desk after the
final EXIT — and reserve 999.966336891999895941 mUSDC; vault +
desk mUSDC = 1,000.000000000000000000, the seed, exactly. Reactive
#5R: `updates = 31` (one per push), `duplicatesIgnored = 0`,
12 `TrimSuppressed` events total, 0 `EpisodeCancelled`.

**Process incident, recorded plainly.** The driver process was
killed by a service restart after update 22 (stage D, push 2); the
/tmp transcript of pushes 1–22 was lost with it. State was rebuilt
from chain reads (updates = 22, oracle last price $99.401, vault
0.000381598666909677 WETH / 0 mUSDC, protections 4, rerisks 2) and
the run was resumed with `tools/rehearse_v5_resume.sh` for pushes
23–31 only — no price was ever pushed twice (the oracle's
`PriceUpdated` history and the reactive's update count agree: 31
pushes, 31 updates). Origin txs for pushes 18–22 were recovered
from the oracle's transaction history (push 18
`0xde47206c…`, 19 `0x1c947346…`, 20 `0xccce9db7…`, 21
`0xde0ae9fe…`, 22 `0x6a7e342d…`). Contract behaviour shows no
deviation anywhere; the incident is in the driving tooling, not
the system under test.

## 4. Live window — trio #5 main (real Chainlink feed)

2026-11-19, ~15 min driver window (`tools/drive_chainlink.sh`,
adapter poked every 75 s; gates: 10 bps deadband / 60 s min-interval
/ 300 s heartbeat). The feed was quiet: all three emissions carry
the same Chainlink answer, **$1,803.58151417** — the first on the
deadband path, the other two heartbeat re-emissions of the
unchanged round.

| Sync tx (Base Sepolia) | Emitted price | React tx (Lasna) |
|------------------------|---------------|------------------|
| `0xb906f18a5d686b3e31a99b819191cc3a3a7cfa871dc904906b90c95437133241` | $1,803.58151417 | `0xc37d27aebf2364b1434932804d57679f334b498522e5375a4d83a416614fe0b3` |
| `0xde6e782b4ee17937e40a04ef856a20e403d2491525211b7640d68b367898a752` | $1,803.58151417 (heartbeat) | `0x5fddb9a1c4e46644fb2732b7f478ade587460fed7880e1dfe7f03653d1c08f13` |
| `0x6bba31c8a6d8a8c1af06fce8e0629607d1efa55e77c8335fdb8dc3287df2f9c3` | $1,803.58151417 (heartbeat) | `0xdd726c29430816fa0ed2f01d9319c28f3719e2fa0bc03e6b2019acc7292fc8e7` |

Reactive #5 read back after the window: `updates = 3`,
`lastAction = 0` (HOLD — warm-up; decisions start at the third
price and no inference has had a full window yet), anchor
initialised to $1,803.58151417 (the repeated print neither raises
nor decays it materially across three updates), `duplicatesIgnored
= 0`. Balance after 3 reacts: 0.9758959 lREACT; topped up +0.10
(tx `0x8c3464fa4629550126f5ef8c39e2dec77a7fb933ea665f9d2f63cdcf4765f0de`)
to **1.0758959 lREACT** end-state. Trios #3 and #4 reactives
ingested the same three emissions in parallel (balances §5). No
firing was forced on the main trio — its firing proof is the
rehearsal trio above, same contract code.

## 5. Fuel after the runs (read on-chain, 2026-11-19)

| Balance | Value |
|---------|-------|
| Trio #5 reactive (main), Lasna | **1.0758959 lREACT** (1.05 funded + 0.10 top-up; 3 reacts) |
| Trio #5R reactive (rehearsal), Lasna | **0.314275 lREACT** (of 1.40 funded; 31 reacts + 6 callbacks) |
| Trio #4 reactive (main), Lasna | 0.8655486 lREACT (also ingested this window's emissions) |
| Trio #3 reactive, Lasna | 1.3477034 lREACT (also ingested this window's emissions) |
| Vault #5 position / billing, Base Sepolia | 0.0001 WETH / 0.0001 ETH (untouched) |
| Vault #5R billing, Base Sepolia | 0.0000929759632 ETH (of 0.0001; 6 callbacks) |
| Dev wallet, Lasna | 1.517200799990399062 lREACT |
| Dev wallet, Ethereum Sepolia | 0.910149002390096494 ETH |
| Dev wallet, Base Sepolia | 0.008579116987476140 ETH |

Funding route used (all on-chain, no web faucet): two rounds of
the Sepolia faucet contract
`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` `request(devWallet)`
at 0.02 ETH each (txs
`0x32a76c104f3336fbc75b2edbcb09144821d8afd991b481b843f0769149929774`,
`0x020734f2646bb3553eedbd21afe640e2e09f68b1e6464bbc0babd6607035b3e6`)
→ +2.1 lREACT each on Lasna (dev balance 0.2296481 → 4.4296481
lREACT before deployments). No bridge was needed this round: the
Base Sepolia balance carried in (0.0093165 ETH) covered all Base
deploys, seeds, wraps and pushes.
