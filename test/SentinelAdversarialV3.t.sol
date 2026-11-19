// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactiveV3} from "../src/SentinelReactiveV3.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Adversarial / edge-behaviour tests for SentinelReactiveV3 —
///         the v2 adversarial suite (test/SentinelAdversarial.t.sol)
///         re-run against the repair release, with the two repaired
///         behaviours re-pinned to their NEW measured semantics:
///           (c) replayed logs are now IGNORED ENTIRELY (v2: ingested
///               as fresh updates; only the cooldown prevented a
///               double fire). Repair 1 of TRIO4.md.
///           (e) the V-recovery blind window is UNCHANGED — the model
///               v3 retrain that targeted it failed its validation
///               gates and was not shipped (TRIO4.md), so this case
///               keeps pinning the limitation honestly: 7 HOLD steps
///               into a post-recovery decline, EXIT at step 8, with
///               the re-armed callback firing inside the old cooldown.
///         Cases (a), (b) and (d) carry over with identical numbers:
///         same weights, same features, same anchor.
/// @dev Every log here carries a unique identity (incrementing txHash)
///      — with dedup active, the v2 suite's txHash = 0 style would eat
///      its own stream. Replays re-send an identical LogRecord.
contract SentinelAdversarialV3Test is Test {
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
    SentinelReactiveV3 internal reactive;
    uint256 internal _nonce;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        // Production-shaped parameters: 3600 s cooldown, one price per 60 s.
        reactive = new SentinelReactiveV3(ORIGIN_CHAIN, oracle, token, ORIGIN_CHAIN, 3600);
        reactive.setVault(vault);
    }

    function _log(uint256 price, uint256 ts) internal returns (IReactive.LogRecord memory) {
        _nonce++;
        return IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: oracle,
            topic0: PRICE_TOPIC0,
            topic1: uint256(uint160(token)),
            topic2: 0,
            topic3: 0,
            data: abi.encode(price, ts),
            blockNumber: _nonce,
            opCode: 2,
            blockHash: 0,
            txHash: _nonce * 7919,
            logIndex: 0
        });
    }

    function _feed(uint256 price, uint256 ts) internal {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_log(price, ts));
    }

    function _feedRecord(IReactive.LogRecord memory log_) internal {
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

    // --- (a) stale / frozen feed (unchanged from v2) -------------------------------

    /// @notice After a real -8% step fires TRIM, the feed freezes: the same
    ///         price is re-delivered 30 times with advancing timestamps
    ///         (as NEW logs — a frozen feed is not a replay). Measured
    ///         behaviour, identical to v2: the model keeps voting TRIM
    ///         briefly, no second callback ever fires (suppression window
    ///         first, then the cooldown), the anchor drawdown decays
    ///         7.6% -> 5.3% and the vote returns to HOLD. A frozen feed can
    ///         never escalate to EXIT.
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
        assertEq(reactive.duplicatesIgnored(), 0, "frozen-feed repeats are new logs, not replays");
    }

    /// @notice A feed that freezes from the very start (one price, repeated
    ///         as new logs) is pure warmup noise: no votes, no callbacks.
    function testFrozenFeedFromStartIsInert() public {
        for (uint256 i = 0; i < 20; i++) {
            _feed(P100, T0 + i * 60);
            assertEq(reactive.lastAction(), SentinelModelV2.HOLD);
        }
        assertEq(reactive.anchorPeak(), P100);
        assertEq(sys.callbackCount(), 0);
    }

    // --- (b) whipsaw (unchanged from v2) --------------------------------------------

    /// @notice Square wave straight across the TRIM band: 100 <-> 92, forty
    ///         updates. The model NEVER votes TRIM or EXIT on this stream
    ///         and nothing fires — identical to v2.
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
    ///         price oscillates 92 <-> 85 for 24 updates. Identical to v2:
    ///         exactly one further TRIM vote, zero EXIT votes, callback
    ///         count stays at 1 (the vote lands inside both the new
    ///         suppression window and the cooldown).
    function testWhipsawSawtoothBoundedCallbacks() public {
        _feedToTrim();
        assertEq(sys.callbackCount(), 1);

        uint256 trimVotes = 0;
        uint256 exitVotes = 0;
        for (uint256 i = 1; i <= 24; i++) {
            _feed(i % 2 == 1 ? P85 : P92, T0 + 300 + i * 60);
            if (reactive.lastAction() == SentinelModelV2.TRIM) trimVotes++;
            if (reactive.lastAction() == SentinelModelV2.EXIT) exitVotes++;
            assertEq(sys.callbackCount(), 1, "suppression + cooldown bound firing under whipsaw");
        }
        assertEq(trimVotes, 1, "measured: one TRIM vote across the sawtooth");
        assertEq(exitVotes, 0, "measured: sawtooth never escalates to EXIT");
    }

    // --- (c) replayed log records — REPAIRED -----------------------------------------

    /// @notice REPAIR 1 pinned: a redelivered log is now ignored ENTIRELY.
    ///         V2 ingested the replay as a fresh update (window and anchor
    ///         advanced; the old test pinned updates == 4 after one replay
    ///         and == 6 after the firing-log replay). V3: updates do not
    ///         move, the anchor does not move, and the duplicate counter
    ///         records each ignored redelivery.
    function testReplayedLogIgnoredEntirely() public {
        _feed(P100, T0);
        _feed(P100_5, T0 + 60);
        IReactive.LogRecord memory third = _log(P99_8, T0 + 120);
        _feedRecord(third);
        assertEq(reactive.updates(), 3);
        uint256 anchorBefore = reactive.anchorPeak();

        _feedRecord(third); // exact replay of the previous log
        assertEq(reactive.updates(), 3, "replay is NOT ingested (v2: updates advanced)");
        assertEq(reactive.anchorPeak(), anchorBefore, "replay does not step the anchor");
        assertEq(reactive.duplicatesIgnored(), 1);
        assertEq(reactive.lastAction(), SentinelModelV2.HOLD);
        assertEq(sys.callbackCount(), 0);

        IReactive.LogRecord memory firing = _log(P92, T0 + 300);
        // Two intervening distinct logs to reach the TRIM path shape.
        _feed(P100_2, T0 + 180);
        _feed(P100_1, T0 + 240);
        _feedRecord(firing);
        assertEq(reactive.lastAction(), SentinelModelV2.TRIM);
        assertEq(sys.callbackCount(), 1);
        uint256 updatesBefore = reactive.updates();

        _feedRecord(firing); // exact replay of the firing log
        assertEq(reactive.updates(), updatesBefore, "crash replay is not ingested either");
        assertEq(sys.callbackCount(), 1, "no double fire");
        assertEq(reactive.duplicatesIgnored(), 2);
    }

    // --- (d) anchor decay edge: the slow grind (unchanged from v2) -------------------

    /// @notice A -0.5%/step grind — five times slower than the -2.6%/step
    ///         pace v1's window could never EXIT. Identical to v2 (same
    ///         weights): no EXIT vote for the first 51 updates; the first
    ///         EXIT lands exactly at update 52 (index 51) with anchorDD
    ///         at 18.50%.
    function testSlowGrindReachesExit() public {
        uint256 p = P100;
        uint256 firstExitStep = type(uint256).max;
        for (uint256 i = 0; i < 90; i++) {
            _feed(p, T0 + i * 60);
            if (reactive.updates() >= 3 && reactive.lastAction() == SentinelModelV2.EXIT && firstExitStep == type(uint256).max) {
                firstExitStep = i;
                assertEq(reactive.lastFeatures(6), int256(185038), "anchorDD at first grind EXIT");
            }
            p = p * 995 / 1000;
        }
        assertEq(firstExitStep, 51, "first EXIT at the anchor band, step index 51");
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertTrue(sys.callbackCount() > 0, "grind EXITs fired callbacks");
    }

    // --- (e) state reset / re-arm after EXIT — blind window STILL OPEN -----------------

    /// @notice Full cycle: crash -> TRIM + EXIT (state resets on EXIT) ->
    ///         recovery to a NEW high (anchor re-peaks to it, asserted) ->
    ///         a fresh decline. The re-arm half of v2's finding is fixed
    ///         since v2 and stays fixed: the new cycle's EXIT callback
    ///         FIRES at T0+1020, deep inside the first cycle's 3600 s
    ///         cooldown. The blind-window half is STILL OPEN, pinned
    ///         honestly: the model votes HOLD for the first seven -3%
    ///         steps after the sharp V-recovery (the recovery prices
    ///         fill the window) and engages at step 8, straight to EXIT.
    ///         The v3 retrain that targeted this (TRIO4.md) reached
    ///         step 1 on this exact path but regressed held-out fidelity
    ///         below the shipped v2's 95.41% in all three attempts and
    ///         was not shipped; this test is the standing evidence.
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
            assertEq(reactive.lastAction(), SentinelModelV2.HOLD, "blind window: window still holds the V-recovery");
            assertEq(sys.callbackCount(), 2, "nothing fires while the model holds");
        }
        p = p * 97 / 100;
        _feed(p, T0 + 540 + 8 * 60);
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertEq(sys.callbackCount(), 3, "re-armed: new cycle fires inside the old cooldown");
        assertEq(_callbackAction(sys.callbackAt(2)), SentinelModelV2.EXIT);
    }
}
