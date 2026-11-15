// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ChainlinkPriceAdapter} from "../src/ChainlinkPriceAdapter.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwap} from "../src/SentinelSwap.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Unit tests for the Chainlink origin adapter (upgrade B): the
///         emission throttle (deadband / min-interval / heartbeat), round
///         validation (staleness, completeness, positive answer), 8→18
///         decimal normalisation, byte-level event-shape equality with
///         `MockPriceOracle.PriceUpdated`, and `SentinelSwap` pricing off
///         the adapter via the shared `IPriceSource` view.
/// @dev Demo parameters (design §B): deadband 10 bps, minInterval 60 s,
///      heartbeat 300 s, maxStaleness 3,600 s.
contract ChainlinkPriceAdapterTest is Test {
    uint256 internal constant T0 = 1_700_000_000;
    int256 internal constant P2000 = 2000e8; // $2,000 at the feed's 8 decimals.
    uint256 internal constant P2000_18 = 2000e18; // $2,000 in the 18-decimal convention.

    bytes32 internal constant PRICE_UPDATED_TOPIC = keccak256("PriceUpdated(address,uint256,uint256)");

    MockAggregatorV3 internal feed;
    MockERC20 internal weth; // Adapter token key + swap risk-asset stand-in.
    ChainlinkPriceAdapter internal adapter;

    event PriceUpdated(address indexed token, uint256 price, uint256 updatedAt);

    function setUp() public {
        vm.warp(T0);
        feed = new MockAggregatorV3(8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        adapter = new ChainlinkPriceAdapter(address(feed), address(weth), 10, 60, 300, 3600);
        feed.setRound(P2000, T0);
    }

    /// @dev Counts `PriceUpdated` logs emitted by the adapter during one sync.
    function _syncAndCountEmissions() internal returns (uint256 count) {
        vm.recordLogs();
        adapter.sync();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(adapter) && logs[i].topics.length > 0
                    && logs[i].topics[0] == PRICE_UPDATED_TOPIC
            ) {
                count++;
            }
        }
    }

    function testFirstSyncEmitsNormalizedPrice() public {
        // Round timestamped 60 s ago: the emitted updatedAt must be the
        // round's own timestamp, not the sync block time.
        feed.setRound(P2000, T0 - 60);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit PriceUpdated(address(weth), P2000_18, T0 - 60);
        adapter.sync();

        assertEq(adapter.lastPrice(), P2000_18, "8-decimal answer normalised x1e10");
        assertEq(adapter.priceScaleFactor(), 1e10);
        assertEq(adapter.latestPrice(address(weth)), P2000_18);
        assertEq(adapter.latestPrice(address(0xBEEF)), 0, "unknown token reads 0, like the mock oracle");
    }

    function testEventShapeIdenticalToMockOracle() public {
        MockPriceOracle oracle = new MockPriceOracle();
        vm.recordLogs();
        oracle.setPrice(address(weth), P2000_18); // emits (price, block.timestamp = T0)
        adapter.sync(); // round updatedAt is T0 (setUp), normalised price is P2000_18
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory oracleLog;
        Vm.Log memory adapterLog;
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(oracle)) {
                oracleLog = logs[i];
                found++;
            } else if (logs[i].emitter == address(adapter)) {
                adapterLog = logs[i];
                found++;
            }
        }
        assertEq(found, 2, "exactly one log from each origin");
        assertEq(adapterLog.topics[0], oracleLog.topics[0], "same topic0");
        assertEq(adapterLog.topics[0], PRICE_UPDATED_TOPIC);
        assertEq(adapterLog.topics[1], oracleLog.topics[1], "same topic1 (token)");
        assertEq(adapterLog.data, oracleLog.data, "same data payload (price, updatedAt)");
    }

    function testDeadbandSuppressesSmallMove() public {
        adapter.sync(); // first emission at $2,000
        vm.warp(T0 + 61); // past minInterval, before heartbeat
        feed.setRound(2001e8, T0 + 61); // +0.05% < 0.1% deadband
        assertEq(_syncAndCountEmissions(), 0, "inside the deadband: no emission");
        assertEq(adapter.lastPrice(), P2000_18);
    }

    function testMoveBeyondDeadbandEmits() public {
        adapter.sync();
        vm.warp(T0 + 61);
        feed.setRound(2010e8, T0 + 61); // +0.5% > 0.1% deadband
        assertEq(_syncAndCountEmissions(), 1);
        assertEq(adapter.lastPrice(), 2010e18);
    }

    function testMoveDownBeyondDeadbandEmits() public {
        adapter.sync();
        vm.warp(T0 + 61);
        feed.setRound(1990e8, T0 + 61); // -0.5%: the deadband is symmetric
        assertEq(_syncAndCountEmissions(), 1);
        assertEq(adapter.lastPrice(), 1990e18);
    }

    function testMinIntervalBlocksBigMove() public {
        adapter.sync();
        vm.warp(T0 + 30); // before minInterval (60 s)
        feed.setRound(2100e8, T0 + 30); // +5%: far beyond the deadband
        assertEq(_syncAndCountEmissions(), 0, "minInterval is a hard floor");
        assertEq(adapter.lastPrice(), P2000_18);

        vm.warp(T0 + 61);
        assertEq(_syncAndCountEmissions(), 1, "the same round emits once the floor passes");
        assertEq(adapter.lastPrice(), 2100e18);
    }

    function testHeartbeatEmitsUnchangedPrice() public {
        adapter.sync();
        vm.warp(T0 + 300); // heartbeat reached; round unchanged (300 s old < maxStaleness)
        vm.expectEmit(true, false, false, true, address(adapter));
        emit PriceUpdated(address(weth), P2000_18, T0);
        adapter.sync();
        assertEq(adapter.lastEmittedAt(), T0 + 300);
    }

    function testStaleRoundRejected() public {
        feed.setRound(P2000, T0 - 3601); // older than maxStaleness (3,600 s)
        assertEq(_syncAndCountEmissions(), 0);
        assertEq(adapter.lastPrice(), 0);
        assertEq(adapter.latestPrice(address(weth)), 0);
    }

    function testNonPositiveAnswerRejected() public {
        feed.setRound(0, T0);
        assertEq(_syncAndCountEmissions(), 0);
        feed.setRound(-100e8, T0);
        assertEq(_syncAndCountEmissions(), 0);
        assertEq(adapter.lastPrice(), 0);
    }

    function testIncompleteRoundRejected() public {
        feed.setRoundFull(7, P2000, T0, 6); // answeredInRound < roundId
        assertEq(_syncAndCountEmissions(), 0);
        assertEq(adapter.lastPrice(), 0);
    }

    function testSwapPricesFromAdapter() public {
        MockUSDC usdc = new MockUSDC();
        address vaultActor = makeAddr("vault");
        SentinelSwap swap = new SentinelSwap(address(weth), address(usdc), address(adapter), vaultActor);
        usdc.mint(address(swap), 1_000_000 ether); // seed the reserve
        weth.mint(vaultActor, 100 ether);
        vm.prank(vaultActor);
        weth.approve(address(swap), type(uint256).max);

        // Before the first sync the adapter reports 0 and the desk moves
        // nothing (its zero-price no-op path), exactly as with the mock.
        vm.prank(vaultActor);
        assertEq(swap.swapRiskForSafe(10 ether), 0);

        // After a sync, the desk prices off the Chainlink-derived price.
        adapter.sync();
        vm.prank(vaultActor);
        uint256 safeOut = swap.swapRiskForSafe(10 ether);
        assertEq(safeOut, 20_000 ether, "10 WETH at the adapted $2,000");
        assertEq(usdc.balanceOf(vaultActor), 20_000 ether);
        assertEq(weth.balanceOf(address(swap)), 10 ether);
    }
}
