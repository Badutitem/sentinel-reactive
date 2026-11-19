// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IERC20, SentinelSwapV2} from "./SentinelSwapV2.sol";

/// @title SentinelVaultV4 — destination-chain vault with scale-in re-risk (trio #5, variant B).
/// @notice SentinelVaultV3 plus the second re-risk tranche. The re-risk
///         evaluation (RERISK-VARIANTS.md) crowned variant B — scale-in —
///         over the shipped single-shot rule, so the buyback now lands in
///         two tranches behind two distinct action codes:
///           - RERISK (3): spend HALF the current safe balance back into
///             the risk asset (the reclaim tranche);
///           - RERISK_FINAL (4): spend the ENTIRE remaining safe balance
///             (the confirmation tranche, fired by the reactive contract
///             when the anchor sets a new high above the episode anchor).
///         Actions 1/2 behave exactly as V2/V3 — same guards, same
///         callback ABI (`executeProtection(address,uint8)`), same desk
///         semantics — so the only behavioural delta against V3 is how
///         action 3 spends and that action 4 exists.
/// @dev Callback execution on the real network is billed to this contract in
///      the destination chain's native token, so on testnet it must be funded
///      with a little Base Sepolia ETH. The vault grants the swap desk max
///      allowances on BOTH assets in its constructor (risk for the forward
///      swap, safe for the reverse swap); that is safe only because the desk
///      is `onlyVault` and holds no other privileges. A tranche that buys
///      nothing back (no safe balance, no reference price, or an empty desk
///      inventory — the desk never reverts, it partially fills or returns 0)
///      leaves `closed`, `reriskCount` and the balances untouched: the
///      counters only move when risk actually changed hands.
contract SentinelVaultV4 is AbstractCallback {
    uint8 public constant ACTION_TRIM = 1;
    uint8 public constant ACTION_EXIT = 2;
    uint8 public constant ACTION_RERISK = 3;
    uint8 public constant ACTION_RERISK_FINAL = 4;

    /// @notice Risk asset the position is held in (WETH on Base Sepolia:
    ///         0x4200000000000000000000000000000000000006).
    IERC20 public immutable riskAsset;
    /// @notice Safe asset the position is de-risked into (MockUSDC).
    IERC20 public immutable safeAsset;
    /// @notice Two-way fixed-price desk the vault trades through.
    SentinelSwapV2 public immutable swap;
    /// @notice Deployer; the only address allowed to `withdraw` ERC20s.
    address public owner;

    /// @notice True once an EXIT protection has closed the position.
    bool public closed;
    /// @notice How many protection callbacks have been executed.
    uint256 public protectionCount;
    /// @notice How many re-risk tranche callbacks actually bought risk back.
    uint256 public reriskCount;
    /// @notice Destination-chain timestamp of the last executed protection.
    uint256 public lastProtectionAt;

    event PositionOpened(uint256 size);
    event ProtectionExecuted(address indexed reactive, uint8 action, uint256 positionBefore, uint256 positionAfter);
    event DeRisked(uint8 action, uint256 riskOut, uint256 safeIn);
    event ReRisked(uint256 safeSpent, uint256 riskBought);

    error NotOwner(address caller);

    /// @param callbackProxy_ The destination chain's callback proxy
    ///        (Base Sepolia: 0x476F44b11F5C942c58f4c8E3d0300E5710743585).
    /// @param reactive_ The SentinelReactive contract on Lasna — the only
    ///        sender whose callbacks this vault will honour. Immutable: a wrong
    ///        address here means redeploying the vault.
    /// @param riskAsset_ WETH (the position asset).
    /// @param safeAsset_ MockUSDC (the de-risk target asset).
    /// @param swap_ The SentinelSwapV2 desk; granted max allowances on both assets.
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
        require(IERC20(riskAsset_).approve(swap_, type(uint256).max), "SentinelVaultV4: risk approve failed");
        require(IERC20(safeAsset_).approve(swap_, type(uint256).max), "SentinelVaultV4: safe approve failed");
    }

    /// @notice Current position size: the vault's live risk-asset balance.
    /// @dev Same getter ABI V1 exposed for its counter — now backed by real tokens.
    function positionSize() public view returns (uint256) {
        return riskAsset.balanceOf(address(this));
    }

    /// @notice Safe-asset balance accumulated by de-risking.
    function safeBalance() external view returns (uint256) {
        return safeAsset.balanceOf(address(this));
    }

    /// @notice Arms (or re-arms) the position by depositing risk asset.
    /// @dev The arming path (replaces V1's `openPosition`): pulls `amount` of
    ///      WETH from the caller, who must have approved this vault.
    function deposit(uint256 amount) external {
        require(riskAsset.transferFrom(msg.sender, address(this), amount), "SentinelVaultV4: deposit failed");
        closed = false;
        emit PositionOpened(amount);
    }

    /// @notice Executes a protection action requested by the reactive contract.
    /// @dev `reactive_` is injected by the network (it overwrites the first
    ///      argument of the requested payload with the requesting contract's
    ///      address); the payload Sentinel sends reserves it as address(0).
    ///      TRIM sells half the position, EXIT sells all of it and closes,
    ///      RERISK spends half the safe balance buying the risk asset back,
    ///      RERISK_FINAL spends whatever safe balance remains. The swap desk
    ///      never reverts on a short reserve or inventory (it partially
    ///      fills), so no callback can be bricked by desk size.
    function executeProtection(address reactive_, uint8 action_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        uint256 before_ = positionSize();
        if (action_ == ACTION_RERISK || action_ == ACTION_RERISK_FINAL) {
            uint256 safeBal = safeAsset.balanceOf(address(this));
            uint256 spend = action_ == ACTION_RERISK ? safeBal / 2 : safeBal;
            if (spend > 0) {
                uint256 riskOut = swap.swapSafeForRisk(spend);
                if (riskOut > 0) {
                    closed = false;
                    reriskCount++;
                    emit ReRisked(safeBal - safeAsset.balanceOf(address(this)), riskOut);
                }
            }
        } else if (!closed && before_ > 0) {
            if (action_ == ACTION_EXIT) {
                uint256 safeIn = swap.swapRiskForSafe(before_);
                closed = true;
                emit DeRisked(action_, before_ - positionSize(), safeIn);
            } else if (action_ == ACTION_TRIM) {
                uint256 safeIn = swap.swapRiskForSafe(before_ / 2);
                emit DeRisked(action_, before_ - positionSize(), safeIn);
            }
        }
        protectionCount++;
        lastProtectionAt = block.timestamp;
        emit ProtectionExecuted(reactive_, action_, before_, positionSize());
    }

    /// @notice Owner-only ERC20 rescue: re-arming between demos and
    ///         end-of-life recovery (V1's stranded funds are the lesson).
    ///         Callback-billing ETH is not touched — this is for ERC20s only.
    function withdraw(address asset, address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        require(IERC20(asset).transfer(to, amount), "SentinelVaultV4: withdraw failed");
    }

    /// @notice Crude health proxy for demos: live risk balance, or 0 when closed.
    function health() external view returns (uint256) {
        return closed ? 0 : positionSize();
    }
}
