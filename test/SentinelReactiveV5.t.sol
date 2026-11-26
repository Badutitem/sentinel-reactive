// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactiveV5} from "../src/SentinelReactiveV5.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Tests for SentinelReactiveV5 (Release 5 as evaluated): the v3
///         behaviours carried over (crash-path firing parity, replay
///         dedup) plus the variant-B scale-in episode machine:
///           (a) bleed -> EXIT -> reclaim at >= 97% of the episode
///               anchor after >= 3 updates -> tranche 1 (action 3)
///               fires and the episode STAYS OPEN;
///           (b) recovery to only ~90% of the anchor -> neither
///               tranche fires, the episode stays open;
///           (c) an instant reclaim still waits out the 3-update
///               minimum before tranche 1;
///           (d) tranche 1 never double-fires, and tranche 2 never
///               fires without the anchor exceeding the episode anchor;
///           (e) a new anchor high BEFORE the 3-update minimum still
///               cancels the episode (V1 behaviour);
///           (f) a print above the anchor AFTER the minimum fires
///               tranche 1 instead of cancelling — B's reclaim-first
///               ordering — and the next new anchor high fires
///               tranche 2 (action 4); pinned again on the evaluation's
///               full succ_V stream, where V1 cancelled and B fired
///               tranche 1 at update 17 and tranche 2 at update 18;
///           (g) an EXIT after a completed re-risk opens a FRESH
///               episode (tranches reset) whose own tranche 1 fires on
///               its own reclaim.
/// @dev Every expectation was measured on the evaluation mirror
///      (tools/rerisk_variants.py, variant B — the validated mirror of
///      this exact machine) before being pinned here. Cooldown is
///      300 s with 400 s spacing throughout, so the timestamp cooldown
///      never binds. Every log carries a unique identity (dedup active).
contract SentinelReactiveV5Test is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));

    uint256 internal constant ORIGIN_CHAIN = 84532; // Base Sepolia
    uint256 internal constant DEST_CHAIN = 84532;
    address internal oracle = makeAddr("oracle");
    address internal token = makeAddr("token");
    address internal vault = makeAddr("vault");

    uint8 internal constant RERISK = 3;
    uint8 internal constant RERISK_FINAL = 4;

    // Prices in 1e8 units.
    uint256 internal constant P100 = 10_000_000_000;
    uint256 internal constant P100_5 = 10_050_000_000;
    uint256 internal constant P99_8 = 9_980_000_000;
    uint256 internal constant P100_2 = 10_020_000_000;
    uint256 internal constant P100_1 = 10_010_000_000;
    uint256 internal constant P101 = 10_100_000_000;
    uint256 internal constant P98 = 9_800_000_000;
    uint256 internal constant P96 = 9_600_000_000;
    uint256 internal constant P95 = 9_500_000_000;
    uint256 internal constant P92 = 9_200_000_000;
    uint256 internal constant P90 = 9_000_000_000;
    uint256 internal constant P88 = 8_800_000_000;
    uint256 internal constant P85 = 8_500_000_000;
    uint256 internal constant P81 = 8_100_000_000;
    uint256 internal constant P76 = 7_600_000_000;

    uint256 internal constant T0 = 1_700_000_000;

    MockSystemContract internal sys;
    SentinelReactiveV5 internal reactive;
    uint256 internal _nonce; // log-identity counter

    event EpisodeOpened(uint256 episodeAnchor, uint256 updates);
    event EpisodeCancelled(uint256 price, uint256 originTimestamp, uint256 updates);

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        reactive = new SentinelReactiveV5(ORIGIN_CHAIN, oracle, token, DEST_CHAIN, 300);
        reactive.setVault(vault);
    }

    function _feed(uint256 price, uint256 ts) internal {
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
            txHash: _nonce * 7919, // unique per log
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
    }

    function _feedN(uint256 price, uint256 tsStart, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            _feed(price, tsStart + i * 400);
        }
    }

    function _callbackAction(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) internal pure returns (uint8) {
        bytes memory body = new bytes(cfg.payload.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = cfg.payload[i + 4];
        }
        (, uint8 action) = abi.decode(body, (address, uint8));
        return action;
    }

    function _countAction(uint8 action) internal view returns (uint256 count) {
        for (uint256 i = 0; i < sys.callbackCount(); i++) {
            if (_callbackAction(sys.callbackAt(i)) == action) count++;
        }
    }

    /// @dev The shared bleed: calm prices, then -8% (TRIM fires at
    ///      update 6), then 81 (EXIT fires at update 7 and refreshes
    ///      the episode: anchor 9_999_850_397, start update 7).
    function _bleedToExit() internal {
        _feed(P100, T0);
        _feed(P100_5, T0 + 400);
        _feed(P99_8, T0 + 800);
        _feed(P100_2, T0 + 1200);
        _feed(P100_1, T0 + 1600);
        _feed(P92, T0 + 2000);
        _feed(P81, T0 + 2400);
        assertEq(sys.callbackCount(), 2);
        assertEq(_callbackAction(sys.callbackAt(0)), SentinelModelV2.TRIM);
        assertEq(_callbackAction(sys.callbackAt(1)), SentinelModelV2.EXIT);
        assertTrue(reactive.episodeActive());
        assertEq(reactive.episodeAnchor(), 9_999_850_397);
        assertEq(reactive.episodeStartUpdate(), 7);
        assertFalse(reactive.tranche1Fired());
        assertFalse(reactive.tranche2Fired());
    }

    // --- carried-over v3 behaviour -------------------------------------------------

    /// @notice The v3 crash path fires identically in v5 (TRIM, EXIT,
    ///         EXIT), and the last EXIT leaves a fresh episode open,
    ///         anchored at the anchor in effect when it fired.
    function testCrashPathParityAndEpisodeOpens() public {
        _bleedToExit();
        _feed(P76, T0 + 2800);
        assertEq(sys.callbackCount(), 3);
        assertEq(_callbackAction(sys.callbackAt(2)), SentinelModelV2.EXIT);
        assertTrue(reactive.episodeActive());
        assertEq(reactive.episodeStartUpdate(), 8);
        assertEq(reactive.episodeAnchor(), reactive.anchorPeak(), "episode anchors at the firing moment's anchor");
        assertEq(reactive.episodeAnchor(), 9_989_850_546);
        assertEq(reactive.reriskCount(), 0);
    }

    /// @notice Dedup (v3 repair 1) is intact: a replayed log is ignored
    ///         completely — in particular it cannot advance an open
    ///         episode toward its 3-update minimum.
    function testReplayedLogIgnoredAndDoesNotAdvanceEpisode() public {
        _bleedToExit();
        _nonce++;
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: oracle,
            topic0: PRICE_TOPIC0,
            topic1: uint256(uint160(token)),
            topic2: 0,
            topic3: 0,
            data: abi.encode(P98, T0 + 2800),
            blockNumber: _nonce,
            opCode: 2,
            blockHash: 0,
            txHash: _nonce * 7919,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
        assertEq(reactive.updates(), 8);
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_); // exact replay
        assertEq(reactive.updates(), 8, "replay not ingested");
        assertEq(reactive.duplicatesIgnored(), 1);
        assertEq(sys.callbackCount(), 2, "replay cannot manufacture progress toward a re-risk");
    }

    // --- (a) tranche 1 fires on the reclaim; the episode stays open -------------------

    function testTranche1AfterExitOnReclaim() public {
        _bleedToExit();
        _feed(P85, T0 + 2800); // update 8: 1 since the de-risk
        _feed(P90, T0 + 3200); // update 9: 2
        _feed(P95, T0 + 3600); // update 10: 3, but 95 < 97% of the anchor — no fire
        assertEq(sys.callbackCount(), 2, "minimum met but price still below the reclaim band");
        _feed(P98, T0 + 4000); // update 11: 98 >= 97% of 99.9985... — tranche 1 fires
        assertEq(sys.callbackCount(), 3);
        assertEq(_callbackAction(sys.callbackAt(2)), RERISK);
        assertEq(_countAction(RERISK), 1, "exactly one action-3 callback");
        assertEq(_countAction(RERISK_FINAL), 0);
        assertEq(reactive.reriskCount(), 1);
        assertTrue(reactive.tranche1Fired());
        assertFalse(reactive.tranche2Fired());
        assertTrue(reactive.episodeActive(), "unlike V1, the episode stays open for tranche 2");
    }

    // --- tranche 2 fires on the new anchor high ------------------------------------------

    function testTranche2OnNewAnchorHigh() public {
        _bleedToExit();
        _feed(P85, T0 + 2800);
        _feed(P90, T0 + 3200);
        _feed(P95, T0 + 3600);
        _feed(P98, T0 + 4000); // update 11: tranche 1
        assertEq(_countAction(RERISK), 1);

        _feed(P101, T0 + 4400); // update 12: the anchor sets a new high above the episode anchor
        assertEq(sys.callbackCount(), 4);
        assertEq(_callbackAction(sys.callbackAt(3)), RERISK_FINAL);
        assertEq(_countAction(RERISK_FINAL), 1, "exactly one action-4 callback");
        assertEq(reactive.reriskCount(), 2, "both tranches of the episode counted");
        assertTrue(reactive.tranche2Fired());
        assertFalse(reactive.episodeActive(), "tranche 2 closes the episode");
    }

    // --- (b) shallow recovery: neither tranche fires ---------------------------------------

    function testNoReriskOnShallowRecovery() public {
        _bleedToExit();
        _feed(P85, T0 + 2800);
        _feed(P88, T0 + 3200);
        _feedN(P90, T0 + 3600, 6); // parks at 90% of the pre-crash level, ~90.0% of the episode anchor
        assertEq(_countAction(RERISK), 0, "90% is below the 97% reclaim band: no tranche 1");
        assertEq(_countAction(RERISK_FINAL), 0);
        assertEq(reactive.reriskCount(), 0);
        assertEq(sys.callbackCount(), 2);
        assertTrue(reactive.episodeActive(), "the episode is still open: neither fired nor cancelled");
        assertFalse(reactive.tranche1Fired());
    }

    // --- (c) instant reclaim still waits out the 3-update minimum -----------------------------
    //
    // The -0.5%/step grind fires its TRIM at update 8 with the price at
    // 9_655_206_466 — already >= 97% of the episode anchor it opens
    // (9_930_209_650): the most instant reclaim possible. Tranche 1
    // still cannot fire on updates 9 or 10 and fires exactly at update
    // 11. The flat prints that follow never push the anchor above the
    // episode anchor, so tranche 2 never fires either.

    function testTranche1WaitsForMinimumUpdates() public {
        uint256[8] memory grind = [
            uint256(10_000_000_000),
            uint256(9_950_000_000),
            uint256(9_900_250_000),
            uint256(9_850_748_750),
            uint256(9_801_495_006),
            uint256(9_752_487_530),
            uint256(9_703_725_092),
            uint256(9_655_206_466)
        ];
        for (uint256 i = 0; i < grind.length; i++) {
            _feed(grind[i], T0 + i * 400);
        }
        assertEq(sys.callbackCount(), 1);
        assertEq(_callbackAction(sys.callbackAt(0)), SentinelModelV2.TRIM);
        assertTrue(reactive.episodeActive(), "a fired TRIM opens an episode too");
        assertEq(reactive.episodeAnchor(), 9_930_209_650);
        assertEq(reactive.episodeStartUpdate(), 8);
        uint256 flat = grind[7];
        assertTrue(flat * 100 >= reactive.episodeAnchor() * 97, "the price never left the reclaim band");

        _feed(flat, T0 + 3200); // update 9: 1 since the de-risk
        _feed(flat, T0 + 3600); // update 10: 2
        assertEq(sys.callbackCount(), 1, "in-band but inside the minimum: no tranche 1 yet");
        assertEq(reactive.reriskCount(), 0);

        _feed(flat, T0 + 4000); // update 11: the third update — tranche 1 fires
        assertEq(sys.callbackCount(), 2);
        assertEq(_callbackAction(sys.callbackAt(1)), RERISK);
        assertEq(reactive.reriskCount(), 1);
        assertTrue(reactive.episodeActive());

        _feedN(flat, T0 + 4400, 5); // flat forever: the anchor only decays, never exceeds the episode anchor
        assertEq(_countAction(RERISK_FINAL), 0, "no new anchor high: no tranche 2");
        assertEq(sys.callbackCount(), 2);
    }

    // --- (d) no double-fire; no tranche 2 without a new anchor high ----------------------------

    function testTranchesFireOnlyOnceAndTranche2NeedsNewHigh() public {
        _bleedToExit();
        _feed(P85, T0 + 2800);
        _feed(P90, T0 + 3200);
        _feed(P95, T0 + 3600);
        _feed(P98, T0 + 4000); // tranche 1 fires here (update 11)
        assertEq(reactive.reriskCount(), 1);

        _feedN(P98, T0 + 4400, 6); // price sits in the band; the anchor decays below the episode anchor
        assertEq(_countAction(RERISK), 1, "tranche 1 never double-fires");
        assertEq(_countAction(RERISK_FINAL), 0, "in-band prints alone cannot fire tranche 2");
        assertEq(reactive.reriskCount(), 1);
        assertEq(sys.callbackCount(), 3, "and no other callbacks on a calm in-band price");
        assertTrue(reactive.episodeActive(), "the episode waits for its new anchor high");
    }

    // --- (e) a new anchor high BEFORE the minimum still cancels ---------------------------------

    function testNewAnchorHighBeforeMinimumCancelsEpisode() public {
        _bleedToExit();
        // Update 8 prints 101 — above the episode anchor (99.9985...) —
        // but only 1 update has passed since the de-risk, so the
        // reclaim cannot fire yet and the cancel still applies (V1
        // behaviour, kept by B for the pre-minimum case).
        vm.expectEmit(false, false, false, true, address(reactive));
        emit EpisodeCancelled(P101, T0 + 2800, 8);
        _feed(P101, T0 + 2800);
        assertFalse(reactive.episodeActive());
        assertFalse(reactive.tranche1Fired(), "cancelled, not fired");
        assertEq(reactive.reriskCount(), 0);

        _feedN(P98, T0 + 3200, 5); // back inside the old band: nothing left to fire
        assertEq(_countAction(RERISK), 0);
        assertEq(_countAction(RERISK_FINAL), 0);
        assertEq(sys.callbackCount(), 2, "only the original TRIM + EXIT");
    }

    // --- (f) B's ordering: an above-anchor print AFTER the minimum fires tranche 1 ---------------
    //
    // The succ_V lesson in miniature: the recovery stalls at 96
    // (below the 97% band), then prints 103 — above the episode anchor.
    // V1's cancel-first order killed its episode on exactly this shape;
    // B evaluates the reclaim first once the minimum has passed, so
    // tranche 1 fires on the 103 print and tranche 2 on the next new
    // anchor high (110).

    function testAboveAnchorPrintAfterMinimumFiresTranche1NotCancel() public {
        _bleedToExit();
        _feed(P85, T0 + 2800); // update 8
        _feed(P90, T0 + 3200); // update 9
        _feed(P96, T0 + 3600); // update 10: minimum met, but 96 < 97% of 99.9985... — no fire
        assertEq(sys.callbackCount(), 2);

        _feed(10_300_000_000, T0 + 4000); // update 11: 103, above the episode anchor
        assertEq(sys.callbackCount(), 3, "tranche 1 fired -- the episode was NOT cancelled");
        assertEq(_callbackAction(sys.callbackAt(2)), RERISK);
        assertTrue(reactive.tranche1Fired());
        assertTrue(reactive.episodeActive(), "no cancel after tranche 1: the episode lives on");

        _feed(11_000_000_000, T0 + 4400); // update 12: 110, the next new anchor high
        assertEq(sys.callbackCount(), 4);
        assertEq(_callbackAction(sys.callbackAt(3)), RERISK_FINAL);
        assertEq(reactive.reriskCount(), 2);
        assertFalse(reactive.episodeActive());
    }

    /// @notice The evaluation's full succ_V stream, pinned end to end:
    ///         the drop fires TRIM then four EXITs (each refreshing the
    ///         episode; the operative one opens at the 68 trough,
    ///         anchor 9_959_910_953); the recovery prints 96 at update
    ///         16 — just below the refreshed episode's 97% band — then
    ///         103 at update 17, where V1 cancelled and B fires tranche
    ///         1; 110 at update 18 fires tranche 2. Seven callbacks,
    ///         no cancels.
    function testSuccVStreamFiresBothTranches() public {
        uint256[25] memory stream = [
            uint256(10_000_000_000), // 100
            uint256(10_050_000_000), // 100.5
            uint256(9_980_000_000), // 99.8
            uint256(10_020_000_000), // 100.2
            uint256(10_010_000_000), // 100.1
            uint256(9_400_000_000), // 94
            uint256(8_800_000_000), // 88
            uint256(8_200_000_000), // 82
            uint256(7_600_000_000), // 76
            uint256(7_100_000_000), // 71
            uint256(6_800_000_000), // 68
            uint256(7_200_000_000), // 72
            uint256(7_700_000_000), // 77
            uint256(8_300_000_000), // 83
            uint256(8_900_000_000), // 89
            uint256(9_600_000_000), // 96
            uint256(10_300_000_000), // 103
            uint256(11_000_000_000), // 110
            uint256(11_800_000_000), // 118
            uint256(12_500_000_000), // 125
            uint256(13_200_000_000), // 132
            uint256(13_200_000_000),
            uint256(13_200_000_000),
            uint256(13_200_000_000),
            uint256(13_200_000_000)
        ];
        for (uint256 i = 0; i < stream.length; i++) {
            _feed(stream[i], T0 + i * 400);
        }
        assertEq(sys.callbackCount(), 7);
        uint8[7] memory expected = [
            SentinelModelV2.TRIM,
            SentinelModelV2.EXIT,
            SentinelModelV2.EXIT,
            SentinelModelV2.EXIT,
            SentinelModelV2.EXIT,
            RERISK,
            RERISK_FINAL
        ];
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(_callbackAction(sys.callbackAt(i)), expected[i], "succ_V callback sequence");
        }
        assertEq(reactive.reriskCount(), 2);
        assertFalse(reactive.episodeActive(), "both tranches spent: the episode is closed");
    }

    // --- (g) an EXIT after a completed re-risk opens a fresh episode ------------------------------
    //
    // Full two-cycle stream (mirror-measured): bleed -> EXIT ->
    // tranche 1 at update 10 (98) -> tranche 2 at update 11 (101) ->
    // a long second bleed the model first HOLDs (blind window) ->
    // EXITs at updates 17 and 18 -> the recovery's tranche 1 at
    // update 24, fired by the SECOND episode (opened at update 18,
    // anchor 10_029_511_744, tranches reset).

    function testExitAfterReriskOpensFreshEpisode() public {
        _bleedToExit();
        _feed(P85, T0 + 2800); // 8
        _feed(P90, T0 + 3200); // 9
        _feed(P98, T0 + 3600); // 10: tranche 1
        _feed(P101, T0 + 4000); // 11: tranche 2 — first episode complete
        assertEq(reactive.reriskCount(), 2);
        assertFalse(reactive.episodeActive());

        _feed(P90, T0 + 4400); // 12
        _feed(8_000_000_000, T0 + 4800); // 13: 80
        _feed(7_400_000_000, T0 + 5200); // 14: 74
        _feed(7_400_000_000, T0 + 5600); // 15: 74
        _feed(6_800_000_000, T0 + 6000); // 16: 68
        assertEq(sys.callbackCount(), 4, "the model HOLDs the fresh-peak decline first (blind window)");
        _feed(6_200_000_000, T0 + 6400); // 17: 62 — EXIT
        _feed(5_800_000_000, T0 + 6800); // 18: 58 — EXIT again, refreshing the episode
        assertEq(sys.callbackCount(), 6);
        assertEq(_callbackAction(sys.callbackAt(4)), SentinelModelV2.EXIT);
        assertEq(_callbackAction(sys.callbackAt(5)), SentinelModelV2.EXIT);
        assertTrue(reactive.episodeActive(), "the second EXIT opened a fresh episode");
        assertEq(reactive.episodeStartUpdate(), 18);
        assertEq(reactive.episodeAnchor(), 10_029_511_744);
        assertFalse(reactive.tranche1Fired(), "the fresh episode's tranches are reset");
        assertFalse(reactive.tranche2Fired());

        _feed(6_600_000_000, T0 + 7200); // 19: 66
        _feed(7_400_000_000, T0 + 7600); // 20: 74
        _feed(8_200_000_000, T0 + 8000); // 21: 82
        _feed(P90, T0 + 8400); // 22: 90
        _feed(P96, T0 + 8800); // 23: 96 — still below 97% of 100.295...
        assertEq(_countAction(RERISK), 1, "no tranche 1 yet in the second episode");
        _feed(9_900_000_000, T0 + 9200); // 24: 99 >= 97% of the second episode's anchor
        assertEq(_countAction(RERISK), 2, "the second episode fires its own tranche 1");
        assertEq(_countAction(RERISK_FINAL), 1, "still only the first episode's tranche 2");
        assertEq(reactive.reriskCount(), 3);
        assertTrue(reactive.tranche1Fired());
        assertTrue(reactive.episodeActive(), "the second episode now waits for its tranche 2");
    }
}
