# Release 6 — live drive (56-push June 2022 crash replay, V6 set)

**Verdict: PASS.** 56/56 pushes, mirror-exact fires, reconciliation exact
to the wei, Lasna log verification 13/13. Live set is a completed
demonstration set; the flagship was untouched throughout. This is a live
drive of the V6 set — NOT a new numbered release, no "Release 9" label
anywhere.

## Live set (fresh parallel set — not the rehearsal set, not the flagship)

| Role | Contract | Address |
|---|---|---|
| Oracle (MockPriceOracle, allowlisted) | Base Sepolia | `0x3862815C65d0142BF91eB4bE0C66463021e06f30` |
| Swap desk (SentinelSwapV3) | Base Sepolia | `0xEAe1C0674c9E8F96442A6a6839C18F01eC05553A` |
| Brain (SentinelReactiveV6) | Lasna | `0x78c18D3F064B19193Ab856D15b83287e677Ff569` |
| Vault (SentinelVaultV6) | Base Sepolia | `0xC429ba42745be233614b486B25855821f2b9A99a` |

All four Sourcify exact_match (deploy record: `V6-DEPLOY.md`).
Pusher (dedicated, key only in goal `hidden_files/v6-pusher.env`):
`0x82cFCFe9e33772D971c4e19870325fD311c12c5f` — all 56 pushes sent with
the pusher key; the dev key never pushed a price.

## Prep — 27 Nov 2026, 14:57–14:58 UTC (`tools/prep_release6_live_drive.sh`)

- Dev seed redeemed: `0x0d6b45dae56c40c7c3e5fefa2b5ecf9426094bb3b0184a3f119dc9debbae260c` — vault back to empty, dev WETH 0.01065 (seed principal back, exact).
- Burner top-ups from dev: A +0.003 ETH `0xa69a5f18107c8959ef83b0f6c2466ecee3b27d12af10667aeb803f16f9dab12f`, B +0.001 ETH `0x68f252ec33aa0bc2a0627a2841159fc96d205853fe199145532184757c680004`, C +0.001 ETH `0x92b543bbab2742eb2ae659baf9c82fd0c3a85b99ea40ae7cbe8f18e7f21e5b12`.
- Pre-drive gates PASS: brain updates 0 / lastAction 0 / balance 2.20 lREACT, exitLatched false, vaultLocked true (brain + swap), MIN_SANE_PRICE 1e18, band 2000, pusher allowlisted, vault empty/open, desk 1,000 mUSDC, swap stale pre-first-push. Flagship before: brain updates 1, vault totalShares 2e15.
- No faucet: brain 2.20 lREACT already covered June core (rehearsal June 1.9544173).

## Drive — 27 Nov 2026, 14:58:49–15:44:23 UTC (`tools/rehearse_release6_live.sh`, setsid-detached)

Feed: real Binance ETH/USDT hourly closes, June 2022 crash, klines indices 120–175 (start 11 Jun 2022 00:00 UTC $1,679.28; end 13 Jun 2022 07:00 UTC $1,283.46; max drawdown −23.57%). 56 pushes, mirror prediction (same window as Release 7/8): votes H/T/E 18/35/1 over 54 decisions (updates 1–2 warm-up, no Decision), TRIM@9/21/32/44/55, EXIT@56, 30 TRIM votes suppressed, 0 cooldown blocks — **all matched exactly**.

| Fire | Update | Price | Managed risk | Managed safe |
|---|---|---|---|---|
| TRIM | 9 | $1,578.19 | 0.0015 WETH | 2.367285 mUSDC |
| TRIM | 21 | $1,523.34 | 0.00175 WETH | 5.03313 mUSDC |
| TRIM | 32 | $1,471.26 | 0.000875 WETH | 6.3204825 mUSDC |
| TRIM | 44 | $1,479.59 | 0.00035 WETH | 5.5742425 mUSDC |
| TRIM | 55 | $1,324.35 | 0.000925 WETH | 6.79926625 mUSDC |
| EXIT | 56 | $1,283.46 | 0 | 7.98646675 mUSDC |

Full per-push table: `~/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release6-live-push-table.md` (56 rows, origin tx per push).

Deposits (all through the public flow): A 0.003 WETH (wrap `0xbe9fc16821f4a15cf297d64b6648af5af7e43f9a5a681a7e2031fe1a477d576d`, approve `0x2d0bafc84566910186a6c7522a48e60bdcf7812c17ecb29869e7c0dc35289d63`, deposit `0x591de3ef9183a7b82063a9992e68c006a3e207929ad1e820bfc54cb38ff89a25`), B 0.002 WETH (wrap `0xf7d0f221f8a8272bf0aa85ff28c7717b7701cab2aa5a390e65482369ffa954f1`, approve `0x82d5efba9be51cce63c29cf820181521c075bc623a1d4bce1772be5b5040ac7c`, deposit `0x47519b70cb49e95b22301ce2967fd7322e294a3fa69176a1c5a9af409d7031f6`), C 0.0015 WETH (wrap `0xe6e72b89aa007a8393c5365df901acc6321e3f40ced449d8db1dc180455b7e00`, approve `0x8f10eea768df5b09993f48508bf7764874c3f84e5dc44b35631b257cc7fb7f38`, deposit `0x1786c9aaf07ad562c80c699c34bf64e4147d241ba4177ca8661bd974f746760c`).

A partial redeem at update 32: `0xd3f2bd93c1be4a1c309d32b2b14f57ed6e04b686259569d144a3da7e5f7f7e3c` — 0.000175 WETH + 1.2640965 mUSDC, managed totals matched design (risk 0.0007 / safe 5.056386).

Final redemptions (after EXIT@56): A `0xcc8906fe6414b0d36844e5731eb26858f95fc23810711400b18b5987f1899457` = 2.926934955370680890 mUSDC; B `0xaedaad7d851fcc9505f4470db1bd54f0caafb584a6809de3d65f59a7bfa7369c` = 2.926934955370680890 mUSDC; C `0x5aa66ef66da918b3f9a6a765f3217763dda208e7792e6c1cbc3bfcbafb8ba6cf` = 2.132596839258638220 mUSDC; all WETH legs 0. Sum 7.98646675 = pre-sequence managedSafe. A = B exactly.

Final state: updates 56, protectionCount 6, reriskCount 0, closed true, managed 0/0, raw 0/0, totalShares 0; desk WETH 0.006325, desk mUSDC 990.74943675. Conservation: WETH users 0.000175 + desk 0.006325 = 0.0065; mUSDC users 9.25056325 + desk 990.74943675 = 1,000. **Reconciliation exact to the wei.**

### Incident: runtime restart killed the driver at update 26 — resumed, no double-push

At 15:18:07 UTC the setsid-detached driver died mid-drive (log mtime frozen, no driver process, brain updates stuck at 26) when the VM runtime restarted. The driver did NOT abort on a mismatch — it was killed externally; the log shows no ABORT/FAIL. Resume followed the task rule (resume from the last chain-confirmed update, never double-push):

- Verified the update-26 checkpoint from chain before resuming: updates 26, lastAction 1 (TRIM), prot 2, managedRisk 0.00175 / managedSafe 5.03313, totalShares 5e15, shares A 3e15 / B 2e15 / C 0, closed false, oracle price still the idx-145 price $1,513.85 (no idx-146 push had been sent).
- Resume driver `tools/rehearse_release6_live_resume.sh` re-asserts all of the above as gates, then continues at idx 146 (update 27) through EXIT@56 and the final redemption sequence. First resume push idx 146 landed 15:21:56 UTC, update 27, action 1, prot 2.
- No price was pushed twice: 56 PriceSeen in the Lasna log, 56 unique reaction txs (see verification below).

## Independent verification (from chain, not the driver log)

- Brain (Lasna): updates 56, lastAction 2 (EXIT), balance 0.2455827 lREACT — consumed **1.9544173**, identical to the V6 rehearsal June consumption to the wei.
- Vault: totalShares 0, protectionCount 6, closed true, managed 0/0. Desk: WETH 0.006325, mUSDC 990.74943675.
- Lasna event logs: **13/13 PASS** on 154 logs from deploy block 9379532 (script `release6-live-verify-logs.py`). PriceSeen 56 (prices == klines 120–175 ×1e10, in order, updates 1–56, 56 unique txs); Decision 54 matching the mirror (votes H/T/E 18/35/1); TrimSuppressed 30; CallbackRequested 6 (5× TRIM then EXIT); EpisodeOpened 6 with anchors identical to the R7/R8 live runs to the wei (1,670,700,457,692,077,400,000 / 1,650,761,951,701,554,530,246 / 1,632,694,090,308,448,539,297 / 1,613,209,160,648,899,634,865 / 1,595,552,320,737,700,386,439 / 1,593,956,768,416,962,686,052); EpisodeCancelled 0. Raw logs: `release6-live-lasna-logs.json`; reaction tx map: `release6-live-reaction-txs.json`.
- Note on the count: 154 raw logs = 152 mirror events + 1 `VaultSet` (wiring tx `0xe98a2b83…`, topic `0xe7ae49f8…`, data = vault address) + 1 `PostExitLatch(true, 56)` (topic `0x372728ef…`, tx `0xe0fc2d31…`). The R8 live run had 153 because the V5 brain has no PostExitLatch event; the extra log here is the V6 AH-2 latch firing at EXIT, exactly as designed.
- Payouts verified from receipt Transfer logs (not the driver log, not wallet balances — burners carry mUSDC from earlier runs): A partial 0.000175 WETH + 1.2640965 mUSDC; finals as above.
- Latch V6: `exitLatched()` true after EXIT@56; CallbackRequested stayed 6, protectionCount stayed 6 — no callback no-op after the latch.
- Flagship untouched before and after: brain updates 1, vault totalShares 2e15. R8 live brain stayed at updates 57, V6 rehearsal brain at updates 110.

## Spend

- lREACT: **1.9544173** (brain 2.20 → 0.2455827). No faucet round — dev Lasna unchanged at 1.2254590.
- Base Sepolia ETH, dev: 0.027044236729572602 → 0.022043580874645480 = **0.0050007** (top-ups 0.005 + ~0.0000007 gas for redeem + 3 top-up sends).
- Base Sepolia ETH, pusher: 0.004977703049779061 → 0.004965571940977475 = **0.0000121** for 56 pushes.
- Burner ETH after drive: A 0.0004826, B 0.0004876, C 0.0009822 (wrap + gas spent, deposits redeemed back to the wei).

## Files

- Driver: `tools/rehearse_release6_live.sh` (+ resume variant `tools/rehearse_release6_live_resume.sh`, used after the runtime-restart incident); log `release6-live-driver.log`; push table `release6-live-push-table.md` (goal hidden_files).
- Verification: `release6-live-verify-logs.py`, `release6-live-lasna-logs.json`, `release6-live-reaction-txs.json` (goal hidden_files).
- Prep: `tools/prep_release6_live_drive.sh`, `release6-live-prep.log` (goal hidden_files).
- This record: `V6-DRIVE.md` (repo root).

## What remains (needs the user's separate word)

- Flagship migration to V6 — NOT authorized, NOT done.
- GitHub push of the new files — NOT done.
- DoraHacks edit — NOT touched.
