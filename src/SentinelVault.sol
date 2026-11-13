// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

/// @title SentinelVault — destination-chain mock vault guarded by Sentinel.
/// @notice Lives on the destination chain (Base Sepolia). Holds a mock position
///         whose only way to be protected is a Reactive Network callback: the
///         network's callback proxy calls `executeProtection`, with the Sentinel
///         reactive contract's address injected as the first argument.
///         Guards (both, per the Omni callback model):
///           - `onlyServiceProvider`: caller must be the chain's callback proxy;
///           - `onlyCallbackSender`: injected address must be our reactive contract.
/// @dev Mock position semantics: TRIM halves the position, EXIT closes it fully.
///      `openPosition` is a permissionless demo helper so the position can be
///      re-armed between demo runs. Callback execution on the real network is
///      billed to this contract in the destination chain's native token, so on
///      testnet it must be funded with a little Base Sepolia ETH.
contract SentinelVault is AbstractCallback {
    uint8 public constant ACTION_TRIM = 1;
    uint8 public constant ACTION_EXIT = 2;

    /// @notice Current mock position size (0 = flat).
    uint256 public positionSize;
    /// @notice True once an EXIT protection has closed the position.
    bool public closed;
    /// @notice How many protection callbacks have been executed.
    uint256 public protectionCount;
    /// @notice Destination-chain timestamp of the last executed protection.
    uint256 public lastProtectionAt;

    event PositionOpened(uint256 size);
    event ProtectionExecuted(address indexed reactive, uint8 action, uint256 positionBefore, uint256 positionAfter);

    /// @param callbackProxy_ The destination chain's callback proxy
    ///        (Base Sepolia: 0x476F44b11F5C942c58f4c8E3d0300E5710743585).
    /// @param reactive_ The SentinelReactive contract on Lasna — the only
    ///        sender whose callbacks this vault will honour. Immutable: a wrong
    ///        address here means redeploying the vault.
    constructor(address payable callbackProxy_, address reactive_)
        AbstractCallback(IPayable(callbackProxy_), reactive_)
    {}

    /// @notice (Re)opens the mock position. Demo helper.
    function openPosition(uint256 size_) external {
        positionSize = size_;
        closed = false;
        emit PositionOpened(size_);
    }

    /// @notice Executes a protection action requested by the reactive contract.
    /// @dev `reactive_` is injected by the network (it overwrites the first
    ///      argument of the requested payload with the requesting contract's
    ///      address); the payload Sentinel sends reserves it as address(0).
    function executeProtection(address reactive_, uint8 action_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        uint256 before_ = positionSize;
        if (!closed && positionSize > 0) {
            if (action_ == ACTION_EXIT) {
                positionSize = 0;
                closed = true;
            } else if (action_ == ACTION_TRIM) {
                positionSize = positionSize / 2;
            }
        }
        protectionCount++;
        lastProtectionAt = block.timestamp;
        emit ProtectionExecuted(reactive_, action_, before_, positionSize);
    }

    /// @notice Crude health proxy for demos: position size, or 0 when closed.
    function health() external view returns (uint256) {
        return closed ? 0 : positionSize;
    }
}
