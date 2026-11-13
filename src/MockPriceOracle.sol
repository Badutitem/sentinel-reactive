// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title MockPriceOracle — origin-chain price feed (testnet mock).
/// @notice Stands in for a real price oracle on the origin chain (Base Sepolia).
///         Anyone can push a price with `setPrice` — this is a demo driver, not
///         a production oracle. Every update emits `PriceUpdated`, which is the
///         event the Sentinel reactive contract on Lasna subscribes to.
/// @dev The event carries the price and the origin timestamp as non-indexed
///      data (ABI-encoded into `LogRecord.data`), and the token as the indexed
///      topic1, so the reactive side can subscribe per-token.
contract MockPriceOracle {
    event PriceUpdated(address indexed token, uint256 price, uint256 updatedAt);

    mapping(address => uint256) public priceOf;
    mapping(address => uint256) public updatedAtOf;

    /// @notice Pushes a new price for `token` and emits the subscribed event.
    function setPrice(address token, uint256 price) external {
        priceOf[token] = price;
        updatedAtOf[token] = block.timestamp;
        emit PriceUpdated(token, price, block.timestamp);
    }

    /// @notice Latest price pushed for `token` (0 if never set).
    function latestPrice(address token) external view returns (uint256) {
        return priceOf[token];
    }
}
