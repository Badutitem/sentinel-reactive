// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactiveV2} from "../src/SentinelReactiveV2.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Adversarial / edge-behaviour tests for SentinelReactiveV2 (added
///         2026-11-19, "safe package": no contract logic changed). Every
///         behavioural claim below was MEASURED against the shipped contract
///         before being pinned here — where the measured behaviour is a
///         limitation rather than a guarantee, the test documents it as such
///         and says so in its name and comments.
///         Covered: (a) a frozen/stale feed cannot manufacture protection
///         actions; (b) whipsaw around the TRIM band — square wave and
///         sawtooth; (c) replayed log records; (d) the slow-grind anchor
///         property at -0.5%/step; (e) re-arm after EXIT once a new high
///         re-peaks the anchor.
contract SentinelAdversarialTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));
    uint256 internal constant ORIGIN_CHAIN = 84532; // Base Sepolia
    uint256 internal constant T0 = 1_700_000_000;

    address internal oracle = makeAddr("oracle");
    address internal token = makeAddr("token");
    address internal vault = makeAddr("vault");

    // Prices in 1e8 units.
    uint256 internal constant P100 = 10_000_000_000;
    uint256 internal constant P100_5 = 10_050_000_000;
    uint256 internal constant P99_8 = 9_980_000_000;
    uint256 internal constant P100_2 = 10_020_000_000;
    uint256 internal constant P100_1 = 10_010_000_000;
    uint256 internal constant P92 = 9_200_000_000;
    uint256 internal constant P85 = 8_500_000_000;
    uint256 internal constant P81 = 8_100_000_000;
    uint256 internal constant P105 = 10_500_000_000;
    uint256 internal constant P98 = 9_800_000_000;
    uint256 internal constant P90 = 9_000_000_000;

    MockSystemContract internal sys;
    SentinelReactiveV2 internal reactive;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        // Production-shaped parameters: 3600 s cooldown, one price per 60 s.
        reactive = new SentinelReactiveV2(ORIGIN_CHAIN, oracle, token, ORIGIN_CHAIN, 3600);
        reactive.setVault(vault);
    }

    function _feed(uint256 price, uint256 ts) internal {
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: oracle,
            topic0: PRICE_TOPIC0,
            topic1: uint256(uint160(token)),
            topic2: 0,
            topic3: 0,
            data: abi.encode(price, ts),
            blockNumber: 0,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
    }

    function _callbackAction(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) internal pure returns (uint8) {
        bytes memory body = new bytes(cfg.payload.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = cfg.payload[i + 4];
        }
        (, uint8 action) = abi.decode(body, (address, uint8));
        return action;
    }

    /// @dev The calm prefix + -8% step used across this suite: the model's
    ///      first protection vote on this path is the TRIM at the last feed.
    function _feedToTrim() internal {
        _feed(P100, T0);
        _feed(P100_5, T0 + 60);
        _feed(P99_8, T0 + 120);
        _feed(P100_2, T0 + 180);
        _feed(P100_1, T0 + 240);
        _feed(P92, T0 + 300);
    }

    // --- (a) stale / frozen feed -------------------------------------------------

    /// @notice After a real -8% step fires TRIM, the feed freezes: the same
    ///         price is re-delivered 30 times with advancing timestamps.
    ///         Measured behaviour: the model keeps voting TRIM briefly (the
    ///         window still shows the drop), the cooldown suppresses every
    ///         repeat, and as the anchor leaks toward the frozen price the
    ///         drawdown feature decays (7.6% -> 5.3% over the 30 repeats) and
    ///         the vote returns to HOLD. A frozen feed can never escalate to
    ///         EXIT and never fires a second callback.
    function testStaleFeedCannotManufactureExit() public {
        _feedToTrim();
        assertEq(reactive.lastAction(), SentinelModelV2.TRIM);
        assertEq(sys.callbackCount(), 1);
        assertEq(_callbackAction(sys.callbackAt(0)), SentinelModelV2.TRIM);

        for (uint256 i = 1; i <= 30; i++) {
            _feed(P92, T0 + 300 + i * 60);
            assertTrue(reactive.lastAction() != SentinelModelV2.EXIT, "stale feed must never vote EXIT");
            assertEq(sys.callbackCount(), 1, "stale feed must never fire again");
        }
        assertEq(reactive.lastAction(), SentinelModelV2.HOLD, "frozen price decays back to calm");
        assertEq(reactive.lastFeatures(6), int256(52901), "anchorDD after 30 frozen repeats");
    }

    /// @notice A feed that freezes from the very start (one price, repeated)
    ///         is pure warmup noise: zero returns, zero drawdown, no votes,
    ///         no callbacks, however long it runs.
    function testFrozenFeedFromStartIsInert() public {
        for (uint256 i = 0; i < 20; i++) {
            _feed(P100, T0 + i * 60);
            assertEq(reactive.lastAction(), SentinelModelV2.HOLD);
        }
        assertEq(reactive.anchorPeak(), P100);
        assertEq(sys.callbackCount(), 0);
    }

    // --- (b) whipsaw ---------------------------------------------------------------

    /// @notice Square wave straight across the TRIM band: 100 <-> 92, forty
    ///         updates. Measured behaviour: the model NEVER votes TRIM or
    ///         EXIT on this stream — each down-leg is fully retraced by the
    ///         next up-leg, so no window ever looks like a crash — and nothing
    ///         fires. No flap exists at this amplitude to bound.
    function testWhipsawSquareWaveNoFlap() public {
        uint256 trimVotes = 0;
        uint256 exitVotes = 0;
        for (uint256 i = 0; i < 40; i++) {
            _feed(i % 2 == 0 ? P100 : P92, T0 + i * 60);
            if (reactive.updates() >= 3) {
                if (reactive.lastAction() == SentinelModelV2.TRIM) trimVotes++;
                if (reactive.lastAction() == SentinelModelV2.EXIT) exitVotes++;
            }
        }
        assertEq(trimVotes, 0, "square wave must not produce TRIM votes");
        assertEq(exitVotes, 0, "square wave must not produce EXIT votes");
        assertEq(sys.callbackCount(), 0);
    }

    /// @notice Sawtooth UNDER the TRIM point after a TRIM already fired:
    ///         price oscillates 92 <-> 85 for 24 updates. Measured behaviour:
    ///         exactly one further TRIM vote, zero EXIT votes, and the
    ///         callback count stays at 1 — continued bad prices inside the
    ///         cooldown cannot re-fire, and the oscillation never escalates.
    function testWhipsawSawtoothBoundedCallbacks() public {
        _feedToTrim();
        assertEq(sys.callbackCount(), 1);

        uint256 trimVotes = 0;
        uint256 exitVotes = 0;
        for (uint256 i = 1; i <= 24; i++) {
            _feed(i % 2 == 1 ? P85 : P92, T0 + 300 + i * 60);
            if (reactive.lastAction() == SentinelModelV2.TRIM) trimVotes++;
            if (reactive.lastAction() == SentinelModelV2.EXIT) exitVotes++;
            assertEq(sys.callbackCount(), 1, "cooldown bounds firing under whipsaw");
        }
        assertEq(trimVotes, 1, "measured: one TRIM vote across the sawtooth");
        assertEq(exitVotes, 0, "measured: sawtooth never escalates to EXIT");
    }

    // --- (c) replayed log records ----------------------------------------------------

    /// @notice The contract has NO replay deduplication — a redelivered log
    ///         is ingested as a fresh update (window and anchor advance), and
    ///         this test pins that honestly. What replay cannot do is double
    ///         -fire: the cooldown is keyed on the log's own origin timestamp,
    ///         so an exact replay of the crash log (same price, same ts)
    ///         votes TRIM again but fires nothing.
    function testReplayedLogIngestedButCannotDoubleFire() public {
        _feed(P100, T0);
        _feed(P100_5, T0 + 60);
        _feed(P99_8, T0 + 120);
        _feed(P99_8, T0 + 120); // exact replay of the previous log
        assertEq(reactive.updates(), 4, "replay is ingested as an update (no dedup)");
        assertEq(reactive.lastAction(), SentinelModelV2.HOLD);
        assertEq(sys.callbackCount(), 0);

        _feed(P92, T0 + 300);
        assertEq(reactive.lastAction(), SentinelModelV2.TRIM);
        assertEq(sys.callbackCount(), 1);

        _feed(P92, T0 + 300); // exact replay of the firing log
        assertEq(reactive.updates(), 6, "crash replay is ingested too");
        assertEq(reactive.lastAction(), SentinelModelV2.TRIM, "replay votes the same action");
        assertEq(sys.callbackCount(), 1, "same origin ts: cooldown blocks the duplicate fire");
    }

    // --- (d) anchor decay edge: the slow grind ---------------------------------------

    /// @notice A -0.5%/step grind — five times slower than the -2.6%/step
    ///         pace v1's window could never EXIT. Measured behaviour: no EXIT
    ///         vote for the first 51 updates; the first EXIT lands exactly at
    ///         update 52 (index 51) with anchorDD at 18.50%, i.e. the anchor
    ///         band crossing, not any window feature, is what fires it. The
    ///         grind then keeps voting EXIT to the end of the series.
    function testSlowGrindReachesExit() public {
        uint256 p = P100;
        uint256 firstExitStep = type(uint256).max;
        for (uint256 i = 0; i < 90; i++) {
            _feed(p, T0 + i * 60);
            if (
                reactive.updates() >= 3 && reactive.lastAction() == SentinelModelV2.EXIT
                    && firstExitStep == type(uint256).max
            ) {
                firstExitStep = i;
                assertEq(reactive.lastFeatures(6), int256(185038), "anchorDD at first grind EXIT");
            }
            p = p * 995 / 1000;
        }
        assertEq(firstExitStep, 51, "first EXIT at the anchor band, step index 51");
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertTrue(sys.callbackCount() > 0, "grind EXITs fired callbacks");
    }

    // --- (e) state reset / re-arm after EXIT -------------------------------------------

    /// @notice Full cycle: crash -> TRIM + EXIT (state resets on EXIT) ->
    ///         recovery to a NEW high (anchor re-peaks to it, asserted) -> a
    ///         fresh decline. Measured behaviour, documented honestly:
    ///         the model does NOT react to the first steps of a decline that
    ///         starts immediately after a sharp V-recovery — the recovery
    ///         prices still fill the window, and seven -3% steps vote HOLD.
    ///         At the eighth step the window is a clean decline, the model
    ///         votes EXIT (straight to EXIT, no TRIM first on this path), and
    ///         the callback FIRES at T0+1020 — deep inside the first cycle's
    ///         3600 s cooldown (which would have run to T0+3960) — proving
    ///         the EXIT reset re-armed the guardian for the new position.
    function testRearmAfterExitNewHigh() public {
        _feedToTrim();
        _feed(P81, T0 + 360); // EXIT; fired-state resets here
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertEq(sys.callbackCount(), 2);
        assertEq(_callbackAction(sys.callbackAt(0)), SentinelModelV2.TRIM);
        assertEq(_callbackAction(sys.callbackAt(1)), SentinelModelV2.EXIT);

        // Recovery to a new high: the anchor re-peaks to it.
        _feed(P90, T0 + 420);
        _feed(P98, T0 + 480);
        _feed(P105, T0 + 540);
        assertEq(reactive.anchorPeak(), P105, "anchor re-peaks at the new high");

        // Fresh sustained decline, -3%/step from the new high.
        uint256 p = P105;
        for (uint256 i = 1; i <= 7; i++) {
            p = p * 97 / 100;
            _feed(p, T0 + 540 + i * 60);
            assertEq(reactive.lastAction(), SentinelModelV2.HOLD, "window still holds the V-recovery");
            assertEq(sys.callbackCount(), 2, "nothing fires while the model holds");
        }
        p = p * 97 / 100;
        _feed(p, T0 + 540 + 8 * 60);
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertEq(sys.callbackCount(), 3, "re-armed: new cycle fires inside the old cooldown");
        assertEq(_callbackAction(sys.callbackAt(2)), SentinelModelV2.EXIT);
    }
}
