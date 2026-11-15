// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactive} from "../src/SentinelReactive.sol";
import {SentinelModel} from "../src/model/SentinelModel.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";

/// @notice Tests for SentinelReactive: subscription, the onlySystem guard, the
///         feature pipeline (exact expected features/logits from the off-chain
///         reference), and the callback firing rules (escalation vs cooldown).
///         The system contract is simulated by etching MockSystemContract at
///         the real system address 0x8888...8888 and pranking it to deliver
///         LogRecords — exactly how the network calls react() in production.
contract SentinelReactiveTest is Test {
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
    uint256 internal constant P70 = 7_000_000_000;
    uint256 internal constant P69 = 6_900_000_000;

    uint256 internal constant T0 = 1_700_000_000;

    MockSystemContract internal sys;
    SentinelReactive internal reactive;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        reactive = new SentinelReactive(ORIGIN_CHAIN, oracle, token, DEST_CHAIN, 3600);
    }

    function _feed(uint256 price, uint256 ts) internal {
        _feedTopic(PRICE_TOPIC0, price, ts);
    }

    function _feedTopic(uint256 topic0, uint256 price, uint256 ts) internal {
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: oracle,
            topic0: topic0,
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

    function _feedCrashPath() internal {
        _feed(P100, T0);
        _feed(P100_5, T0 + 60);
        _feed(P99_8, T0 + 120);
        _feed(P100_2, T0 + 180);
        _feed(P100_1, T0 + 240);
        _feed(P92, T0 + 300);
        _feed(P81, T0 + 360);
        _feed(P76, T0 + 420);
    }

    function _expectedPayload(uint8 action) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("executeProtection(address,uint8)", address(0), action);
    }

    // --- subscription & guards -------------------------------------------------

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
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: oracle,
            topic0: PRICE_TOPIC0,
            topic1: uint256(uint160(token)),
            topic2: 0,
            topic3: 0,
            data: abi.encode(P100, T0),
            blockNumber: 0,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM_ADDR));
        reactive.react(log_);
    }

    function testUnknownTopicIgnored() public {
        _feedTopic(0xdeadbeef, P100, T0);
        assertEq(reactive.updates(), 0);
        assertEq(sys.callbackCount(), 0);
    }

    function testSetVaultOnlyOwner() public {
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(bytes("Sentinel: not owner"));
        reactive.setVault(vault);
    }

    // --- feature pipeline ------------------------------------------------------

    function testWarmupNoInference() public {
        reactive.setVault(vault);
        _feed(P100, T0);
        _feed(P99_8, T0 + 60);
        assertEq(reactive.updates(), 2);
        assertEq(reactive.lastAction(), SentinelModel.HOLD);
        assertEq(sys.callbackCount(), 0);
    }

    function testCalmPathNoCallback() public {
        reactive.setVault(vault);
        _feed(P100, T0);
        _feed(P100_5, T0 + 60);
        _feed(P99_8, T0 + 120);
        _feed(P100_2, T0 + 180);
        _feed(P100_1, T0 + 240);
        assertEq(reactive.lastAction(), SentinelModel.HOLD);
        assertEq(sys.callbackCount(), 0);
    }

    function testCrashPathFeaturesAndScores() public {
        reactive.setVault(vault);
        _feedCrashPath();
        assertEq(reactive.lastAction(), SentinelModel.EXIT);
        // Exact features at the final (EXIT) step, from the reference implementation.
        int256[6] memory expectedFeatures =
            [int256(-61728), int256(-37309), int256(59455), int256(243781), int256(-240000), int256(-188900)];
        for (uint256 i = 0; i < 6; i++) {
            assertEq(reactive.lastFeatures(i), expectedFeatures[i], "feature");
        }
        int256[3] memory expectedScores = [int256(-3798214), int256(-820386), int256(5069154)];
        for (uint256 k = 0; k < 3; k++) {
            assertEq(reactive.lastScores(k), expectedScores[k], "score");
        }
    }

    // --- callback firing rules ---------------------------------------------------

    function testCrashPathTrimThenExit() public {
        reactive.setVault(vault);
        _feed(P100, T0);
        _feed(P100_5, T0 + 60);
        _feed(P99_8, T0 + 120);
        _feed(P100_2, T0 + 180);
        _feed(P100_1, T0 + 240);
        _feed(P92, T0 + 300); // model votes TRIM here
        assertEq(sys.callbackCount(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory cfg = sys.callbackAt(0);
        assertEq(cfg.chainId, DEST_CHAIN);
        assertEq(cfg.recipient, vault);
        assertEq(cfg.gasLimit, 1_000_000);
        assertEq(keccak256(cfg.payload), keccak256(_expectedPayload(SentinelModel.TRIM)));

        _feed(P81, T0 + 360); // still TRIM, but inside cooldown -> no new callback
        assertEq(sys.callbackCount(), 1);

        _feed(P76, T0 + 420); // escalation to EXIT -> fires despite cooldown
        assertEq(sys.callbackCount(), 2);
        cfg = sys.callbackAt(1);
        assertEq(keccak256(cfg.payload), keccak256(_expectedPayload(SentinelModel.EXIT)));
    }

    function testCooldownBlocksAndExpires() public {
        reactive.setVault(vault);
        _feedCrashPath(); // EXIT fired at T0 + 420
        assertEq(sys.callbackCount(), 2);

        _feed(P70, T0 + 480); // still EXIT, 60 s later -> blocked by cooldown
        assertEq(sys.callbackCount(), 2);

        _feed(P69, T0 + 420 + 3600); // cooldown over -> fires again
        assertEq(sys.callbackCount(), 3);
    }

    function testNoVaultNoCallback() public {
        _feedCrashPath(); // vault never set
        assertEq(reactive.lastAction(), SentinelModel.EXIT);
        assertEq(sys.callbackCount(), 0);
    }
}
