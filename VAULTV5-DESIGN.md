# SentinelVaultV5 — design (per-user pooled vault, trio #6 candidate)

Status: phase 1 (design + contract + tests, local only — NOT deployed).
Predecessor: `src/SentinelVaultV4.sol` (trio #5, one shared position,
public deposit, owner-only withdraw, no per-user accounting).
Companion docs: `TRIO5-DESIGN.md` (the brain/vault/desk trio as shipped),
`RERISK-VARIANTS.md` (why re-risk is variant B, scale-in).

## 1. What changes, what does not

V5 changes exactly one thing: **who owns the position**. The vault's WETH /
MockUSDC pool stops being one operator's position and becomes a pool that
anyone can fund and anyone can leave, with per-user share accounting.

Everything the rest of the system depends on is unchanged:

| Surface | V4 | V5 |
|---|---|---|
| Callback ABI | `executeProtection(address,uint8)`, actions 1 TRIM / 2 EXIT / 3 RERISK / 4 RERISK_FINAL | identical, same guards (`onlyServiceProvider` + `onlyCallbackSender`) |
| Desk | `SentinelSwapV2`, `onlyVault`, vault grants max allowances on both assets in the constructor | identical |
| Guard semantics | TRIM sells half the risk, EXIT sells all + closes, RERISK spends half the safe balance, RERISK_FINAL spends the rest | identical — but computed on the **managed** balances (§3), not raw `balanceOf` |
| Views | `positionSize()`, `safeBalance()`, `health()`, `closed`, `protectionCount`, `reriskCount`, `lastProtectionAt` | identical signatures; position/safe now report the managed totals |
| `deposit(uint256)` | pulls WETH, re-arms (`closed = false`), emits `PositionOpened` | same selector and re-arm semantics; additionally mints shares and returns the share count (return values are not part of the selector — existing callers, the demo app and the agent connector, are unaffected) |
| Owner `withdraw(asset,to,amount)` | unrestricted ERC20 rescue | **restricted for the two pool assets** (§7) — the one deliberate semantic break, forced by per-user backing |

## 2. Share model: basket shares over managed totals

A share is not a claim on a price; it is a claim on a **fraction of the
pool's two balances**. If you hold `s` of `T` shares, your claim is
`s/T` of the managed WETH and `s/T` of the managed MockUSDC. Guard
actions change the pool's composition (WETH → USDC on TRIM/EXIT, back on
RERISK); they never change anyone's fraction. That is the whole point of
pooling: the brain manages one position, the users own slices of
whatever the position currently is.

### 2.1 Managed totals (the anti-donation decision)

Share value is computed from two state variables, `managedRisk` and
`managedSafe` — **not** from the vault's raw token balances. Managed
totals move only through sanctioned flows:

- `deposit(a)`: `managedRisk += a` (exactly the pulled amount).
- `redeem(s)`: managed totals decrease by exactly the amounts paid out.
- `executeProtection(...)`: the callback measures the vault's real
  balance deltas across the desk trade (`after − before`, per asset)
  and applies those deltas to the managed totals. A pending donation
  sits inside both `before` and `after`, so it cancels out of the
  delta and never enters the managed totals.
- Nothing else moves them. In particular, a plain ERC20 transfer to the
  vault address (a "donation") changes **no** managed total, **no**
  share price, and **no** user's claim.

Why: the classic share-inflation attack (first depositor mints 1 share
for 1 wei, donates a fortune directly to the vault, the next victim's
deposit rounds to 0 shares, the attacker redeems everything) works only
because naive vaults price shares off `balanceOf`. With managed totals
the donation is invisible to pricing, so the attack has no mechanism —
no virtual-share offset, no minimum-deposit band-aid needed. The cost
of this choice: donated funds are *surplus* (§7) — they back nobody's
claim until the owner skims them. On a testnet demo vault that is the
right trade; it also matches how the desk already treats its own
reserves (seeded by plain transfer, spent only through sanctioned
calls).

Invariant INV-1 (backing): at all times
`riskAsset.balanceOf(vault) >= managedRisk` and
`safeAsset.balanceOf(vault) >= managedSafe`. Every payout is computed
from managed totals, so claims can always be paid in full.

### 2.2 Share price and the first depositor

Deposits arrive in WETH only, but the pool may hold a WETH/USDC mix, so
minting needs one conversion: the pool's value expressed in risk-asset
units,

```
poolRiskEq = managedRisk + riskEq(managedSafe)
riskEq(x)  = x * riskUnit * PRICE_SCALE / (safeUnit * price)
```

using the **desk's own reference price** — read from
`swap.priceSource()`, the identical source and formula
`SentinelSwapV2.swapSafeForRisk` uses, so the vault can never value the
safe leg at a price the desk would not trade at. No new constructor
parameter: the price source is reached through the already-wired swap.
If the pool holds no safe asset (`managedSafe == 0`), the price is
never consulted and deposits work at any oracle state.

- **First depositor** (`totalShares == 0`): by INV-2 below, managed
  totals are then exactly 0, and shares mint **1:1** with the WETH
  deposited (both assets are 18-decimal as deployed; shares carry the
  risk asset's scale). There is no seed price to manipulate — the
  first depositor's exchange rate is definitional, and §2.1 removes
  the donation lever that makes first-deposit pricing dangerous in
  naive vaults.
- **Later depositors**: `shares = floor(amount * totalShares / poolRiskEq)`,
  computed *before* the deposit lands. Flooring rounds against the
  depositor and in favour of the existing holders (§5). A deposit that
  would mint 0 shares **reverts** (`ZeroShares`) — the vault never takes
  funds for nothing.
- **No reference price** (`price == 0`) while `managedSafe > 0`: the
  safe leg cannot be valued, so `deposit` reverts (`NoReferencePrice`).
  Deposits into a risk-only pool, all redemptions, and all guard
  callbacks are unaffected by oracle state.

### 2.3 Redemption

`redeem(s)` burns `s` of the caller's shares and pays, pro-rata:

```
riskOut = floor(s * managedRisk / totalShares)
safeOut = floor(s * managedSafe / totalShares)
```

No price is consulted: a slice of the basket is a slice of the basket
at any price. Rounding floors in favour of the pool (§5).

**Full-redemption rule:** when `s == totalShares` (the caller is
redeeming every outstanding share), the payout is the *entire* managed
balances, not the floored formula. This makes the terminal state exact
— the last leaver takes the accumulated rounding dust with them, the
managed totals return to exactly 0, and the next deposit is a clean
first deposit again (INV-2: `totalShares == 0 ⟺ managedRisk == 0 ∧
managedSafe == 0` whenever no shares are outstanding… precisely: zero
shares outstanding implies zero managed totals, because the only way
to reach zero shares is a full redemption or never depositing).

## 3. Guard actions under pooling

`executeProtection` is V4's function with two mechanical substitutions:
every quantity V4 read from raw balances is read from the managed
totals, and after the desk trade the managed totals are re-synced from
the measured balance deltas (§2.1).

- **TRIM (1)**: sells `managedRisk / 2` of WETH through the desk.
  Every holder's claim keeps the same fraction; its composition shifts
  toward USDC. No share counts change.
- **EXIT (2)**: sells all managed WETH, sets `closed = true`. Holders
  now own slices of a pure-USDC pool. EXIT does **not** force anyone
  out — redemption stays open (§4).
- **RERISK (3, tranche 1)**: spends `managedSafe / 2` buying WETH back.
  Note the deliberate narrowing vs V4: V4 spent half the *raw* safe
  balance; V5 spends half the *managed* safe balance, so surplus
  donations are never put at risk by the brain.
- **RERISK_FINAL (4, tranche 2)**: spends the entire remaining managed
  safe balance. Same narrowing.
- Counters (`protectionCount`, `reriskCount`, `lastProtectionAt`,
  `closed` transitions, the `DeRisked` / `ReRisked` /
  `ProtectionExecuted` events) behave exactly as V4: counters move only
  when risk actually changed hands, measured by the desk fill, exactly
  as V4 measured it. A callback that fills nothing (no price, empty
  desk inventory, nothing to sell) still counts as a protection call
  and still cannot strand value: the deltas are zero, the managed
  totals are untouched, every claim is worth exactly what it was.

Partial fills compose with pooling for free: the desk fills what it
can, the delta is what it is, fractions are unchanged.

## 4. Deposit / withdraw flows

### Deposit
1. Caller approves the vault for WETH (as today).
2. `deposit(amount)` → shares computed (§2.2) → `transferFrom` pulls
   the WETH → managed totals and share ledger updated → `closed`
   cleared (V4's re-arm semantics: fresh risk in the pool means the
   position is economically open again, even after an EXIT) →
   `PositionOpened` + `SharesMinted` emitted.
3. Depositing is open at **any** time: before any action, mid-episode
   (after a TRIM, before the re-risk), and after EXIT (buying a slice
   of the de-risked pool at the current reference price). There is no
   deposit window to game: the price you enter at is the pool's
   current managed composition valued at the desk's current price.

### Redeem (user withdraw)
1. `redeem(shares)` → payouts computed (§2.3) → shares burned and
   managed totals decremented **before** any transfer
   (checks-effects-interactions; the repo has no reentrancy-guard
   library and V5 follows the house style of ordering instead) →
   both assets transferred → `SharesRedeemed` emitted.
2. Redemption is open at **any** time, including mid-episode and
   while `closed`. A user who leaves mid-episode takes their pro-rata
   slice of the *current* composition (e.g. half-de-risked after a
   TRIM); the episode continues for the remaining holders with a
   smaller pool. Nothing about the brain's state machine references
   share counts, so exits cannot desync it.
3. `redeemAll()` convenience = `redeem(sharesOf(msg.sender))`.

Shares are an internal ledger (`sharesOf`), **not** an ERC20, and are
non-transferable in phase 1 — a deliberate scope cut (judgment call,
§8): transferability adds approval/allowance surface that the
hackathon demo does not need, and the invariant proofs stay simpler.

## 5. Rounding rules

One rule, applied everywhere: **every division floors, and the floor
always cuts against the party transacting, in favour of the pool.**

- Deposit minting floors → the newcomer gets at most their exact
  pro-rata share, usually a hair less; existing holders are never
  diluted by rounding.
- Redemption payouts floor → the leaver leaves at most a wei or two
  behind per asset; remaining holders are never shorted by rounding.
- The accumulated dust is not lost: it stays in the managed totals and
  is swept out exactly by the full-redemption rule (§2.3). Hence
  INV-3 (exact reconciliation): *if every holder redeems in any order,
  the total paid out across all redemptions equals the managed totals
  at the start of the sequence, to the wei, per asset* — the
  intermediate floors only decide *who* (the last redeemer) collects
  the dust.

## 6. Edge cases

- **Empty pool, first deposit**: 1:1 mint (§2.2). Deposit of 0 reverts.
- **Deposit after EXIT**: pool is pure USDC; the deposit is valued
  against `riskEq(managedSafe)` at the current price. The depositor
  buys into the de-risked basket, and `closed` clears — if the brain
  later re-risks, the new money participates like everyone else's.
  Pinned by test.
- **Withdraw during an open episode**: §4 — always allowed, pays the
  current composition, episode continues for the rest.
- **Withdraw-all by one user**: if they hold all shares, the
  full-redemption rule pays the entire managed balances and the pool
  resets to a pristine empty state (next deposit is a first deposit).
  If they hold only part, they take exactly their fraction; the pool
  and everyone else's claims are untouched to the wei.
- **Dust**: a dust deposit that would mint 0 shares reverts instead of
  donating itself to the pool. A dust redemption may pay 0 of the
  scarcer leg (floored) while still burning the shares — documented,
  and the amounts are bounded by `totalShares` wei of value; tests pin
  the behaviour rather than pretend it away.
- **Donation / share-price manipulation**: §2.1 — direct transfers
  cannot move share price or any claim. Pinned by an adversarial test
  that replays the classic inflation attack end-to-end and shows the
  victim's claim intact and the attacker's donation stranded as
  surplus.
- **Desk shortfall during a callback while users are mid-flow**:
  deposits/redemptions and callbacks are separate transactions; each
  sees the managed totals left by the previous one. There is no
  interleaving inside a transaction (the desk calls are internal to
  the callback; redemption transfers happen after state updates).
- **`closed` with shares outstanding**: a display/episode flag only.
  It gates TRIM/EXIT exactly as in V4 and never gates redemption.
- **Zero reference price**: deposits into a mixed pool revert;
  redemptions and callbacks proceed (§2.2, §3).

## 7. The owner rescue, narrowed (deliberate break from V4)

V4's `withdraw(asset, to, amount)` let the owner pull *any* ERC20,
including the position itself — correct for an operator vault,
indefensible for a pooled one: it would let the owner spend user
backing. V5 keeps the function and signature but caps it:

- For `riskAsset`: `amount <= balanceOf(risk) − managedRisk` — only
  the **surplus** (donations, stray transfers) can be skimmed.
- For `safeAsset`: symmetric.
- For any other token: unrestricted, as V4 (stray airdrop rescue).

The owner's own money enters and leaves like everyone else's: via
`deposit` / `redeem`, holding shares. End-of-life recovery is: holders
redeem (last one sweeps the dust exactly), owner skims any surplus.
Callback-billing ETH is untouched, as in V4 (this is an ERC20-only
path).

## 8. Judgment calls made in this design

1. **Managed totals instead of `balanceOf` pricing** — kills the
   donation/inflation attack by construction; costs donation
   visibility (donations become owner-skimmable surplus, never user
   yield). (§2.1)
2. **Owner rescue capped at surplus for pool assets** — the one place
   V5 deliberately breaks V4 semantics; unrestricted rescue and
   per-user backing cannot coexist. (§7)
3. **Guard actions operate on managed balances**, so the brain never
   trades surplus donations. V4 traded raw balances. (§3)
4. **Shares are a non-transferable internal ledger**, not an ERC20,
   in phase 1. (§4)
5. **Deposit values the safe leg through `swap.priceSource()`** — no
   new constructor wiring, and vault/desk price disagreement is
   impossible by construction; the cost is a deposit-time dependency
   on the oracle existing (only when the pool actually holds safe
   asset). (§2.2)
6. **`deposit` returns the minted share count** — selector unchanged,
   existing callers unaffected; new callers (app/agent) get the number
   without a second read. (§1)

## 9. Invariants the test suite must prove

- **INV-1 (backing)**: raw balances ≥ managed totals after every
  operation, including callbacks and donations.
- **INV-2 (clean reset)**: `totalShares == 0` implies both managed
  totals are 0; a deposit into that state mints 1:1.
- **INV-3 (exact reconciliation)**: sequential full redemption by all
  holders pays out exactly the managed totals, to the wei, per asset —
  after arbitrary interleavings of deposits, TRIM, EXIT, RERISK,
  RERISK_FINAL, and price changes.
- **INV-4 (fraction stability)**: a guard callback never changes any
  holder's share count or fraction; it only changes pool composition.
- **INV-5 (no rounding theft)**: no deposit mints shares worth more
  than the WETH contributed (valued at the desk price at deposit
  time); no redemption pays more than the pro-rata claim; rounding
  residue only ever accumulates to the pool / last redeemer.
- **INV-6 (donation neutrality)**: a direct transfer to the vault
  changes no claim, no share price, and no managed total; the donated
  amount is exactly the owner-skimmable surplus.
- **INV-7 (interface parity)**: callback guards, action semantics,
  counters and events match V4's pinned behaviour test-for-test,
  including partial fills, zero-price no-ops and tranche accounting.

Implementation: `src/SentinelVaultV5.sol`;
tests: `test/SentinelVaultV5.t.sol`.
