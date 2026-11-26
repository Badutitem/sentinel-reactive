# Sentinel Release 7 — LIVE deploy record

Status: **LIVE SET DEPLOYED, SEEDED, VERIFIED. The 56-push firing drive has NOT run yet.**
Deploy 2026-11-26 18:01–18:03 UTC (27 Nov 01:01–01:03 WIB). Design:
`RELEASE7-DESIGN.md`. Rehearsal record (June core + Aug stretch, both
PASS): `RELEASE7-REHEARSAL.md`. Deploy driver:
`tools/deploy_release7.sh` (same proven script as the rehearsals).
Logs: goal `hidden_files/release7-live-faucet.log`,
`release7-live-deploy.log`. Live driver (prepared, NOT run):
`tools/rehearse_release7_live.sh`.

Pre-flight gates passed before any spend: `forge test` 165/165
(24 suites, 0 failed — re-run for this deploy); flagship brain
updates 3, lastAction 0, balance 11.5613437 lREACT (untouched).

Note on source: the repo working tree carries the Release rename
(comment-only NatSpec changes in `src/`, e.g. "trio #4" →
"Release 4"). No code changed. This set was compiled and deployed
from the current source, and Sourcify exact_match below confirms
the deployed bytecode matches it.

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
This set is NOT the rehearsal set (core oracle
`0xAdEBD7a0…`, brain `0x4030b23…`, vault `0xf68e7fC…` are untouched).

Deploy txs: oracle
`0xc8c1b621092fcdce9e5d24aa714cb01dce1d4d1070f80a412e2b8a3fcb62dfe0`;
swap
`0x51f82c8aeec9801fc4cb2cae1cb3bdeffdb20cfbe35e6241b590d371fffa0ec5`;
brain
`0x866aadff6c1b62c1d49e460428218414053458e283bda7c7e2a90c2a6f0dc54a`;
vault
`0x7521022b90adfe583916b182c6ead473a0740d550baaf96bc250d57b8ab2c806`;
`swap.setVault`
`0x91305c652be72a5af0efa4e5616530b294b4ae59cb3b822b583fda65c9ad43db`;
`reactive.setVault`
`0x1263d8d8d0e3165de2a1697fee4627eaec0644a86a30b603cd0d8d5577d677ac`;
desk seed mint (1,000 mUSDC)
`0x23d69173b718f5c68bf502b5b573c70f411ee14d23e13b8c1231239a03c1d7f5`;
vault billing fund (0.0001 ETH)
`0x21761c593a22d0802419cf67f0f5f2289d5e536d268f86566f92bd05fbb2f4a6`.

Wiring verified by reads at deploy: swap `priceSource` = oracle,
brain `oracle` = oracle, brain `updates` = 0 at birth, vault
`totalShares` = 0 at birth, swap `vault` = vault, brain `vault` =
vault. R-7 check passed: flagship brain still points at its
Chainlink adapter (`0xab9c7a5178b444cd1c1fd705e5ebecf4b9a1c25f`), not
the fresh oracle; flagship brain after wiring: updates 3,
lastAction 0.

## 2. Funding (faucet, 1 round)

Faucet round tx
`0xe86250b74ab56a5ff45a42b740499744fc0c0bbfd13ba6fd654966309d69ca30`
(Sepolia contract `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`,
`request(dev)`, 0.02 ETH, status 0x1). Dev Lasna 0.6423038 → 2.6423038
immediately (+2.0), then 2.7423038 (+0.1 more, see incident 1) —
gate ≥ 2.18 passed. Brain attach 2.00 lREACT at deploy (balance read
2.00 exactly after deploy).

## 3. Owner seed (public flow, dev wallet)

Wrap 0.002 ETH → WETH
`0x565e858cb342a6d0a7f277d3b0317f85de37e620589d8e8e708a94c7d0e1c58c`;
approve vault
`0x078838747235569f135c9f500cb216519f9b93a9556da544bcc98d5947f9806f`;
vault `deposit(0.002 WETH)`
`0xce1439ce07881c09e1f9ceeb61345425ffcad3f73dfea7916d4ce59c7a54c6c1`.
Shares read back exactly 1:1 — `sharesOf(dev)` =
2,000,000,000,000,000.

## 4. Verification reads (after seed)

- Vault: `totalShares` 2,000,000,000,000,000; `managedRisk`
  2,000,000,000,000,000 (0.002 WETH); `managedSafe` 0; `closed`
  false.
- Desk: mUSDC balance 1,000 exactly; WETH balance 0.
- Brain: `updates` 0; `lastAction` 0; `anchorPeak` 0 (warm-up — no
  price ingested yet); balance 2.00 lREACT; `oracle` = fresh oracle;
  `vault` = fresh vault.
- Swap: `vault` = fresh vault; `priceSource` = fresh oracle.
- Oracle: `latestPrice(WETH)` = 0 (no push yet — correct).
- Sourcify (v2 endpoint, all **exact_match** creation + runtime):
  oracle matchId 60015039; swap 60015040; brain 60015041; vault
  60015042. Verification job IDs: oracle
  `14f967d9-a111-4462-b8fa-3da2c1b29771`; swap
  `69b636db-2a5a-410e-aeae-92baa6952a89`; brain
  `c9f6d081-e2dc-4111-8509-ae2285c8fede`; vault
  `5624241e-a687-42e3-9262-ad9d0b844027`.

## 5. Flagship — untouched (before and after)

Before deploy: brain updates 3, lastAction 0, balance 11.5613437
lREACT. After deploy + seed: brain updates 3, lastAction 0,
balance 11.5613437 lREACT; flagship vault `totalShares`
2,300,000,000,000,000 (0.002 seed + 0.0003 filming-burner shares,
unchanged). No flagship transaction was sent at any point.

## 6. Spend (measured)

| Item | Amount |
|---|---|
| Sepolia ETH (faucet round) | 0.020000000000483132 (0.02 + 483,132 wei gas) |
| Lasna lREACT consumed | 2.180171500001801715 (2.00 brain attach + 0.1801715 deploy gas) |
| Base Sepolia ETH out of dev wallet | 0.0021175194267725 (0.002 WETH seed principal + 0.0001 vault billing + 0.0000175194267725 gas) |

Dev balances after deploy + seed: Base Sepolia
0.061849264347043344; Lasna 0.562132299981348377; Sepolia
0.610146133711001254.

## 7. Incidents (all tooling-side, no chain impact)

1. **Faucet credit arrived in two parts.** The faucet tx receipt
   was status 0x1 and dev Lasna read 2.6423038 (+2.0) at 18:01:36
   UTC; the deploy preflight at 18:01:56 UTC read 2.7423038 (+0.1
   more). Total round yield 2.1 lREACT — the same 2.0/2.1 variance
   seen in the 25 Nov top-up log (rounds yielded 2.0 or 2.1). No
   second faucet round was sent. Deploy gas reconciles exactly
   against the 2.7423038 figure (2.7423038 − 2.00 − 0.1801715 =
   0.5621323).
2. **Sepolia RPC first read empty.** `cast balance` on Sepolia via
   `ethereum-sepolia-rpc.publicnode.com` returned nothing once;
   retry on the same endpoint (and Tenderly) returned
   0.630146133711484386. `rpc.sepolia.org` 404s — do not use it.

## 8. What is ready / what is NOT done

Ready: the live set is deployed, funded (2.00 lREACT in the brain),
seeded (0.002 WETH, 1:1 shares), verified on Sourcify, and wired
to the June 2022 replay feed. The live driver
`tools/rehearse_release7_live.sh` is prepared with the new
addresses (diff vs the rehearsal driver: 4 addresses + log path +
header only) and logs to
`hidden_files/release7-live-driver.log`. Mirror scripts are in
goal `hidden_files/r7_mirror.py` / `r7_scan.py`; klines
`tools/data/klines_jun2022.json` (sha256
`e003dd72be0253ce5d91f999a620a95660018dd56008ffa5236b806b12d2ed47`).

NOT done: the 56-push firing drive (design §6) has NOT run — brain
still at updates 0. Nothing public touched: no DoraHacks edit, no
video, no git push, no README/docs change.

Pre-drive note: burner A (`0xEBB89D023458b2c65dB199585c314e4693aA9aD6`)
holds only ~0.000994 Base ETH — short of its 0.003 WETH deposit +
gas for the live drive. B (~0.003996) and C (~0.005496) cover
theirs. Top up A by ~0.0025 ETH from dev before the drive (dev
holds 0.0618 — ample). Do not start the drive until the mirror
re-run vs klines 120–175 passes again on this set's driver.
