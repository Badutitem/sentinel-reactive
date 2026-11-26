# Sentinel Release 8 — LIVE deploy record

Status: **LIVE SET DEPLOYED, SEEDED, VERIFIED. No live drive run — the
June-core rehearsal (56 pushes, mirror-exact, reconciliation to the wei)
is the proof for this fixed code.**
Deploy 2026-11-26 23:02–23:04 UTC (27 Nov 06:02–06:04 WIB). Design:
`FIX-DESIGN.md`. Rehearsal record (June core PASS + pre/post-drive
attack tests): `RELEASE8-REHEARSAL.md`. Deploy driver:
`tools/deploy_release8.sh`; verify `tools/verify_release8.sh`; seed
`tools/seed_release8.sh`. Logs: goal
`hidden_files/release8-live-faucet.log`, `release8-live-deploy.log`,
`release8-live-verify.log`, `release8-live-seed.log`.

Pre-flight gates passed before any spend: `forge test` 190/190
(27 suites, 0 failed — re-run for this deploy); post-drive attack
gate PASS (F2 both swap directions REFUSED after a genuine 3600 s
halt; F4 zero-price print consumed without brick, brain 56 → 57 on
the next legitimate price); flagship brain updates 3, lastAction 0,
balance 11.5613437 lREACT (untouched).

Note on source: this set was compiled and deployed from the FIXED
source (F1 allowlisted replay oracle, F4 zero-price guard in `react()`,
F2 consumption-side staleness bound, F3 `_lastFiredTs` kept across the
EXIT reset). Sourcify exact_match below confirms the deployed bytecode
matches it.

## 1. The set (fresh live set, fixed V5 code, parallel to the flagship)

| Contract | Chain | Address |
|---|---|---|
| MockPriceOracle (allowlisted) | Base Sepolia | `0x9380ee21a8C00f9FB42346F63E28BCf1B847de4F` |
| SentinelSwapV2 | Base Sepolia | `0xBDF3e24a673016dcCB00f7CA489456e3fa2d7D41` |
| SentinelReactiveV5 (brain, mock origin, 2.20 lREACT attached) | Lasna | `0x2C1d278d31d52Ec8405cF33E319ba0eB8C6b0d1F` |
| SentinelVaultV5 | Base Sepolia | `0x86b551AF1D8A5c0c2767Bf8Bb53F1F8bAeC74e18` |

Reused shared contracts: WETH
`0x4200000000000000000000000000000000000006`, MockUSDC
`0x96E467Ff7958851d307D28118EBAAD333CAb85B2`, callback proxy
`0x476F44b11F5C942c58f4c8E3d0300E5710743585` (same as flagship).
This set is NOT the rehearsal set (rehearsal oracle
`0x4e2DFac734D63AA391edE6556e374c2da69c7BA5`, brain
`0x81709d3C667f67562349ce8e0971ba238Ef0cCc8`, vault
`0x7E20bf60316e978f73eDeA2290b571C5633E0131` are untouched).

Deploy txs: oracle
`0x89da9e81f4448771db1010de08335445e53512a94818387ea60f38a99357d0bf`;
swap
`0xc7ce7ff352fcfaccef00985f06f8bcca52745215e1a75b34d28473a36a610723`;
brain
`0x9c992e1a3fa52dfb881ab44854ebb41087ea5b0438667f0616c224c005c7caee`;
vault
`0x7e2745af0bf0905f17a2054e5625f24ca731e9f06ffb5543c296355ac1e41bf0`.
Wiring: swap.setVault
`0x5b8de462bb93ad3f58257f2d10e61eb1ac9786fb28d05460ecaf1e5e8bcc5511`;
reactive.setVault
`0x3a99ff603d8fd84138967d9ce4cb660e4b140d3392ea21dc66fc51f571140ed9`.

## 2. Sourcify verification (all exact_match, creation + runtime)

| Contract | matchId |
|---|---|
| MockPriceOracle | 60033452 |
| SentinelSwapV2 | 60033484 |
| SentinelReactiveV5 | 60033492 |
| SentinelVaultV5 | 60033495 |

Verified via `forge verify-contract` (Sourcify v2), then re-checked
independently against the v2 API. Job IDs in
`release8-live-verify.log`.

## 3. Funding (faucet, 2 rounds)

Dev Lasna was 0.278213099979509185 lREACT — below the deploy gate
2.40. Two faucet rounds, 0.02 Sepolia ETH each, `request(dev)` on
`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`:
round 1 tx
`0xd38e9e7d6a97755a5327042a8fe1d05cf347cdfa1792aa1d69e457f25f251bbc`
(+2.1 exact, dev Lasna 2.378213099979509185); round 2 tx
`0x3d2f81d225ca2b8e40270c6bf0fd01ee0ae1ad2b3f22798067c98e1995a4148e`
(+2.1 exact, dev Lasna 4.478213099979509185). Gate passed with margin
2.078. Dev Sepolia after: 0.530118162909856994 ETH.
Brain attached 2.20 lREACT at creation; dev Lasna after deploy
2.096399399977691048; dev Base Sepolia 0.053080147666907048 ETH.

## 4. Seed (public flow, 0.002 WETH, shares exactly 1:1)

Wrap tx
`0xc53e8098c121a3889e9bb2c227767869a7a772edf4e21c91e7ddabccf133301d`;
approve tx
`0x660dae9478da461fbf11720cfb9088e0012764749439ced774367aefb37d1507`;
deposit tx
`0xd7cd05cf6dc5f0ed80ca9658506d2afbb264e8d5b331ce355f2b536d89ae839c`.
Read back: sharesOf(dev) 2000000000000000 (1:1), totalShares
2000000000000000, managedRisk 2000000000000000, managedSafe 0.
Desk seeded exactly 1,000 mUSDC (mint tx
`0x35600686e56b9a8e6d6ba4a029a79d393a1391030c44523241d49a72ca3a99fd`);
vault billing funded 0.0001 ETH (tx
`0xc915be1f7765bbcd4564e93037984948583467d8d0347b83dba5ac23b8021977`).

## 5. Flagship untouched — and NOT migrated

Flagship brain `0x37EeF5e3179E55c0e96E1528180B55Fa20DC150B` verified
updates 3, lastAction 0 before AND after every on-chain step in this
deploy (preflight, wiring, seed). Flagship vault
`0x108513e6439664fdeE9050e1ccc208e8c1b61441` totalShares
2300000000000000 throughout. The flagship position (0.0023 WETH)
was NOT moved: migration of the flagship to R8 contracts is NOT
authorized. This R8 live set runs parallel, same pattern as
Release 7. Open precondition for any future migration decision: the
flagship Chainlink adapter is ~45 h stale — a fresh sync() is needed
before migration can be considered.

## 6. What remains

- Live Proof R8 section: update the "post-drive attack tests still
  pending" line to PASS (F2 refused, F4 guard held, 22:56–22:57 UTC
  26 Nov) and add the live addresses above.
- DoraHacks description: append the Release 7 + Release 8 sections
  (draft in goal `hidden_files/release78-description-draft.md` — fill
  in the live R8 addresses from §1 and update the suite count row
  165/165 → 190/190; drop the draft's "Regression suite 190/190"
  sentence in the R8 section so the number appears exactly once).
- Video v8 upload + relink in 6 places.
- Git push: rename files + Release 7 files + Release 8 files
  (incl. this record) + presentation fixes. Re-verify the suite
  count before pushing — it is 190/190 at deploy time, not 174/174.
