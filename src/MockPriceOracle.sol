// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title MockPriceOracle — origin-chain price feed (testnet mock).
/// @notice Stands in for a real price oracle on the origin chain (Base Sepolia).
///         Pushes are restricted to allowlisted pusher addresses; the deployer
///         is allowlisted at construction. Every update emits `PriceUpdated`,
///         which is the event the Sentinel reactive contract on Lasna
///         subscribes to.
/// @dev The event carries the price and the origin timestamp as non-indexed
///      data (ABI-encoded into `LogRecord.data`), and the token as the indexed
///      topic1, so the reactive side can subscribe per-token.
contract MockPriceOracle {
    event PriceUpdated(address indexed token, uint256 price, uint256 updatedAt);
    event PusherAllowed(address indexed pusher);
    event PusherRevoked(address indexed pusher);

    error NotOwner(address caller);
    error NotPusher(address caller);

    address public owner;
    mapping(address => bool) public pricePushers;

    mapping(address => uint256) public priceOf;
    mapping(address => uint256) public updatedAtOf;

    constructor() {
        owner = msg.sender;
        pricePushers[msg.sender] = true;
        emit PusherAllowed(msg.sender);
    }

    /// @notice Allowlist `pusher_` to push prices. Owner-only.
    function allowPusher(address pusher_) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        pricePushers[pusher_] = true;
        emit PusherAllowed(pusher_);
    }

    /// @notice Remove `pusher_` from the allowlist. Owner-only.
    function revokePusher(address pusher_) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        pricePushers[pusher_] = false;
        emit PusherRevoked(pusher_);
    }

    /// @notice Pushes a new price for `token` and emits the subscribed event.
    /// @dev Allowlisted pushers only.
    function setPrice(address token, uint256 price) external {
        if (!pricePushers[msg.sender]) revert NotPusher(msg.sender);
        priceOf[token] = price;
        updatedAtOf[token] = block.timestamp;
        emit PriceUpdated(token, price, block.timestamp);
    }

    /// @notice Latest price pushed for `token` (0 if never set).
    function latestPrice(address token) external view returns (uint256) {
        return priceOf[token];
    }

    /// @notice Block timestamp of the last push for `token` (0 if never set).
    function priceUpdatedAt(address token) external view returns (uint256) {
        return updatedAtOf[token];
    }
}
