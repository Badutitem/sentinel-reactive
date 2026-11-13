// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {SentinelReactive} from "../src/SentinelReactive.sol";
import {SentinelVault} from "../src/SentinelVault.sol";
import {SentinelModel} from "../src/model/SentinelModel.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Simulated end-to-end test of the full Sentinel loop, mirroring the
///         three on-chain legs the buildathon submission must prove:
///           1. origin event   — MockPriceOracle emits PriceUpdated (real emit);
///           2. reactive tx    — the system contract (mock etched at 0x8888...)
///              delivers the log to SentinelReactive.react(), which runs the
///              MLP and requests a callback with an exact payload;
///           3. callback tx    — the captured payload is delivered to the vault
///              the way the network does it (proxy as caller, reactive address
///              injected into the first argument) and the position de-risks.
///         On testnet the same three legs appear as three transaction hashes.
contract SentinelEndToEndTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant T0 = 1_700_000_000;

    address internal proxy = makeAddr("baseSepoliaCallbackProxy");
    address internal token = makeAddr("mockToken");

    MockSystemContract internal sys;
    MockPriceOracle internal oracle;
    SentinelReactive internal reactive;
    SentinelVault internal vault;

    event PriceUpdated(address indexed token, uint256 price, uint256 updatedAt);
    event ProtectionExecuted(address indexed reactive, uint8 action, uint256 positionBefore, uint256 positionAfter);

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));

        oracle = new MockPriceOracle();
        reactive = new SentinelReactive(BASE_SEPOLIA, address(oracle), token, BASE_SEPOLIA, 3600);
        vault = new SentinelVault(payable(proxy), address(reactive));
        reactive.setVault(address(vault));
        vault.openPosition(1000);
    }

    /// @dev Pushes a price through the real oracle (leg 1: a genuine event),
    ///      then delivers the corresponding log to the reactive contract as the
    ///      system contract (leg 2), with data byte-identical to the emitted log.
    function _pushPrice(uint256 price, uint256 ts) internal {
        vm.warp(ts);
        oracle.setPrice(token, price);
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(oracle),
            topic0: PRICE_TOPIC0,
            topic1: uint256(uint160(token)),
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
    }

    /// @dev Delivers a captured callback to the vault the way the network does:
    ///      the proxy calls the payload with the first argument overwritten by
    ///      the requesting reactive contract's address.
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

    function testOriginEventIsReal() public {
        vm.warp(T0);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit PriceUpdated(token, 10_000_000_000, T0);
        oracle.setPrice(token, 10_000_000_000);
        assertEq(oracle.latestPrice(token), 10_000_000_000);
    }

    function testFullLoopCrash() public {
        _pushPrice(10_000_000_000, T0); // 100.0
        _pushPrice(10_050_000_000, T0 + 60); // 100.5
        _pushPrice(9_980_000_000, T0 + 120); // 99.8
        _pushPrice(10_020_000_000, T0 + 180); // 100.2
        _pushPrice(10_010_000_000, T0 + 240); // 100.1
        assertEq(sys.callbackCount(), 0, "calm market: no protection");

        _pushPrice(9_200_000_000, T0 + 300); // 92.0  (-8%)  -> TRIM
        _pushPrice(8_100_000_000, T0 + 360); // 81.0  (-12%) -> TRIM, cooldown
        _pushPrice(7_600_000_000, T0 + 420); // 76.0  (-6%)  -> EXIT (escalation)
        assertEq(reactive.lastAction(), SentinelModel.EXIT);
        assertEq(sys.callbackCount(), 2, "TRIM + EXIT callbacks requested");

        // Leg 3: deliver both callbacks in order, as the network would.
        _deliver(sys.callbackAt(0)); // TRIM
        assertEq(vault.positionSize(), 500);
        assertFalse(vault.closed());

        vm.expectEmit(true, false, false, true, address(vault));
        emit ProtectionExecuted(address(reactive), SentinelModel.EXIT, 500, 0);
        _deliver(sys.callbackAt(1)); // EXIT
        assertEq(vault.positionSize(), 0);
        assertTrue(vault.closed());
        assertEq(vault.protectionCount(), 2);
    }

    function testFullLoopCalm() public {
        _pushPrice(10_000_000_000, T0);
        _pushPrice(10_050_000_000, T0 + 60);
        _pushPrice(9_980_000_000, T0 + 120);
        _pushPrice(10_020_000_000, T0 + 180);
        _pushPrice(10_010_000_000, T0 + 240);
        assertEq(reactive.lastAction(), SentinelModel.HOLD);
        assertEq(sys.callbackCount(), 0);
        assertEq(vault.positionSize(), 1000);
        assertEq(vault.protectionCount(), 0);
    }
}
