# SentinelVaultV5 — On-Chain Multi-User Rehearsal (set "V5R")

**Date:** 25 Nov 2026, 05:26–05:46 WIB (24 Nov 22:26–22:46 UTC) · **Verdict: PASS — every stage, reconciliation exact to the wei, zero contract anomalies.**
Driver: `tools/rehearse_vaultv5.sh` (exit 0, no aborts). Full transcript: goal `hidden_files/vaultv5-rehearsal-driver.log`.
The brain's behaviour reproduced the trio #5R reference run **exactly**: 31 oracle updates → TRIM@7, EXIT@15, RERISK@18, RERISK_FINAL@19, TRIM@25, EXIT@31; final counters protectionCount = 6, reriskCount = 2. Three burner users deposited at three different times, one redeemed partially mid-episode, all redeemed fully at the end; the vault reset to zero.

## 1. Deployments (fresh rehearsal set)

| Contract | Chain | Address | Deploy tx |
|---|---|---|---|
| MockPriceOracle | Base Sepolia | `0x4a3022010e253bc2dc49c2cb03ce0e5c544630b3` | `0x6f7c47e83362dd724aba20982de8a8728341c28d7ab77a5f97082cd4856096ab` |
| SentinelReactiveV5 (brain, 1.40 lREACT attached, cooldown 300 s, mock origin) | Lasna | `0xaf030D808133C36E571c87C3A3fD2B7F511971E0` | `0x352cecccb4e1de45da531012fc3ba2b62eaf9dbd81492d2931291726996f60fe` |
| SentinelSwapV2 (desk) | Base Sepolia | `0xF25B97c6c3738b8a91a9c3eE2E1518e3ffB0A34a` | `0x7769032e11c254c5ee7ba6b6a842226765ddc349ad533e7d6c365c7028a0d9a4` |
| SentinelVaultV5 | Base Sepolia | `0xf874c4E680EBBD65315a130A521399f43171dad2` | `0x3a452655159bc803bb0485fa94215b5c0e211b83363ed6f354875e67ee344e1e` |

Reused shared contracts: WETH `0x4200000000000000000000000000000000000006`, MockUSDC `0x96E467Ff7958851d307D28118EBAAD333CAb85B2`, callback proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585`.
**Sourcify: SentinelVaultV5 = exact_match (creation + runtime)**, first poll of the v2 API (job `0ae64292-2308-4d7a-9a23-3400300edfca`).

Wiring & seeding (all verified by reads afterwards): `swap.setVault` `0xc680b88058c70be6ab09994dfc8e5601bd58ade37f2d733083c262e810319c62` · `reactive.setVault` `0xe3c87c9105c9eea582adb0581cc7c657dc42e73ec74942877b6ddb85838cbdd8` · desk seeded exactly 1,000 mUSDC (mint `0x6a4ab1575cc6741f93a6276f8d0f075fe43b562a23f6bb173e24bbcbfba3c44e`) · vault callback billing funded 0.0001 ETH (`0xc841a0f1e6627f24e7c92900710a32141b77813068226ada56a7466ec835893d`).
Brain funding path (proven route only): Sepolia faucet `request(devWallet)` paid 0.02 ETH from dev (`0x4bcd3033b6be49ed1d875915ca7dce1bd479c5dd9ffe1d10f9b25bcfe8b284e5`) → dev Lasna balance +2.1 lREACT exactly (1.517200799990399062 → 3.617200799990399062).
Burners (keys in goal `hidden_files/vaultv5-rehearsal-burners.env`, mode 600), each funded 0.01 ETH from dev: A `0xEBB89D023458b2c65dB199585c314e4693aA9aD6` (fund `0xea5a3f6345a4b79410ffe8450a2a443250a71a1ee69ac4f8c3036ec029b81d37`), B `0xbeE6b4857fDf82455348B5BdADf85f0E538409fF` (fund `0x816a891b904eb85a4166478b66e40f1640c82ce79031c5c1918abd57c7811572`), C `0x0be5e7CC763F4B2aC524d7038e14fB60C6b05A6f` (fund `0xee80a02ada41a2dff45174b3d83cd3ddfc6a1d38f21ff33ae260781f4e287ff4`).

## 2. Run — stages and guard actions

Price series = the #5R 31-push series. Stage A calm (100, 100.5, 99.8, 100.2, 100.1 → updates 1–5, all HOLD, 0 callbacks). Stage B bleed ×0.98 (updates 6–15). Stage C recovery (90, 93, 96.5, 99.5, 103.5 → updates 16–20). Stage D bleed from the new anchor (updates 21–31). TRIM votes on updates 8–14 and 26–30 were suppressed by the episode machine (TrimSuppressed), exactly as in #5R.

| # | Push (origin tx, Base Sepolia) | Action | React tx (Lasna) | Callback tx (Base Sepolia) | Fill (vault managed totals after) |
|---|---|---|---|---|---|
| 7 | 96.136 — `0xa5cd2610c8698b2d87ca470f85258746002e3d67d89e44077aa9314ed002cfef` | TRIM | `0x7ca302168713135ad0e3c2a9e6c93ba57032ef6391f732d53bbb746ae902e18d` | `0x3eb37187018077fc4028fc6feefc01235ad7da7be5cab1682140b0cbe74d8850` | sold 0.0015 WETH @96.136 → risk 0.0015, safe 0.144204 |
| 15 | 81.789 — `0xa76b1d6d30eeeb2b9a6360208c8844a39ad865c58ae588966dad55ee37e5b61a` | EXIT (closed) | `0x3a4bed7b9004cfcc246bd05d86863a4baab30d71deb520e8228acb03fb103e6d` | `0x31ca689cc3d19c9e9c3a40466c691916c203935b8141fcb5c026924c320122ba` | sold 0.0035 WETH @81.789 → risk 0, safe 0.4304655 |
| 18 | 96.5 — `0x5b3e07e391b835e685e0c96c5160fe4d3d854e7df16b24c3fff243835104d512` | RERISK (tranche 1) | `0xebfe72a8379750ac5e3128f3345a5bc7ae742f965c500c32a527b21449abe7bd` | `0x7f5a500b0712349aebb67a6f66c64ca148fce34116c9c34e2eb5bec36f9c2799` | spent half the safe leg (0.21523275) @96.5 → risk 0.002230391191709844, safe 0.21523275 |
| 19 | 99.5 — `0xffe3e70ef0faecb2af2144c3660611e2293babb6d08f9fdf53d2e2a12092fd51` | RERISK_FINAL (tranche 2) | `0x7c06c53d55997591a0b0d85089fe166175cb798c514fe812e01295205db0f254` | `0x9a202f1d2656c6ae5bbf92e91c0169a2de27ed32813685eda13255c2d45dadcc` | spent the rest (0.1721862) @99.5 → risk 0.003514827526232197, safe 0 |
| 25 | 93.556 — `0xff4e6f89f448a1218553bfae75059d3bb02738f505d111c7fbd0fd1e2ba85218` | TRIM | `0x41b4e844d788f0bfaf5a23ae1db7ce1bf95c93e74a64de5dd6d71003518f0698` | `0x6d6fa13305602bf2081247de0f6566975c7fabf6660745fea8beab5479a34a4c` | sold 0.002507413763116098 WETH @93.556 → risk 0.002507413763116099, safe 0.234583602022089664 |
| 31 | 82.876 — `0xb5584cfbc5483abc57325a8e1f8f5287a36faa6deacfeba5c24ddb4a9d059162` | EXIT (closed) | `0x1c463d384840772b1bcbbcb8b352c9b27361726ee58f3f0a8dfaaefb2ece9845` | `0x4aab3b582fde31e1733275889569c6541b4ec1ebd1e617e92f95dc80e3d8d859` | sold 0.002507413763116099 WETH @82.876 → risk 0, safe 0.442388025054099484 |

Cooldown hygiene: push-25 origin block timestamp 1795560133 vs the 300 s cooldown deadline from push 15 (1795559791 + 300 = 1795560091) — cleared by 42 s on natural cadence (see incident 3).

## 3. Per-user deposits and payouts (wei-exact)

| User | Deposit (WETH) | When | Shares minted | Partial redeem | Final redeemAll payout | Total received |
|---|---|---|---|---|---|---|
| A `0xEBB8…9aD6` | 0.003 (wrap `0x9c8ad6…84191`, approve `0x634087…80584`, deposit `0xf26356…594d`) | before push 1 | 3,000,000,000,000,000 (1:1, empty vault) | 1,000,000,000,000,000 shares after tranche 1 (`0xa4fab1…df7e`) → 446,078,238,341,968 WETH + 43,046,550,000,000,000 mUSDC | `0xaefcdc…2467` → 155,032,012,527,049,755 mUSDC | 446,078,238,341,968 WETH + 198,078,562,527,049,755 mUSDC |
| B `0xbeE6…09fF` | 0.002 (wrap `0xd773de…8137`, approve `0x8d7d08…cf5dd`, deposit `0x2a2d06…e9e9`) | after TRIM@7 | 2,000,000,000,000,000 (pool risk-eq at 96.136 = 0.003 exactly) | — | `0x1bd834…1686` → 155,032,012,527,049,755 mUSDC | 155,032,012,527,049,755 mUSDC |
| C `0x0be5…6A6f` | 0.0015 (wrap `0x93765f…9ca1`, approve `0x591bf1…b55a`, deposit `0x97d5c3…1b7`) | after update 20 | 1,707,053,889,620,536 (risk-only pool, floored formula) | — | `0x162935…70b9` → 132,323,999,999,999,974 mUSDC (full-redemption remainder) | 132,323,999,999,999,974 mUSDC |

A and B held equal shares (2e15) at the final redemption and received **identical** final payouts — the fairness property, observed live. C, redeeming last, received the entire remaining managed balance under the full-redemption rule.

## 4. Reconciliation — the hard gate (all checks PASS, exact integer math, recomputed independently from the recorded states)

- Share mints recomputed from the design formula: A 1:1 ✓ · B = ⌊0.002 × 3e15 / (0.0015 + 0.144204/96.136)⌋ = 2e15 ✓ · C = ⌊0.0015 × 4e15 / 0.003514827526232197⌋ = 1,707,053,889,620,536 ✓
- Guard fills recomputed at desk reference prices: TRIM1 safe-in = 0.0015 × 96.136 = 0.144204 ✓ · EXIT1 add = 0.0035 × 81.789 = 0.2862615 ✓ · TRIM2 safe-in = sold × 93.556 ✓ · EXIT2 add = 0.002507413763116099 × 82.876 = 0.207804423032009820 ✓ (desk formula `riskIn × price × safeUnit / (riskUnit × PRICE_SCALE)`, both tokens 18-dec)
- A partial redeem = floored pro-rata of both legs ✓ (WETH leg ⌊2230391191709844/5⌋ = 446,078,238,341,968; mUSDC leg exact fifth)
- Final sequence: payouts 155,032,012,527,049,755 + 155,032,012,527,049,755 + 132,323,999,999,999,974 = **442,388,025,054,099,484 = the managedSafe snapshotted immediately before the sequence, to the wei** ✓
- **WETH conservation:** users 446,078,238,341,968 + desk 6,053,921,761,658,032 + vault 0 = **6,500,000,000,000,000 = total deposits (0.0065)** ✓
- **mUSDC conservation:** users 485,434,575,054,099,484 + desk 999,514,565,424,945,900,516 + vault 0 = **1,000,000,000,000,000,000,000 = the 1,000 seed** ✓
- End state (fresh reads): totalShares 0, managedRisk 0, managedSafe 0, vault raw balances 0/0, all user share balances 0 — clean reset ✓

## 5. Invariants (VAULTV5-DESIGN.md §8)

| Invariant | On-chain verdict |
|---|---|
| INV-1 backing (raw ≥ managed) | PASS — asserted at all 12 snapshots; raw == managed at every one (no donations occurred) |
| INV-2 clean reset | PASS — final totals all zero; the reset→1:1 re-deposit half is covered by the unit suite (not re-run on-chain) |
| INV-3 exact reconciliation | PASS — §4, to the wei |
| INV-4 fraction stability | PASS — share counts unchanged across all 6 callbacks (checked at every post-callback snapshot) |
| INV-5 no rounding theft | PASS — B and C mints equal the floored formula exactly; rounding favors the pool |
| INV-6 donation neutrality | Not exercised on-chain (no donation was sent); holds by construction (managed totals) + unit tests |
| INV-7 interface parity with V4 | PASS — identical action sequence, suppression pattern and counters to the #5R V4-brain run |

## 6. Fuel / spend

| Item | Amount |
|---|---|
| Base Sepolia ETH — dev gross outflow (0.100478297987411878 → 0.070352720558743524) | 0.03012557742866835 (includes 0.03 burner funding + 0.0001 vault billing) |
| — of which still held: burner leftovers (A 0.006997784306953361, B 0.007998631180865435, C 0.008498700841954470) | 0.023495116329773264 |
| — of which still held: vault callback billing leftover (0.0001 − 0.0000078456048 consumed by 6 callbacks) | 0.0000921543952 |
| **Base Sepolia ETH actually burned (all gas: deploys, wiring, 31 oracle pushes, user txs + callback billing draw)** | **0.006538306703695088** |
| lREACT — reactive end balance 0.314275 of 1.40 attached → consumed by 31 reacts + 6 callback requests | 1.085725 |
| lREACT — dev Lasna gas (reactive deploy + setVault) | 0.18017150000180174 |
| Sepolia ETH — faucet round (0.02 payment + 0.00000000001973213 gas) for +2.1 lREACT | 0.02000000001973213 |

## 7. Incidents / anomalies (all tooling-side; none in the contracts under test)

1. First reactive deploy attempt failed **pre-broadcast** ("constructor argument count mismatch: expected 5 but got 6") against a stale local artifact; `forge build --force` + retry succeeded. No chain impact.
2. The first `cast wallet new` burner batch printed keys to stderr and was parsed empty — those three addresses were discarded **unfunded and unused**; a fresh batch was created and persisted correctly.
3. The driver's one read of the oracle's `updatedAtOf` after EXIT@15 returned empty (transient RPC failure), so its scripted cooldown wait for stage D did not engage. The natural cadence satisfied the 300 s cooldown anyway — verified from chain timestamps (push-25 origin ts 1795560133 ≥ deadline 1795560091, margin 42 s) and TRIM@25 fired normally.
4. My first reconciliation pass flagged EXIT2's fill as off by 83 wei — the check itself used the wrong sold amount (TRIM2's floored half instead of the remaining balance). Recomputed with the correct input, the fill matches the desk formula exactly (§4). Chain data was never wrong; no value was created or destroyed at any step (conservation held throughout).
5. Public-RPC log limits shaped the evidence collection: Base Sepolia `eth_getLogs` ≤ 200 blocks, Lasna ≤ 30,000 blocks — callback/react hashes were recovered with windowed queries (§2). Base Sepolia publicnode is behind a Cloudflare challenge from this VM and was not used.
6. Ad-hoc post-run reads of the reactive's counters with guessed getter names returned empty for two fields; the driver's reads (from the contract source) and the recovered event history are the authoritative record (updates 31, protectionCount 6, reriskCount 2).

**Live trio #5 was not touched. Nothing was pushed to GitHub; DoraHacks was not edited. This set is rehearsal-only.**
