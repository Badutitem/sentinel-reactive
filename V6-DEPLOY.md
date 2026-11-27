# Sentinel — Live set V6 deploy record

Status: **LIVE SET DEPLOYED, SEEDED, VERIFIED. No live drive run — the
June-core rehearsal (56 pushes, mirror-exact, bleed 0 callbacks) is the
proof for this fixed code. This is a "live set V6", NOT a new numbered
release — no "Release 9" label anywhere.**
Deploy 2026-11-27 13:26–13:30 UTC (20:26–20:30 WIB). Design:
`V6-DESIGN.md`. Rehearsal record: `V6-REHEARSAL.md`. Deploy driver:
`tools/deploy_release6_live.sh` (live variant of
`tools/deploy_release6.sh`: fresh-only, R6_ORACLE resume forbidden);
seed `tools/seed_release6_live.sh`; verify
`tools/verify_release6_live.sh`. Logs: goal
`hidden_files/release6-live-faucet.log`, `release6-live-deploy.log`,
`release6-live-seed.log`, `release6-live-verify.log`.

Pre-flight gates passed before any spend: `forge test` 219/219
(29 suites, 0 failed — re-run for this deploy); flagship brain updates
1, vault shares 2e15 (untouched before, during, and after every step).

Note on source: this set was compiled and deployed from the V6 source
(AH-2 post-EXIT latch, AH-3/AH-4 $1–$1M sane-price bounds, AH-5 20%
deposit band, AH-6 single-use vault wiring lock). Sourcify
exact_match below confirms the deployed bytecode matches it.

## 1. The set (fresh live set, V6 code, parallel to the flagship)

| Contract | Chain | Address |
|---|---|---|
| MockPriceOracle (allowlisted; owner dev, pusher 0x82cF…c5f) | Base Sepolia | `0x3862815C65d0142BF91eB4bE0C66463021e06f30` |
| SentinelSwapV3 | Base Sepolia | `0xEAe1C0674c9E8F96442A6a6839C18F01eC05553A` |
| SentinelReactiveV6 (brain, mock origin, 2.20 lREACT attached) | Lasna | `0x78c18D3F064B19193Ab856D15b83287e677Ff569` |
| SentinelVaultV6 | Base Sepolia | `0xC429ba42745be233614b486B25855821f2b9A99a` |

Reused shared contracts: WETH
`0x4200000000000000000000000000000000000006`, MockUSDC
`0x96E467Ff7958851d307D28118EBAAD333CAb85B2`, callback proxy
`0x476F44b11F5C942c58f4c8E3d0300E5710743585` (same as flagship).
Feed for this set = mock oracle replay June 2022 (same as live sets
R7/R8) — NOT the Chainlink adapter; Chainlink is flagship-only.
This set is NOT the rehearsal set (rehearsal oracle
`0x94244819916102Db22FbA4f58542055dF3E37f55`, brain
`0x66d7bd3e11cE7934ED425b0E7df23Ed7e39a79B4`, vault
`0xbA9ed52D3a4A4Cb20EFD2BC9Fc60742CeB7683F6` are untouched:
brain updates 110, vault shares 0 before and after).

Deploy txs: oracle
`0xfdbee6fdf62bcb0c14855cf29b14b20f3fbcfaf8524879abaa389c9f69046f66`;
swap
`0xef40fdf3d6872a89d830abfc3e31289af235b4bc183a4559943c5123c14c7b35`;
brain
`0xac6f1727315253bddf86f35084b88eb70c08736eb7f590373c253d573a9cfb37`
(2.20 lREACT attached); vault
`0xd4e93d9f1e9ea651e65449bd16094499064834b13e12627b538aa929f0f0baa4`.
Wiring: swap.setVault
`0xaf97c194e24cdd4a2a7fd2eadccb319162a0b0a19ac6c72c1f7270d73718b58e`;
reactive.setVault
`0xe98a2b83223415a52fe599512d2244c37809f024d7dfb2739611d553c75d0526`;
oracle.allowPusher(pusher)
`0xb207d77134909fb3f27cd08a0ce912863aad1084ad1437dac505fb65a94b913d`
(dedicated pusher `0x82cFCFe9e33772D971c4e19870325fD311c12c5f`; key
ONLY in goal `hidden_files/v6-pusher.env`, mode 600).

## 2. Sourcify verification (all exact_match, creation + runtime)

Verified via `forge verify-contract` (Sourcify v2), then re-checked
independently against the v2 API. Brain verify job ID
`e66492a5-6c35-4948-8301-e45a4a4c1533`.

| Contract | matchId |
|---|---|
| MockPriceOracle | 60074894 |
| SentinelSwapV3 | 60074895 |
| SentinelReactiveV6 | 60075111 |
| SentinelVaultV6 | 60074928 |

## 3. Read-back gates (all PASS, verified independently after deploy)

- `swap.MIN_SANE_PRICE()` 1e18, `swap.MAX_SANE_PRICE()` 1_000_000e18,
  `vault.MAX_DEPOSIT_DEVIATION_BPS()` 2000, `swap.vaultLocked()`
  true, `reactive.vaultLocked()` true, `reactive.exitLatched()`
  false, `vault.lastSettledPrice()` 0.
- Wiring in-set: swap.priceSource = live oracle, swap.vault = live
  vault; brain.oracle = live oracle, brain.vault = live vault;
  vault.swap = live swap; vault constructor calldata (deploy tx)
  confirms callbackProxy = shared proxy, reactive = live brain,
  risk WETH, safe mUSDC, swap = live swap (no public getter exists
  for the callback sender — it is an immutable used only by the
  `onlyCallbackSender` modifier).
- Oracle: owner = dev, `pricePushers(dev)` true,
  `pricePushers(pusher)` true, `latestPrice(WETH)` 0 at birth.
- Swap: `MAX_PRICE_AGE()` 3600, `priceStale()` true pre-push
  (never-pushed source reads stale, fail closed).

## 4. Funding (faucet, 1 round)

Dev Lasna was 1.517558399973902638 lREACT — below the deploy gate
2.40. One faucet round, 0.02 Sepolia ETH, `request(dev)` on
`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`
(RPC ethereum-sepolia-rpc.publicnode.com; previewed via eth_call
first, no revert):
round 1 tx
`0xa173b6d63a457969187a620e55e7ae390db4ffdb1e7149ec93f6d927ae5f3915`
(+2.1 exact, dev Lasna 3.617558399973902638). Gate passed with margin
1.2176. Dev Sepolia after: 0.450115385558882778 ETH.

## 5. Seed (public flow, 0.002 WETH, shares exactly 1:1)

Wrap tx
`0x5dd6e8d96c71e37ba9e66964e4de49e9f9fa53b01eb7ec2e36049fd98abe4e3a`;
approve tx
`0xf3d18de0a390f3cb8af15540c66d25b614dda1ba78440e18b65dd902aa483e14`;
deposit tx
`0x9dff87074cab8275465d12ba02a4c9dbe17aa88d77d7d43279ca72eb82483e0a`.
Read back: sharesOf(dev) 2000000000000000 (1:1), totalShares
2000000000000000, managedRisk 2000000000000000, managedSafe 0.
Desk seeded exactly 1,000 mUSDC (mint tx
`0x6e2b93bc51dd52313443865acd0a66dc85cbf5c4cc2384d04071ab88fa117cac`);
vault billing funded 0.0001 ETH (tx
`0x32e294ce5aa269129bef25a34cf68ad568bac59100f8226c00a6cd78eb01e50c`).

## 6. Flagship untouched — and NOT migrated

Flagship brain `0x162DdFa4dD0db9bA60c4444b9a1BD1fa6b5343A9` verified
updates 1, oracle still Chainlink adapter
`0xcc99348d41eec983584eE071EADC7091a895030d`, before AND after every
on-chain step in this deploy. Flagship vault
`0xD61E27bC945ceE8Bd967aA42c907e7bA6968b5e9` totalShares
2000000000000000 throughout. The R8 live brain
`0x2C1d278d31d52Ec8405cF33E319ba0eB8C6b0d1F` stayed at updates 57
(its post-drive-attack-test value, pre-existing) and the V6
rehearsal brain stayed at updates 110. The flagship position was
NOT moved: migration of the flagship to V6 contracts is NOT
authorized. This V6 live set runs parallel, same pattern as
Release 7 / Release 8.

## 7. Spend (this live deploy)

- Sepolia ETH: **0.02** faucet + ~0.00000197 gas (dev Sepolia
  0.470117356229213342 -> 0.450115385558882778).
- Base Sepolia ETH: **~0.0021238 gross** (dev 0.029168035726141463
  -> 0.027044236729572602) — of which 0.002 WETH is now the dev
  seed in the vault (shares 2e15) and 0.0001 ETH is the vault
  billing fund; net gas ~0.0000238 ETH.
- Lasna lREACT: **2.20 attached** to the brain + **~0.1921 deploy
  gas** (dev Lasna 3.6175584 -> 1.2254590 after deploy). Brain
  holds exactly 2.20 lREACT; brain updates 0.
- Final dev balances: Base Sepolia 0.027044236729572602 ETH,
  Lasna 1.225458999971981644 lREACT, Sepolia
  0.450115385558882778 ETH.

## 8. What remains (needs the user's separate word)

- Live drive 56-push (June replay) on this set — NOT run.
- Flagship migration to V6 — NOT authorized, NOT done.
- GitHub push of the new files (this record, live scripts) — NOT done.
- DoraHacks edit — NOT touched.
