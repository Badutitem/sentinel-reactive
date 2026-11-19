// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactiveV4} from "../src/SentinelReactiveV4.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Adversarial test for the re-risk machine: a square wave that
///         does everything it can to make re-risk flap — crash to EXIT,
///         reclaim into the band, crash again, reclaim again, three full
///         cycles. The state machine's bound is structural: an episode
///         opens only on a fired de-risk, fires at most one re-risk, and
///         must be re-opened by a NEW de-risk before it can fire again —
///         so N completed cycles produce AT MOST N re-risks. Measured
///         on this stream (mirror first, then pinned): exactly 3
///         re-risks for 3 cycles — one per cycle, at updates 10, 20 and
///         30 — inside 11 total callbacks. No cycle double-fires, no
///         reclaim is skipped, and the wave cannot manufacture a
///         re-risk without a preceding fired EXIT.
contract SentinelAdversarialV4Test is Test {
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
    uint256 internal constant P98 = 9_800_000_000;
    uint256 internal constant P92 = 9_200_000_000;
    uint256 internal constant P90 = 9_000_000_000;
    uint256 internal constant P82 = 8_200_000_000;
    uint256 internal constant P81 = 8_100_000_000;
    uint256 internal constant P74 = 7_400_000_000;

    uint256 internal constant T0 = 1_700_000_000;

    MockSystemContract internal sys;
    SentinelReactiveV4 internal reactive;
    uint256 internal _nonce;
    uint256 internal _ts;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        reactive = new SentinelReactiveV4(ORIGIN_CHAIN, oracle, token, DEST_CHAIN, 300);
        reactive.setVault(vault);
        _ts = T0;
    }

    function _feed(uint256 price) internal {
        _nonce++;
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: oracle,
            topic0: PRICE_TOPIC0,
            topic1: uint256(uint160(token)),
            topic2: 0,
            topic3: 0,
            data: abi.encode(price, _ts),
            blockNumber: _nonce,
            opCode: 2,
            blockHash: 0,
            txHash: _nonce * 7919,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
        _ts += 400;
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

    /// @notice Three full square-wave cycles. Per cycle the reclaim leg
    ///         (six prints at 98, inside the band of that cycle's
    ///         episode anchor) produces exactly one re-risk, and the
    ///         drop leg (90, 82, 74, 74) produces the EXIT(s) that open
    ///         the next cycle's episode. Total: 3 re-risks, 11
    ///         callbacks — the bound is one re-risk per de-risk episode,
    ///         and the wave saturates it exactly without ever breaking it.
    function testSquareWaveReriskBoundedByCycles() public {
        // Opening bleed to the first EXIT (TRIM at 6, EXIT at 7).
        _feed(P100);
        _feed(P100_5);
        _feed(P99_8);
        _feed(P100_2);
        _feed(P100_1);
        _feed(P92);
        _feed(P81);
        assertEq(sys.callbackCount(), 2);

        for (uint256 cycle = 1; cycle <= 3; cycle++) {
            // Reclaim leg: six prints at 98. The re-risk fires on the
            // third print after the cycle's EXIT (updates 10, 20, 30
            // across the cycles) and never twice.
            for (uint256 i = 0; i < 6; i++) {
                _feed(P98);
            }
            assertEq(_reriskCallbacks(), cycle, "exactly one re-risk per completed cycle");
            assertEq(reactive.reriskCount(), cycle);
            assertFalse(reactive.episodeActive(), "the cycle's episode is spent");

            // Drop leg: opens the next episode via fresh EXITs.
            _feed(P90);
            _feed(P82);
            _feed(P74);
            _feed(P74);
            assertTrue(reactive.episodeActive(), "the drop leg's EXIT opened a fresh episode");
            assertEq(_reriskCallbacks(), cycle, "the drop leg itself fires no re-risk");
        }

        // Full measured sequence: TRIM, EXIT, then per cycle
        // (RERISK, EXIT, EXIT) — 11 callbacks, 3 of them action 3.
        assertEq(sys.callbackCount(), 11);
        assertEq(_reriskCallbacks(), 3);
        uint8[11] memory expected = [
            SentinelModelV2.TRIM,
            SentinelModelV2.EXIT,
            RERISK,
            SentinelModelV2.EXIT,
            SentinelModelV2.EXIT,
            RERISK,
            SentinelModelV2.EXIT,
            SentinelModelV2.EXIT,
            RERISK,
            SentinelModelV2.EXIT,
            SentinelModelV2.EXIT
        ];
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(_callbackAction(sys.callbackAt(i)), expected[i], "callback sequence");
        }
    }
}
