# Sentinel — Flagship Migration to the Fixed (Release 8) Code

**Status: MIGRATION COMPLETE AND VERIFIED.** 27 Nov 2026, 09:13–09:22 UTC
(16:13–16:22 WIB). User order 27 Nov 15:57 WIB ("clean all remaining bugs,
re-audit everything"). Maintenance only: no new features, no redesign, no
model changes. The live flagship position moved from the old-code set onto
a fresh set built from the fixed code. Deploy driver:
`tools/deploy_flagship_fixed.sh`; verify `tools/verify_flagship_fixed.sh`.
Logs: goal `hidden_files/flagship-migration-preflight.log` (n/a — preflight
reads are in this file and the step logs), `flagship-migration-step-a.log`,
`flagship-migration-faucet.log`, `flagship-migration-deploy.log`,
`flagship-migration-verify.log`, `flagship-migration-redeem.log`,
`flagship-migration-seed.log`. Nothing was pushed to GitHub by this run;
no DoraHacks page was edited.

## 0. Preflight (all gates passed)

- `forge test`: **205/205, 28 suites, 0 failed** (re-run this run). Count
  drifted from 190/190 at the R8 deploy: the attacker-hunt lane added 15
  tests (`test/AttackerHunt.t.sol`, 15/15). The suite is green; the number
  is taken from the output, not hand-copied.
- Old flagship state re-read live before any spend — matched the brief
  exactly, no drift: brain updates 3, lastAction 0, balance 11.5613437
  lREACT; vault totalShares 2.3e15, managedRisk 2.3e15, managedSafe 0,
  closed false, billing 0.0001 ETH; dev shares 2e15, filming-burner
  shares 3e14; swap desk 1,000 mUSDC / 0 WETH; adapter lastPrice
  $1,679.60422012, lastEmittedAt 1795561929 (~57.7 h stale), params
  10/60/300/3600/1e10, feed `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`,
  WETH; feed live at $1,730.75; dev Base ETH 0.044021760607926221, WETH
  0.00605, Lasna 2.096399399977691048 lREACT, Sepolia ETH
  0.530118162909856994.

## 1. The old set (retired as flagship, still functional for redemption)

| Contract | Chain | Address |
|---|---|---|
| SentinelReactiveV5 (old flagship brain) | Lasna (5318007) | `0x37EeF5e3179E55c0e96E1528180B55Fa20DC150B` |
| SentinelSwapV2 (old flagship desk) | Base Sepolia (84532) | `0x17700999733F766968EA252D5a17ac39F96F2C28` |
| SentinelVaultV5 (old flagship vault) | Base Sepolia (84532) | `0x108513e6439664fdeE9050e1ccc208e8c1b61441` |
| ChainlinkPriceAdapter (old adapter) | Base Sepolia (84532) | `0xAb9c7a5178B444cd1C1fD705e5eBeCf4b9A1C25F` |

Final state (09:22 UTC): brain updates 4, lastAction 0 (HOLD), balance
**11.5287155 lREACT — STRANDED, no withdraw path by Reactive design; do
not try to recover it**. Vault totalShares 3e14 (filming burner only,
see §4), managedRisk 3e14, managedSafe 0, raw WETH 3e14, raw mUSDC 0,
closed false. Desk 1,000 mUSDC / 0 WETH. Old adapter lastEmittedAt
1795770817, lastPrice $1,730.75. The old brain keeps its subscription to
the old adapter and will keep reacting on stranded fuel; its callbacks
hit the drained old vault and no-op. The old vault stays functional for
redemption (the burner's 0.0003 is redeemable by its holder at any time).

## 2. The new set (live flagship, fixed code)

| Contract | Chain | Address | Deploy tx | Sourcify matchId |
|---|---|---|---|---|
| ChainlinkPriceAdapter (fresh, heartbeat 3600 — AH-1) | Base Sepolia | `0xcc99348d41eec983584eE071EADC7091a895030d` | `0x0f931b6ed5609d15dab41b7f12d999690324aead210ba776a0225a47862701a4` | 60062190 |
| SentinelSwapV2 | Base Sepolia | `0xe8427C91A5456a4Ee82AE033A72ac3A3Ab11A371` | `0x2e6c5f251c70fc7907db42a978e225b4bcb482caefa5ced0b3b0041ce7e4099d` | 60062144 |
| SentinelReactiveV5 (new flagship brain, 2.20 lREACT attached) | Lasna | `0x162DdFa4dD0db9bA60c4444b9a1BD1fa6b5343A9` | `0x13ba5870a6b46414edacfd34fae0d22d5ef32715fa2a54f862b321eff8e7ae2e` | 60062192 |
| SentinelVaultV5 | Base Sepolia | `0xD61E27bC945ceE8Bd967aA42c907e7bA6968b5e9` | `0x6ae1723482fd3af6d747f9d01d84dd4d2c74c4db4a7a6fab96b1ed81c4ca475b` | 60062162 |

All four Sourcify **exact_match (creation + runtime)**, verified
independently against the v2 API (not just forge's accept). Reused shared
contracts: WETH `0x4200000000000000000000000000000000000006`, MockUSDC
`0x96E467Ff7958851d307D28118EBAAD333CAb85B2`, callback proxy
`0x476F44b11F5C942c58f4c8E3d0300E5710743585` (same as the old flagship).
No mock oracle anywhere in this set (Chainlink origin throughout).

Wiring (all read back after deploy, all in-set): brain oracle = fresh
adapter, brain vault = new vault; vault swap = new swap, vault
`_CALLBACK_SENDER` = new brain; swap priceSource = fresh adapter, swap
vault = new vault. Wiring txs: swap.setVault
`0xe65760d913191a6fe304d56d6960a32ff719cf1be3e6ad7fdea56c9446a718b8`,
reactive.setVault
`0x56834c45701e1ce6be8be7e946c0396f02fa7a07358e9463ce9f7adea3f71423`.
Desk seeded exactly 1,000 mUSDC (mint
`0x3fa2877db89bc8f265f32cba2d57ed46132f7c69e7adf5c5b6d430f1140b57b7`);
vault billing funded 0.0001 ETH
(`0xeeb558c8626c521ca8ade00e2c501d3817492455f1dde9fe67adaf957ee93088`).

Fresh adapter params read back after deploy: feed
`0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`, token WETH, deadbandBps 10,
minInterval 60, **heartbeat 3600**, maxStaleness 3600, priceScaleFactor
1e10; lastPrice 0 / lastEmittedAt 0 at birth; `priceUpdatedAt(WETH)` 0 at
birth (the N1 read-back — the old adapter reverts this call, the fresh
one answers it).

## 3. Step (a) — fresh sync on the OLD adapter first

Sync tx `0xc595a441d9d30a74ffb6b17f623755bad9f09f0147e7d75022b9047ae2a004a8`
(09:13:31 UTC): emission landed, lastEmittedAt 1795561929 → 1795770817,
lastPrice $1,679.60422012 → **$1,730.75** (live Chainlink round). Old
brain ingested it: updates 3 → **4**, lastAction **0 (HOLD — price rose,
as expected)**, balance 11.5613437 → 11.5287155 (one react cost
0.0326282), anchorPeak $1,730.75. Old vault untouched by the sync:
totalShares 2.3e15, managedRisk 2.3e15, managedSafe 0, protectionCount 0.
Gate passed; funds moved only after this read.

## 4. Step (b) — funding + deploy

Dev Lasna was 2.0964 — below the 2.40 gate. ONE faucet round:
`request(dev)` on `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` with 0.02
Sepolia ETH (tx
`0xf6b84ce92d2ec6dfa39f7ec24ba19bc89a1b6936aeb17d74606069f1e836f692`,
09:16:15 UTC): **+2.1 lREACT exact**, dev Lasna 2.096399399977691048 →
4.196399399977691048; dev Sepolia 0.530118162909856994 →
0.510117612035732466. Gate passed with margin 1.7964.

Deploy 09:17:05–09:18:54 UTC (see §2 for addresses/txs). New brain
attached exactly **2.20 lREACT** at creation (balance read 2.20 exact).
Deploy gas from dev Lasna ≈ 0.1818 lREACT (dev Lasna after deploy
1.814585699975872911). R7/R8 live sets verified untouched before AND
after every step: R7 brain updates 56, vault 0; R8 brain updates 57,
vault 0.

## 5. Step (c) — redeem the old flagship in full (pro-rata, to the wei)

Dev `redeemAll()` tx
`0x2d09ae4b465c4f700b1647f5d74e7d5f7007de52f7ffa74b2def1ddba67b55e8`
(09:20:37 UTC, status 0x1): dev WETH 0.00605 → **0.00805 (+0.002 exact)**,
dev mUSDC unchanged (84.127776887 — no mUSDC back, the vault was
all-risk). Old vault after: totalShares **3e14**, managedRisk 3e14,
managedSafe 0, raw WETH 3e14, raw mUSDC 0. Reconciliation exact to the
wei: 2.3e15 in − 2e15 dev out = 3e14 left.

**The 0.0003 filming-burner shares were NOT redeemed — key not in our
files.** Holder `0x7abd9419af88d16dcc907cc40cb4aa9397580dd1` (deposit
0.0005, partial redeem 0.0002, 24 Nov). Checked: rehearsal burners A/B/C
are `0xEBB89D023458b2c65dB199585c314e4693aA9aD6` /
`0xbeE6b4857fDf82455348B5BdADf85f0E538409fF` /
`0x0be5e7CC763F4B2aC524d7038e14fB60C6b05A6f` — none matches; the segment
burner is `0xFf39c0C4EE537FCdd29B1df28Cb524ACEaf9D9ec` — also not it; a
workspace grep finds no key for 0x7abd…. Nothing was attempted for that
address. The 0.0003 stays in the old vault, redeemable by its holder at
any time. **Open question for the parent/user: is that wallet the user's
(he redeems it himself) or a lost burner?**

## 6. Step (d) — sync the fresh adapter, then seed through the public flow

Critical order held: the fresh adapter was synced FIRST (its
lastEmittedAt was 0; the new swap read `priceStale() == true` and the
seed deposit would have reverted `StalePrice` before then). Sync tx
`0x38b89fc850ea769e2e418e48645b01d825dc9d6fddc59ab0b119bfd18f209057`
(09:21:18 UTC): emission landed, lastEmittedAt 0 → **1795771287**,
lastPrice 0 → **$1,728.01138712** (live feed round $1,728.01138712,
updatedAt 1795770883); new swap `priceStale()` true → **false**
(priceAge 7 s at read). Only then the seed:

- Wrap 0.002 ETH → `0x51b38aed2482ca5a95b9c029d843bea6da383d301a79e8aedd52a5f6ed017b12`
- Approve exact → `0x9ffd0818992881dc5d2b7f00a78439be523f2e52116bea4fa7c805746cdbad50`
- Deposit → `0x6affdc92f81675e551a1c9cf85a328767286b45242e07842ab604aed97b1fb71`

Read back: sharesOf(dev) **2e15 (exactly 1:1)**, totalShares 2e15,
managedRisk 2e15, managedSafe 0, closed false, billing 0.0001 ETH; desk
1,000 mUSDC / 0 WETH; swap `priceStale() == false`. New brain:
**updates 1, lastAction 0 (HOLD)**, balance 2.1776106 lREACT.

Two brief-wording corrections, recorded honestly (the numbers, not the
brief, are the authority):
- The brief's step-(d) verify said "new brain updates 0". The brain
  necessarily ingests the required pre-seed sync emission (its
  subscription was live from deploy), so **updates 1, lastAction 0** is
  the correct post-sync state — warm-up HOLD on a single price, exactly
  as the old flagship read updates 3 / HOLD after its first window.
- The brief's step-7 "brain balance is 2.20 minus deploy gas only" is
  imprecise: deploy gas (~0.1818 lREACT) was paid from **dev Lasna**,
  not from the brain. Brain balance is 2.20 − 0.0223894 (first-react
  cost) = **2.1776106**.

## 7. Fuel math

- Attached 2.20 lREACT; measured burn 0.0295521/reaction → runway at
  attach ≈ **74 reactions**. Remaining after react #1: 2.1776106 /
  0.0295521 ≈ **73.7 reactions**.
- First-react cost on the new brain: 0.0223894 (warm-up, no callback —
  below the 0.0295521 average, which includes callbacks).
- The liveness watch alarms on low brain fuel (below one firing cycle,
  0.08 lREACT) and on `priceStale() == true` / adapter age > 3600 s.
- Old brain stranded total grows: 11.5287155 lREACT joins the stranded
  total (previously ~1.1635 across retired brains + 11.5613437 flagged
  in the re-audit; the step-(a) react spent 0.0326282 first).

## 8. Parameter deviation from the original brief (adopted in-flight)

**Fresh adapter heartbeat is 3600 s, NOT 300 s** (follow-up from the
attacker-hunt lane, adopted before deploy). Finding AH-1 (Medium,
PoC'd): `sync()` is permissionless and the adapter emits on heartbeat
alone even with a flat price — 10 pokes at 300 s spacing forced 10
emissions. At heartbeat 300 s a stranger drains the flagship brain
(11.56 lREACT) in ~391 pokes ≈ 32.6 h. At 3600 s the same drain takes
~16 days and the liveness watch has time to alarm. Deadband moves still
emit after minInterval 60 s, so real price moves are unaffected; only
flat-price emissions slow down (flat = HOLD anyway). Read back after
deploy: heartbeat = 3600. Nothing else in the plan changed.

## 9. Open findings from the re-audit (need a user decision)

Recorded, NOT built in this run — each needs code changes (a new release
cycle) and the user's explicit decision:

- **AH-2 (Medium)** — gentle bleed burns ~2.16 lREACT on 20 callbacks,
  ~98% of a 2.20 budget, with no attacker needed. **Caveat:** its fuel
  math is lREACT-side (unit-proven); the vault-billing-ETH side for 20
  callbacks is untested (only 6 callbacks proven live with 0.0001 ETH
  billing). With the new brain funded at 2.20 lREACT, an AH-2-style
  bleed would nearly empty it — the liveness watch must alarm on brain
  balance, and the parent should consider a higher attach or a V6 fix
  decision before judging. Fix would need a new V6 brain (post-EXIT
  suppression).
- **AH-3 (Low)** — 1-wei price cliff. Fix: MIN_SANE_PRICE.
- **AH-4 (Low)** — absurd price bricks an in-flight callback. Fix: swap
  price bound.
- **AH-5 (Low)** — within-band deposit theft, priced: +12.5% pump /
  −24.3% dump / +41% on a 12-step walk. Fix: band 50% → 20%.
- **AH-6 (Low)** — owner `setVault` redirections disable protection.
  Fix: multisig / constructor-immutable wiring.

Other open items (not code): the 0.0003 burner question (§5); MCP /
Live Proof / DoraHacks repoint to the new flagship set (parent's call —
needs a live browser; the DoraHacks section draft is in goal
`hidden_files/flagship-migration-dorahacks-draft.md`); Lane 2 F-2 doc fix
in `FLAGSHIP-V5.md` (#5 brain record) still unverified; frontend LD-1 /
LD-2 / LD-3 / LD-5 fixes from the re-audit (wrong-chain race, stale
shares on RPC failure, receipt-timeout stale UI, account switch
mid-deposit) were NOT in this migration's scope and remain open; the
re-audit §5 live-proof gates F2/F3/F4/F5 are covered by the forge
regression suite (205/205 green) — no live firing of the new brain was
attempted in this run.

## 10. Final state summary (09:22 UTC, all live reads)

- New flagship brain 0x162DdFa4…5343A9: updates 1, lastAction 0, balance
  2.1776106 lREACT. New vault 0xD61E27bC…b5e9: totalShares 2e15,
  managedRisk 2e15, managedSafe 0, closed false, billing 0.0001 ETH.
  New swap 0xe8427C91…371: desk 1,000 mUSDC / 0 WETH, priceStale false.
  Fresh adapter 0xcc99348d…030d: lastPrice $1,728.01138712,
  lastEmittedAt 1795771287, heartbeat 3600.
- Old flagship brain 0x37EeF5e3…150B: updates 4, lastAction 0, balance
  11.5287155 (stranded). Old vault 0x108513e6…1441: totalShares 3e14
  (burner), managedRisk 3e14, managedSafe 0, raw WETH 3e14, raw mUSDC 0.
- R7 live: brain updates 56, vault 0 — untouched. R8 live: brain
  updates 57, vault 0 — untouched.
- Dev final: Base ETH 0.041896928058315291, WETH 0.00805, Lasna
  1.814585699975872911 lREACT.

## 11. Repoint + final re-audit (coordinator, 27 Nov 2026 ~09:3x UTC)

The migration coordinator's run ended at the deploy/seed/record. This
section is the coordinator's own step 3 (repoint) and step 4 (final
re-audit) — done after the coordinator's report, verified independently
from live reads, source, and the suite output.

### 11.1 Repoint (local files only — NOT pushed; the parent pushes after review)

| File | Change |
|---|---|
| `docs/index.html` | Brain/vault display + `R5`/`V5`/`S5` consts → new set; `R5_DEPLOY` 9172277 → 9365765, `V5_DEPLOY` 63196568 → 64246191; test row 190/190 → 205/205; "previous flagship (Release 5)" → "(Release 6, the pre-fix contracts)"; feed note "live since 25 Nov" → "current set went live 27 Nov". JS `node --check` OK. Old flagship addresses 0×, new 5×. |
| `docs/app.html` | `VAULT` const + both display addresses → new vault; added `SWAP` const + `managedRisk`/`managedSafe`/`priceSource`/`latestPrice` selectors. LD-4 (pre-deposit quote) + LD-5 (account-switch abort) implemented — see §11.2. JS `node --check` OK. Old flagship addresses 0×, new 4×. |
| `docs/agent.json` | Brain/vault/swap → new set (address + explorer + Sourcify links each); added the fresh adapter as a 4th contract; `sentinel_verify` description "(Release 6)" → "(fixed-code set, migrated 27 Nov 2026)"; version 1.1.0 → 1.2.0. Valid JSON. |
| `agent/server.mjs` | `R5`/`V5`/`S5` consts + `R5_DEPLOY`/`V5_DEPLOY` → new set/blocks; version 1.1.0 → 1.2.0; `sentinel_verify` description updated. `node --check` OK. |
| `README.md` | Flagship table → new 4-contract set (incl. adapter row, heartbeat 3600) + deploy txs; seed paragraph updated to the new set's facts (one emission $1,728.01138712, HOLD, 2.1776106 lREACT); heading "(2026-11-25)" → "(2026-11-25, migrated to the fixed code 2026-11-27)"; test count 190/190 → 205/205 (table + `forge test` comment). The Release 2 adapter row (line 266) is HISTORY and was left alone. |

Live curl check of the GitHub Pages site is NOT possible yet — the
repointed files are local only until the parent pushes. After the push,
verify: `https://badutitem.github.io/sentinel-reactive/` and
`/app.html` return 200 with the new addresses present and the old
flagship addresses 0×. (The live site still serves the old files until
then — expected, not a failure.)

### 11.2 Frontend fixes finished in this run (LD-4, LD-5)

Correction to the re-audit's first draft: LD-1/2/3 were ALREADY
implemented in `docs/app.html` during the Release 8 fix (verified from
the file: `sendTx` re-checks the chain + pins `chainId`;
`refreshShares` propagates failure and `runRedeem` aborts on it;
`waitReceipt` does a final receipt check). Only the manual
live-browser pass for LD-1/2/3 stays open.

- **LD-5 (account switch mid-deposit) — IMPLEMENTED:** `flowAccount`
  snapshots the account at flow start in `runDeposit`/`runRedeem`;
  `sendTx` throws ("wallet account changed mid-flow — stopped,
  nothing further was sent") if the account changed; the
  `accountsChanged` handler logs the abort. This is the pinned abort
  mechanism the fix design left open.
- **LD-4 (pre-deposit quote) — IMPLEMENTED:** `refreshQuote()` mirrors
  the vault's mint formula exactly (1:1 when no shares are out, else
  `floor(amount * totalShares / poolRiskEq)` with the safe leg valued
  at the desk's reference price, rounded up — same as
  `SentinelVaultV5._poolRiskEq`); shown as an estimate next to the
  deposit steps; refreshes on amount input and on pool change. The
  label states the contract mints the exact amount at deposit time.
- Both JS-checked (`node --check` OK). The manual live-browser pass
  for LD-4/LD-5 stays open (subagent cannot drive a live browser).

### 11.3 Final re-audit on the new flagship set (step 4)

- **F1 (mock oracle) — N/A, verified:** the new brain's `oracle()` reads
  back as the fresh Chainlink adapter (live read); no mock oracle
  exists anywhere in the set. Unit proofs in the suite:
  `testF1_StrangerCannotPushPrice`,
  `testF1_PumpedPriceCannotStealViaDeposit`,
  `testF1_DeviationGuardTripsAt60PassesAt40`.
- **F2 (stale fill) — PROVEN at code level + on identical code live:**
  unit proofs `testF2_StalePriceRefusesFill`,
  `testF2_StalePriceRevertsDeposit`, `testF2_NeverPushedIsStale`,
  `testF2_FreshPriceStillFills`; live proof on the R8 live set (same
  code) 27 Nov 08:37–08:39 UTC — both swap directions refused at
  priceAge 3896 s. On the NEW set the wiring is verified live
  (`priceSource` = fresh adapter, `priceUpdatedAt` answers,
  `priceStale() == false`); a live stale-fill test on the new set
  itself was NOT run — it would need a callback (vault-gated) or a
  3600 s unsynced wait, and no EXIT was fired on the new brain for
  this. Stated plainly, not assumed.
- **F3 (repeat EXIT) — PROVEN by unit test, not by live firing:**
  `testF3_RepeatExitIsCooldownGated` (12 callbacks → 2),
  `testF3_ExitFiresAgainAfterCooldown`,
  `testL3_CooldownStillGatesAfterReset`. No EXIT was fired on the new
  flagship brain (updates 1, lastAction 0 HOLD).
- **F4 (zero price brick) — PROVEN by source + unit test:** the
  adapter's `sync()` returns silently on `answer <= 0`
  (`ChainlinkPriceAdapter.sol:103`); the brain's `react()` consumes
  but ignores `price == 0` (`SentinelReactiveV5.sol:256`);
  `testF4_ZeroPriceIgnoredBrainKeepsWorking`,
  `testF4_ZeroFirstPriceIsIgnored`. No zero round exists on the live
  feed to test against (feed live at $1,728.01) — stated, not assumed.
- **F5 —** `testF5_UnknownActionReverts` (suite green).
- **`forge test`: 205/205, 28 suites, 0 failed** (re-run by the
  coordinator this run; the 15 extra tests are the attacker-hunt
  PoCs in `test/AttackerHunt.t.sol`).
- **Sourcify: all four new contracts exact_match** — independently
  re-verified via the v2 API this run (adapter/swap/vault on 84532,
  brain on 5318007).
- **Old flagship set drained:** dev redeemed 0.002 to the wei; old
  vault holds only the filming burner's 0.0003 (3e14 shares, redeemable
  by its holder); old brain's 11.5287155 lREACT is stranded testnet
  fuel (no withdraw path — not attempted).
- **Watch repoint (for the parent):** the `sentinel-liveness-watch`
  cron must move to the new flagship set — brain
  `0x162DdFa4dD0db9bA60c4444b9a1BD1fa6b5343A9`, vault
  `0xD61E27bC945ceE8Bd967aA42c907e7bA6968b5e9`, swap
  `0xe8427C91A5456a4Ee82AE033A72ac3A3Ab11A371`, adapter
  `0xcc99348d41eec983584eE071EADC7091a895030d`. Tripwire: brain
  lREACT < 0.35 (existing rule). With AH-2 in mind, the watch should
  also alarm on a fast brain-balance fall, not just the absolute
  floor — the new brain holds 2.1776106 lREACT (~73.7 reactions), and
  an AH-2-style bleed would nearly empty it.

### 11.4 What remains open (unchanged from §9, plus the repoint)

- **AH-2..AH-6 need a user decision** (new code = new release cycle):
  AH-2 Medium (V6 brain, post-EXIT suppression), AH-3 Low
  (`MIN_SANE_PRICE`), AH-4 Low (swap price bound), AH-5 Low (band
  50% → 20% + pusher-key separation), AH-6 Low (multisig /
  constructor-immutable wiring). None built in this run.
- The 0.0003 filming-burner question (§5) — needs the user's answer.
- DoraHacks page still shows the OLD flagship set + 190/190: the
  874-char section draft + trim note are in goal
  `hidden_files/flagship-migration-dorahacks-draft.md`; the edit needs
  the parent/browser + the user's word (description near the 30,000
  limit; also update the 190/190 row to 205/205 at paste time).
- Manual live-browser pass for LD-1/2/3/4/5 in the demo app (the
  agent cannot drive a live browser).
- Lane 2 F-2 doc fix in `FLAGSHIP-V5.md` still unverified.
- Files changed in this run (for the parent's push): `README.md`,
  `docs/index.html`, `docs/app.html`, `docs/agent.json`,
  `agent/server.mjs`, `FLAGSHIP-MIGRATION.md` (this file),
  `tools/deploy_flagship_fixed.sh`, `tools/verify_flagship_fixed.sh`,
  `test/AttackerHunt.t.sol` (new, 15 tests). No `src/` change. Nothing
  pushed by this run.
