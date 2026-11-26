// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactiveV3} from "../src/SentinelReactiveV3.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";

/// @notice Tests for SentinelReactiveV3 (Release 4 repair release): the v2
///         behaviours carried over (subscription, guards, anchor, bit-exact
///         parity against the tools/train.py mirror over the SHIPPED v2
///         weights — the v3 retrain failed its gates, see RELEASE4.md) plus
///         the two contract-level repairs:
///           1. replay dedup — a redelivered log changes nothing at all;
///           2. TRIM suppression — after a TRIM fires, TRIM votes are
///              suppressed for 10 updates unless EXIT conditions hold.
///         Every pinned number was produced by running the actual Python
///         mirror (forward_int_v2 over SentinelWeightsV2 plus a mirror
///         of the V3 firing semantics) on the same series, never by hand.
/// @dev Log identities: unlike the v2 suites (which feed txHash = 0 for
///      every log — dedup would eat them), this suite gives every log a
///      unique identity via an incrementing counter, and replays are fed
///      by re-sending an identical LogRecord struct.
contract SentinelReactiveV3Test is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));

    uint256 internal constant ORIGIN_CHAIN = 84532; // Base Sepolia
    uint256 internal constant DEST_CHAIN = 84532;
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
    uint256 internal constant P81 = 8_100_000_000;
    uint256 internal constant P76 = 7_600_000_000;

    uint256 internal constant T0 = 1_700_000_000;

    MockSystemContract internal sys;
    SentinelReactiveV3 internal reactive;
    uint256 internal _nonce; // log-identity counter

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        reactive = new SentinelReactiveV3(ORIGIN_CHAIN, oracle, token, DEST_CHAIN, 3600);
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
            txHash: _nonce * 7919, // unique per log
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

    // --- subscription & guards (carried from v2) --------------------------------

    function testSubscriptionRecorded() public view {
        assertEq(sys.subscriptionCount(), 1);
        (
            address subscriber,
            uint256 chainId,
            address contractAddress,
            uint256 topic0,
            uint256 topic1,
            uint256 topic2,
            uint256 topic3
        ) = sys.subscriptions(0);
        assertEq(subscriber, address(reactive));
        assertEq(chainId, ORIGIN_CHAIN);
        assertEq(contractAddress, oracle);
        assertEq(topic0, PRICE_TOPIC0);
        assertEq(topic1, uint256(uint160(token)));
        assertEq(topic2, REACTIVE_IGNORE);
        assertEq(topic3, REACTIVE_IGNORE);
    }

    function testReactRejectsNonSystem() public {
        IReactive.LogRecord memory log_ = _log(P100, T0);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM_ADDR));
        reactive.react(log_);
    }

    function testUnknownTopicIgnored() public {
        IReactive.LogRecord memory log_ = _log(P100, T0);
        log_.topic0 = 0xdeadbeef;
        _feedRecord(log_);
        assertEq(reactive.updates(), 0);
        assertEq(reactive.anchorPeak(), 0);
        assertEq(reactive.duplicatesIgnored(), 0, "foreign logs are not dedup-tracked");
        assertEq(sys.callbackCount(), 0);
    }

    function testSetVaultOnlyOwner() public {
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(bytes("Sentinel: not owner"));
        reactive.setVault(vault);
    }

    // --- anchor + parity (shipped v2 weights, identical numbers to v2) -----------

    function testFirstPriceInitializesAnchor() public {
        _feed(P100, T0);
        assertEq(reactive.anchorPeak(), P100);
        _feed(9_000_000_000, T0 + 60);
        assertEq(reactive.anchorPeak(), 9_990_000_000, "max(90, 100 x 999/1000)");
    }

    function testCrashPathParity() public {
        reactive.setVault(vault);
        _feed(P100, T0);
        _feed(P100_5, T0 + 60);
        _feed(P99_8, T0 + 120);
        _feed(P100_2, T0 + 180);
        _feed(P100_1, T0 + 240);
        _feed(P92, T0 + 300);
        assertEq(reactive.lastAction(), SentinelModelV2.TRIM);
        assertEq(sys.callbackCount(), 1);
        _feed(P81, T0 + 360);
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertEq(sys.callbackCount(), 2);
        _feed(P76, T0 + 420);
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        // Bit-exact pins, identical to SentinelReactiveV2's crash path:
        // same features, same weights, same forward pass.
        int256[7] memory expectedFeatures = [
            int256(-61728),
            int256(-37309),
            int256(59455),
            int256(243781),
            int256(-240000),
            int256(-188900),
            int256(239227)
        ];
        for (uint256 i = 0; i < 7; i++) {
            assertEq(reactive.lastFeatures(i), expectedFeatures[i], "feature");
        }
        int256[3] memory expectedScores = [int256(-5038852), int256(-7095521), int256(727410)];
        for (uint256 k = 0; k < 3; k++) {
            assertEq(reactive.lastScores(k), expectedScores[k], "score");
        }
        // EXIT reset: the second EXIT vote fires inside the cooldown too.
        assertEq(sys.callbackCount(), 3);
        assertEq(reactive.lastTrimFiredUpdate(), 0, "EXIT reset clears the suppression state");
    }

    function testNoVaultNoCallback() public {
        _feed(P100, T0);
        _feed(P100_5, T0 + 60);
        _feed(P99_8, T0 + 120);
        _feed(P100_2, T0 + 180);
        _feed(P100_1, T0 + 240);
        _feed(P92, T0 + 300);
        _feed(P81, T0 + 360);
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertEq(sys.callbackCount(), 0);
    }

    // --- REPAIR 1: replay dedup ----------------------------------------------------

    /// @notice A redelivered log is ignored COMPLETELY: no update count,
    ///         no anchor step, no new inference, no callback — the exact
    ///         opposite of v2's pinned behaviour (ingested as a fresh
    ///         update; see SentinelAdversarial.t.sol case (c)).
    function testReplayedLogIgnoredCompletely() public {
        reactive.setVault(vault);
        IReactive.LogRecord memory l1 = _log(P100, T0);
        IReactive.LogRecord memory l2 = _log(P100_5, T0 + 60);
        IReactive.LogRecord memory l3 = _log(P99_8, T0 + 120);
        _feedRecord(l1);
        _feedRecord(l2);
        _feedRecord(l3);
        assertEq(reactive.updates(), 3);
        uint256 anchorBefore = reactive.anchorPeak();
        int256 scoreBefore = reactive.lastScores(0);

        _feedRecord(l2); // exact replay of the middle log
        assertEq(reactive.updates(), 3, "replay must not advance updates");
        assertEq(reactive.anchorPeak(), anchorBefore, "replay must not step the anchor");
        assertEq(reactive.lastScores(0), scoreBefore, "replay must not re-run inference");
        assertEq(reactive.duplicatesIgnored(), 1);

        _feedRecord(l1); // replay of a warmup log: also ignored
        assertEq(reactive.updates(), 3);
        assertEq(reactive.duplicatesIgnored(), 2);
        assertEq(sys.callbackCount(), 0);
    }

    /// @notice The firing log itself, replayed, cannot double-fire — and
    ///         (stronger than v2) is not even ingested.
    function testReplayedFiringLogCannotDoubleFire() public {
        reactive.setVault(vault);
        _feed(P100, T0);
        _feed(P100_5, T0 + 60);
        _feed(P99_8, T0 + 120);
        _feed(P100_2, T0 + 180);
        _feed(P100_1, T0 + 240);
        IReactive.LogRecord memory firing = _log(P92, T0 + 300);
        _feedRecord(firing);
        assertEq(reactive.lastAction(), SentinelModelV2.TRIM);
        assertEq(sys.callbackCount(), 1);
        uint256 updatesBefore = reactive.updates();

        _feedRecord(firing); // exact replay
        assertEq(reactive.updates(), updatesBefore, "firing-log replay not ingested");
        assertEq(sys.callbackCount(), 1, "no double fire");
        assertEq(reactive.duplicatesIgnored(), 1);
    }

    /// @notice Identity is (chain, contract, txHash, logIndex): a second
    ///         log from the same transaction (different logIndex) and a
    ///         log with the same index in a different transaction are
    ///         both genuine new logs and must be processed.
    function testDistinctLogIdentitiesAreProcessed() public {
        IReactive.LogRecord memory a = _log(P100, T0);
        IReactive.LogRecord memory b = _log(P100_5, T0 + 60);
        b.txHash = a.txHash; // same tx, different logIndex
        b.logIndex = 1;
        IReactive.LogRecord memory c = _log(P99_8, T0 + 120);
        c.logIndex = 1; // same logIndex as b, different tx
        _feedRecord(a);
        _feedRecord(b);
        _feedRecord(c);
        assertEq(reactive.updates(), 3, "distinct identities are all processed");
        assertEq(reactive.duplicatesIgnored(), 0);
    }

    // --- REPAIR 3: TRIM suppression --------------------------------------------------
    //
    // These two tests use the PRODUCTION cooldown (300 s) with 400 s
    // spacing, so the time-based cooldown never binds and every firing
    // decision is attributable to the suppression rule alone. Paths and
    // expectations were measured on the Python mirror of the V3 firing
    // semantics before being pinned here.

    function _deploySuppressionInstance() internal returns (SentinelReactiveV3 r) {
        r = new SentinelReactiveV3(ORIGIN_CHAIN, oracle, token, DEST_CHAIN, 300);
        r.setVault(vault);
    }

    function _feedR(SentinelReactiveV3 r, uint256 price, uint256 ts) internal {
        _nonce++;
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
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
        vm.prank(SYSTEM_ADDR);
        r.react(log_);
    }

    /// @notice The -0.5%/step slow grind exercises the whole rulebook:
    ///         TRIM fires at update 8; the TRIM votes at updates 9-18 are
    ///         suppressed (window = 10 updates); TRIM fires again at 19,
    ///         30 and 41 as each window lapses; at update 51 a TRIM vote
    ///         arrives inside the window BUT with EXIT conditions met
    ///         (anchorDD 18.18% >= 18%, momentum negative) and FIRES via
    ///         the bypass; at update 52 the model votes EXIT, which
    ///         fires and resets the suppression state.
    function testTrimSuppressionWindowLapseAndBypass() public {
        SentinelReactiveV3 r = _deploySuppressionInstance();
        uint256 p = P100;
        for (uint256 i = 0; i < 61; i++) {
            _feedR(r, p, T0 + i * 400);
            p = p * 995 / 1000;
            uint256 u = i + 1; // updates counter after this feed
            if (u == 8) {
                assertEq(sys.callbackCount(), 1, "first TRIM fires at update 8");
                assertEq(_callbackAction(sys.callbackAt(0)), SentinelModelV2.TRIM);
                assertEq(r.lastTrimFiredUpdate(), 8);
            }
            if (u == 18) {
                assertEq(sys.callbackCount(), 1, "updates 9-18: TRIM votes suppressed");
                assertEq(r.lastAction(), SentinelModelV2.TRIM, "the vote still happens; only the fire is withheld");
            }
            if (u == 19) {
                assertEq(sys.callbackCount(), 2, "window lapsed: TRIM fires again at 19");
                assertEq(r.lastTrimFiredUpdate(), 19);
            }
            if (u == 41) {
                assertEq(sys.callbackCount(), 4, "TRIM fires at 8/19/30/41");
                assertEq(r.lastTrimFiredUpdate(), 41);
            }
            if (u == 50) {
                assertEq(sys.callbackCount(), 4, "updates 42-50 suppressed");
            }
            if (u == 51) {
                assertEq(sys.callbackCount(), 5, "EXIT conditions met: TRIM bypasses suppression at 51");
                assertEq(_callbackAction(sys.callbackAt(4)), SentinelModelV2.TRIM);
                assertTrue(r.lastFeatures(6) >= 180_000, "bypass requires anchorDD >= 18%");
                assertTrue(r.lastFeatures(4) < 0, "bypass requires negative momentum");
                assertEq(r.lastTrimFiredUpdate(), 51);
            }
            if (u == 52) {
                assertEq(r.lastAction(), SentinelModelV2.EXIT);
                assertEq(sys.callbackCount(), 6, "EXIT fires and resets");
                assertEq(r.lastTrimFiredUpdate(), 0, "EXIT reset clears suppression");
            }
        }
        // Updates 53-61 keep voting EXIT; each fires (post-reset state).
        assertEq(sys.callbackCount(), 15);
        for (uint256 i = 5; i < 15; i++) {
            assertEq(_callbackAction(sys.callbackAt(i)), SentinelModelV2.EXIT);
        }
    }

    /// @notice The -2%/step bleed: TRIM fires at update 3, its repeat
    ///         votes are suppressed, and the EXIT escalation at update
    ///         12 fires immediately — suppression never delays an EXIT.
    function testSuppressionNeverBlocksExit() public {
        SentinelReactiveV3 r = _deploySuppressionInstance();
        uint256 p = P100;
        for (uint256 i = 0; i < 31; i++) {
            _feedR(r, p, T0 + i * 400);
            p = p * 98 / 100;
            uint256 u = i + 1;
            if (u == 3) {
                assertEq(sys.callbackCount(), 1);
                assertEq(_callbackAction(sys.callbackAt(0)), SentinelModelV2.TRIM);
            }
            if (u == 11) {
                assertEq(sys.callbackCount(), 1, "TRIM repeats suppressed through update 11");
            }
            if (u == 12) {
                assertEq(r.lastAction(), SentinelModelV2.EXIT);
                assertEq(sys.callbackCount(), 2, "EXIT fires inside the suppression window");
                assertEq(_callbackAction(sys.callbackAt(1)), SentinelModelV2.EXIT);
            }
        }
        assertEq(sys.callbackCount(), 21, "1 TRIM + EXIT at every update 12-31");
    }
}
