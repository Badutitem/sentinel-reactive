// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IERC20, IERC20Metadata, IPriceSource, SentinelSwapV2} from "./SentinelSwapV2.sol";

/// @title SentinelVaultV5 — pooled destination-chain vault with per-user shares (Release 6).
/// @notice SentinelVaultV4's guard machine (TRIM / EXIT / RERISK /
///         RERISK_FINAL, variant B scale-in) with the ownership model
///         replaced: the position is now a POOL. Anyone can `deposit`
///         WETH and receives shares; anyone can `redeem` shares at any
///         time and is paid pro-rata in WETH + MockUSDC according to
///         the pool's current composition. The brain-facing surface is
///         V4's, unchanged: same callback ABI
///         (`executeProtection(address,uint8)`), same guards, same desk,
///         same counters and events. Full design: VAULTV5-DESIGN.md.
/// @dev The load-bearing difference from V4 is ACCOUNTING. Share value
///      is computed from two managed totals (`managedRisk`,
///      `managedSafe`), never from raw `balanceOf`: managed totals move
///      only through deposit / redeem / protection callbacks (the
///      callback re-syncs them from the desk trade's measured balance
///      deltas). A plain transfer to this contract — a donation —
///      therefore cannot move the share price or any user's claim,
///      which kills the first-depositor inflation attack by
///      construction; donated funds sit as owner-skimmable surplus
///      (see `withdraw`). Guard actions likewise operate on the
///      managed balances, so the brain never trades surplus.
///      Rounding always floors against the party transacting, in
///      favour of the pool; the accumulated dust is swept exactly by
///      the full-redemption rule in `redeem`, so sequential redemption
///      by every holder pays out the managed totals to the wei.
contract SentinelVaultV5 is AbstractCallback {
    uint8 public constant ACTION_TRIM = 1;
    uint8 public constant ACTION_EXIT = 2;
    uint8 public constant ACTION_RERISK = 3;
    uint8 public constant ACTION_RERISK_FINAL = 4;

    /// @notice Mirrors SentinelSwapV2.PRICE_SCALE (18-decimal USD).
    uint256 public constant PRICE_SCALE = 1e18;

    /// @notice Risk asset the position is held in (WETH on Base Sepolia:
    ///         0x4200000000000000000000000000000000000006).
    IERC20 public immutable riskAsset;
    /// @notice Safe asset the position is de-risked into (MockUSDC).
    IERC20 public immutable safeAsset;
    /// @notice Two-way fixed-price desk the vault trades through.
    SentinelSwapV2 public immutable swap;
    /// @notice Deployer; may skim surplus and rescue stray tokens (see
    ///         `withdraw`). Holds no claim on managed funds except
    ///         through shares it earns by depositing, like anyone else.
    address public owner;

    /// @notice True once an EXIT protection has closed the position.
    ///         Episode/display flag only — it never gates redemption.
    bool public closed;
    /// @notice How many protection callbacks have been executed.
    uint256 public protectionCount;
    /// @notice How many re-risk tranche callbacks actually bought risk back.
    uint256 public reriskCount;
    /// @notice Destination-chain timestamp of the last executed protection.
    uint256 public lastProtectionAt;

    /// @notice Total shares outstanding.
    uint256 public totalShares;
    /// @notice Per-user share balances (internal ledger, non-transferable).
    mapping(address => uint256) public sharesOf;
    /// @notice The share-backed risk-asset total. Always <= the vault's
    ///         raw risk balance; the difference is surplus (donations).
    uint256 public managedRisk;
    /// @notice The share-backed safe-asset total (see `managedRisk`).
    uint256 public managedSafe;

    /// @notice Price (18-decimal USD) the desk last settled a trade or
    ///         deposit at; 0 = no settlement yet. Anchor for the deposit
    ///         deviation guard (Release 8, F1-B): a deposit into a mixed
    ///         pool reverts when the reference price is more than 50%
    ///         away from this anchor.
    uint256 public lastSettledPrice;
    /// @notice Deposit deviation band: 5000 bps = 50% from `lastSettledPrice`.
    uint256 public constant MAX_DEPOSIT_DEVIATION_BPS = 5000;

    event PositionOpened(uint256 size);
    event ProtectionExecuted(address indexed reactive, uint8 action, uint256 positionBefore, uint256 positionAfter);
    event DeRisked(uint8 action, uint256 riskOut, uint256 safeIn);
    event ReRisked(uint256 safeSpent, uint256 riskBought);
    event SharesMinted(address indexed user, uint256 amount, uint256 shares);
    event SharesRedeemed(address indexed user, uint256 shares, uint256 riskOut, uint256 safeOut);

    error NotOwner(address caller);
    error ZeroAmount();
    error ZeroShares();
    error NoReferencePrice();
    error StalePrice(uint256 ageSeconds);
    error PriceDeviation(uint256 price, uint256 anchor);
    error UnknownAction(uint8 action);
    error InsufficientShares(address user, uint256 requested, uint256 held);
    error ExceedsSurplus(address asset, uint256 requested, uint256 surplus);

    /// @param callbackProxy_ The destination chain's callback proxy
    ///        (Base Sepolia: 0x476F44b11F5C942c58f4c8E3d0300E5710743585).
    /// @param reactive_ The SentinelReactive contract on Lasna — the only
    ///        sender whose callbacks this vault will honour. Immutable: a wrong
    ///        address here means redeploying the vault.
    /// @param riskAsset_ WETH (the position asset).
    /// @param safeAsset_ MockUSDC (the de-risk target asset).
    /// @param swap_ The SentinelSwapV2 desk; granted max allowances on both assets.
    ///        The deposit-time price source is read through it
    ///        (`swap.priceSource()`), so vault and desk can never
    ///        disagree on the reference price.
    constructor(
        address payable callbackProxy_,
        address reactive_,
        address riskAsset_,
        address safeAsset_,
        address swap_
    ) AbstractCallback(IPayable(callbackProxy_), reactive_) {
        riskAsset = IERC20(riskAsset_);
        safeAsset = IERC20(safeAsset_);
        swap = SentinelSwapV2(swap_);
        owner = msg.sender;
        require(IERC20(riskAsset_).approve(swap_, type(uint256).max), "SentinelVaultV5: risk approve failed");
        require(IERC20(safeAsset_).approve(swap_, type(uint256).max), "SentinelVaultV5: safe approve failed");
    }

    /// @notice Current position size: the pool's managed risk balance.
    /// @dev Same getter ABI as V1–V4; under pooling it reports the
    ///      share-backed total, excluding any surplus donations.
    function positionSize() public view returns (uint256) {
        return managedRisk;
    }

    /// @notice Safe-asset balance accumulated by de-risking (managed).
    function safeBalance() external view returns (uint256) {
        return managedSafe;
    }

    /// @notice Raw risk balance sitting in the vault above the managed
    ///         total — donations and stray transfers, backing no claim.
    function surplusRisk() public view returns (uint256) {
        return riskAsset.balanceOf(address(this)) - managedRisk;
    }

    /// @notice Raw safe balance above the managed total (see `surplusRisk`).
    function surplusSafe() public view returns (uint256) {
        return safeAsset.balanceOf(address(this)) - managedSafe;
    }

    /// @notice A user's current pro-rata claim on the managed pool, in
    ///         both assets — exactly what `redeem(sharesOf(user))`
    ///         would pay (floored, except a full redemption, which
    ///         sweeps the managed totals exactly).
    function claimOf(address user) public view returns (uint256 riskClaim, uint256 safeClaim) {
        uint256 shares = sharesOf[user];
        if (shares == 0 || totalShares == 0) return (0, 0);
        if (shares == totalShares) return (managedRisk, managedSafe);
        riskClaim = shares * managedRisk / totalShares;
        safeClaim = shares * managedSafe / totalShares;
    }

    /// @notice The pool's managed value in risk-asset units, valuing the
    ///         safe leg at the desk's reference price with the desk's
    ///         own formula (rounded UP, so deposit share-minting rounds
    ///         against the depositor). Never consulted when the pool
    ///         holds no safe asset; reverts when the safe leg cannot be
    ///         valued (no reference price).
    function _poolRiskEq() internal view returns (uint256) {
        if (managedSafe == 0) return managedRisk;
        uint256 price = IPriceSource(address(swap.priceSource())).latestPrice(address(riskAsset));
        if (price == 0) revert NoReferencePrice();
        uint256 riskUnit = 10 ** uint256(IERC20Metadata(address(riskAsset)).decimals());
        uint256 safeUnit = 10 ** uint256(IERC20Metadata(address(safeAsset)).decimals());
        uint256 denom = price * safeUnit;
        uint256 safeEq = (managedSafe * riskUnit * PRICE_SCALE + denom - 1) / denom;
        return managedRisk + safeEq;
    }

    /// @notice Deposits risk asset into the pool and mints shares.
    /// @dev First deposit (no shares outstanding — which by the
    ///      full-redemption rule means the managed totals are zero)
    ///      mints 1:1. Later deposits mint
    ///      `floor(amount * totalShares / poolRiskEq)` valued BEFORE
    ///      the deposit lands; a deposit that would mint 0 shares
    ///      reverts rather than donate itself to the pool. Re-arms the
    ///      position (`closed = false`), exactly V4's deposit.
    /// @return shares The shares minted to the caller.
    function deposit(uint256 amount) external returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        uint256 price;
        if (totalShares == 0) {
            shares = amount;
        } else {
            if (managedSafe > 0) {
                // Release 8 (F2): a deposit into a mixed pool fails closed
                // on a stale reference price — the user retries later.
                if (swap.priceStale()) revert StalePrice(swap.priceAge());
                // Release 8 (F1-B): a compromised or fat-fingered pusher
                // must not reprice the pool in one print. The guard binds
                // deposits only — protection fills are never banded (a
                // genuine crash exit must never be blocked by a band).
                price = IPriceSource(address(swap.priceSource())).latestPrice(address(riskAsset));
                if (lastSettledPrice != 0) {
                    if (price > lastSettledPrice * 3 / 2 || price * 2 < lastSettledPrice) {
                        revert PriceDeviation(price, lastSettledPrice);
                    }
                }
            }
            shares = amount * totalShares / _poolRiskEq();
            if (shares == 0) revert ZeroShares();
        }
        require(riskAsset.transferFrom(msg.sender, address(this), amount), "SentinelVaultV5: deposit failed");
        managedRisk += amount;
        totalShares += shares;
        sharesOf[msg.sender] += shares;
        closed = false;
        // Release 8 (F1-B): the deposit itself settles at this price.
        if (managedSafe > 0 && price > 0) lastSettledPrice = price;
        emit PositionOpened(amount);
        emit SharesMinted(msg.sender, amount, shares);
    }

    /// @notice Burns `shares` of the caller's shares and pays their
    ///         pro-rata slice of BOTH managed balances. Open at any
    ///         time — mid-episode and while closed alike; leaving never
    ///         touches the brain's state. Redeeming every outstanding
    ///         share pays the entire managed balances (not the floored
    ///         formula), so the pool resets to exactly zero and the
    ///         rounding dust is never stranded.
    /// @return riskOut WETH paid out.
    /// @return safeOut MockUSDC paid out.
    function redeem(uint256 shares) public returns (uint256 riskOut, uint256 safeOut) {
        if (shares == 0) revert ZeroShares();
        uint256 held = sharesOf[msg.sender];
        if (shares > held) revert InsufficientShares(msg.sender, shares, held);
        if (shares == totalShares) {
            riskOut = managedRisk;
            safeOut = managedSafe;
        } else {
            riskOut = shares * managedRisk / totalShares;
            safeOut = shares * managedSafe / totalShares;
        }
        // Effects before interactions: the ledger and totals settle
        // before any token moves (house style — no guard library).
        sharesOf[msg.sender] = held - shares;
        totalShares -= shares;
        managedRisk -= riskOut;
        managedSafe -= safeOut;
        if (riskOut > 0) {
            require(riskAsset.transfer(msg.sender, riskOut), "SentinelVaultV5: risk payout failed");
        }
        if (safeOut > 0) {
            require(safeAsset.transfer(msg.sender, safeOut), "SentinelVaultV5: safe payout failed");
        }
        emit SharesRedeemed(msg.sender, shares, riskOut, safeOut);
    }

    /// @notice Redeems the caller's entire share balance.
    function redeemAll() external returns (uint256 riskOut, uint256 safeOut) {
        return redeem(sharesOf[msg.sender]);
    }

    /// @notice Executes a protection action requested by the reactive contract.
    /// @dev V4's function, with quantities read from the managed totals
    ///      and the totals re-synced afterwards from the desk trade's
    ///      measured raw-balance deltas (a pending donation is inside
    ///      both measurements and cancels out — it never enters the
    ///      managed totals). `reactive_` is injected by the network;
    ///      the payload Sentinel sends reserves it as address(0).
    ///      TRIM sells half the managed risk, EXIT sells all of it and
    ///      closes, RERISK spends half the managed safe balance,
    ///      RERISK_FINAL spends the rest. The desk never reverts on a
    ///      short reserve or inventory, so no callback can be bricked
    ///      by desk size; a callback that fills nothing moves no
    ///      managed value and changes no one's claim.
    function executeProtection(address reactive_, uint8 action_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        // Release 8 (F5): unknown action codes revert instead of
        // inflating `protectionCount` with a phantom protection.
        if (action_ < ACTION_TRIM || action_ > ACTION_RERISK_FINAL) revert UnknownAction(action_);
        // Release 8 (F1-B): reference price read once, before the swaps;
        // the anchor moves only when value actually moves (below).
        uint256 refPrice = IPriceSource(address(swap.priceSource())).latestPrice(address(riskAsset));
        uint256 before_ = positionSize();
        uint256 rawRiskBefore = riskAsset.balanceOf(address(this));
        uint256 rawSafeBefore = safeAsset.balanceOf(address(this));
        if (action_ == ACTION_RERISK || action_ == ACTION_RERISK_FINAL) {
            uint256 spend = action_ == ACTION_RERISK ? managedSafe / 2 : managedSafe;
            if (spend > 0) {
                uint256 riskOut = swap.swapSafeForRisk(spend);
                if (riskOut > 0) {
                    closed = false;
                    reriskCount++;
                    if (refPrice > 0) lastSettledPrice = refPrice;
                    emit ReRisked(rawSafeBefore - safeAsset.balanceOf(address(this)), riskOut);
                }
            }
        } else if (!closed && before_ > 0) {
            if (action_ == ACTION_EXIT) {
                uint256 safeIn = swap.swapRiskForSafe(before_);
                closed = true;
                if (safeIn > 0 && refPrice > 0) lastSettledPrice = refPrice;
                emit DeRisked(action_, rawRiskBefore - riskAsset.balanceOf(address(this)), safeIn);
            } else if (action_ == ACTION_TRIM) {
                uint256 safeIn = swap.swapRiskForSafe(before_ / 2);
                if (safeIn > 0 && refPrice > 0) lastSettledPrice = refPrice;
                emit DeRisked(action_, rawRiskBefore - riskAsset.balanceOf(address(this)), safeIn);
            }
        }
        // Re-sync the managed totals by the trade's measured deltas.
        // Surplus is constant across this call, so raw deltas equal
        // managed deltas exactly.
        managedRisk =
            uint256(int256(managedRisk) + (int256(riskAsset.balanceOf(address(this))) - int256(rawRiskBefore)));
        managedSafe =
            uint256(int256(managedSafe) + (int256(safeAsset.balanceOf(address(this))) - int256(rawSafeBefore)));
        protectionCount++;
        lastProtectionAt = block.timestamp;
        emit ProtectionExecuted(reactive_, action_, before_, positionSize());
    }

    /// @notice Owner-only ERC20 rescue, NARROWED from V4: for the two
    ///         pool assets only the surplus above the managed totals
    ///         (donations, stray transfers) may be pulled — user
    ///         backing is untouchable. Any other token is rescuable in
    ///         full, as V4. The owner's own managed funds leave only
    ///         through `redeem`, like everyone's. Callback-billing ETH
    ///         is not touched — this is for ERC20s only.
    function withdraw(address asset, address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        if (asset == address(riskAsset)) {
            uint256 surplus = surplusRisk();
            if (amount > surplus) revert ExceedsSurplus(asset, amount, surplus);
        } else if (asset == address(safeAsset)) {
            uint256 surplus = surplusSafe();
            if (amount > surplus) revert ExceedsSurplus(asset, amount, surplus);
        }
        require(IERC20(asset).transfer(to, amount), "SentinelVaultV5: withdraw failed");
    }

    /// @notice Crude health proxy for demos: managed risk balance, or 0 when closed.
    function health() external view returns (uint256) {
        return closed ? 0 : positionSize();
    }
}
