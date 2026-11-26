// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactiveV4} from "../src/SentinelReactiveV4.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Tests for SentinelReactiveV4 (Release 5 candidate): the v3
///         behaviours carried over (crash-path firing parity, replay
///         dedup) plus the RE-RISK episode machine:
///           (a) bleed -> EXIT -> recovery to >= 97% of the episode
///               anchor after >= 3 updates -> exactly ONE action-3
///               callback;
///           (b) recovery to only ~90% of the anchor -> NO re-risk, the
///               episode stays open;
///           (c) an instant reclaim (price already inside the band when
///               the de-risk fires) still waits out the 3-update
///               minimum before firing;
///           (d) after the re-risk, further in-band updates do NOT fire
///               again in the same episode;
///           (e) a new anchor high above the episode anchor cancels the
///               episode silently — no re-risk even in the band later.
/// @dev Every expectation was measured on the Python mirror of the V4
///      firing semantics (tools/train.py forward_int_v2 over the shipped
///      v2 weights + a mirror of the episode machine) before being
///      pinned here. Cooldown is 300 s with 400 s spacing throughout, so
///      the timestamp cooldown never binds and every firing decision is
///      attributable to the rule under test. Every log carries a unique
///      identity (dedup is active).
contract SentinelReactiveV4Test is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));

    uint256 internal constant ORIGIN_CHAIN = 84532; // Base Sepolia
    uint256 internal constant DEST_CHAIN = 84532;
    address internal oracle = makeAddr("oracle");
    address internal token = makeAddr("token");
    address internal vault = makeAddr("vault");

    uint8 internal constant RERISK = 3;

    // Prices in 1e8 units.
    uint256 internal constant P100 = 10_000_000_000;
    uint256 internal constant P100_5 = 10_050_000_000;
    uint256 internal constant P99_8 = 9_980_000_000;
    uint256 internal constant P100_2 = 10_020_000_000;
    uint256 internal constant P100_1 = 10_010_000_000;
    uint256 internal constant P101 = 10_100_000_000;
    uint256 internal constant P98 = 9_800_000_000;
    uint256 internal constant P95 = 9_500_000_000;
    uint256 internal constant P92 = 9_200_000_000;
    uint256 internal constant P90 = 9_000_000_000;
    uint256 internal constant P88 = 8_800_000_000;
    uint256 internal constant P85 = 8_500_000_000;
    uint256 internal constant P81 = 8_100_000_000;
    uint256 internal constant P76 = 7_600_000_000;

    uint256 internal constant T0 = 1_700_000_000;

    MockSystemContract internal sys;
    SentinelReactiveV4 internal reactive;
    uint256 internal _nonce; // log-identity counter

    event EpisodeOpened(uint256 episodeAnchor, uint256 updates);
    event EpisodeCancelled(uint256 price, uint256 originTimestamp, uint256 updates);

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        reactive = new SentinelReactiveV4(ORIGIN_CHAIN, oracle, token, DEST_CHAIN, 300);
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

    function _reriskCallbacks() internal view returns (uint256 count) {
        for (uint256 i = 0; i < sys.callbackCount(); i++) {
            if (_callbackAction(sys.callbackAt(i)) == RERISK) count++;
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
        assertFalse(reactive.reriskUsed());
    }

    // --- carried-over v3 behaviour -------------------------------------------------

    /// @notice The v3 crash path fires identically in v4 (TRIM, EXIT,
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

    // --- (a) bleed -> EXIT -> reclaim -> exactly one re-risk -------------------------

    function testReriskAfterExitOnReclaim() public {
        _bleedToExit();
        _feed(P85, T0 + 2800); // update 8: 1 since the de-risk
        _feed(P90, T0 + 3200); // update 9: 2
        _feed(P95, T0 + 3600); // update 10: 3, but 95 < 97% of the anchor — no fire
        assertEq(sys.callbackCount(), 2, "minimum met but price still below the reclaim band");
        _feed(P98, T0 + 4000); // update 11: 98 >= 97% of 99.9985... — re-risk fires
        assertEq(sys.callbackCount(), 3);
        assertEq(_callbackAction(sys.callbackAt(2)), RERISK);
        assertEq(_reriskCallbacks(), 1, "exactly one action-3 callback");
        assertEq(reactive.reriskCount(), 1);
        assertTrue(reactive.reriskUsed());
        assertFalse(reactive.episodeActive(), "the episode is spent");
    }

    // --- (b) shallow recovery: no re-risk ---------------------------------------------

    function testNoReriskOnShallowRecovery() public {
        _bleedToExit();
        _feed(P85, T0 + 2800);
        _feed(P88, T0 + 3200);
        _feedN(P90, T0 + 3600, 6); // parks at 90% of the pre-crash level, ~90.0% of the episode anchor
        assertEq(_reriskCallbacks(), 0, "90% is below the 97% reclaim band: no re-risk");
        assertEq(reactive.reriskCount(), 0);
        assertEq(sys.callbackCount(), 2);
        assertTrue(reactive.episodeActive(), "the episode is still open: neither fired nor cancelled");
    }

    // --- (c) instant reclaim still waits out the 3-update minimum -----------------------
    //
    // The -0.5%/step grind fires its TRIM at update 8 with the price at
    // 9_655_206_466 — already >= 97% of the episode anchor it opens
    // (9_930_209_650): the most instant reclaim possible. The re-risk
    // still cannot fire on updates 9 or 10 and fires exactly at update
    // 11, the third update after the de-risk.

    function testReriskWaitsForMinimumUpdates() public {
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
        assertEq(sys.callbackCount(), 1, "in-band but inside the minimum: no re-risk yet");
        assertEq(reactive.reriskCount(), 0);

        _feed(flat, T0 + 4000); // update 11: the third update — fires
        assertEq(sys.callbackCount(), 2);
        assertEq(_callbackAction(sys.callbackAt(1)), RERISK);
        assertEq(reactive.reriskCount(), 1);
    }

    // --- (d) one re-risk per episode, ever ------------------------------------------------

    function testReriskFiresOnlyOncePerEpisode() public {
        _bleedToExit();
        _feed(P85, T0 + 2800);
        _feed(P90, T0 + 3200);
        _feed(P95, T0 + 3600);
        _feed(P98, T0 + 4000); // re-risk fires here (update 11)
        assertEq(reactive.reriskCount(), 1);

        _feedN(P98, T0 + 4400, 6); // price sits in the band for 6 more updates
        assertEq(_reriskCallbacks(), 1, "no second fire in the same episode");
        assertEq(reactive.reriskCount(), 1);
        assertEq(sys.callbackCount(), 3, "and no other callbacks on a calm in-band price");
    }

    // --- (e) new anchor high cancels the episode --------------------------------------------

    function testNewAnchorHighCancelsEpisode() public {
        _bleedToExit();
        // Update 8 prints 101 — above the episode anchor (99.9985...):
        // the running anchor forms a new high above it and the episode
        // cancels on this very update, before any reclaim can fire.
        vm.expectEmit(false, false, false, true, address(reactive));
        emit EpisodeCancelled(P101, T0 + 2800, 8);
        _feed(P101, T0 + 2800);
        assertFalse(reactive.episodeActive());
        assertFalse(reactive.reriskUsed(), "cancelled, not spent");
        assertEq(reactive.reriskCount(), 0);

        _feedN(P98, T0 + 3200, 5); // back inside the old band: nothing left to fire
        assertEq(_reriskCallbacks(), 0);
        assertEq(sys.callbackCount(), 2, "only the original TRIM + EXIT");
    }
}
