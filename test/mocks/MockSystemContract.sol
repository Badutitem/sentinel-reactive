// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @title MockSystemContract — test double for the Reactive system contract.
/// @notice Tests etch this contract's code at the real system contract address
///         (0x8888888888888888888888888888888888888888) so a SentinelReactive
///         deployed in the test environment subscribes and requests callbacks
///         against this mock, which records everything for assertions —
///         including the exact callback payloads, which the end-to-end test
///         then delivers to the vault the way the real network would.
contract MockSystemContract is ISystemContract {
    struct Subscription {
        address subscriber;
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    Subscription[] public subscriptions;
    CallbackConfiguration_V_1_0[] internal _callbacks;

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function lastCallback() external view returns (CallbackConfiguration_V_1_0 memory) {
        require(_callbacks.length > 0, "MockSystem: no callbacks");
        return _callbacks[_callbacks.length - 1];
    }

    function callbackAt(uint256 i) external view returns (CallbackConfiguration_V_1_0 memory) {
        return _callbacks[i];
    }

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external override {
        subscriptions.push(
            Subscription({
                subscriber: msg.sender,
                chainId: chainId_,
                contractAddress: contract_,
                topic0: topic0_,
                topic1: topic1_,
                topic2: topic2_,
                topic3: topic3_
            })
        );
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external override {}

    function requestCallback(CallbackVersion, bytes memory) external override {}

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external override {
        _callbacks.push(config_);
    }

    function debt(address) external pure override returns (uint256) {
        return 0;
    }

    receive() external payable override {}
}
