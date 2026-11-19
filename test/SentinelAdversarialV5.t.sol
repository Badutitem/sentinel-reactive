// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactiveV5} from "../src/SentinelReactiveV5.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Adversarial test for the variant-B machine: the same square
///         wave the V1 suite used — crash to EXIT, reclaim into the
///         band, crash again, three full cycles. Counting tranches
///         honestly (the evaluation mirror's B run over this exact
///         stream): each cycle's reclaim leg tops out at 98, inside
///         the 97% band but never above the cycle's episode anchor, so
///         tranche 2's new-anchor-high condition NEVER occurs on this
///         stream. The measured B sequence is therefore 3 re-risk
///         events — all of them tranche 1 (updates 10, 20, 30), zero
///         tranche 2 — inside the same 11 callbacks V1 produced. The
///         structural bound carries over: at most one tranche 1 per
///         episode, episodes open only on fired de-risks, so N cycles
///         bound tranche-1 fires by N; the wave saturates it exactly.
contract SentinelAdversarialV5Test is Test {
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
    uint256 internal constant P98 = 9_800_000_000;
    uint256 internal constant P92 = 9_200_000_000;
    uint256 internal constant P90 = 9_000_000_000;
    uint256 internal constant P82 = 8_200_000_000;
    uint256 internal constant P81 = 8_100_000_000;
    uint256 internal constant P74 = 7_400_000_000;

    uint256 internal constant T0 = 1_700_000_000;

    MockSystemContract internal sys;
    SentinelReactiveV5 internal reactive;
    uint256 internal _nonce;
    uint256 internal _ts;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        reactive = new SentinelReactiveV5(ORIGIN_CHAIN, oracle, token, DEST_CHAIN, 300);
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

    function _countAction(uint8 action) internal view returns (uint256 count) {
        for (uint256 i = 0; i < sys.callbackCount(); i++) {
            if (_callbackAction(sys.callbackAt(i)) == action) count++;
        }
    }

    /// @notice Three full square-wave cycles. Per cycle the reclaim
    ///         leg (six prints at 98) produces exactly one tranche 1
    ///         and no tranche 2 — the leg never sets a new anchor high
    ///         above the cycle's episode anchor — and the drop leg
    ///         (90, 82, 74, 74) produces the EXITs that open the next
    ///         cycle's episode, resetting its tranches. Total: 3
    ///         re-risk tranche callbacks (all action 3), 11 callbacks.
    function testSquareWaveScaleInBoundedByCycles() public {
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
            // Reclaim leg: six prints at 98. Tranche 1 fires on the
            // third print after the cycle's EXIT (updates 10, 20, 30
            // across the cycles) and never twice; tranche 2 cannot
            // fire — 98 never exceeds the episode anchor.
            for (uint256 i = 0; i < 6; i++) {
                _feed(P98);
            }
            assertEq(_countAction(RERISK), cycle, "exactly one tranche 1 per completed cycle");
            assertEq(_countAction(RERISK_FINAL), 0, "no new anchor high in the wave: tranche 2 never fires");
            assertEq(reactive.reriskCount(), cycle);
            assertTrue(reactive.tranche1Fired());
            assertTrue(reactive.episodeActive(), "the episode stays open awaiting a tranche 2 that this wave never grants");

            // Drop leg: opens the next episode via fresh EXITs.
            _feed(P90);
            _feed(P82);
            _feed(P74);
            _feed(P74);
            assertTrue(reactive.episodeActive(), "the drop leg's EXIT opened a fresh episode");
            assertFalse(reactive.tranche1Fired(), "the fresh episode's tranches are reset");
            assertEq(_countAction(RERISK), cycle, "the drop leg itself fires no re-risk");
        }

        // Full measured sequence (mirror, variant B): TRIM, EXIT, then
        // per cycle (RERISK, EXIT, EXIT) — 11 callbacks, 3 of them
        // action 3, none of them action 4.
        assertEq(sys.callbackCount(), 11);
        assertEq(_countAction(RERISK), 3);
        assertEq(_countAction(RERISK_FINAL), 0);
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
