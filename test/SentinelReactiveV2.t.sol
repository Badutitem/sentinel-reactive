// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactiveV2} from "../src/SentinelReactiveV2.sol";
import {SentinelReactive} from "../src/SentinelReactive.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {SentinelModel} from "../src/model/SentinelModel.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwap} from "../src/SentinelSwap.sol";
import {SentinelVaultV2} from "../src/SentinelVaultV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";

/// @notice Tests for SentinelReactiveV2: subscription and guards (as v1), the
///         anchor state machine (initialisation, per-update decay), bit-exact
///         feature/logit parity against the tools/train.py integer mirror
///         (features7_from_window + forward_int_v2 over the shipped
///         SentinelWeightsV2), and the cooldown state-leak fix — proven A/B
///         against a v1 contract fed the identical price stream.
///         Every pinned number below was produced by running the actual
///         Python mirror on the same series, never by hand.
contract SentinelReactiveV2Test is Test {
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
    uint256 internal constant P90 = 9_000_000_000;
    uint256 internal constant P81 = 8_100_000_000;
    uint256 internal constant P76 = 7_600_000_000;

    uint256 internal constant T0 = 1_700_000_000;

    MockSystemContract internal sys;
    SentinelReactiveV2 internal reactive;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        reactive = new SentinelReactiveV2(ORIGIN_CHAIN, oracle, token, DEST_CHAIN, 3600);
    }

    function _log(uint256 topic0, uint256 price, uint256 ts) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
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
    }

    function _feed(uint256 price, uint256 ts) internal {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_log(PRICE_TOPIC0, price, ts));
    }

    function _expectedPayload(uint8 action) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("executeProtection(address,uint8)", address(0), action);
    }

    function _callbackAction(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) internal pure returns (uint8) {
        bytes memory body = new bytes(cfg.payload.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = cfg.payload[i + 4];
        }
        (, uint8 action) = abi.decode(body, (address, uint8));
        return action;
    }

    /// @dev Actions of all recorded callbacks addressed to `recipient`, in order.
    function _actionsFor(address recipient) internal view returns (uint8[] memory) {
        uint256 n = 0;
        for (uint256 i = 0; i < sys.callbackCount(); i++) {
            if (sys.callbackAt(i).recipient == recipient) n++;
        }
        uint8[] memory out = new uint8[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < sys.callbackCount(); i++) {
            ISystemContract.CallbackConfiguration_V_1_0 memory cfg = sys.callbackAt(i);
            if (cfg.recipient == recipient) out[j++] = _callbackAction(cfg);
        }
        return out;
    }

    function _assertActions(address recipient, uint8[] memory expected) internal {
        uint8[] memory got = _actionsFor(recipient);
        assertEq(got.length, expected.length, "callback count");
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(got[i], expected[i], "callback action");
        }
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
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM_ADDR));
        reactive.react(_log(PRICE_TOPIC0, P100, T0));
    }

    function testUnknownTopicIgnored() public {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_log(0xdeadbeef, P100, T0));
        assertEq(reactive.updates(), 0);
        assertEq(reactive.anchorPeak(), 0, "an ignored log must not touch the anchor");
        assertEq(sys.callbackCount(), 0);
    }

    function testSetVaultOnlyOwner() public {
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(bytes("Sentinel: not owner"));
        reactive.setVault(vault);
    }

    // --- anchor state machine ----------------------------------------------------

    function testFirstPriceInitializesAnchor() public {
        assertEq(reactive.anchorPeak(), 0, "no price yet: anchor unset");
        _feed(P100, T0);
        assertEq(reactive.anchorPeak(), P100, "first price initialises the peak (no zero-peak state)");
        _feed(P90, T0 + 60);
        assertEq(reactive.anchorPeak(), 9_990_000_000, "max(90, 100 x 999/1000)");
        _feed(P90, T0 + 120); // third update: inference starts
        assertEq(reactive.anchorPeak(), 9_980_010_000);
        assertEq(reactive.lastFeatures(6), int256(98197), "anchorDD after two flat steps at -10%");
        assertEq(reactive.lastFeatures(3), int256(100000), "window drawdown is exactly 10%");
    }

    function testAnchorDecayLongFlatSeries() public {
        _feed(P100, T0);
        // Price drops 10% and then sits flat for 100 updates: the peak is held
        // up only by its own leak, decaying x999/1000 per update. Checkpoints
        // are the Python mirror's iterated integer decay, exactly.
        for (uint256 i = 1; i <= 100; i++) {
            _feed(P90, T0 + i * 60);
            if (i == 1) assertEq(reactive.anchorPeak(), 9_990_000_000, "peak after 1 flat step");
            if (i == 10) assertEq(reactive.anchorPeak(), 9_900_448_800, "peak after 10 flat steps");
            if (i == 50) assertEq(reactive.anchorPeak(), 9_512_056_262, "peak after 50 flat steps");
            if (i == 100) assertEq(reactive.anchorPeak(), 9_047_921_427, "peak after 100 flat steps");
        }
        assertEq(reactive.lastFeatures(6), int256(5296), "anchorDD has nearly forgotten the old peak");
    }

    function testWarmupNoInference() public {
        reactive.setVault(vault);
        _feed(P100, T0);
        _feed(P99_8, T0 + 60);
        assertEq(reactive.updates(), 2);
        assertEq(reactive.anchorPeak(), 9_990_000_000, "anchor updates during warmup too");
        assertEq(reactive.lastAction(), SentinelModelV2.HOLD);
        assertEq(sys.callbackCount(), 0);
    }

    // --- feature / logit parity with the Python mirror ---------------------------

    function testCalmPathNoCallback() public {
        reactive.setVault(vault);
        _feed(P100, T0);
        _feed(P100_5, T0 + 60);
        _feed(P99_8, T0 + 120);
        _feed(P100_2, T0 + 180);
        _feed(P100_1, T0 + 240);
        assertEq(reactive.lastAction(), SentinelModelV2.HOLD);
        assertEq(reactive.lastFeatures(6), int256(986), "calm path: anchorDD ~ 0");
        assertEq(sys.callbackCount(), 0);
    }

    function testCrashPathFeaturesAndScores() public {
        reactive.setVault(vault);
        // Anchor peak after every push (Python anchor_stream on the same path).
        _feed(P100, T0);
        assertEq(reactive.anchorPeak(), 10_000_000_000);
        _feed(P100_5, T0 + 60);
        assertEq(reactive.anchorPeak(), 10_050_000_000);
        _feed(P99_8, T0 + 120);
        assertEq(reactive.anchorPeak(), 10_039_950_000);
        _feed(P100_2, T0 + 180);
        assertEq(reactive.anchorPeak(), 10_029_910_050);
        _feed(P100_1, T0 + 240);
        assertEq(reactive.anchorPeak(), 10_019_880_139);
        _feed(P92, T0 + 300); // model votes TRIM
        assertEq(reactive.anchorPeak(), 10_009_860_258);
        assertEq(sys.callbackCount(), 1);
        assertEq(
            keccak256(sys.callbackAt(0).payload), keccak256(_expectedPayload(SentinelModelV2.TRIM)), "TRIM payload"
        );

        _feed(P81, T0 + 360); // anchor EXIT (anchorDD 19.0% >= 18%, still falling):
        // one step earlier than v1, whose window ladder still says TRIM here.
        assertEq(reactive.anchorPeak(), 9_999_850_397);
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertEq(sys.callbackCount(), 2);
        assertEq(
            keccak256(sys.callbackAt(1).payload), keccak256(_expectedPayload(SentinelModelV2.EXIT)), "EXIT payload"
        );

        _feed(P76, T0 + 420);
        assertEq(reactive.anchorPeak(), 9_989_850_546);
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        // Exact features at the final step, from the reference implementation.
        // The first six are v1's pinned crash-path features, unchanged; [6] is
        // the anchor drawdown the v1 model never saw.
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
        // The first EXIT reset the fired-state, so this second EXIT vote —
        // 60 s after the first, deep inside the 3600 s cooldown — fires too.
        // (V1 blocks exactly this step; see testCooldownResetAfterExit.)
        assertEq(sys.callbackCount(), 3);
    }

    function testSlowBleedParity() public {
        // The deterministic -1.1%/step slow bleed from train.py's v2
        // acceptance (SLOWBLEED_PATH), first 24 prices. No single step falls
        // more than 1.1%, so the 9-price window drawdown never exceeds ~8.5%
        // and v1's EXIT band is unreachable; the anchor carries the memory.
        uint256[24] memory prices = [
            uint256(10000000000),
            uint256(9890000000),
            uint256(9781210000),
            uint256(9673616690),
            uint256(9567206906),
            uint256(9461967630),
            uint256(9357885986),
            uint256(9254949240),
            uint256(9153144798),
            uint256(9052460205),
            uint256(8952883143),
            uint256(8854401428),
            uint256(8757003012),
            uint256(8660675979),
            uint256(8565408543),
            uint256(8471189049),
            uint256(8378005969),
            uint256(8285847903),
            uint256(8194703576),
            uint256(8104561837),
            uint256(8015411657),
            uint256(7927242129),
            uint256(7840042466),
            uint256(7753801999)
        ];
        for (uint256 i = 0; i < 20; i++) {
            _feed(prices[i], T0 + i * 60);
            if (i >= 2) {
                assertTrue(reactive.lastAction() != SentinelModelV2.EXIT, "no EXIT before the anchor band");
            }
        }
        _feed(prices[20], T0 + 20 * 60); // anchorDD crosses 18%: first EXIT
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertEq(reactive.anchorPeak(), 9_801_888_641);
        int256[7] memory exitFeatures = [
            int256(-10999),
            int256(-10999),
            int256(10999),
            int256(84685),
            int256(-84685),
            int256(-43669),
            int256(182258)
        ];
        for (uint256 i = 0; i < 7; i++) {
            assertEq(reactive.lastFeatures(i), exitFeatures[i], "first-EXIT feature");
        }
        int256[3] memory exitScores = [int256(-4909220), int256(-124561), int256(305930)];
        for (uint256 k = 0; k < 3; k++) {
            assertEq(reactive.lastScores(k), exitScores[k], "first-EXIT score");
        }

        for (uint256 i = 21; i < 24; i++) {
            _feed(prices[i], T0 + i * 60);
        }
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertEq(reactive.anchorPeak(), 9_772_512_370);
        int256[7] memory finalFeatures = [
            int256(-10999),
            int256(-10999),
            int256(10999),
            int256(84685),
            int256(-84685),
            int256(-43669),
            int256(206570)
        ];
        for (uint256 i = 0; i < 7; i++) {
            assertEq(reactive.lastFeatures(i), finalFeatures[i], "final feature");
        }
        int256[3] memory finalScores = [int256(-6231058), int256(-1555183), int256(2073805)];
        for (uint256 k = 0; k < 3; k++) {
            assertEq(reactive.lastScores(k), finalScores[k], "final score");
        }
    }

    // --- the cooldown state-leak fix, A/B against v1 ------------------------------

    /// @notice One price stream, two contracts, identical parameters
    ///         (cooldown 3600 s, one price per 60 s): a crash, a full recovery,
    ///         then a fresh -2.5%/step decline — the shape of a NEW position
    ///         armed after the first one EXITed, bleeding again well inside
    ///         the old cooldown window (which runs to T0+3960).
    ///         V1 fires TRIM + EXIT and then goes deaf: its TRIM votes in the
    ///         second decline are not escalations over the stale EXIT and the
    ///         cooldown has not lapsed — the leak. V2 resets on EXIT, so the
    ///         second decline's first TRIM fires (at T0+1140), and that TRIM
    ///         re-arms the cooldown, blocking its own repeats.
    function testCooldownResetAfterExit() public {
        address vaultV1 = makeAddr("vaultV1");
        address vaultV2 = makeAddr("vaultV2");
        SentinelReactive reactiveV1 = new SentinelReactive(ORIGIN_CHAIN, oracle, token, DEST_CHAIN, 3600);
        reactiveV1.setVault(vaultV1);
        reactive.setVault(vaultV2);

        uint256[24] memory path = [
            uint256(10000000000),
            uint256(10050000000),
            uint256(9980000000),
            uint256(10020000000),
            uint256(10010000000),
            uint256(9200000000),
            uint256(8100000000),
            uint256(7600000000),
            uint256(7000000000),
            uint256(7800000000),
            uint256(8400000000),
            uint256(9000000000),
            uint256(9500000000),
            uint256(9900000000),
            uint256(10000000000),
            uint256(10050000000),
            uint256(10050000000),
            uint256(9798750000),
            uint256(9553781250),
            uint256(9314936718),
            uint256(9082063300),
            uint256(8855011717),
            uint256(8633636424),
            uint256(8417795513)
        ];
        for (uint256 i = 0; i < path.length; i++) {
            uint256 ts = T0 + i * 60;
            IReactive.LogRecord memory log_ = _log(PRICE_TOPIC0, path[i], ts);
            vm.prank(SYSTEM_ADDR);
            reactive.react(log_);
            vm.prank(SYSTEM_ADDR);
            reactiveV1.react(log_);

            if (i == 8) {
                // Crash complete. V2: TRIM, then EXIT one step early (anchor),
                // then two more EXITs that only fire because each EXIT reset
                // the state. V1: TRIM + EXIT, and its P70 EXIT vote at this
                // very step is already swallowed by its own cooldown.
                uint8[] memory expV2 = new uint8[](4);
                expV2[0] = SentinelModelV2.TRIM;
                expV2[1] = SentinelModelV2.EXIT;
                expV2[2] = SentinelModelV2.EXIT;
                expV2[3] = SentinelModelV2.EXIT;
                _assertActions(vaultV2, expV2);
                uint8[] memory expV1 = new uint8[](2);
                expV1[0] = SentinelModel.TRIM;
                expV1[1] = SentinelModel.EXIT;
                _assertActions(vaultV1, expV1);
            }
            if (i == 19) {
                // Third step of the second decline: V2's TRIM fires — the
                // leak, fixed. V1 votes TRIM on this step too and stays deaf.
                uint8[] memory expV2 = new uint8[](5);
                expV2[0] = SentinelModelV2.TRIM;
                expV2[1] = SentinelModelV2.EXIT;
                expV2[2] = SentinelModelV2.EXIT;
                expV2[3] = SentinelModelV2.EXIT;
                expV2[4] = SentinelModelV2.TRIM;
                _assertActions(vaultV2, expV2);
                uint8[] memory expV1 = new uint8[](2);
                expV1[0] = SentinelModel.TRIM;
                expV1[1] = SentinelModel.EXIT;
                _assertActions(vaultV1, expV1);
            }
        }
        // The remaining TRIM votes (both models keep voting TRIM to the end of
        // the leg) fire nothing further: V2's post-reset TRIM re-armed its
        // cooldown, V1 is still inside the stale one.
        assertEq(_actionsFor(vaultV2).length, 5);
        assertEq(_actionsFor(vaultV1).length, 2);
    }

    function testNoVaultNoCallback() public {
        _feed(P100, T0);
        _feed(P100_5, T0 + 60);
        _feed(P99_8, T0 + 120);
        _feed(P100_2, T0 + 180);
        _feed(P100_1, T0 + 240);
        _feed(P92, T0 + 300);
        _feed(P81, T0 + 360);
        _feed(P76, T0 + 420);
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertEq(sys.callbackCount(), 0);
    }
}

/// @notice End-to-end: the full loop (oracle event -> reactive inference ->
///         network-style callback delivery) against SentinelVaultV2, on the
///         scenario v1 structurally cannot handle — a steady -2%/step bleed.
///         No single step is violent, the 9-price window drawdown never
///         exceeds ~15%, and a v1 reactive fed the identical stream (asserted
///         at every step) ratchets TRIM forever and never EXITs. The v2
///         reactive's anchor drawdown crosses 18% at step 11 and EXITs; the
///         delivered callbacks close the vault for real tokens.
///         Prices are 18-decimal USD, the swap desk's convention; timestamps
///         are hourly — the cadence the anchor constants were validated at —
///         and the cooldown is the production 300 s, so it never binds.
contract SentinelReactiveV2EndToEndTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant T0 = 1_700_000_000;

    address internal proxy = makeAddr("baseSepoliaCallbackProxy");

    MockSystemContract internal sys;
    MockPriceOracle internal oracle;
    MockERC20 internal weth;
    MockUSDC internal usdc;
    SentinelSwap internal swap;
    SentinelReactiveV2 internal reactive;
    SentinelReactive internal reactiveV1;
    SentinelVaultV2 internal vault;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));

        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwap(address(weth), address(usdc), address(oracle), address(0));
        reactive = new SentinelReactiveV2(BASE_SEPOLIA, address(oracle), address(weth), BASE_SEPOLIA, 300);
        reactiveV1 = new SentinelReactive(BASE_SEPOLIA, address(oracle), address(weth), BASE_SEPOLIA, 300);
        vault = new SentinelVaultV2(payable(proxy), address(reactive), address(weth), address(usdc), address(swap));
        swap.setVault(address(vault));
        reactive.setVault(address(vault));
        // reactiveV1 deliberately gets no vault: it is the control group.

        usdc.mint(address(swap), 1_000_000 ether);
        weth.mint(address(this), 10 ether);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10 ether);
    }

    /// @dev Pushes a price through the real oracle, then delivers the log to
    ///      BOTH reactives as the system contract. Asserts the v1 control
    ///      never votes EXIT on this stream.
    function _pushPrice(uint256 price, uint256 ts) internal {
        vm.warp(ts);
        oracle.setPrice(address(weth), price);
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(oracle),
            topic0: PRICE_TOPIC0,
            topic1: uint256(uint160(address(weth))),
            topic2: 0,
            topic3: 0,
            data: abi.encode(price, ts),
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
        vm.prank(SYSTEM_ADDR);
        reactiveV1.react(log_);
        if (reactiveV1.updates() >= 3) {
            assertTrue(reactiveV1.lastAction() != SentinelModel.EXIT, "v1 must never EXIT a slow bleed");
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

    /// @dev Delivers a captured callback to the vault the way the network
    ///      does: proxy as caller, v2 reactive address injected into the
    ///      first argument.
    function _deliver(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) internal {
        assertEq(cfg.chainId, BASE_SEPOLIA);
        assertEq(cfg.recipient, address(vault));
        bytes memory body = new bytes(cfg.payload.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = cfg.payload[i + 4];
        }
        (address placeholder, uint8 action) = abi.decode(body, (address, uint8));
        assertEq(placeholder, address(0), "payload must reserve the sender slot");
        bytes memory delivered = abi.encodeWithSignature("executeProtection(address,uint8)", address(reactive), action);
        vm.prank(proxy);
        (bool ok,) = address(vault).call(delivered);
        assertTrue(ok, "callback delivery failed");
    }

    function testSlowBleedExitClosesVault() public {
        // $100 falling exactly 2% per step (integer recurrence p * 98 / 100),
        // 31 prices. Total fall ~ -45.5%; steepest 9-price window drawdown
        // ~14.9% — under v1's 21% EXIT band at every step.
        uint256[31] memory prices = [
            uint256(100000000000000000000),
            uint256(98000000000000000000),
            uint256(96040000000000000000),
            uint256(94119200000000000000),
            uint256(92236816000000000000),
            uint256(90392079680000000000),
            uint256(88584238086400000000),
            uint256(86812553324672000000),
            uint256(85076302258178560000),
            uint256(83374776213014988800),
            uint256(81707280688754689024),
            uint256(80073135074979595243),
            uint256(78471672373480003338),
            uint256(76902238926010403271),
            uint256(75364194147490195205),
            uint256(73856910264540391300),
            uint256(72379772059249583474),
            uint256(70932176618064591804),
            uint256(69513533085703299967),
            uint256(68123262423989233967),
            uint256(66760797175509449287),
            uint256(65425581231999260301),
            uint256(64117069607359275094),
            uint256(62834728215212089592),
            uint256(61578033650907847800),
            uint256(60346472977889690844),
            uint256(59139543518331897027),
            uint256(57956752647965259086),
            uint256(56797617595005953904),
            uint256(55661665243105834825),
            uint256(54548431938243718128)
        ];
        for (uint256 i = 0; i < prices.length; i++) {
            _pushPrice(prices[i], T0 + i * 3600);
        }

        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertEq(reactiveV1.lastAction(), SentinelModel.TRIM, "v1 ends the bleed still only trimming");
        // Every decision fired (hourly spacing > 300 s cooldown): 9 TRIMs as
        // the anchor drawdown built through its 10% band, then EXITs from
        // step 11, where anchorDD crossed 18%.
        assertEq(sys.callbackCount(), 29);
        assertEq(_callbackAction(sys.callbackAt(0)), SentinelModelV2.TRIM);
        assertEq(_callbackAction(sys.callbackAt(9)), SentinelModelV2.EXIT, "first EXIT callback");

        for (uint256 i = 0; i < 29; i++) {
            _deliver(sys.callbackAt(i));
        }
        // All 10 WETH sold across the TRIM ratchet + the first EXIT, every
        // fill priced at the final oracle print ($54.5484...), less per-call
        // integer dust — the exact figure the swap math produces.
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 545_484_319_382_437_181_277);
        assertTrue(vault.closed());
        assertEq(vault.protectionCount(), 29);
    }
}
