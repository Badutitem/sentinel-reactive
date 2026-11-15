# Sentinel — an AI-guarded stop-loss

**A stop-loss whose brain is a neural network that lives inside a reactive
contract.** It watches a vault's price feed on Base Sepolia, decides
**HOLD / TRIM / EXIT** entirely on-chain, and executes its own protection
callback across chains. No keeper bot, no off-chain inference server, no
human watching charts at 3 a.m.

**Reactive Omni Buildathon · Track: Reactive Meets AI**

| | |
|---|---|
| 🎥 **Demo video** | https://www.youtube.com/watch?v=mcEdWm5whgE |
| 🏛️ **DoraHacks build** | https://dorahacks.io/build/51122 |
| 🎯 **Model accuracy** | **97.47%** on held-out series (shipped integer model; EXIT calls 100%) |
| ⚡ **Firing loop** | **≈ 2 s** end-to-end (origin → reactive → callback), proven live on testnet |
| 🧪 **Tests** | **42/42** Foundry tests pass, including exact-logit pins, a full-loop end-to-end suite and the real-asset vault suite |
| 🏦 **Vault** | **Real ERC20 position** — `SentinelVaultV2` holds WETH on Base Sepolia and de-risks into MockUSDC through `SentinelSwap` (live proof below) |
| 🧠 **Inference** | **100% on-chain** — an MLP forward pass in Solidity fixed point, inside the reactive contract |

## Why

Stop-losses and liquidation guards today are either dumb thresholds ("sell
at −10%") or trusted off-chain bots (which die, get stuck, or get turned
off). Sentinel replaces both with a learned, context-aware decision — it can
tell a calm dip from the start of a cascade because it sees volatility,
drawdown, momentum and trend together — executed by the Reactive Network's
inversion of control: *if this happens there, do that here*, with no
intermediary. The AI is part of the running system: every decision it makes
is emitted as an event in the reactive transaction itself.

## Architecture

```
 ORIGIN + DESTINATION: Base Sepolia (84532)        REACTIVE: Lasna (5318007)
 ┌───────────────────────────────┐                 ┌──────────────────────────────┐
 │ MockPriceOracle               │  PriceUpdated   │ SentinelReactive             │
 │  setPrice() ──emit──────────┐ │ ───────────────►│  subscribe() in constructor  │
 │                             └─┼─ event log      │  react(log)                  │
 │ SentinelVaultV2               │                 │    ├─ ring buffer (9 prices) │
 │  position: WETH balance       │                 │    ├─ features (6, fixed-pt) │
 │  executeProtection(r, action) │ ◄───────────────┤    ├─ MLP 6→8→3 forward pass │
 │    TRIM → sell half → USDC    │  callback via   │    └─ HOLD / TRIM / EXIT     │
 │    EXIT → sell all, close     │  proxy 0x476F…  │  requestCallbackV_1_0()      │
 └───────────────────────────────┘                 └──────────────────────────────┘
        ▲ guarded by: msg.sender == callback proxy          ▲ guarded by:
          AND injected sender == SentinelReactive             msg.sender == system
                                                              contract 0x8888…8888
```

The three legs of the loop are exactly the three transactions proven
on-chain below: **origin event → reactive transaction → destination
callback**.

## How it works

On every price update, `SentinelReactive` recomputes six market features
from a 9-price ring buffer and runs the MLP forward pass — entirely
on-chain, in Solidity fixed point.

**Features** (all scaled by 1e6):

| # | Feature | Meaning |
|---|---------|---------|
| 0 | last return | most recent step change |
| 1 | mean return | drift over the window (8 returns) |
| 2 | volatility | RMS of returns |
| 3 | drawdown | distance below the window peak |
| 4 | momentum | first → last price change over the window |
| 5 | price vs mean | last price relative to the window average |

**Model**: a 6 → 8 → 3 multilayer perceptron. Hidden units use ReLU; the
output is three logits (**HOLD / TRIM / EXIT**) and argmax wins. All math is
signed fixed point (features ×1e6, weights ×1000, one truncating division
per neuron), so the on-chain result is bit-exact against the off-chain
reference — the unit tests assert exact logits, not approximations. Hidden
units are interpretable: a *crash* detector (drawdown + volatility), a
*severity* unit with a threshold bias that only deep drawdowns pass, a
*downtrend* unit, and a *calm* unit, plus four small texture units.

**Firing rules**: HOLD never fires. TRIM/EXIT request a callback, subject
to an anti-spam cooldown (origin timestamps) — **except escalations**: a
TRIM followed by a worsening EXIT always fires immediately, because a
stop-loss that waits out its own cooldown during a crash is not a
stop-loss.

**Callback authentication** follows the Omni model strictly: the payload's
first argument is an `address(0)` placeholder that the network overwrites
with the reactive contract's address; the vault checks **both** that the
caller is the chain's callback proxy (`onlyServiceProvider`) and that the
injected sender is Sentinel (`onlyCallbackSender`). The reactive side only
accepts logs from the system contract (`onlySystem`).

## Contracts

| Contract | Chain | Role |
|----------|-------|------|
| `src/MockPriceOracle.sol` | Base Sepolia | Mock origin feed; `setPrice` emits `PriceUpdated(token, price, timestamp)` |
| `src/SentinelReactive.sol` | Lasna | `AbstractReactive`; subscribes in constructor, features + inference in `react()`, requests callbacks |
| `src/SentinelVault.sol` | Base Sepolia | `AbstractCallback`; phase-1 mock position, `executeProtection` de-risks (TRIM halves, EXIT closes) |
| `src/MockUSDC.sol` | Base Sepolia | Minimal ERC20 (phase 2); the vault's de-risk target asset |
| `src/SentinelSwap.sol` | Base Sepolia | Fixed-price desk (phase 2); buys the vault's WETH for MockUSDC at the oracle price, holds the seeded reserve |
| `src/SentinelVaultV2.sol` | Base Sepolia | `AbstractCallback`; **real WETH position** (phase 2), `executeProtection` de-risks via `SentinelSwap` (TRIM sells half, EXIT sells all and closes) |
| `src/model/SentinelModel.sol` | (library) | Fixed-point MLP forward pass |
| `src/model/SentinelWeights.sol` | (library) | Quantized weights — **generated by `tools/train.py`, do not hand-edit** |

## Live proof (testnet, 2026-11-13)

All three contracts are deployed and **Sourcify-verified (exact match)**:

| Contract | Chain | Address | Deploy tx |
|----------|-------|---------|-----------|
| `MockPriceOracle` | Base Sepolia (84532) | `0xB828F2F6266E4A1705224ac0b1fCDFE0415351ee` | `0xa0a8dd8bd29002e56ab153076ec5363cba7da2580675d1e4646ce70640669121` |
| `SentinelReactive` | Lasna (5318007) | `0xB828F2F6266E4A1705224ac0b1fCDFE0415351ee` | `0x1349cd6d58fdda0c2a15fee36549d3b25e566988e374ca782445c268b058e563` |
| `SentinelVault` | Base Sepolia (84532) | `0x6f723a2F0E4A45111F42A74448426AAAAb3d7641` | `0x389f8694cbc967cd6076355271a430ffd19633ee7ec9c8ec00b28af670ea547f` |

(The oracle and the reactive contract share an address — both were their
deployer's nonce-0 creation, one per chain.)

Explorers: https://sepolia.basescan.org (Base Sepolia) ·
https://lasna.reactscan.net (Lasna). System contract (Lasna + mainnet):
`0x8888888888888888888888888888888888888888`; callback proxy (Base Sepolia):
`0x476F44b11F5C942c58f4c8E3d0300E5710743585`.

**The rehearsal** — 30 oracle pushes on Base Sepolia → 30 reactive
transactions on Lasna → 2 protection callbacks back on Base Sepolia:

- **Calm:** 7 decisions, all **HOLD**, zero callbacks, position untouched.
- **Grind down → TRIM** (full loop ≈ 2 s): origin
  `0x7aba9f0d8cb303763c1c5298b17193f4c32cfbf9dbe819c5649ba1170f2cded9` →
  reactive `0x9142977c5df4a28d149d62218849bd1ec36abfda5e05546789a4c6486aa3448e`
  → callback `0xb5914403cbd5b49baa10abdd9436fde3f8f0ca6f08ba972318e3e9e664b20eaa`
  (position 1000 → 500).
- **Crash → EXIT** (full loop ≈ 2 s): origin
  `0x1bc65058749df45c25215642d520657fe6a7a2148d2ff3c41f237dba77bc7086` →
  reactive `0x42cf48c375a3453ff09410d8fecc5b7f64ebad8e8925f8596213e0b9ce1400c2`
  → callback `0x1d506a0077b046cf043e303635f5f118800f7b0c7661a172207918c6946d40d7`
  (position 1000 → 0, vault closed).

End state verified on-chain: 30 updates, `lastAction = EXIT`,
`protectionCount = 2`, zero service debt on both networks. The full
stage-by-stage rehearsal log (including the calm stage's ≈25 s slowest
reaction) is in [DEVLOG.md](DEVLOG.md).

### Phase 2 — real-asset vault (2026-11-15)

The reactive contract's callback target was switched (`setVault` on Lasna,
`0xd9d983a15f270a916d60d7c4914ae3d4b82aedc84232c2427a44d7c72ea8d9ee`) from
the phase-1 mock vault to **SentinelVaultV2**, which holds a real WETH
position and de-risks through **SentinelSwap** into **MockUSDC**. All three
new contracts are deployed and **Sourcify-verified (exact match)**:

| Contract | Chain | Address | Deploy tx |
|----------|-------|---------|-----------|
| `MockUSDC` | Base Sepolia (84532) | `0x96E467Ff7958851d307D28118EBAAD333CAb85B2` | `0xb6e416a3d303dbcb721634d09a2c57bfdbe379d0acfa623d10c2eb6e04dd7876` |
| `SentinelSwap` | Base Sepolia (84532) | `0x2C1d278d31d52Ec8405cF33E319ba0eB8C6b0d1F` | `0x31a88186cb276fe19e046283b8d745982b7775e5602d25648dd0c779dc08e3ea` |
| `SentinelVaultV2` | Base Sepolia (84532) | `0x29c0b2FAc813e59E23E12b8f6699bF17d4512192` | `0x1907efc0c1b346ec1d1405b8ae8321022f14502dd401d1fedf6e264139826922` |

**The phase-2 rehearsal** — 13 oracle pushes → 13 reactive transactions →
2 protection callbacks, with real ERC20 transfers inside the callback
transactions:

- **Calm:** 5 decisions, all **HOLD**, zero callbacks, vault untouched
  (0.01 WETH).
- **Grind down → TRIM** (full loop ≈ 1 s): origin
  `0xa1c46ea2b9fbd2bc70ee0e4fd946cec200a643582a287f12171b377018f31c4a` →
  reactive `0x00fc5e4537786544f1a9a6ca6a8d7ad17d8c63d836e6fa05bccf441fd2d30d10`
  → callback `0xf8dabf14c32a5bd234f58ff14e9a8328f717707377acf2989c77fb1e07232072`
  — the callback transferred **0.005 WETH** vault → swap and **14.1
  MockUSDC** swap → vault (position 0.01 → 0.005 WETH).
- **Crash → EXIT** (full loop ≈ 2 s): origin
  `0xbed70db574e02bd3912b4cfa74f5e86cca004800620104effd766e9374a13995` →
  reactive `0xfe39a88434271543356c988fa70fd256946a68d6cba0ee19a49fe3492715af60`
  → callback `0xa55c9079d19bb55ff6e69f992bc2e7fea56a8aa12747d3b1ed9f7f9f0e3c14d2`
  (position re-armed to 0.015 WETH between stages) — **0.015 WETH** out,
  **35.1 MockUSDC** in, vault closed.

End state verified on-chain: VaultV2 holds 0 WETH / 49.2 MockUSDC,
`protectionCount = 2`, closed; the swap holds 0.02 WETH against a 950.8
MockUSDC reserve (seeded 1,000 − 14.1 − 35.1 — reconciles exactly);
reactive `updates = 43`, `lastAction = EXIT`, zero debt, 0.3371809 lREACT
remaining (≈ 12 more reacts; no top-up was needed for the lean rehearsal).
Full log in [DEVLOG.md](DEVLOG.md).

**Deviation, stated plainly:** the deployed reactive contract's
subscription still watches the phase-1 stand-in token
(`0x000000000000000000000000000000000000dEaD`), not WETH. The phase-2
rehearsal drove decisions on that key and mirrored the identical % series
onto the oracle's WETH price key — the key `SentinelSwap` prices from;
both keys live in the same `MockPriceOracle`. A WETH-subscribed reactive
ships with the Chainlink upgrade, which redeploys the reactive leg.

## Model & training

The weights were trained off-chain with `tools/train.py` on **540 synthetic
price series** (calm / uptrend / chop / grind-down / crash / V-recovery;
24,051 train / 6,001 held-out windows, split by series so held-out series
are genuinely unseen), labelled by the stop-loss policy ladder (drawdown
≥ 21% → EXIT; 3–21% and still falling → TRIM; recovering → HOLD). Before
training, the script proved its integer reference implementation bit-for-bit
against the Solidity behaviour; the trained weights were then quantized to
integers (×1000) and embedded in `src/model/SentinelWeights.sol`.

Held-out accuracy: float model 97.10%, quantized integer model (the one
that ships) **97.47%** — per class HOLD 96.9% / TRIM 99.1% / **EXIT 100%**.
The shipped weights are pinned by exact-logit unit tests (calm → HOLD,
grind → TRIM, crash → EXIT). Everything is seeded; re-running the trainer
reproduces the same weights. Only dependency: numpy.

## Build & test

Requires [Foundry](https://getfoundry.sh) (solc 0.8.29). Dependencies
(`forge-std`, `reactive-lib-omni` v0.1.0) live in `lib/` as git submodules.

```bash
forge build
forge test        # 42 tests, 6 suites
```

| Suite | Covers |
|-------|--------|
| `SentinelModel.t.sol` (5) | Exact logits/hidden activations for zero, calm, grind-down and crash feature vectors; uptrend holds |
| `SentinelVault.t.sol` (6) | TRIM/EXIT position effects; both auth guards revert for wrong caller/sender; reopen |
| `SentinelReactive.t.sol` (10) | Subscription recorded by a mock system contract etched at `0x8888…8888`; `onlySystem` guard; unknown topics ignored; warm-up; exact features + scores on a crash path; TRIM-then-EXIT firing; cooldown block + expiry; no-vault safety |
| `SentinelEndToEnd.t.sol` (3) | The full loop with a **real** oracle event: calm market → no callback; crash → TRIM then EXIT callbacks delivered network-style (proxy caller, injected sender) → position 1000 → 500 → 0 |
| `SentinelSwap.t.sol` (7) | Fixed-price desk: swap math at the oracle price with decimals normalisation, reserve accounting, reserve-shortfall partial fill (never reverts), zero-price / zero-amount no-ops |
| `SentinelVaultV2.t.sol` (11) | Real-balance position view; TRIM sells exactly half, EXIT empties and closes; both auth guards revert; re-arm after EXIT; end-to-end loop asserting actual ERC20 balances move |

## Limitations (honest list)

- **Synthetic training data.** The model is trained and evaluated on
  generated price series (540 of them, six scenario families), not on real
  market history. The 97.47% figure measures agreement with the labelling
  policy on unseen *synthetic* series — it is not a backtest.
- **The labelling policy is a rule ladder.** Labels come from a hand-written
  drawdown policy; the MLP learns a smooth, context-aware approximation of
  it. Where learning beats the raw ladder (smoothing in choppy series) is
  not yet quantified — no rule-baseline comparison has been published.
- **Mock oracle for the demo.** The live proof uses `MockPriceOracle`
  (anyone can call `setPrice`) so the crash could be driven on demand. No
  real price feed (e.g. Chainlink) is wired into the loop yet. The deployed
  reactive contract also still subscribes to the phase-1 stand-in token
  (`0x000000000000000000000000000000000000dEaD`), not WETH — in the phase-2
  rehearsal the identical % series was mirrored onto the oracle's WETH key
  for swap pricing. The Chainlink adapter is the next step: it redeploys
  the reactive leg subscribed to WETH on a real feed.
- **Simulated market, real tokens.** Since phase 2 (2026-11-15) the live
  vault is `SentinelVaultV2`: it holds real WETH and TRIM/EXIT execute real
  transfers. But the counterparty is `SentinelSwap` — a fixed-price desk
  seeded with a MockUSDC reserve and priced from the mock oracle — not a
  live DEX market, and MockUSDC is a test token, not Circle's USDC. (The
  phase-1 `SentinelVault` remains deployed with its counter-only position.)
- **Testnet only.** Everything runs on Base Sepolia + Lasna testnet with
  testnet funds; nothing here guards real money.
- **Narrow by construction.** One token, one oracle (immutable), a 9-price
  feature window, and behaviour frozen into the shipped weights — no
  configurability or online adaptation.
- **Operating cost.** The reactive contract pays for its own reactive
  transactions (~0.027 lREACT per price update observed) and silently
  receives nothing while in debt, so its balance has to be monitored and
  topped up for continuous operation.

## Development history

Phase notes, funding and deployment records, the full rehearsal log and the
closed TODO history live in [DEVLOG.md](DEVLOG.md). Deployment keys were
testnet-only and are kept out of this repo (git-ignored local env files).

## License

[MIT](LICENSE)
