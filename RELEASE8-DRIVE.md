# Release 8 — live drive (56-push June 2022 crash replay)

**Verdict: PASS.** 56/56 pushes, 0 aborts, mirror-exact fires, reconciliation exact to the wei, post-drive attacks PASS. Live set is a completed demonstration set; the flagship was untouched throughout.

## Live set (fresh parallel set — not the rehearsal set, not the flagship)

| Role | Contract | Address |
|---|---|---|
| Oracle (MockPriceOracle, allowlisted) | Base Sepolia | `0x9380ee21a8C00f9FB42346F63E28BCf1B847de4F` |
| Swap desk (SentinelSwapV2, fixed code) | Base Sepolia | `0xBDF3e24a673016dcCB00f7CA489456e3fa2d7D41` |
| Brain (SentinelReactiveV5, fixed code) | Lasna | `0x2C1d278d31d52Ec8405cF33E319ba0eB8C6b0d1F` |
| Vault (SentinelVaultV5) | Base Sepolia | `0x86b551AF1D8A5c0c2767Bf8Bb53F1F8bAeC74e18` |

All four Sourcify exact_match (creation + runtime), matchIds 60033452 / 60033484 / 60033492 / 60033495. Deployed 27 Nov 2026 06:02 WIB; record: `RELEASE8-DEPLOY.md`.

## Prep — 27 Nov 2026, 06:51–06:52 UTC (`tools/prep_release8_drive.sh`)

- Dev seed redeemed: `0xafb8ed931aeafe8564f02b001dd8b7fb0f6d35b2912811931d30b9808f37d03f` — vault back to empty, dev WETH 0.00605 (seed principal back, exact).
- Burner top-ups from dev (script): A +0.003 ETH `0x4f4644ed7fc32a51d5d7720b3e82c4b1e420e3401ce34bdf184e23d22533fe3b`, B +0.001 ETH `0x8d4c7a019fd5042211989f9a90bcf5704db9738d5789de65360d44b7744c6abc`, C untouched. The drive coordinator also topped B +0.0015 and C +0.0015 before prep (rehearsal had spent their ETH); those two tx hashes are not preserved in the logs — amounts only, per the coordinator's report.
- Pre-drive gates PASS: brain updates 0 / lastAction 0 / balance 2.20 lREACT, vault empty/open, desk 1,000 mUSDC, swap stale pre-first-push. Flagship before: brain updates 3, lastAction 0, vault totalShares 2.3e15.
- Burner ETH at drive start: A 0.0034907, B 0.0034935, C 0.0029904.

## Drive — 27 Nov 2026, 06:52:43–07:34:10 UTC (`tools/rehearse_release8_live.sh`, setsid-detached)

Feed: real Binance ETH/USDT hourly closes, June 2022 crash, klines indices 120–175 (start 11 Jun 2022 00:00 UTC $1,679.28; end 13 Jun 2022 07:00 UTC $1,283.46; max drawdown −23.57%). 56 pushes, 0 aborts. Mirror prediction (same window as Release 7): votes H/T/E 18/35/1 over 54 decisions (updates 1–2 are warm-up, no Decision), TRIM@9/21/32/44/55, EXIT@56, 30 TRIM votes suppressed, 0 cooldown blocks — **all matched exactly**.

| Fire | Update | Price | Managed risk | Managed safe |
|---|---|---|---|---|
| TRIM | 9 | $1,578.19 | 0.0015 WETH | 2.367285 mUSDC |
| TRIM | 21 | $1,523.34 | 0.00175 WETH | 5.03313 mUSDC |
| TRIM | 32 | $1,471.26 | 0.000875 WETH | 6.3204825 mUSDC |
| TRIM | 44 | $1,479.59 | 0.00035 WETH | 5.5742425 mUSDC |
| TRIM | 55 | $1,324.35 | 0.000925 WETH | 6.79926625 mUSDC |
| EXIT | 56 | $1,283.46 | 0 | 7.98646675 mUSDC |

Full per-push table: `~/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release8-live-push-table.md` (56 rows, origin tx per push).

Deposits (all through the public flow): A 0.003 WETH (wrap `0x179d0512c72fa7450d6882b71b4bc29c18f50d11b73980416fba4cf62a1c8580`, approve `0x8dc2c9056379cad640bd5a7730594552d25f6d009aea86bbab5eed016bdacab7`, deposit `0x75e823439a30de1b43b17ec073ec08be32e209a71821c71d64d5dad261546afd`), B 0.002 WETH (wrap `0x53a252a96780dc9f9a1d00a825d43aa46d97a8411289065e8909743dcc1734e3`, approve `0x520fd56c7a033141c5206956113420fc70986f890b157776af4e3b66a207c278`, deposit `0xc1acd202992e1ff2cccc478a0a2886028d087520a93ddf931c3e1ef8c43e1592`), C 0.0015 WETH (wrap `0xcd3d480549bec8b09181ac2cf3f449eb2dd3dd1306630afc165d257c20fc2c60`, approve `0x7413466639143d120d4a91bf91ea1261e09e8c82ea8c0e9912b6a64285fe495b`, deposit `0x6c99ad3aa7dacb29d00dd5e8366c03644f052db354f75bbe0a8edc09afa86358`).

A partial redeem at update 32: `0xce7f94ff9be1c86dcea848194983cb91780bd197fb32fba5df01b5c61c6b0b94` — 0.000175 WETH + 1.2640965 mUSDC, managed totals matched design (risk 0.0007 / safe 5.056386).

Final redemptions (after EXIT@56): A `0xc09ec783077d7d787e8f320564752e3f50648dec326b32b20d83a4a844649c04` = 2.926934955370680890 mUSDC; B `0x89bfb98bc4994d05fd1fb9ce017470fba32b7d896d838313aced2afb958b5288` = 2.926934955370680890 mUSDC; C `0x4690c97f5d08bc044d1f2bb8e9d2886a307109d1f885d1735834f0030ba57d6f` = 2.132596839258638220 mUSDC; all WETH legs 0. Sum 7.98646675 = pre-sequence managedSafe. A = B exactly (INV-4).

Final state: updates 56, protectionCount 6, reriskCount 0, closed true, managed 0/0, raw 0/0, totalShares 0; desk WETH 0.006325, desk mUSDC 990.74943675. Conservation: WETH users 0.000175 + desk 0.006325 = 0.0065; mUSDC users 9.25056325 + desk 990.74943675 = 1,000. **Reconciliation exact to the wei.**

## Independent verification (parent, from chain)

- Brain (Lasna): updates 56, lastAction 2 (EXIT), balance 0.252192 lREACT — consumed **1.947808**, identical to the R8 rehearsal consumption.
- Vault: totalShares 0, protectionCount 6, closed true, managed 0/0. Desk: WETH 0.006325, mUSDC 990.74943675.
- Lasna event logs: 13/13 PASS on 153 logs from deploy block 9331661 (script `release8-live-verify-logs.py`). PriceSeen 56 (prices == klines 120–175 ×1e10, in order, updates 1–56, 56 unique txs); Decision 54 matching the mirror; TrimSuppressed 30; CallbackRequested 6 (5× TRIM then EXIT); EpisodeOpened 6 with anchors identical to the R7 live run to the wei (1,670,700,457,692,077,400,000 / 1,650,761,951,701,554,530,246 / 1,632,694,090,308,448,539,297 / 1,613,209,160,648,899,634,865 / 1,595,552,320,737,700,386,439 / 1,593,956,768,416,962,686,052); EpisodeCancelled 0. Raw logs: `release8-live-lasna-logs.json`; reaction tx map: `release8-live-reaction-txs.json`.
- Payouts verified from receipt Transfer logs (not the driver log): A partial 0.000175 WETH + 1.2640965 mUSDC; finals as above.
- Flagship untouched before and after: brain updates 3, lastAction 0, 11.5613437 lREACT.

## Post-drive attacks — PASS, 27 Nov 2026 08:37–08:39 UTC (`tools/attack_release8_live_post.sh`)

Run on the closed, empty live set (brain 56, vault closed/shares 0). Log: `release8-live-attacks-post.log`.

- **F2 (stale fill):** after a genuine halt, priceStale = true, priceAge 3896 s (> 3600). Both swap fills from the vault returned 0 + `StalePriceRefused` in trace — fills REFUSED.
- **F4 (zero-price guard):** dev pushed price 0 (allowlisted push succeeds at the oracle) `0x37e14bd5bf5eb5bb8aef5157b46f55f43e90bb353702b7245d4035042c264826`. 45 s later brain updates still 56 — poison log consumed, never ingested, NO BRICK. Dev then pushed a legitimate $1,600 price `0xd8ad760b5f14462407891434932061a1c894108801c75015b00175d2874b5c6c` — brain advanced to 57, lastAction HOLD, protectionCount still 6. Brain alive.
- Flagship after: brain updates 3, lastAction 0, vault totalShares 2.3e15.

Note: the post-drive pushes are a separate phase — the drive final state is updates 56; the brain now sits at 57 (HOLD, no callback, vault still closed/empty).

## Spend

- Drive: 1.947808 lREACT (brain 2.20 → 0.252192). Base Sepolia gas not separately metered for this drive (same 56-push profile as the R7 live drive).
- Prep top-ups: A +0.003, B +0.001 (+0.0015 pre-prep), C +0.0015 pre-prep, from dev. Deposits were the burners' own WETH, all redeemed back to the wei.

## Files

- Driver: `tools/rehearse_release8_live.sh`; log `release8-live-driver.log`; push table `release8-live-push-table.md` (goal hidden_files).
- Verification: `release8-live-verify-logs.py`, `release8-live-lasna-logs.json`, `release8-live-reaction-txs.json` (goal hidden_files).
- Prep: `release8-live-prep.log`; attacks: `tools/attack_release8_live_post.sh`, `release8-live-attacks-post.log` (goal hidden_files).
- This record: `RELEASE8-DRIVE.md` (repo root).
