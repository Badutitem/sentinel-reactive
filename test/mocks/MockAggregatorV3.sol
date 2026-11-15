// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title MockAggregatorV3 — settable Chainlink-style feed (test mock only).
/// @notice Implements the `decimals()` + `latestRoundData()` surface
///         `ChainlinkPriceAdapter` reads, with fully test-controlled round
///         data (answer, timestamps, round completeness). Tests only,
///         never deployed.
contract MockAggregatorV3 {
    uint8 public immutable decimals;

    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    /// @notice Sets a fresh, complete round (answeredInRound == roundId).
    function setRound(int256 answer_, uint256 updatedAt_) external {
        roundId += 1;
        answeredInRound = roundId;
        answer = answer_;
        startedAt = updatedAt_;
        updatedAt = updatedAt_;
    }

    /// @notice Sets a round with explicit ids — for incomplete-round tests
    ///         (answeredInRound < roundId).
    function setRoundFull(uint80 roundId_, int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answeredInRound = answeredInRound_;
        answer = answer_;
        startedAt = updatedAt_;
        updatedAt = updatedAt_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
    {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function description() external pure returns (string memory) {
        return "ETH / USD (mock)";
    }
}
