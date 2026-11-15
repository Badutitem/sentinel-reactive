// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IERC20, SentinelSwap} from "./SentinelSwap.sol";

/// @title SentinelVaultV2 — destination-chain vault holding a real ERC20 position.
/// @notice Phase 2, upgrade A. Same role as SentinelVault (V1), but the
///         position is a real WETH balance held by this contract instead of a
///         bare counter: `positionSize` is a view over the actual balance, so
///         it is truthful by construction. On a protection callback the vault
///         de-risks through SentinelSwap — TRIM sells half the WETH for
///         MockUSDC, EXIT sells all of it — producing real ERC20 transfers in
///         the callback transaction itself.
///         Guards are identical to V1 (the callback interface is byte-identical,
///         so the already-deployed SentinelReactive can be pointed at this
///         vault via its owner-only `setVault` with no reactive redeploy):
///           - `onlyServiceProvider`: caller must be the chain's callback proxy;
///           - `onlyCallbackSender`: injected address must be our reactive contract.
/// @dev Callback execution on the real network is billed to this contract in
///      the destination chain's native token, so on testnet it must be funded
///      with a little Base Sepolia ETH. The vault grants the swap desk a max
///      WETH allowance in its constructor; that is safe only because the desk
///      is `onlyVault` and holds no other privileges.
contract SentinelVaultV2 is AbstractCallback {
    uint8 public constant ACTION_TRIM = 1;
    uint8 public constant ACTION_EXIT = 2;

    /// @notice Risk asset the position is held in (WETH on Base Sepolia:
    ///         0x4200000000000000000000000000000000000006).
    IERC20 public immutable riskAsset;
    /// @notice Safe asset the position is de-risked into (MockUSDC).
    IERC20 public immutable safeAsset;
    /// @notice Fixed-price desk the vault sells through.
    SentinelSwap public immutable swap;
    /// @notice Deployer; the only address allowed to `withdraw` ERC20s.
    address public owner;

    /// @notice True once an EXIT protection has closed the position.
    bool public closed;
    /// @notice How many protection callbacks have been executed.
    uint256 public protectionCount;
    /// @notice Destination-chain timestamp of the last executed protection.
    uint256 public lastProtectionAt;

    event PositionOpened(uint256 size);
    event ProtectionExecuted(address indexed reactive, uint8 action, uint256 positionBefore, uint256 positionAfter);
    event DeRisked(uint8 action, uint256 riskOut, uint256 safeIn);

    error NotOwner(address caller);

    /// @param callbackProxy_ The destination chain's callback proxy
    ///        (Base Sepolia: 0x476F44b11F5C942c58f4c8E3d0300E5710743585).
    /// @param reactive_ The SentinelReactive contract on Lasna — the only
    ///        sender whose callbacks this vault will honour. Immutable: a wrong
    ///        address here means redeploying the vault.
    /// @param riskAsset_ WETH (the position asset).
    /// @param safeAsset_ MockUSDC (the de-risk target asset).
    /// @param swap_ The SentinelSwap desk; granted a max risk-asset allowance.
    constructor(
        address payable callbackProxy_,
        address reactive_,
        address riskAsset_,
        address safeAsset_,
        address swap_
    ) AbstractCallback(IPayable(callbackProxy_), reactive_) {
        riskAsset = IERC20(riskAsset_);
        safeAsset = IERC20(safeAsset_);
        swap = SentinelSwap(swap_);
        owner = msg.sender;
        require(IERC20(riskAsset_).approve(swap_, type(uint256).max), "SentinelVaultV2: approve failed");
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
        require(riskAsset.transferFrom(msg.sender, address(this), amount), "SentinelVaultV2: deposit failed");
        closed = false;
        emit PositionOpened(amount);
    }

    /// @notice Executes a protection action requested by the reactive contract.
    /// @dev `reactive_` is injected by the network (it overwrites the first
    ///      argument of the requested payload with the requesting contract's
    ///      address); the payload Sentinel sends reserves it as address(0).
    ///      TRIM sells half the position, EXIT sells all of it and closes.
    ///      The swap desk never reverts on a short reserve (it partially
    ///      fills), so this callback cannot be bricked by reserve size.
    function executeProtection(address reactive_, uint8 action_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        uint256 before_ = positionSize();
        if (!closed && before_ > 0) {
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
        require(IERC20(asset).transfer(to, amount), "SentinelVaultV2: withdraw failed");
    }

    /// @notice Crude health proxy for demos: live risk balance, or 0 when closed.
    function health() external view returns (uint256) {
        return closed ? 0 : positionSize();
    }
}
