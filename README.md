# Sentinel — an AI-guarded stop-loss

**Reactive Omni Buildathon · Track: Reactive Meets AI**

Sentinel is a stop-loss whose brain is a **neural network that lives inside a
reactive contract**. A price oracle streams updates for a vault position; on
every update the reactive contract recomputes market features and runs a small
MLP forward pass — entirely on-chain, in Solidity fixed point. When the model
votes **TRIM** or **EXIT**, the contract requests a cross-chain callback and
the vault de-risks its position. No keeper bot, no off-chain inference server,
no human watching charts at 3 a.m.: the model is part of the running system,
and every decision it makes is emitted as an event in the reactive transaction
itself.

## Why

Stop-losses and liquidation guards today are either dumb thresholds ("sell at
−10%") or trusted off-chain bots (which die, get stuck, or get turned off).
Sentinel replaces both with a learned, context-aware decision — it can tell a
calm dip from the start of a cascade because it sees volatility, drawdown,
momentum and trend together — executed by the Reactive Network's inversion of
control: *if this happens there, do that here*, with no intermediary.

## Architecture

```
 ORIGIN + DESTINATION: Base Sepolia (84532)        REACTIVE: Lasna (5318007)
 ┌───────────────────────────────┐                 ┌──────────────────────────────┐
 │ MockPriceOracle               │  PriceUpdated   │ SentinelReactive             │
 │  setPrice() ──emit──────────┐ │ ───────────────►│  subscribe() in constructor  │
 │                             └─┼─ event log      │  react(log)                  │
 │ SentinelVault                 │                 │    ├─ ring buffer (9 prices) │
 │  position: 1000 units         │                 │    ├─ features (6, fixed-pt) │
 │  executeProtection(r, action) │ ◄───────────────┤    ├─ MLP 6→8→3 forward pass │
 │    TRIM → halve position      │  callback via   │    └─ HOLD / TRIM / EXIT     │
 │    EXIT → close position      │  proxy 0x476F…  │  requestCallbackV_1_0()      │
 └───────────────────────────────┘                 └──────────────────────────────┘
        ▲ guarded by: msg.sender == callback proxy          ▲ guarded by:
          AND injected sender == SentinelReactive             msg.sender == system
                                                              contract 0x8888…8888
```

The three legs of the loop are exactly the three transactions the submission
proves on-chain: **origin event → reactive transaction → destination
callback**.

## How the AI works

**Features** (recomputed on every price update from a 9-price ring buffer,
all scaled by 1e6):

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
signed fixed point (features ×1e6, weights ×1000, one truncating division per
neuron), so the on-chain result is bit-exact against the off-chain reference —
the unit tests assert exact logits, not approximations. Hidden units are
interpretable: a *crash* detector (drawdown + volatility), a *severity* unit
with a threshold bias that only deep drawdowns pass, a *downtrend* unit, and a
*calm* unit, plus four small texture units.

**Firing rules**: HOLD never fires. TRIM/EXIT request a callback, subject to
an anti-spam cooldown (origin timestamps) — **except escalations**: a TRIM
followed by a worsening EXIT always fires immediately, because a stop-loss
that waits out its own cooldown during a crash is not a stop-loss.

**Weights — status**: phase 2 ships **trained weights**
(`src/model/SentinelWeights.sol`, generated — do not hand-edit). They were
trained by `tools/train.py` on 540 synthetic price series (24,051 train /
6,001 held-out windows) labelled by the stop-loss policy ladder (drawdown
≥ 21% → EXIT; 3–21% and still falling → TRIM; recovering → HOLD). Accuracy
on held-out series: float model 97.10%, quantized integer model (the one
that ships) **97.47%** — per class HOLD 96.9% / TRIM 99.1% / EXIT 100%.
Before training, the script proved its integer reference implementation
bit-for-bit against the phase-1 Solidity behaviour; the shipped weights are
pinned by exact-logit unit tests (calm → HOLD, grind → TRIM, crash → EXIT)
and all 24 Foundry tests pass. The architecture, features and firing rules
are unchanged from phase 1 — only the numbers were learned.

## Contracts

| Contract | Chain | Role |
|----------|-------|------|
| `src/MockPriceOracle.sol` | Base Sepolia | Mock origin feed; `setPrice` emits `PriceUpdated(token, price, timestamp)` |
| `src/SentinelReactive.sol` | Lasna | `AbstractReactive`; subscribes in constructor, features + inference in `react()`, requests callbacks |
| `src/SentinelVault.sol` | Base Sepolia | `AbstractCallback`; mock position, `executeProtection` de-risks (TRIM halves, EXIT closes) |
| `src/model/SentinelModel.sol` | (library) | Fixed-point MLP forward pass |
| `src/model/SentinelWeights.sol` | (library) | Quantized weights — **generated by `tools/train.py`** |

Callback authentication follows the Omni model strictly: the payload's first
argument is an `address(0)` placeholder that the network overwrites with the
reactive contract's address; the vault checks **both** that the caller is the
chain's callback proxy (`onlyServiceProvider`) and that the injected sender is
Sentinel (`onlyCallbackSender`). The reactive side only accepts logs from the
system contract (`onlySystem`).

## Build & test

Requires [Foundry](https://getfoundry.sh) (solc 0.8.29). Dependencies
(`forge-std`, `reactive-lib-omni` v0.1.0) live in `lib/` as git submodules.

```bash
forge build
forge test        # 24 tests, 4 suites
```

| Suite | Covers |
|-------|--------|
| `SentinelModel.t.sol` (5) | Exact logits/hidden activations for zero, calm, grind-down and crash feature vectors; uptrend holds |
| `SentinelVault.t.sol` (6) | TRIM/EXIT position effects; both auth guards revert for wrong caller/sender; reopen |
| `SentinelReactive.t.sol` (10) | Subscription recorded by a mock system contract etched at `0x8888…8888`; `onlySystem` guard; unknown topics ignored; warm-up; exact features + scores on a crash path; TRIM-then-EXIT firing; cooldown block + expiry; no-vault safety |
| `SentinelEndToEnd.t.sol` (3) | The full loop with a **real** oracle event: calm market → no callback; crash → TRIM then EXIT callbacks delivered network-style (proxy caller, injected sender) → position 1000 → 500 → 0 |

A single-chain rehearsal deploy (anvil) is in `script/Deploy.s.sol`.

## Networks & key addresses

| Network | Chain ID | RPC | Currency |
|---------|----------|-----|----------|
| Reactive Lasna (testnet) | 5318007 | https://lasna-rpc.rnk.dev | lREACT |
| Base Sepolia | 84532 | https://sepolia.base.org | ETH |

- System contract (Lasna + mainnet): `0x8888888888888888888888888888888888888888`
- Callback proxy (Base Sepolia): `0x476F44b11F5C942c58f4c8E3d0300E5710743585`

### Deployed addresses (testnet, 2026-11-13)

| Contract | Chain | Address | Deploy tx |
|----------|-------|---------|-----------|
| `MockPriceOracle` | Base Sepolia (84532) | `0xB828F2F6266E4A1705224ac0b1fCDFE0415351ee` | `0xa0a8dd8bd29002e56ab153076ec5363cba7da2580675d1e4646ce70640669121` |
| `SentinelReactive` | Lasna (5318007) | `0xB828F2F6266E4A1705224ac0b1fCDFE0415351ee` | `0x1349cd6d58fdda0c2a15fee36549d3b25e566988e374ca782445c268b058e563` |
| `SentinelVault` | Base Sepolia (84532) | `0x6f723a2F0E4A45111F42A74448426AAAAb3d7641` | `0x389f8694cbc967cd6076355271a430ffd19633ee7ec9c8ec00b28af670ea547f` |

(Fun quirk: the oracle and the reactive contract share an address — both
were their deployer's nonce-0 creation, one per chain.) All three contracts
are **Sourcify-verified (exact match)**. Wiring: `setVault` (Lasna)
`0x6ba3b56887ada7058a11b44bf0ebb1b4a9f6700e9ba5fe87d1733c7a83bc5cf5` ·
`openPosition(1000)` `0xff14511b7503588fed6b023570f0f012702c6510faab7f2c749eedaba01b4945` ·
vault funded with 0.02 ETH `0xe2d94fcad0ad7fc58b522b65995ece5c511ade3c9a496b6acdee332544c3bcb4` ·
reactive contract funded with 1.0 lREACT at deploy + 0.5 lREACT top-up
`0xfd3b08d9865502970462f31fe63d40fee572fe3aac52567d45f9d4e4eac21710`.

## Deployment order (phase 2, for reference)

1. Get testnet funds: Sepolia ETH → swap for lREACT via the faucet contract
   (from Ethereum Sepolia: `request(address)` on
   `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`; from Base Sepolia:
   `0x2afaFD298b23b62760711756088F75B7409f5967`; 1 ETH → 100 lREACT); keep
   some Base Sepolia ETH for the vault's callback billing.
2. Deploy `MockPriceOracle` on Base Sepolia (the reactive contract's
   constructor needs its address — immutable, so the oracle goes first).
3. Deploy `SentinelReactive` on Lasna, funded with lREACT (it pays for its own
   reactive transactions; a contract in debt receives nothing).
4. Deploy `SentinelVault` on Base Sepolia with the reactive contract's
   address (immutable), then `SentinelReactive.setVault(vault)` and
   `SentinelVault.openPosition(1000)`; fund the vault with a little Base
   Sepolia ETH (callback billing).
5. Drive price scenarios with `setPrice` and collect the three tx hashes.

### Phase-2 status (2026-11-13) — DEPLOYED + rehearsed live

- ✅ **Training done** (see "Weights — status" above): `tools/train.py`
  written, weights regenerated, test vectors re-pinned, `forge test` 24/24.
- ✅ **Throwaway dev wallet**: `0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94`
  (testnet only, never to hold real funds; private key in `.env.local`,
  mode 600, git-ignored — it is NOT the user's wallet).
- ✅ **Funding done.** The user transferred 0.1 Sepolia ETH to the dev
  wallet, which unlocked the scripted sequence: faucet swap of 0.02 ETH →
  **2.1 lREACT** credited on Lasna (tx
  `0x1dc70912d6a930cf9024668509487268e1de7f75ba985c8645281b3f531cde0d`), and
  a 0.05 ETH bridge deposit to Base Sepolia via the L1StandardBridge (tx
  `0x08345c161a808a498413933eb42113b05d29724cd3456dfd2833798f3c32a591` —
  plain transfer, same address credited on L2).
- ✅ **Deployed + Sourcify-verified (exact match)** — all three contracts,
  addresses in the table above.
- ✅ **Live rehearsal completed** — next section.

### Live rehearsal (2026-11-13, real cross-chain loop)

30 oracle pushes on Base Sepolia → 30 reactive transactions on Lasna →
2 protection callbacks back on Base Sepolia. Driver: `tools/rehearse.sh`.
Latencies are block-timestamp deltas (Base Sepolia blocks 2 s, Lasna ~1 s).

**Stage A — calm** (9 pushes, 100.0 → 100.2 wiggle): 7 `Decision` events,
all **HOLD**, **zero callbacks**, position untouched. Last origin push
`0x294fa60da3b2932bc3282dfda44bb7836afbca6201a9404745f313aeed4d8dfd`
(07:32:29 UTC) → its Lasna `Decision` tx
`0x83cd350deaa77d0bef29dc5c6ae5332eb4ba969047863cf1dc4c4f220a578411`
(07:32:54 UTC) — ≈25 s, the slowest reaction observed (relay cadence at
first contact; the callback stages below reacted within the same second).

**Stage B — grind down** (9 pushes, 99.0 → 87.7): **TRIM** decided on the
3rd push (96.0) and fired immediately:

| Leg | Tx | Block ts (UTC) |
|-----|----|----------------|
| Origin `setPrice(96.0)` | `0x7aba9f0d8cb303763c1c5298b17193f4c32cfbf9dbe819c5649ba1170f2cded9` | 07:33:50 |
| Reactive `Decision`+`CallbackRequested` (TRIM) | `0x9142977c5df4a28d149d62218849bd1ec36abfda5e05546789a4c6486aa3448e` | 07:33:50 |
| Callback `ProtectionExecuted` (1000 → 500) | `0xb5914403cbd5b49baa10abdd9436fde3f8f0ca6f08ba972318e3e9e664b20eaa` | 07:33:52 |

Full loop ≈ **2 s**. Later grind pushes kept deciding TRIM; the 300 s
cooldown suppressed duplicate callbacks, as designed.

**Stage C — crash** (position re-armed to 1000 via
`0xdecad42804adae02170e7d04f492e9f699de82ab34573618fc3e959ff04e5778`,
9 flush pushes ~100, then 92.0 / 81.0 / 76.0): the 92 and 81 legs decided
TRIM (cooldown-suppressed); at 76.0 the model escalated to **EXIT**,
bypassing the cooldown:

| Leg | Tx | Block ts (UTC) |
|-----|----|----------------|
| Origin `setPrice(76.0)` | `0x1bc65058749df45c25215642d520657fe6a7a2148d2ff3c41f237dba77bc7086` | 07:36:53 |
| Reactive `Decision`+`CallbackRequested` (EXIT) | `0x42cf48c375a3453ff09410d8fecc5b7f64ebad8e8925f8596213e0b9ce1400c2` | 07:36:53 |
| Callback `ProtectionExecuted` (1000 → 0, closed) | `0x1d506a0077b046cf043e303635f5f118800f7b0c7661a172207918c6946d40d7` | 07:36:55 |

Full loop ≈ **2 s**. End state verified on-chain: `updates = 30`,
`lastAction = EXIT`, `protectionCount = 2`, position 0, vault closed,
**zero service debt** on both the Lasna system contract and the Base
Sepolia callback proxy.

**Operating costs observed:** ~0.027 lREACT per reactive transaction
(30 updates ≈ 0.81 lREACT drawn from the reactive contract's balance — it
holds 0.69 lREACT after a post-rehearsal top-up, enough for ~25 more
updates); callbacks cost the vault ~0.0000009 ETH each.

## Phase 2 TODO

- [x] `tools/train.py`: synthetic series generator + trainer + quantizer;
      regenerate `SentinelWeights.sol` with trained weights; refresh the
      reference test vectors and re-run `forge test`. **Done 2026-11-13 —
      integer model 97.47% held-out, 24/24 tests pass.**
- [x] Faucet run: Sepolia ETH → lREACT; fund reactive contract + vault.
      **Done 2026-11-13** (user-funded dev wallet; see status note above).
- [x] Deploy to Lasna + Base Sepolia (order above); verify contracts on
      Sourcify (`forge verify-contract --verifier sourcify`). **Done
      2026-11-13 — all three exact_match.**
- [x] Live rehearsal on testnet: calm (no action), grind-down (TRIM), flash
      crash (EXIT); record the origin → reactive → callback tx-hash triples
      and full-loop latency for each. **Done 2026-11-13 — full loop ≈ 2 s
      on both firing stages.**
- [x] Fill in deployed addresses + tx hashes in this README. **Done
      2026-11-13.**
- [ ] Demo video (< 3 min): drive the crash live on testnet, show the model
      deciding (Decision events) and the vault closing.
- [ ] Submit the BUIDL on DoraHacks — target **Dec 4 WIB**, hard deadline
      Dec 5, 2026.

## License

MIT
