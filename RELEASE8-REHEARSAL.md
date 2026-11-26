# Sentinel Release 8 — rehearsal record (June core + attack tests)

Status: **COMPLETE — PASS. June core exact to the wei; all four attacks
FAILED as required (pre-drive F1a/F1b/F4/F2-never-pushed + post-drive
F2 time-based stale + F4 brain guard). Flagship untouched throughout.**

Run 2026-11-26, 20:59–21:56 UTC (27 Nov 03:59–04:56 WIB) on the fresh
Release 8 set (FIXED code per `FIX-DESIGN.md`, suite 190/190 green).
Driver: `tools/rehearse_release8.sh` (56 pushes, one pass, no resume
needed). Deploy driver: `tools/deploy_release8.sh`. Attack drivers:
`tools/attack_release8_pre.sh` (pre-drive) and
`tools/attack_release8_post.sh` (post-drive, running). Logs: goal
`hidden_files/release8-faucet.log`, `release8-deploy.log`,
`release8-verify.log`, `release8-seed.log`, `release8-attacks-pre.log`,
`release8-prep.log`, `release8-driver.log`, `release8-push-table.md`
(all 56 origin + 6 callback txs), `release8-attacks-post.log` (pending).

Pre-drive gates passed before any push: `forge test` 190/190 (27 suites,
0 failed); mirror re-run vs klines 120–175 (`r7_mirror.py --window 120
175 --spacing 40/35/60`): votes H/T/E 18/35/1, fires TRIM@9/21/32/44/55,
EXIT@56, 30 suppressed, 0 cooldown blocks, 0 re-risk — identical to the
R7 prediction and spacing-invariant. Note on the mirror: it models the
pre-F3 EXIT reset, but June has EXIT only at the last push, so the F3
fix changes nothing here; L3 has no episode closes (`reriskCount` 0);
F4/L8 have no zero or absurd prices in the stream; F2 fills land
minutes after their emission. The prediction therefore applies
unchanged to the patched code. Burners verified with the choreography
balances (A topped +0.003 ETH, B +0.001 ETH from dev; C needed none).
Flagship brain before and after every step: updates 3, lastAction 0 —
untouched.

## 1. The set

| Contract | Chain | Address |
|---|---|---|
| MockPriceOracle (allowlisted) | Base Sepolia | `0x4e2DFac734D63AA391edE6556e374c2da69c7BA5` |
| SentinelSwapV2 | Base Sepolia | `0xCf5d79A28f2ACd2E340780e12D1E5eb8D94409f8` |
| SentinelReactiveV5 (brain, mock origin, 2.20 lREACT attached) | Lasna | `0x81709d3C667f67562349ce8e0971ba238Ef0cCc8` |
| SentinelVaultV5 | Base Sepolia | `0x7E20bf60316e978f73eDeA2290b571C5633E0131` |

Reused shared contracts: WETH
`0x4200000000000000000000000000000000000006`, MockUSDC
`0x96E467Ff7958851d307D28118EBAAD333CAb85B2`, callback proxy
`0x476F44b11F5C942c58f4c8E3d0300E5710743585` (same as V5R/flagship/R7).

Deploy txs (deploy log): oracle
`0xa9ee970f6eb3a53672c924af17722fd32367426e1abbf3c3e7d4237aeef6af40`;
swap
`0xc8555d9229cf17f0bb2813406363cf2fb2d1bbd105a5df1df83f9268e6ae39ea`;
brain
`0xa4fa2494342f7e1e01d01c8dd1f216e45d8d44a0209883fe57c7607e365a7d0e`
(balance 2.20 lREACT at birth, exact); vault
`0xc22b08e40f2667692d736895f55a2888a3b174e490a10a7b786819a86aaee3ca`;
swap.setVault
`0x7ce31a10bcf412c087f6e4c631a88f69f087f691e8140e041cb143fafb9ef7fa`;
reactive.setVault
`0x3f4a1651ea811172586b71e1a86740ddfd82d1445c085d8c2ea2c749141eb63e`;
desk seed mint
`0x03023eb23d4a0d8877148ea77adc94fa2213f6f060b82d266e7cbbf11ca921fd`;
vault billing fund
`0x553cc3764a89106146d79650855f97577ac57deac1ba06800e50a0f2cfc597db`
(vaultETH 1e14).

R8 read-backs passed at deploy: oracle `owner() == dev`,
`pricePushers(dev) == true`; swap `MAX_PRICE_AGE() == 3600`,
`priceStale() == true` pre-push (never-pushed source reads stale —
fail closed); vault `lastSettledPrice() == 0`. Wiring verified by
reads: swap `priceSource` = oracle, brain `oracle` = oracle, brain
`updates` = 0 at birth, vault `totalShares` = 0 at birth, swap `vault`
= vault, brain `vault` = vault. Post-drive independent re-read
confirmed swap.priceSource/vault, brain.oracle/vault, vault.swap and
oracle.owner all still in-set. (Three guessed getters —
brain.callbackSender, vault.reactive, vault.callbackSender — do not
exist as public functions; the six executed callbacks, all arriving
via the proxy with the R8 vault in the payload, are the functional
proof of the proxy→vault path.) Flagship brain still points at its
Chainlink adapter, updates 3, lastAction 0 after wiring.

Sourcify — all four **exact_match** (creation + runtime), checked via
GET `/v2/verify/{jobId}` (authoritative; the repo mirror lagged at
check time): oracle job `08c4ec9e-ed2a-4fbf-9f3d-ab91cafff2d9`, swap
`903414ba-2a41-4f73-aeab-3785b4172530`, brain
`fdf0491a-476e-4136-8b3b-ef23759eb7a7`, vault
`29c69f78-1054-4aec-8584-56c626708d32` — all `completed: true`,
`creationMatch: exact_match`, `runtimeMatch: exact_match`.

## 2. Funding (faucet, 1 round)

Faucet round tx
`0x84ab3fa463987e120989b063b9eea397364c1f6b4635fcbde1fb411d812f7f87`
(Sepolia contract `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`,
`request(dev)`, 0.02 ETH, status 0x1, block 0xba7247). Dev Lasna
0.560026799981327322 → 2.660026799981327322 (+2.1 lREACT exact, top of
the known 2.0–2.1 variance; single part).
Dev Sepolia 0.590120705711001254 → 0.570118162910619834 (0.02 +
0.00000254280038142 gas). (The +45 s/+75 s settle reads were
interrupted by an exec service restart mid-wait; the credit was
confirmed by a later read at 2.660026799981327322, +2.1 exact.)

Funding math: have 2.6600268; need 2.20 attach + ~0.1801715 deploy gas
= 2.3801715; design gate 2.40 PASSED with margin 0.2600268. One round
covered it in either yield case (2.0 would have given 2.5600268).

## 3. Owner seed (public flow, dev wallet) + pre-drive attacks

Seed (seed log): wrap 0.002 ETH → WETH
`0xe1115ea09114cba021e0b0755f00d1c641c10275ee9c519f36b32a53dd52cbea`;
approve vault
`0xc2e748acbb66981c486785043343ac8d20d321abee9604b44ade8737179add04`;
vault `deposit(0.002 WETH)`
`0xd5423e683eadcd9625bb10f888133dfb9ad451dc8a84b5ad7a02664b3566ed7a`.
Shares read back exactly 1:1 — `sharesOf(dev)` =
2,000,000,000,000,000.

### Pre-drive attack tests — ALL FAILED as required

Stranger = burner C `0x0be5e7CC763F4B2aC524d7038e14fB60C6b05A6f`
(NOT allowlisted; verified `pricePushers(stranger) == false` first).
Every push was proven two ways: eth_call reverts `NotPusher`
(selector `0x31d7f16e`) AND the on-chain tx lands status `0x0`.

| Attack | Evidence |
|---|---|
| F1a pump (100x, $167,928) | eth_call reverts NotPusher; on-chain tx `0x7c9702874bb4bc73e175eaa5c599e0cf8cb734b7a3f090a09efa72747dc3f4e2` status 0x0. Oracle price still 0, brain updates still 0. (Two earlier diagnosis txs for the same attack also reverted 0x0: `0xfc3f570442afd2455b6506571f4a2739d2c757ad0d985d8203e60c886bc34cd7` block 0x3d0f81d, `0x8524acba0c0bd4ef7869c2e3bdf0adeee2ddac5c8eaad360ca994229db70583a`.) |
| F1a deposit after the reverted pump | Stranger deposits 0.0005 WETH at the true price: mints exactly 500000000000000 shares (fair 1:1); redeemAll returns exactly the 0.0005 WETH (WETH 1892402911115748 → 2392402911115748, exactly +0.0005 wrapped); vault back to dev seed only. NO THEFT. Wrap `0xc96eb7e67bab539113f843911c7ae4eac4cb3117b3cce3ea7401301af40e7ee8`, approve `0x431ae655255aa036ede8f5927c2beaa1b055be4a4680a2368984f5dd43363ce8`, deposit `0xec29483c4a4478db2d8f3cfb7967fb57439cc3e108f6c35167d266f532a89eab`, redeemAll `0x4625a6f78a2e29a3a495e501c5d05af7c735f5448e6c2d56f4a44744220517b4`. (Mixed-pool variant of the theft is forge-covered, `testF1_PumpedPriceCannotStealViaDeposit` + deviation-guard test; not run mid-replay because a mid-run deposit+redeem would perturb the exact managed-total accounting.) |
| F1b fake crash ($1500/$1200/$900) | All 3 pushes revert NotPusher on-chain: `0x13d1ddfa05e328baf12092788a15fa4b797504daa08489cef321b636f92d332d`, `0x8d8777ed38c0c315dab491c63417ba23155c3d60869cc555d3d00116d5f67a13`, `0xc9895e67ccc67be2a2a10de603d1e77f5cba94780a6dd39f95426680d9457b49` (all status 0x0). Oracle price 0, brain updates 0, lastAction HOLD, protectionCount 0 — NO EXIT FIRED. |
| F4 zero price | Stranger `setPrice(WETH, 0)` reverts NotPusher on-chain: `0x444ca3a5a6143f8e6f20e3fffff383b45ff25f8e0303096bc9333a22cacf53bc` status 0x0. Oracle price 0, brain updates 0 — the brain never saw the poison print. (Layer-2 brain-guard check runs post-drive, §7.) |
| F2 stale, never-pushed source | `priceStale() == true`, `priceAge() == 1795727470` (> 3600). eth_call of `swapRiskForSafe(1e15)` and `swapSafeForRisk(1e15)` FROM the vault address both return 0 and trace the `StalePriceRefused` event — fills REFUSED, never filled at a stale price. |

Flagship after the attacks: brain updates 3, lastAction 0, vault
totalShares 2.3e15 — untouched.

### Pre-drive prep

Dev seed redeemAll
`0xe9e5f572d6ff9a69ca93605ddf5bd0e1dfa9c72b85a42672b4c645de4b980ebc`
(vault back to totalShares 0, managed 0/0; dev WETH 0.00405 — seed
principal back exactly). Burner top-ups from dev: A +0.003 ETH
`0xe394fa15bcc41a39730d3bd98467f6f681996dc6e97dcf097de6d42ae59ef5c0`
(A ETH 0.003492435612572457), B +0.001 ETH
`0x61795cc719530fcea7cb00f4aad09000adc98b091bd8a100d5cc1af7d5a25ed9`
(B ETH 0.002994733547048452); C untouched (0.002991530226714542).
Pre-drive gates PASS: brain 0/0/2.20, vault empty/open, desk 1,000
mUSDC, swap still stale pre-first-push (first drive push clears it).

## 4. Firing sequence — observed vs mirror (exact match)

Feed: Binance ETHUSDT hourly closes, June 2022 crash, klines
indices 120–175, 56 pushes, one close per push, gaps ≥ 42 s
(driver floor 40 s; the mirror validated 35–60 s spacing). Start
11 Jun 2022 00:00 UTC $1,679.28; end 13 Jun 2022 07:00 UTC $1,283.46;
max drawdown −23.57%. Drive 21:13:01–21:56:13 UTC, one pass, no
resume needed.

Observed on-chain (every push asserted `updates` +1 and
`lastAction` == mirror; full per-push origin txs in
`release8-push-table.md`):

| Update | Close (UTC) | Price | Action | AnchorDD | Callback |
|---|---|---|---|---|---|
| 1–8 | 11 Jun 00:00–07:00 | $1,679.28 → $1,667.46 | HOLD ×8 | — | none, protectionCount 0 |
| 9 | 11 Jun 08:00 | $1,578.19 | **TRIM** | 5.5% | protectionCount 1 |
| 21 | 11 Jun 20:00 | $1,523.34 | **TRIM** | 7.7% | protectionCount 2 |
| 32 | 12 Jun 07:00 | $1,471.26 | **TRIM** | 9.9% | protectionCount 3 |
| 44 | 12 Jun 19:00 | $1,479.59 | **TRIM** | 8.3% | protectionCount 4 |
| 55 | 13 Jun 06:00 | $1,324.35 | **TRIM** | 17.0% | protectionCount 5 |
| 56 | 13 Jun 07:00 | $1,283.46 | **EXIT** | 19.5% | protectionCount 6, closed = true |

TRIM@9 origin
`0xced4f144ce82e85f5cee121e3adbc7cec08dc023e641707d0a1e71f1340e54bd`,
Base callback
`0xbb91058d76fa3a5c559a79383e6b260a00261660bd4a08caef6968011f71587c`,
Lasna reaction
`0x5c79307c1f9a9e4959417b8a42d3320e8788333e296fa9e5e297f8fe91e99226`.
EXIT@56 origin
`0x54d9e2f113da65f0cabc4ccdb91a86ee362c9e5d7e218b00c2b3b7a291d300a0`,
Base callback
`0x0d28a2f365073f709654a3799595d3ed4907230133202b6079e2f3da5e51b41a`,
Lasna reaction
`0x326df7941a5c19e44fac0e11c60accc7392c33688cced8d70bd2f3c4dd216714`.
All 6 Base callback txs status 0x1 (TRIM@21
`0xae3a203e1876b41cc31b733c8d6b798b0f1851717f7780d4179972c1879effa5`,
TRIM@32
`0x6edb8015e9417a099b7665d565f77f49cd1fecdab07e0a694206163ae5a01ab3`,
TRIM@44
`0xc98121a4f46d4e999a71c0efce76e6ab38651d0fcf1c36db08ec454ebfa8b438`,
TRIM@55
`0x617d101a1e5c2c2d2958836737d36da11d617abf14347a567671e502d63269f3`;
Lasna reactions TRIM@21
`0xbcae4730b921aac79ca660e0f75c69c4933d11f8b6638b77fb138d8c172d8c3e`,
TRIM@32
`0x938b2d55f512ba52b3be73941e08ca4038cf95e158fbe2d4d4a92053a0ba33b1`,
TRIM@44
`0xa9bb1bded775ee9f66b4af8541d3076ad006149ffb01e221bc858ab7c1704514`,
TRIM@55
`0xc85cc0867e05871076277e25c99754ace8ec81143781c15e20fd4a164edb9edd`).

Independent event-log verification (Lasna logs from the brain's
deploy block 0x8e49a2): 56 PriceSeen (updates 1–56 sequential,
prices == klines 120–175 ×1e10 exactly), 54 Decision events (votes
H/T/E 18/35/1 — mirror 54/54), 30 TrimSuppressed events,
6 CallbackRequested events (actions [1,1,1,1,1,2]), 6 EpisodeOpened
events whose episodeAnchor values match the mirror's predictions to
the wei ($1,670.70 / $1,650.76 / $1,632.69 / $1,613.21 / $1,595.55 /
$1,593.96). **Stop rule honoured: no update 57 was ever pushed
during the replay (R-2).**

Final chain state, re-read live after the run: brain updates 56,
lastAction 2 (EXIT), balance 0.252192 lREACT, anchorPeak
1,593,956,768,416,962,686,052 (identical to the R7 live set to the
wei); vault protectionCount 6, reriskCount 0, totalShares 0,
managedRisk 0, managedSafe 0, closed true,
`lastSettledPrice` $1,283.46 (set by the EXIT fill); desk WETH
0.006325, desk mUSDC 990.74943675; oracle last price $1,283.46.
Flagship brain after the run: updates 3, lastAction 0, balance
11.5613437 lREACT — untouched.

## 5. Deposits, fills, redemptions (all exact)

| Step | Action | Fill | Managed totals after |
|---|---|---|---|
| A deposit before push 1 | 0.003 WETH | 3,000,000,000,000,000 shares (1:1) | risk 0.003, safe 0 |
| TRIM@9 $1,578.19 | sell 0.0015 WETH | +2.367285 mUSDC | risk 0.0015, safe 2.367285 |
| B deposit after TRIM@9 | 0.002 WETH | 2,000,000,000,000,000 shares | risk 0.0035, safe 2.367285 |
| TRIM@21 $1,523.34 | sell 0.00175 WETH | +2.665845 mUSDC | risk 0.00175, safe 5.03313 |
| TRIM@32 $1,471.26 | sell 0.000875 WETH | +1.2873525 mUSDC | risk 0.000875, safe 6.3204825 |
| A partial redeem | 1e15 shares | +0.000175 WETH +1.2640965 mUSDC | risk 0.0007, safe 5.056386 |
| TRIM@44 $1,479.59 | sell 0.00035 WETH | +0.5178565 mUSDC | risk 0.00035, safe 5.5742425 |
| C deposit after TRIM@44 | 0.0015 WETH | 1,457,221,886,906,302 shares (floored) | risk 0.00185, safe 5.5742425 |
| TRIM@55 $1,324.35 | sell 0.000925 WETH | +1.22502375 mUSDC | risk 0.000925, safe 6.79926625 |
| EXIT@56 $1,283.46 | sell 0.000925 WETH | +1.1872005 mUSDC | risk 0, safe 7.98646675, closed |
| Final redeemAll A | 2e15 shares | +2.926934955370680890 mUSDC | safe 5.05953179462931911 |
| Final redeemAll B | 2e15 shares | +2.926934955370680890 mUSDC | safe 2.13259683925863822 |
| Final redeemAll C | 1,457,221,886,906,302 shares | +2.132596839258638220 mUSDC (full-redemption remainder) | 0 / 0 / 0 |

Key txs (driver log): A deposit wrap
`0x84caf8f71cdef228dfb1ad4ef9e32161b8b2844811e85d7e2b3e741aa255874f`,
approve
`0x686b58e85cb5267b1c76bd5eb57f3c77877723804bcb8fe5a06df52abe1d2738`,
deposit
`0xddfea5f20639fce545531252d6e1007e614b0079d21048f4285f07906d1ff1c6`;
B deposit wrap
`0xb5f8e5042b2d08447783aa664ecd987d5f618caa42903863017ac901b359a25d`,
approve
`0x878ca98473313e8ef381c1327b24550eeb7e394868c335a5e6fdccf3e114a0c0`,
deposit
`0x7aa82a2143922bb0f7aa4c8637eb93b010e981dc6ec53220d64107b5a5df1274`;
A partial redeem
`0x67953c9ad33ebecb00e81ec9971a8eb2971002692c50a830619f238f1724f2dc`;
C deposit wrap
`0xea8b6e71e51a0187b65ee6bb30283c0cba8ba0a8f7ef302e61d0222fe0da8492`,
approve
`0x9159fa06a9ae17445ab36ff97db291ec3f14a85618b500dec1bfb674b1eb85a6`,
deposit
`0xd4949139d7a5f8315101be62c28a80142893b0aae346474884811c73668a6570`;
A redeemAll
`0x9d8580a7d3e0e76edbd82d60f196ba4e4b8f7477a4e55db079d45e836ef34e3b`;
B redeemAll
`0x423c6d5e8ee09ed1eedbac5342d02ac1474edf1e50d22177199a5d3e0d650aa8`;
C redeemAll
`0x9939f202b1c0d09edc4535ebf0c8e29a5718d2c7421765cdf0d2be06bcb4cd65`.

All fills verified two ways: the driver's `expect_managed`
assertions at every callback (design §3 table), and the WETH /
mUSDC balance deltas in the redemption log lines, recomputed
independently after the run: A partial +0.000175 WETH +1.2640965
mUSDC; A redeemAll +2.926934955370680890 mUSDC; B redeemAll
+2.926934955370680890 mUSDC (identical to A — the fairness
property); C redeemAll +2.132596839258638220 mUSDC.

## 6. Reconciliation (independent recomputation)

- Share mints: A 3e15 (1:1), B 2e15, C 1,457,221,886,906,302
  (floored formula) — all exact.
- Every fill from the desk formula at the pushed price — all
  exact (driver asserts + §5 table).
- Final payouts sum: 2.926934955370680890 + 2.926934955370680890 +
  2.132596839258638220 = 7.98646675 mUSDC = pre-sequence
  managedSafe, to the wei.
- Conservation: WETH — users 0.000175 (A partial) + desk 0.006325
  = 0.0065 deposited. mUSDC — users 9.25056325 (partial 1.2640965
  + finals 7.98646675) + desk 990.74943675 = 1,000 seeded.
- End state: totalShares 0, managedRisk 0, managedSafe 0, raw
  vault balances 0/0 — clean reset.

## 7. Post-drive attack tests — COMPLETE, all failed as required

`tools/attack_release8_post.sh` (log `release8-attacks-post.log`).
Entry gates re-passed on launch (brain updates 56, lastAction 2,
vault closed + empty). The script waited out the 3600 s staleness
bound from the last drive push (idx 175, 21:55:12 UTC, epoch
1795730112; deadline 22:56:12 UTC), then:

| Attack | Evidence |
|---|---|
| F2 time-based stale (genuine 3600 s halt, no pushes since 21:55:12 UTC) | At 22:56:17 UTC: `priceStale() == true`, `priceAge() == 3675` (> 3600). eth_call of `swapRiskForSafe(1e15)` and `swapSafeForRisk(1e15)` FROM the vault address both return 0 and trace the `StalePriceRefused` event — fills REFUSED after a real halt, never filled at the stale price. |
| F4 brain guard, layer 2 (dev is allowlisted) | Dev pushes price 0: tx `0xef766a2843729c8e720ef2f5a71da9437459ed560190ebcb09a6d724c3f9565e` (the oracle stores 0 — the allowlisted push succeeds). 45 s later brain updates still 56 — the poison log was consumed, never ingested, NO BRICK. Dev then pushes a legitimate price, $1,600 (mirror-chosen HOLD; mirror says update 57 votes HOLD with no callback): tx `0x33ad39bf5072f998c8b0b27d96c42f18b3cdfbe11f0b4f0e33a47a471045e354`. Brain advanced to 57, lastAction HOLD, protectionCount still 6 — BRAIN ALIVE after the poison print. Independently re-read after the run: updates 57, lastAction 0, balance 0.2042991 lREACT, oracle last price $1,600, vault prot 6. |

Flagship after the post-drive tests: brain updates 3, lastAction 0,
vault totalShares 2.3e15 — untouched. The post-drive pushes (0 and
$1,600) are POST-REPLAY phase: they advanced updates 56 → 57 and are
recorded here, separately from the rehearsal final state in §4–§6
(updates 56).

## 8. Invariants

INV-1 (backing: raw ≥ managed at every snapshot) — asserted by
the driver at every snapshot, all pass. INV-2 (clean reset) —
final state above. INV-3 (exact reconciliation) — §6, all lines
exact. INV-4 (fraction stability: equal shares → equal payouts)
— A and B final payouts identical to the wei. INV-5 (no rounding
theft) — C's floored shares, full-redemption remainder exact.
INV-6 (donation neutrality) — NOT exercised on-chain in this run;
holds by construction + unit tests (same as R7). INV-7 (interface
parity with V4) — same code, unchanged. INV-8 (firing proof) —
the June half: TRIM and EXIT callbacks executed on-chain with real
token transfers, each moving managed totals by the desk fill at
the pushed price; EXIT left managedRisk = 0, closed = true, and
the full redemption paid out exactly the managed totals. The
RERISK half of INV-8 is not claimed for this June run (no re-risk
in the window) — it was proven on the R7 Aug stretch set.
NEW in R8: INV-5 holds unconditionally again (allowlist +
deviation guard); liveness holds (one bad print can never wedge
the brain — F4 guard, §7 pending); no trade/deposit ever executes
on a price older than 3600 s (F2, §3 + §7 pending).

## 9. Spend (measured)

| Item | Amount |
|---|---|
| lREACT consumed by brain (56 reacts + 6 callbacks) | 1.947808 (attach 2.20, left 0.252192) |
| Sepolia ETH (faucet) | 0.02000254280038142 (0.02 + 2542800381420 wei gas) |
| Base Sepolia ETH, drive gas (56 pushes + 13 user txs) | 0.000015057422953605 (dev + A + B + C ETH+WETH deltas across the drive minus desk WETH 0.006325; R7 live: 0.000013932126411831) |
| Base Sepolia ETH, vault billing draw (6 callbacks) | 0.000007696158086104 (vault ETH 0.0001 funded at deploy → 0.000092303841913896 left; R7: 0.000007177524085038) |
| Base Sepolia ETH, total burned (drive) | 0.000022753581039709 |
| Base Sepolia ETH, deploy gas | 0.000119431628099283 (dev Base 0.059334075233967525 → 0.059214643605868242) |
| Lasna lREACT, deploy gas (ex-attach) | 0.181813700001818137 (dev Lasna 2.660026799981327322 → 0.278213099979509185, of which 2.20 was the attach; R7: 0.1801715) |
| Burner top-ups (pre-drive, from dev) | 0.004 ETH (A +0.003, B +0.001) |

Note on the brain burn: 1.947808 vs the R7 June-core 1.9471002 —
+0.0007078 (+0.036%). The design expected the F3 fix to reduce
consumption, but the patched `react()` costs marginally more per
call (zero/absurd guard + changed EXIT-branch writes); the +13%
headroom (2.20 attach) absorbed it with 0.252192 to spare, against
R7's 0.0528998. No gate failed — the brain never ran dry and
firing was identical.

Dev balances after the drive: Base Sepolia
0.053202052373163551 ETH + 0.00405 WETH; Lasna 0.278213099979509185
lREACT (unchanged by the drive — the brain spends its own
balance); Sepolia 0.570118162910619834 ETH.

## 10. Incidents (V5R §7 style)

1. **Attack script aborted twice on its own checks (tooling-side,
   no chain impact).** First: `cast send --async --json` — with
   `--async`, cast prints the bare tx hash, not JSON, so the
   JSON parse failed. Diagnosis: manual `--gas-limit 100000
   --async` broadcast proved the fix (that tx,
   `0xfc3f570442afd2455b6506571f4a2739d2c757ad0d985d8203e60c886bc34cd7`,
   landed status 0x0 as required). Second: the F1a WETH check
   compared post-redeem WETH to pre-wrap WETH, forgetting the
   wrap itself adds 0.0005 WETH — the round-trip was in fact exact
   (+0.0005 wrapped). Both were script bugs, not chain findings;
   the third run completed all pre-drive attacks. The first abort
   also surfaced the real mechanism: plain `cast send` refuses a
   reverting tx at gas estimation (`NotPusher(0x0be5e7CC...)`),
   so reverting attack txs need an explicit `--gas-limit`.
2. **Post-drive script launched twice with wrong parameters
   (tooling-side, no chain impact).** First launch used the wrong
   date (2026-11-27 instead of 2026-11-26) for the last-push epoch
   — a ~24 h wait. Killed before it did anything (a `pkill -f`
   also SIGTERM'd its own shell; noted, not repeated). Second
   launch failed `Permission denied` — the script was never
   `chmod +x`'d. Third launch correct: waiting 3409 s to the
   22:56:12 UTC deadline. No chain state was touched by the bad
   launches.
3. **Exec service restart killed the post-drive wait mid-sleep
   (tooling-side, no chain impact).** At ~22:36–22:37 UTC the
   service restarted and the detached `sleep 3409` was gone with
   it (setsid/nohup did not survive this restart). Relaunched at
   22:37:27 UTC; the script is idempotent — it re-passed its entry
   gates (brain 56, vault closed + empty) and recomputed the
   remaining wait (1106 s) from the stored last-push epoch, then
   completed F2 + F4 cleanly. Lesson: a long `sleep` inside a
   detached script is not restart-proof on this VM; the epoch
   arithmetic that recomputes the remaining wait is what saved
   the run.
3. **Sourcify repo mirror lagged at check time (record-keeping
   only).** `repo.sourcify.dev/.../full_match/.../metadata.json`
   404'd minutes after submission, and `/v2/contracts/` 404'd
   (wrong path — the lookup is `/v2/contract/`, singular). The
   authoritative job endpoint GET `/v2/verify/{jobId}` returned
   `completed: true, exact_match` for all four; that is the
   verification evidence used here.

## 11. What this proves / what it does not

The June core proves the fixed set fires exactly as the mirror
predicted, on real June 2022 crash data, with real token transfers
and a wei-exact multi-user redemption — and that the F1/F4
allowlist stops a stranger's pump, fake crash and zero-price
pushes cold (all reverted on-chain, no state effect), while the
F2 staleness bound refuses fills on a never-pushed source. What
it does not prove: a re-risk on this set (June has none), a
mixed-pool share-theft attempt on-chain (forge-covered; the
on-chain F1a ran on the seed-only pool), or wall-clock behaviour
(the replay compresses 56 market hours into ~43 minutes of
driving). Nothing public was touched by this run: no DoraHacks
edit, no video, no git push, no README/docs change. This is a
rehearsal set, NOT the live set — no live deployment was made.
