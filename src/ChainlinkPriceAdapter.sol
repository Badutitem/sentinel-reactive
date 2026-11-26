// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Minimal Chainlink AggregatorV3 surface the adapter reads.
/// @dev Deliberately call-based: the adapter polls `latestRoundData()` and
///      never subscribes to feed events (see the adapter's notice below).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkPriceAdapter — origin-chain adapter from a real Chainlink
///        feed to Sentinel's `PriceUpdated` event (Release 2, upgrade B).
/// @notice Polls the Chainlink ETH/USD proxy on Base Sepolia via
///         `latestRoundData()` and re-emits the **identical**
///         `PriceUpdated(address indexed token, uint256 price, uint256 updatedAt)`
///         event `MockPriceOracle` emits — same topic0, the token in topic1,
///         `(price, updatedAt)` in the data — so a stock `SentinelReactive`
///         subscribes to this contract unchanged; only the subscribed address
///         differs from the mock origin.
/// @dev Why polling, not events: the Chainlink proxy does not reliably emit
///      the `AnswerUpdated` event a reactive subscription would need (that
///      pattern silently never fired for a competitor project). This adapter
///      therefore never subscribes to Chainlink events — anyone may call
///      `sync()`, which reads the feed with a call and re-emits our own event
///      only when the emission rules below pass. The decision system stays
///      keeperless; only this public price relay is poked, and anyone may
///      poke it.
///      Emission rules (deadband / heartbeat / minInterval double as the
///      lREACT fuel throttle — every emitted event costs the reactive
///      contract one reactive transaction):
///        - the round must be valid: positive answer, complete round
///          (`answeredInRound >= roundId`), and `updatedAt` no older than
///          `maxStaleness`;
///        - at least `minInterval` must have passed since the last emission;
///        - the normalised price must have moved at least `deadbandBps`
///          from the last emitted price, OR `heartbeat` must have elapsed
///          since the last emission.
///      Every failed check is a silent return — no emit, no revert — so
///      callers can spam `sync()` safely and cheaply.
///      Prices are normalised to the pipeline-wide 18-decimal USD
///      convention: `price18 = answer × 10^(18 − feedDecimals)` — exactly
///      ×1e10 for the 8-decimal ETH/USD feed. The Sentinel model only uses
///      price ratios (it is scale-invariant), but `SentinelSwap`'s pricing
///      and human readers rely on the single convention.
contract ChainlinkPriceAdapter {
    event PriceUpdated(address indexed token, uint256 price, uint256 updatedAt);

    /// @notice The Chainlink feed (proxy) this adapter relays.
    IAggregatorV3 public immutable feed;
    /// @notice Token key the events are emitted under (WETH on Base Sepolia:
    ///         0x4200000000000000000000000000000000000006) — matches the
    ///         reactive contract's topic1 filter and the vault's risk asset.
    address public immutable token;
    /// @notice Minimum price move, in basis points of the last emitted
    ///         price, that justifies an emission before the heartbeat.
    uint256 public immutable deadbandBps;
    /// @notice Hard floor between two emissions, in seconds.
    uint256 public immutable minInterval;
    /// @notice Maximum silence, in seconds: an emission happens at least
    ///         this often even if the price never leaves the deadband.
    uint256 public immutable heartbeat;
    /// @notice Rounds whose `updatedAt` is older than this (seconds) are
    ///         rejected as stale.
    uint256 public immutable maxStaleness;
    /// @notice 10^(18 − feedDecimals): ×1e10 for the 8-decimal ETH/USD feed.
    uint256 public immutable priceScaleFactor;

    /// @notice Last emitted price (18-decimal USD); 0 before the first sync.
    uint256 public lastPrice;
    /// @notice Block timestamp of the last emission.
    uint256 public lastEmittedAt;

    constructor(
        address feed_,
        address token_,
        uint256 deadbandBps_,
        uint256 minInterval_,
        uint256 heartbeat_,
        uint256 maxStaleness_
    ) {
        feed = IAggregatorV3(feed_);
        token = token_;
        deadbandBps = deadbandBps_;
        minInterval = minInterval_;
        heartbeat = heartbeat_;
        maxStaleness = maxStaleness_;
        uint8 feedDecimals = IAggregatorV3(feed_).decimals();
        require(feedDecimals <= 18, "ChainlinkPriceAdapter: feed decimals > 18");
        priceScaleFactor = 10 ** (18 - uint256(feedDecimals));
    }

    /// @notice Reads the feed and emits `PriceUpdated` if the emission rules
    ///         pass. Permissionless; silently returns otherwise.
    /// @dev The emitted `updatedAt` is the feed round's own timestamp (the
    ///      origin timestamp the reactive contract decodes), not the local
    ///      block time of the sync transaction.
    function sync() external {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0) return;
        if (updatedAt == 0 || updatedAt > block.timestamp) return;
        if (answeredInRound < roundId) return;
        if (block.timestamp - updatedAt > maxStaleness) return;

        uint256 price = uint256(answer) * priceScaleFactor;

        if (lastPrice != 0) {
            if (block.timestamp < lastEmittedAt + minInterval) return;
            bool moved = _movedBeyondDeadband(price);
            bool heartbeatDue = block.timestamp >= lastEmittedAt + heartbeat;
            if (!moved && !heartbeatDue) return;
        }

        lastPrice = price;
        lastEmittedAt = block.timestamp;
        emit PriceUpdated(token, price, updatedAt);
    }

    /// @notice Latest emitted price for `token_` (0 for any other token, or
    ///         before the first successful sync).
    /// @dev Same `IPriceSource` shape `MockPriceOracle` exposes, so a
    ///      `SentinelSwap` can price off this adapter unchanged.
    function latestPrice(address token_) external view returns (uint256) {
        return token_ == token ? lastPrice : 0;
    }

    /// @notice Block timestamp of the last emission for `token_` (0 for any
    ///         other token, or before the first successful sync).
    function priceUpdatedAt(address token_) external view returns (uint256) {
        return token_ == token ? lastEmittedAt : 0;
    }

    /// @notice True if `price` differs from the last emitted price by at
    ///         least `deadbandBps` basis points of the last emitted price.
    function _movedBeyondDeadband(uint256 price) internal view returns (bool) {
        uint256 diff = price > lastPrice ? price - lastPrice : lastPrice - price;
        return diff * 10_000 >= lastPrice * deadbandBps;
    }
}
