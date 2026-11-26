# Sentinel Release 7 — rehearsal record (June core + Aug stretch)

> **RECONSTRUCTION NOTICE — 2026-11-27 ~02:40 WIB.** This file was
> accidentally overwritten during the live-drive write-up (a write call
> replaced the whole file instead of appending the new section). The
> June-core and Aug-stretch sections below were rebuilt the same night
> from the surviving primary sources: the driver logs, deploy logs,
> push tables, the mirror plan (`r7-stretch-plan.txt`), the driver
> scripts, and the rehearsal coordinator's report. Every claim was
> re-checked against those sources; the final chain states of both
> rehearsal sets and all eight Sourcify verifications were re-read
> live from chain on 27 Nov. No number in the rebuilt sections comes
> from memory alone. The original wording of the lost sections is
> gone; the facts are the same. The live-drive section at the end is
> the original text, preserved verbatim.

---

# Sentinel Release 7 — June core rehearsal record

Status: **JUNE CORE COMPLETE — PASS. All checks exact to the wei.**
Run 2026-11-26, 15:05–15:50 UTC (22:05–22:50 WIB) on the fresh
June-core rehearsal set (same V5 code as the flagship, no code
changes). Driver: `tools/rehearse_release7.sh` (main pass, updates
1–54 plus the idx-174 push) + `tools/rehearse_release7_resume.sh`
(resume: re-verified the TRIM@55 state from chain, pushed update 56
and ran the final redemption). Logs: goal
`hidden_files/release7-deploy.log`, `release7-driver.log`,
`release7-driver-resume.log`, `release7-push-table.md` (all 56 origin
+ reaction txs).

Pre-drive gates passed before any push: mirror prediction from
`RELEASE7-DESIGN.md` §6 (votes H/T/E 18/35/1, fires TRIM@9/21/32/
44/55, EXIT@56, 30 suppressed, 0 cooldown blocks). Burners A/B/C
verified with the choreography balances (A 0.003, B 0.002, C 0.0015
WETH plus gas). Dev preflight (deploy log): Base Sepolia
0.064233236539342257, Lasna 2.802646799986753522 (after 1 faucet
round before the deploy: 0.02 Sepolia ETH → +2.1 lREACT, dev Lasna
0.702647 → 2.802647; that round's tx hash was not separately
logged). Flagship brain before and after: updates 3, lastAction 0 —
untouched.

## 1. The set

| Contract | Chain | Address |
|---|---|---|
| MockPriceOracle | Base Sepolia | `0xAdEBD7a0C3129020c0E807673848E812daCc3409` |
| SentinelSwapV2 | Base Sepolia | `0xa5400474d07bdC26E5591589D7EaA1824065771E` |
| SentinelReactiveV5 (brain, mock origin, 2.00 lREACT attached) | Lasna | `0x4030b231B348B212175c0D218735cf82Ff2f0f5a` |
| SentinelVaultV5 | Base Sepolia | `0xf68e7fC6d496E8ad253ee0B7D74059B9e8A25237` |

Reused shared contracts: WETH
`0x4200000000000000000000000000000000000006`, MockUSDC
`0x96E467Ff7958851d307D28118EBAAD333CAb85B2`, callback proxy
`0x476F44b11F5C942c58f4c8E3d0300E5710743585` (same as V5R/flagship).

Deploy txs (deploy log): oracle pre-deployed (first deploy attempt
aborted on a `forge create` parse failure — the oracle had already
landed, so it was reused, no duplicate deployed); swap
`0x440776943df3319cf97c85d38f426ed4aaded06d857f14dfba1c8ce51dd74c71`;
brain
`0xd2789af145b984ae772057bd860e222a05c52939e567a485739859087651fde4`
(balance 2.00 lREACT at birth); vault
`0x898dbf7b0d281c224a63829d63f83070deb07d847c897f59090ceaa67ffa0ab9`;
swap.setVault
`0xd12d7d8007b5217a5333a395b48cad1aacd48ce1e75d7be010c932fe22d59bdd`;
reactive.setVault
`0xddc68261ccabc055cc403823ad4880f60520c06aee14d0522e646aba29f2f0f7`;
desk seed mint
`0x05570393412aefe06b3c76d38497fa3b98c8ae57232bfc302712f711f215d426`;
vault billing fund
`0xa174c0d7df3aff8dc36f9aa4346771cb8997e1d8f5739dda6e4e0a7c4b508464`
(vaultETH 1e14).

Sourcify — all four **exact_match** (creation + runtime), re-verified
by me on 27 Nov via the v2 endpoint: oracle matchId 60005983, swap
60005988, brain 60005994, vault 60005996.

## 2. Firing sequence — observed vs mirror (exact match)

Feed: Binance ETHUSDT hourly closes, June 2022 crash, klines
indices 120–175, 56 pushes, one close per push, gaps ≥ 42 s
(driver floor 40 s; the mirror validated 35–60 s spacing). Start
11 Jun 2022 00:00 UTC $1,679.28; end 13 Jun 2022 07:00 UTC $1,283.46;
max drawdown −23.57%.

Observed on-chain (every push asserted `updates` +1 and
`lastAction` == mirror; full per-push origin + Lasna reaction txs
in `release7-push-table.md`):

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
`0x41c0dcdb557bbd618c0be8caa6726cd354fb0a1985e57c17b8072f8412da2ad1`,
reaction
`0x48052eb83c141a896f33658762c340a95d7a5c8286cceefefad2fcfe5503b0bf`.
EXIT@56 origin
`0x58bfedff8e8c6cce2d1474f6637a6334984cbf8a62c6e033564655df524330af`,
reaction
`0x76f57e7e0048c51e92a95e706c670e65722f32e9ff83e06c26c755ed88c72f9b`.

**Stop rule honoured: no update 57 was ever pushed (R-2).**

Final chain state, re-read live on 27 Nov: brain updates 56,
lastAction 2 (EXIT), balance 0.0528998 lREACT; vault
protectionCount 6, totalShares 0, closed true; desk WETH 0.006325,
desk mUSDC 990.74943675 (same values as the resume log's final
snapshot).

## 3. Deposits, fills, redemptions (all exact)

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

Key txs (driver logs): A deposit wrap
`0x8788cec5b7f3d4d3ddca6ea11cd2f982dedecf5e145334b3c61f8035e59dd79b`,
approve
`0x1e8f331aa13f559a789944198369306d337c59678d2d2639b3609a25551bd72d`,
deposit
`0x2cfbfc4f9309f1f0ffb4a0bbcb70c4816edd672cff47dc87795120d9319818f5`;
B deposit deposit
`0xac87b59dfe1889a4c2fa5953ee7ab983229a44cae5347ce185ae134b1d2401c8`;
A partial redeem
`0x614625002674a7fbbee1623d1dfce95184bcc67cb1c95bbe5cbd060bdc7e0257`;
C deposit wrap
`0x4703604e3a3305067156e4a61b4533e7a416be2190a02a0ddf3ea990fa9cb860`,
approve
`0xcf85636a0957f07037260bb41cde5ff5a79c2ebde392335613b2ca555438bf0a`,
deposit
`0x781fbeb6e5945cd4ebbbb43749e94a9f19366b8806053b3255107c74d8ffa8fb`;
A redeemAll
`0x4c8e27ae8691ceb3f1140e054c739d7477fbd3c68782af4d7c17140319766e7d`;
B redeemAll
`0xd99389d7d888e9cc613e461829c61d6322d226018ee5ce13cc08cca98b0d8522`;
C redeemAll
`0xcd4d12f5db654e90b1af82237da15e4d8983e5f97eb2b91d16f416c5e4b308c9`.

All fills verified two ways: the driver's `expect_managed`
assertions at every callback (design §3 table), and the MockUSDC /
WETH `Transfer` events in the four redemption receipts,
recomputed independently after the run: A partial +0.000175 WETH
+1.2640965 mUSDC; A redeemAll +2.926934955370680890 mUSDC; B
redeemAll +2.926934955370680890 mUSDC (identical to A — the
fairness property); C redeemAll +2.132596839258638220 mUSDC.

## 4. Reconciliation (independent recomputation)

- Share mints: A 3e15 (1:1), B 2e15, C 1,457,221,886,906,302
  (floored formula) — all exact.
- Every fill from the desk formula at the pushed price — all
  exact (driver asserts + §3 table).
- Final payouts sum: 2.926934955370680890 + 2.926934955370680890 +
  2.132596839258638220 = 7.98646675 mUSDC = pre-sequence
  managedSafe, to the wei.
- Conservation: WETH — users 0.000175 (A partial) + desk 0.006325
  = 0.0065 deposited. mUSDC — users 9.25056325 (partial 1.2640965
  + finals 7.98646675) + desk 990.74943675 = 1,000 seeded.
- End state: totalShares 0, managedRisk 0, managedSafe 0, raw
  vault balances 0/0 — clean reset.

## 5. Invariants

INV-1 (backing: raw ≥ managed at every snapshot) — asserted by
the driver at every snapshot, all pass. INV-2 (clean reset) —
final state above. INV-3 (exact reconciliation) — §4, all lines
exact. INV-4 (fraction stability: equal shares → equal payouts)
— A and B final payouts identical to the wei. INV-5 (no rounding
theft) — C's floored shares, full-redemption remainder exact.
INV-6 (donation neutrality) — NOT exercised on-chain in this run;
holds by construction + unit tests (same as the V5R rehearsal).
INV-7 (interface parity with V4) — same code, unchanged.
INV-8 (firing proof) — the June half: TRIM and EXIT callbacks
executed on-chain with real token transfers, each moving managed
totals by the desk fill at the pushed price; EXIT left
managedRisk = 0, closed = true, and the full redemption paid out
exactly the managed totals. The RERISK half of INV-8 is not
claimed for this June run (no re-risk in the window) — it was
proven on the Aug stretch set below.

## 6. Spend (measured)

| Item | Amount |
|---|---|
| lREACT consumed by brain (56 reacts + 6 callbacks) | 1.9471002 (attach 2.00, left 0.0528998 — re-read live 27 Nov) |
| Sepolia ETH (faucet) | 0.02 (1 round before deploy → +2.1 lREACT) |
| Base Sepolia ETH, drive gas (56 pushes + 13 user txs) | 0.0001296 (coordinator's accounting — includes the set deploy gas in the row below; do not add the two rows) |
| Base Sepolia ETH, deploy gas | 0.000118444208816999 (dev Base 0.064233236539342257 → 0.064114792330525258) |
| Lasna lREACT, deploy gas (ex-attach) | 0.1801715 (dev Lasna 2.802646799986753522 → 0.622475299984951807, of which 2.00 was the attach) |

## 7. Incidents (V5R §7 style)

1. **First deploy attempt aborted on a `forge create` parse
   failure (tooling-side, no chain impact).** The deploy script
   could not parse forge's output for the MockPriceOracle deploy —
   but the oracle had already landed, so the second attempt reused
   `0xAdEBD7a0C3129020c0E807673848E812daCc3409` and no duplicate
   was deployed. A third attempt (same reuse) then completed the
   set.
2. **Main driver aborted after the idx-174 push — its own
   expected-action table was short one token (tooling-side, no
   chain impact).** The `EXPECTED_ACTIONS` string in
   `tools/rehearse_release7.sh` had 55 tokens (11 ones in the
   44–55 run instead of 12), so position 55 read as EXIT(2) while
   the chain correctly voted TRIM(1). Abort message: "update 55
   (idx 174): lastAction 1 != mirror 2". The push HAD landed
   (origin tx
   `0xbcce7ace3551198f38515847ac12a3d244f40da6553b058f7777a9ff9880fc43`)
   and the TRIM@55 callback HAD fired (protectionCount 5,
   managed totals exact). No state was corrupted and no price was
   pushed twice. The resume driver re-verified state from chain +
   the design table (updates 55, prot 5, oracle history 55
   PriceUpdated events, managed totals matching design at
   TRIM@55) and completed update 56 + the final redemption. The
   table on disk now is the fixed 56-token version.

## 8. What this proves / what it does not

The June core proves the de-risk half of Release 7 on the
rehearsal set: TRIM and EXIT callbacks executed on-chain with real
token transfers, on real June 2022 crash data, with a wei-exact
multi-user redemption. What it does not prove: a re-risk on this
set (June has none — see the Aug stretch below), or wall-clock
behaviour (the replay compresses 56 market hours into ~45 minutes
of driving; the public wording in design §2c says exactly that).
Nothing public was touched by this run: no DoraHacks edit, no
video, no git push, no README/docs change.

---

# Sentinel Release 7 — Aug stretch rehearsal record

Status: **AUG STRETCH COMPLETE — PASS. All checks exact to the wei.**
Run 2026-11-26, 16:13–17:41 UTC (23:13–00:41 WIB) on a fresh
second set (same V5 code, no code changes). Driver:
`tools/rehearse_release7_stretch.sh` (main pass, updates 1–41) +
`tools/rehearse_release7_stretch_resume.sh` (resume, updates 42–103
+ final redemption). Logs: goal
`hidden_files/release7-stretch-deploy.log`,
`release7-stretch-driver.log`,
`release7-stretch-driver-resume.log`,
`release7-stretch-push-table.md` (all 103 origin + reaction txs),
`release7-stretch-callbacks.txt` (all 11 callback events),
`r7-stretch-plan.txt` (mirror prediction + simulated episode).

Pre-drive gates passed before any push: mirror prediction from
`r7-stretch-plan.txt` (votes H/T/E 63/36/2, fires 9, suppressed 29,
cooldown 0, rerisk 2). Faucet: 2 rounds before the deploy, txs
`0x471b845a595d4be3ab0683ac048faabfd240c954b71e0dca6d538b063a1b0d65`
and
`0x7f5a041fa4249863269fdc6fcb9968e7b51fd217a1218f04225875812d3c6e2a`
(0.04 Sepolia ETH → +4.2 lREACT; dev Lasna 0.6224752... →
4.8224752...; dev Sepolia 0.670146133711484386 →
0.630146133711484386). Dev preflight (deploy log): Base Sepolia
0.064103599581789875, Lasna 4.822475299984951807, flagship brain
updates 3, lastAction 0, balance 11.5613437 lREACT — untouched
before and after.

## 1. The set (fresh second set, same V5 code, no new contracts)

| Contract | Chain | Address |
|---|---|---|
| MockPriceOracle | Base Sepolia | `0x0AE8fe8884580c6F6D5a5683DE42b241584EA304` |
| SentinelSwapV2 | Base Sepolia | `0x46f61e3ce5D9c441Df9DC6138f67d468524986a4` |
| SentinelReactiveV5 (brain, mock origin, 4.00 lREACT attached) | Lasna | `0x88B53f2Aa7e5056EB21616498aC926d7AD837851` |
| SentinelVaultV5 | Base Sepolia | `0x4998d509123aFdf6F2911359906d7df801BF062e` |

Reused shared contracts: WETH
`0x4200000000000000000000000000000000000006`, MockUSDC
`0x96E467Ff7958851d307D28118EBAAD333CAb85B2`, callback proxy
`0x476F44b11F5C942c58f4c8E3d0300E5710743585` (same as V5R/flagship).

Deploy txs (deploy log): oracle
`0x3a15ba9f276509e4b83e4c6c2582de065bee08d5c217917248e3238acce16f05`;
swap
`0xd45480d6d97090e8a7176af44f1c73899d4e4bccbc44210477d399b9240bee60`;
brain
`0x478d10ac8c6b8bd1f5893d13a2af13befb96a841e8273eb183364734c68793c7`
(balance 4.00 lREACT at birth); vault
`0x6cc3feedc47a8f0abb24718fb89b129616905e46a62c2879580c02885e922d8b`;
swap.setVault
`0x33f5c63b4d9b6d5bbbeedbab940669c57f41f154962af691f82fa2c1b9ca15d4`;
reactive.setVault
`0x1136b16350a650265585bfd6c0dffa225e42433e9d8d0ab87475cf6eaffcaf49`;
desk seed mint
`0x320355b630d0f03317c2979b2882a5c3a13f1da08a159a0fad75bdfe7382d65b`;
vault billing fund
`0x23b56ff1bf1da36a5a9d222e7028ffdffdd43914b204d685cbc6dbb883a90991`
(vaultETH 1e14).

Sourcify — all four **exact_match** (creation + runtime), re-verified
by me on 27 Nov via the v2 endpoint: oracle matchId 60009189, swap
60009190, brain 60009191, vault 60009195 (the deploy log also holds
the four verify-job IDs 3307a7ee-..., d222d3ce-..., f61ffc38-...,
083ad565-...).

## 2. Firing sequence — observed vs mirror (exact match)

Feed: Binance ETHUSDT hourly closes, Aug 2024 window, klines
indices 280–382, 103 pushes, one close per push, gaps ≥ 42 s
(driver floor 40 s). Start 04 Aug 2024 00:00 UTC $2,810.80; end
08 Aug 2024 07:00 UTC $2,707.67.

Observed on-chain (every push asserted `updates` +1 and
`lastAction` == mirror; full per-push origin + Lasna reaction txs
in `release7-stretch-push-table.md`):

| Update | Close (UTC) | Price | Action | Callback |
|---|---|---|---|---|
| 1–7 | 04 Aug 00:00–06:00 | $2,810.80 → $2,722.17 | HOLD ×7 | none, protectionCount 0 |
| 8 | 04 Aug 07:00 | $2,688.92 | **TRIM** | protectionCount 1 |
| 15 | 04 Aug 14:00 | $2,268.21 | **EXIT** | protectionCount 2, closed = true |
| 17 | 04 Aug 16:00 | $2,325.44 | TRIM (no-op) | protectionCount 3, totals unchanged |
| 21 | 04 Aug 20:00 | $2,228.21 | EXIT (no-op) | protectionCount 4, totals unchanged |
| 27 | 05 Aug 02:00 | $2,374.41 | TRIM (no-op) | protectionCount 5, totals unchanged |
| 41 | 05 Aug 16:00 | $2,460.51 | TRIM (no-op) | protectionCount 6, totals unchanged |
| 55 | 06 Aug 06:00 | $2,475.40 | TRIM (no-op) | protectionCount 7, totals unchanged |
| 68 | 06 Aug 19:00 | $2,473.01 | TRIM (no-op) | protectionCount 8, totals unchanged |
| 79 | 07 Aug 06:00 | $2,356.46 | TRIM (no-op) | protectionCount 9, totals unchanged |
| 97 | 08 Aug 00:00 | $2,585.83 | **RERISK** (tranche 1) | protectionCount 10, reriskCount 1 |
| 102 | 08 Aug 05:00 | $2,640.90 | **RERISK_FINAL** (tranche 2) | protectionCount 11, reriskCount 2 |
| 103 | 08 Aug 07:00 | $2,707.67 | HOLD | last push |

All 7 no-ops confirmed on-chain: the vault was closed after
EXIT@15, so each post-EXIT TRIM/EXIT callback fired (prot kept
counting) but moved no tokens — managed totals verified unchanged
at every no-op snapshot. C deposited after TRIM@79 (vault
re-opened by the deposit: closed false, risk 0.0015). **Stop rule
honoured: no update 104 was ever pushed.**

All 11 callback events (`release7-stretch-callbacks.txt`, Base
Sepolia txs, managedRisk before → after):

| # | Action | Callback tx | Risk before → after |
|---|---|---|---|
| 1 | TRIM@8 | `0xebdcf3f363b1e343893a439ed9513aaca85646fb6d15c11e30b81042fc6e8de3` | 0.003 → 0.0015 |
| 2 | EXIT@15 | `0x0b090e44c1e02a95a1bfa2fd4c085d91ef7d6a0db1db06b4240337dacc7ef6da` | 0.0035 → 0 |
| 3 | TRIM@17 no-op | `0xa415ecc13ce5c3267ca9409768c02bac943781cee29d0f6280fdbe16ab3bb562` | 0 → 0 |
| 4 | EXIT@21 no-op | `0x2d65cc859daad5fabcfd72f9ba19f6f5e4345c6bba53a20bb10f6a3bb6620948` | 0 → 0 |
| 5 | TRIM@27 no-op | `0x0feaa1678dd01459b2ec448c9e19cc82ebd80ed8fb3184f4c765faa84d2d3769` | 0 → 0 |
| 6 | TRIM@41 no-op | `0xc001c052f104eb83875bc2a83c159f1f4c600956db232e5ee92cb6396e257b6e` | 0 → 0 |
| 7 | TRIM@55 no-op | `0x7c8b421c0de2d931b17387db59c569384604bf47632e0d3538e4ed2bd17d0b94` | 0 → 0 |
| 8 | TRIM@68 no-op | `0xd9631d79999cc27404d7e1cebeecc8ea4fc663be6cb5ba1fbbe3a3a2ed69c443` | 0 → 0 |
| 9 | TRIM@79 no-op | `0xc4ae6e4b1a96b5ca5e23cbd6398772fec70f2305ac95f80949a32be38c7ba549` | 0 → 0 |
| 10 | RERISK@97 | `0xe54244cfbd99f26034213a051a7c2ffc50130c9afd10c549d3859bd2375bd932` | 0.0015 → 0.003351957011868529 |
| 11 | RERISK_FINAL@102 | `0x1c61bcfb19eb378e450fd0006f8e4a93cd3b0c314e7c04e272dda4fed7b05ac0` | 0.003351957011868529 → 0.005165295646424930 |

Final chain state, re-read live on 27 Nov: brain updates 103,
lastAction 0, balance 0.4067646 lREACT; vault protectionCount 11,
reriskCount 2, totalShares 0, closed false (re-armed by re-risk,
correct); desk WETH 0.001334704353575070, desk mUSDC 997.605577.

## 3. Deposits, fills, redemptions (all exact)

| Step | Action | Fill | Managed totals after |
|---|---|---|---|
| A deposit before push 1 | 0.003 WETH | 3,000,000,000,000,000 shares (1:1) | risk 0.003, safe 0 |
| TRIM@8 $2,688.92 | sell 0.0015 WETH | +4.03338 mUSDC | risk 0.0015, safe 4.03338 |
| B deposit after TRIM@8 | 0.002 WETH | 2,000,000,000,000,000 shares | risk 0.0035, safe 4.03338 |
| EXIT@15 $2,268.21 | sell 0.0035 WETH | +7.938735 mUSDC | risk 0, safe 11.972115, closed |
| A partial redeem | 1e15 shares | +2.394423 mUSDC | risk 0, safe 9.577692 |
| TRIM@17 / EXIT@21 / TRIM@27 / TRIM@41 / TRIM@55 / TRIM@68 / TRIM@79 | no-ops | 0 | risk 0, safe 9.577692 |
| C deposit after TRIM@79 | 0.0015 WETH | 1,476,217,861,255,091 shares (floored) | risk 0.0015, safe 9.577692 |
| RERISK@97 $2,585.83 | spend 4.788846 mUSDC | +0.001851957011868529 WETH | risk 0.003351957011868529, safe 4.788846 |
| RERISK_FINAL@102 $2,640.90 | spend 4.788846 mUSDC | +0.001813338634556401 WETH | risk 0.005165295646424930, safe 0 |
| Final redeemAll A | 2e15 shares | +0.001886446367654591 WETH | risk 0.003278849278770339, safe 0 |
| Final redeemAll B | 2e15 shares | +0.001886446367654591 WETH | risk 0.001392402911115748, safe 0 |
| Final redeemAll C | 1,476,217,861,255,091 shares | +0.001392402911115748 WETH | 0 / 0 / 0 |

Key txs (driver logs): A deposit wrap
`0x191707fb91cd906d3ce7bcdddf880be6d59ed9ac6b45d5290490f92af5a06ca1`,
approve
`0x8d1511b55fd1ea1c975325fbcfd902ae22f3d156e4f1b33bbbcb0c029ed9ef30`,
deposit
`0xc5a211b0bdb61c99d3b0ee8bb2cf1d194a2980d632dc7b7e4492545f548efbee`;
B deposit deposit
`0xef1f1c1691eb961ef6febaff9be59d102e8b8239303bd582d9766dc3057b7ec8`;
A partial redeem
`0x05ee36b7a39911ce427b259fdecafc0c20f5a29961c107074da68dab178148ec`;
C deposit wrap
`0xb53f4fc3669a12d991eaecae770eac1e11a11e229b08402e0780d230b4abed94`,
approve
`0xf71bea6e37c8e55e35ce29193fb7d1ecd31f4e6a82c6e59cf19d4f3e4ac31565`,
deposit
`0x8d3795042df2d8b40bbcd035c98b383091432c48b3e37e938203ff410b7454ec`;
A redeemAll
`0x0fa72e97802820ccca80dfec8c24acbbea50a116167b60d3c557ea51e38c34c1`;
B redeemAll
`0x9db6697ab94baf6e3f604d4bdaa3aeb5c919039888209c5c3aaa531a6abb110f`;
C redeemAll
`0x2b1b2b1df83e2cee505be585a215938e40ccb03286b605deafa982da4a775084`.

All fills verified two ways: the driver's `expect_managed`
assertions at every callback (the simulated episode in
`r7-stretch-plan.txt`), and the WETH `Transfer` events in the
three final redemption receipts, recomputed independently after
the run: A +0.001886446367654591, B +0.001886446367654591
(identical — the fairness property), C +0.001392402911115748.

## 4. Reconciliation (independent recomputation)

- Share mints: A 3e15 (1:1), B 2e15, C 1,476,217,861,255,091
  (floored formula) — all exact.
- Every fill from the desk formula at the pushed price — all
  exact (driver asserts + plan).
- Final payouts sum: 0.001886446367654591 + 0.001886446367654591 +
  0.001392402911115748 = 0.005165295646424930 WETH =
  pre-sequence managedRisk, to the wei.
- Conservation: WETH — users 0.005165295646424930 + desk
  0.001334704353575070 = 0.0065 deposited. mUSDC — users 2.394423
  (A partial) + desk 997.605577 = 1,000 seeded.
- End state: totalShares 0, managedRisk 0, managedSafe 0, raw
  vault balances 0/0 — clean reset.

## 5. Invariants

INV-1 (backing: raw ≥ managed at every snapshot) — asserted by
the driver at every snapshot, all pass. INV-2 (clean reset) —
final state above. INV-3 (exact reconciliation) — §4, all lines
exact. INV-4 (fraction stability: equal shares → equal payouts)
— A and B final payouts identical to the wei. INV-5 (no rounding
theft) — C's floored shares, full-redemption remainder exact.
INV-6 (donation neutrality) — NOT exercised on-chain in this run;
holds by construction + unit tests (same as the June core).
INV-7 (interface parity with V4) — same code, unchanged.
**INV-8 RERISK half now CLAIMED** — both tranches were real buys:
tranche 1 spent 4.788846 mUSDC for 0.001851957011868529 WETH,
tranche 2 spent 4.788846 mUSDC for 0.001813338634556401 WETH, and
the desk inventory covered both in full (desk WETH 0.005 →
0.003148042988131471 → 0.001334704353575070). The 4.00 lREACT
attach is vindicated: the run consumed 3.5932354 — above the
design's 3.50 estimate. At 3.50 the brain would have run dry
~0.09 short before RERISK_FINAL.

## 6. Spend (measured)

| Item | Amount |
|---|---|
| lREACT consumed by brain (103 reacts + 11 callbacks) | 3.5932354 (attach 4.00, left 0.4067646 — re-read live 27 Nov) |
| Sepolia ETH (faucet) | 0.04 (2 rounds → +4.2 lREACT) |
| Base Sepolia ETH, drive gas (103 pushes + 13 user txs) | 0.0001368 (coordinator's accounting — includes the set deploy gas in the row below; do not add the two rows) |
| Base Sepolia ETH, deploy gas | 0.000117435841753582 (dev Base 0.064103599581789875 → 0.063986163740036293) |
| Lasna lREACT, deploy gas (ex-attach) | 0.1801715 (dev Lasna 4.822475299984951807 → 0.642303799983150092, of which 4.00 was the attach) |

Combined June core + Aug stretch (coordinator's accounting):
Sepolia ETH 0.060000508561220544 (3 faucet rounds total); Base
Sepolia drive gas 0.000266452765526031 (core 0.0001296 + stretch
0.0001368 — both figures already include their set's deploy gas; the
§6 deploy-gas rows break the same gas out, they are not additional); lREACT 5.5403356 (core 1.9471002 + stretch 3.5932354).
Dev balances after both rehearsals: Lasna 0.6423038 lREACT, Base
Sepolia 0.063966783773815844 ETH, Sepolia 0.630146133711484386 ETH.

## 7. Incidents (V5R §7 style)

1. **Runtime restart killed the main driver at 16:44:19 UTC
   before push 42 (tooling-side, no chain impact).** The driver
   died after the TRIM@41 no-op snapshot (updates 41, prot 6);
   no price was pushed twice. Diagnosis: the mirror re-run with
   an 1800 s gap at 41→42 is identical, so the resume was safe.
2. **First resume attempt aborted on its own start-state check
   (tooling-side, no chain impact).** The check compared
   totalShares `4000000000000000` against the string `4e15` and
   failed on its own typo. Fixed, state re-verified (updates 41,
   prot 6, closed, managed 0 / 9.577692), second resume drove
   42–103 to completion at 17:41:05 UTC.
3. **`sepolia.drpc.org` now refuses Sepolia on the free plan.**
   The faucet rounds ran on
   `ethereum-sepolia-rpc.publicnode.com`. **Sourcify v1 API
   removed** — verifications done via the v2 endpoint.

## 8. What this proves / what it does not

The Aug stretch proves the full two-way cycle on the rehearsal
set: de-risk (TRIM@8 + EXIT@15), seven vault-closed no-op
callbacks with totals provably unchanged, re-arm via a new deposit
after the close, and RERISK + RERISK_FINAL as real buys with exact
fills and a wei-exact all-WETH redemption. Together with the June
core, Release 7 now has its complete firing record: June core
(de-risk) + Aug stretch (two-way cycle). What it does not prove:
a re-risk on the LIVE set (the June window has none — that half
rests on this rehearsal), or wall-clock behaviour (the replay
compresses 103 market hours into ~88 minutes of driving; the
public wording in design §2c says exactly that). Nothing public
was touched by this run: no DoraHacks edit, no video, no git push,
no README/docs change.

---

# Sentinel Release 7 — LIVE June drive record (live set)

Status: **LIVE DRIVE COMPLETE — PASS. All checks exact to the wei.**
Run 2026-11-26, 18:18–19:31 UTC (27 Nov 01:18–02:31 WIB) on the fresh
live set deployed 18:01–18:03 UTC the same day (deploy record:
`RELEASE7-DEPLOY.md`; live set, NOT the rehearsal set). Driver:
`tools/rehearse_release7_live.sh` (main pass, updates 1–27) +
`tools/rehearse_release7_live_resume.sh` (resume 1, updates 29–38)
+ `tools/rehearse_release7_live_resume2.sh` (resume 2, updates
40–56, with retry-hardened read helpers). Logs: goal
`hidden_files/release7-live-driver.log`,
`release7-live-driver-resume.log`,
`release7-live-driver-resume2.log`,
`release7-live-push-table.md` (all 56 origin + reaction txs),
`release7-live-fuel-monitor*.log`,
`release7-live-lasna-logs.json` (all 153 brain events — 152 drive events + 1 deploy-time VaultSet, which is not a drive event),
`r7-mirror-live-rerun.txt` (mirror re-run before the drive).

Pre-drive gates passed before any push: mirror re-run vs klines
120–175 (`r7_mirror.py --window 120 175 --spacing 40`): votes
H/T/E 18/35/1, fires TRIM@9/21/32/44/55, EXIT@56, 30 suppressed,
0 cooldown blocks — identical to the design prediction. Burner
balances verified (A ~0.003494 after a 0.0025 ETH top-up from dev,
tx `0xda44508683ef40bc367d57db61a0afcaedbf07ac3ce1a35e4dc40752076f94c0`;
B ~0.003996, C ~0.005496). Live brain updates 0, lastAction 0,
balance exactly 2.00 lREACT. Flagship brain updates 3, lastAction 0,
balance 11.5613437 lREACT.

Pre-drive correction (design-state restore, no chain impact on the
run): the deploy had seeded the live vault with 0.002 WETH from the
dev wallet (deploy verification of the public flow), but the design's
choreography requires an empty vault at push 1 (A first deposit
1:1). Dev `redeemAll` before the drive, tx
`0x39e80c6595d8ad0932ea491d35389339da7f9b2db7418255a67b150a9d3a966d`
(status 0x1): vault back to totalShares 0, managedRisk 0,
managedSafe 0, dev WETH back to exactly 0.002. Gas 303,633,600,000
wei.

## 1. The set (fresh live set, same V5 code, no new contracts)

| Contract | Chain | Address |
|---|---|---|
| MockPriceOracle | Base Sepolia | `0x9960575DB4681bC5c02cBa4A7248633aFE897f9d` |
| SentinelSwapV2 | Base Sepolia | `0x23484EC173816395494492f0677f9DB985B73111` |
| SentinelReactiveV5 (brain, mock origin, 2.00 lREACT attached) | Lasna | `0x31414A31674d1E138C0Dce0FA04828229DE22FC9` |
| SentinelVaultV5 | Base Sepolia | `0xF2Fda1aCEb36a95136eCDA6707C7CDc96D105068` |

Reused shared contracts: WETH
`0x4200000000000000000000000000000000000006`, MockUSDC
`0x96E467Ff7958851d307D28118EBAAD333CAb85B2`, callback proxy
`0x476F44b11F5C942c58f4c8E3d0300E5710743585` (same as V5R/flagship).

## 2. Firing sequence — observed vs mirror (exact match)

Feed: Binance ETHUSDT hourly closes, June 2022 crash, klines
indices 120–175, 56 pushes, one close per push, gaps ≈ 42 s
(≥ 40 s floor; two resume gaps were far longer — see §7 — and the
sequence is spacing-invariant upward). Start 11 Jun 2022 00:00 UTC
$1,679.28; end 13 Jun 2022 07:00 UTC $1,283.46; max drawdown
−23.57%.

Observed on-chain (every push asserted `updates` +1 and
`lastAction` == mirror; full per-push origin + Lasna reaction txs
in `release7-live-push-table.md`):

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
`0x0487f95b92deed3860ebd7a2106fd3dc86b324fd297f6ff79c00f7f217f6b888`,
reaction (Lasna block 9316322)
`0x31e13572ae3a19450da4956ed9837471492b73111d26ae18a6ffc6ab4456d7a5`.
EXIT@56 origin
`0x301281b73877d4f663ad622d8a0adf2bd68f249df8cdedb06c4c6b15a438eef2`,
reaction (Lasna block 9319895)
`0xd66ef07fe89a7863197e32df1ebf613636180c6ea1a3fc1952782666877e7c32`.
Both reaction txs status 0x1, from the Reactive relayer
`0x038E06667e42782E571EaB20432b9237F9bD6B82` (same relayer as the
rehearsal core).

Independent event-log verification (Lasna logs from the brain's
deploy block, all 153 events — 152 drive events, 56 + 54 + 30 + 6 + 6, plus 1 deploy-time VaultSet, which is not a drive event): 56 PriceSeen (updates 1–56, prices
match klines 120–175 ×1e10 exactly), 54 Decision events (updates
3–56; actions match the mirror 54/54), 30 TrimSuppressed events,
6 CallbackRequested events, 6 EpisodeOpened events whose
episodeAnchor values match the mirror's predictions to the wei
($1,670.70 / $1,650.76 / $1,632.69 / $1,613.21 / $1,595.55 /
$1,593.96). **Stop rule honoured: no update 57 was ever pushed
(R-2).**

Final chain state, read independently after the run: brain updates
56, lastAction 2 (EXIT), balance 0.0528998 lREACT, anchorPeak
1,593,956,768,416,962,686,052; vault protectionCount 6,
reriskCount 0, totalShares 0, managedRisk 0, managedSafe 0, closed
true, vault ETH 0.000092822475914962; desk WETH 0.006325, desk
mUSDC 990.74943675; oracle last price $1,283.46. Flagship brain
after the run: updates 3, lastAction 0, balance 11.5613437 lREACT
— untouched.

## 3. Deposits, fills, redemptions (all exact)

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

All fills verified two ways: the driver's `expect_managed`
assertions at every callback (design §3 table), and the MockUSDC /
WETH `Transfer` events in the four redemption receipts,
recomputed independently after the run: A partial
`0x35aa0d15000d28c87d94ef89539b7e53e759e29d57f02f4875a6f93f4a012bbf`
(+0.000175 WETH, +1.2640965 mUSDC); A redeemAll
`0x0403a6f7aab9166b866716554c3ded337576ce2f613857ac6e539c2a00e5e9a1`
(+2.926934955370680890 mUSDC); B redeemAll
`0x7b95a2ca723c2545ae4a10ebdefc0ffd0e9a3f863f834fb4ec077c342ebfbd44`
(+2.926934955370680890 mUSDC — identical to A, the fairness
property); C redeemAll
`0x15f4cfb7340edc70188a5b3433a30cb65dc338bb3c6e581e5dc6248cdb9ccbf8`
(+2.132596839258638220 mUSDC).

## 4. Reconciliation (independent recomputation)

- Share mints: A 3e15 (1:1), B 2e15, C 1,457,221,886,906,302
  (floored formula) — all exact.
- Every fill from the desk formula at the pushed price — all
  exact (driver asserts + §3 table).
- Final payouts sum: 2.926934955370680890 + 2.926934955370680890 +
  2.132596839258638220 = 7.98646675 mUSDC = pre-sequence
  managedSafe, to the wei.
- Conservation: WETH — users 0.000175 (A partial) + desk 0.006325
  = 0.0065 deposited. mUSDC — users 9.25056325 (partial 1.2640965
  + finals 7.98646675) + desk 990.74943675 = 1,000 seeded.
- End state: totalShares 0, managedRisk 0, managedSafe 0, raw
  vault balances 0/0 — clean reset.

## 5. Invariants

INV-1 (backing: raw ≥ managed at every snapshot) — asserted by
the driver at every snapshot, all pass. INV-2 (clean reset) —
final state above. INV-3 (exact reconciliation) — §4, all lines
exact. INV-4 (fraction stability: equal shares → equal payouts)
— A and B final payouts identical to the wei. INV-5 (no rounding
theft) — C's floored shares, full-redemption remainder exact.
INV-6 (donation neutrality) — NOT exercised on-chain in this run;
holds by construction + unit tests (same as the rehearsal core).
INV-7 (interface parity with V4) — same code, unchanged.
INV-8 (firing proof) — the June half: TRIM and EXIT callbacks
executed on-chain with real token transfers, each moving managed
totals by the desk fill at the pushed price; EXIT left
managedRisk = 0, closed = true, and the full redemption paid out
exactly the managed totals. The RERISK half of INV-8 is not
claimed for this June drive (no re-risk in the window) — it was
proven on the Aug stretch rehearsal set, not this live set.

## 6. Spend (measured)

| Item | Amount |
|---|---|
| lREACT consumed by brain (56 reacts + 6 callbacks) | 1.9471002 (attach 2.00, left 0.0528998) — identical to the June core rehearsal to the wei |
| Sepolia ETH (faucet) | 0 — no faucet round was needed; dev Sepolia unchanged at 0.610146133711001254 |
| Base Sepolia ETH, wallet gas (56 pushes + 13 user txs) | 0.000013932126411831 (computed from dev + A + B + C (ETH+WETH) balance deltas minus desk WETH 0.006325; dev seed redeemAll gas 0.0000003036336 excluded — it was pre-drive) |
| Base Sepolia ETH, vault billing draw (6 callbacks) | 0.000007177524085038 (vault ETH 0.0001 funded at deploy → 0.000092822475914962 left) |
| Base Sepolia ETH, total burned (drive) | 0.000021109650496869 |

Dev balances after the drive: Base Sepolia
0.059338631312289244 ETH + 0.002 WETH; Lasna 0.562132299981348377
lREACT (unchanged — no faucet round); Sepolia
0.610146133711001254 ETH.

## 7. Incidents (V5R §7 style)

1. **RPC read outage aborted the main driver at idx 147
   (tooling-side, no chain impact).** At ~18:37–18:41 UTC both
   `lasna-rpc.rnk.dev` and `sepolia.base.org` timed out
   repeatedly. The driver had already broadcast the idx-147
   `setPrice` tx; its oracle-readback assert failed on the empty
   read and it aborted — but the tx had landed and Reactive
   ingested it (updates 28, lastAction 1, suppressed TRIM per the
   mirror). Diagnosis: chain reads after the outage showed
   updates 28, oracle price = idx-147 price, prot 2, managed
   totals = TRIM@21 state, shares A/B/C correct. Resume 1
   (`rehearse_release7_live_resume.sh`) rebuilt state from those
   reads with hard gates and continued from idx 148; idx 147 was
   never re-pushed.
2. **Exec session SIGTERM killed resume 1 right after push idx
   158 (tooling-side, no chain impact).** The resume-1 driver was
   launched with `nohup` inside an exec session that also ran the
   fuel watcher in the foreground; the session was SIGTERM'd at
   ~18:58:51 UTC and took the driver with it (the `nohup` only
   guards SIGHUP, not SIGTERM to the process group). The idx-158
   push had already landed and been ingested (updates 39,
   lastAction 0 HOLD per the mirror) before the kill. Diagnosis:
   chain reads showed updates 39, oracle price = idx-158 price,
   prot 3, managed totals = post-A-partial-redeem state, shares
   correct. Resume 2 was launched fully detached (`setsid nohup
   ... < /dev/null &`, per the watchdog lesson) and completed the
   run.
3. **Resume 2 aborted once on its first gate — a single transient
   empty read (tooling-side, no chain impact).** The `updates`
   gate read returned empty during another brief RPC blip; state
   was untouched (updates still 39). Fix: the read helpers (`cv`,
   `sharesof`, `bal`) in `rehearse_release7_live_resume2.sh` were
   given a 5-try retry (idempotent reads only; sends unchanged).
   Relaunched; gates passed and the run completed. The retry
   hardening is tooling-only and does not change any asserted
   value.
4. **Two pushes have no driver log line (record-keeping only).**
   Update 28 (idx 147) and update 39 (idx 158) were pushed and
   ingested but their `push idx=` log lines were never written
   (incidents 1 and 2 above). Their origin txs, ingestion and
   actions are chain-verified: idx 147's origin tx is absent from
   the logs (aborted before the log call) but its PriceUpdated
   ingestion is proven by updates 28 + the PriceSeen event; idx
   158's origin tx is likewise proven by updates 39 + PriceSeen.
   Update 27's log line is truncated (`prot=` empty — the RPC
   blip at print time); its origin tx, action and prot are in the
   log / chain-verified. The push table notes all three.
5. **Fuel watch: no top-up was needed.** Brain balance never
   projected to run dry: 1.0315854 lREACT at update 28, 0.6490191
   at update 39, 0.0528998 at update 56. The 2.00 attach covered
   the 1.9471002 consumption with 0.0528998 to spare.

## 8. What this proves / what it does not

The live Release 7 set fired exactly as the mirror predicted, on
real June 2022 crash data, with real token transfers and a
wei-exact multi-user redemption. The guard's decisions, callbacks
and token transfers are live on-chain; the price path is history
(a replay — see design §2c wording). What it does not prove: a
re-risk on the live set (June has none; the two-way cycle was
proven on the Aug stretch rehearsal set), or wall-clock behaviour
(the replay compresses 56 market hours into ~73 minutes of
driving). Nothing public was touched by this run: no DoraHacks
edit, no video, no git push, no README/docs change. The Release 7
page section + video update still wait for the user's word.
