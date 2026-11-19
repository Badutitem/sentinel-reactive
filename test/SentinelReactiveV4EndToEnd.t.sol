// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactiveV4} from "../src/SentinelReactiveV4.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwapV2} from "../src/SentinelSwapV2.sol";
import {SentinelVaultV3} from "../src/SentinelVaultV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice End-to-end for the re-risk release: the full two-way cycle
///         against real ERC20 balances —
///           bleed -> TRIM -> EXIT (vault fully in the safe asset)
///           -> recovery -> RERISK (safe balance spent back into risk)
///           -> second bleed -> EXIT again (protection still works on
///           the restored position).
///         Callbacks are delivered stage by stage, so every fill prices
///         at its own stage's oracle print, and balances are asserted
///         after each stage. The stream was measured on the Python
///         mirror first: TRIM at update 6, EXIT at 7, RERISK at 10,
///         and — after the blind-window HOLDs at 90 and 80 that the
///         shipped model answers a fresh-peak decline with — the second
///         EXIT at update 13. Log identities are unique per push (dedup
///         is active in v4).
contract SentinelReactiveV4EndToEndTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant T0 = 1_700_000_000;

    uint8 internal constant RERISK = 3;

    address internal proxy = makeAddr("baseSepoliaCallbackProxy");

    MockSystemContract internal sys;
    MockPriceOracle internal oracle;
    MockERC20 internal weth;
    MockUSDC internal usdc;
    SentinelSwapV2 internal swap;
    SentinelReactiveV4 internal reactive;
    SentinelVaultV3 internal vault;
    uint256 internal _nonce;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));

        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwapV2(address(weth), address(usdc), address(oracle), address(0));
        reactive = new SentinelReactiveV4(BASE_SEPOLIA, address(oracle), address(weth), BASE_SEPOLIA, 300);
        vault = new SentinelVaultV3(payable(proxy), address(reactive), address(weth), address(usdc), address(swap));
        swap.setVault(address(vault));
        reactive.setVault(address(vault));

        usdc.mint(address(swap), 1_000_000 ether);
        weth.mint(address(this), 10 ether);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10 ether);
    }

    function _pushPrice(uint256 price, uint256 ts) internal {
        vm.warp(ts);
        oracle.setPrice(address(weth), price);
        _nonce++;
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
            txHash: _nonce * 7919,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
    }

    function _deliver(uint256 idx) internal {
        ISystemContract.CallbackConfiguration_V_1_0 memory cfg = sys.callbackAt(idx);
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

    function _callbackAction(uint256 idx) internal view returns (uint8) {
        ISystemContract.CallbackConfiguration_V_1_0 memory cfg = sys.callbackAt(idx);
        bytes memory body = new bytes(cfg.payload.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = cfg.payload[i + 4];
        }
        (, uint8 action) = abi.decode(body, (address, uint8));
        return action;
    }

    function testFullCycleBleedExitReriskBleedExit() public {
        // --- Stage 1: calm, then -8% -> TRIM --------------------------------
        _pushPrice(100e18, T0);
        _pushPrice(100.5e18, T0 + 3600);
        _pushPrice(99.8e18, T0 + 7200);
        _pushPrice(100.2e18, T0 + 10800);
        _pushPrice(100.1e18, T0 + 14400);
        assertEq(sys.callbackCount(), 0, "calm market: no protection");

        _pushPrice(92e18, T0 + 18000); // update 6: TRIM
        assertEq(sys.callbackCount(), 1);
        assertEq(_callbackAction(0), SentinelModelV2.TRIM);
        _deliver(0); // TRIM priced at the current oracle print: $92
        assertEq(weth.balanceOf(address(vault)), 5 ether);
        assertEq(usdc.balanceOf(address(vault)), 460 ether, "5 WETH at $92");
        assertFalse(vault.closed());

        // --- Stage 2: the bleed continues -> EXIT ----------------------------
        _pushPrice(81e18, T0 + 21600); // update 7: EXIT
        assertEq(sys.callbackCount(), 2);
        assertEq(_callbackAction(1), SentinelModelV2.EXIT);
        _deliver(1); // EXIT priced at $81
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 865 ether, "460 + 5 WETH at $81");
        assertTrue(vault.closed());
        assertTrue(reactive.episodeActive(), "the EXIT opened a re-risk episode");
        assertEq(reactive.episodeStartUpdate(), 7);

        // --- Stage 3: recovery -> RERISK --------------------------------------
        _pushPrice(85e18, T0 + 25200); // update 8: 1 since the de-risk
        _pushPrice(90e18, T0 + 28800); // update 9: 2
        assertEq(sys.callbackCount(), 2, "reclaim band not yet reached / minimum not met");
        _pushPrice(98e18, T0 + 32400); // update 10: 98 >= 97% of the episode anchor -> RERISK
        assertEq(sys.callbackCount(), 3);
        assertEq(_callbackAction(2), RERISK);
        assertEq(reactive.reriskCount(), 1);
        assertFalse(reactive.episodeActive());

        _deliver(2); // RERISK priced at $98: spends all 865 USDC
        // 865 / 98 = 8.826530612... WETH (floor of the desk's integer math).
        assertEq(weth.balanceOf(address(vault)), 8_826_530_612_244_897_959);
        assertEq(usdc.balanceOf(address(vault)), 0, "the entire safe balance was spent");
        assertFalse(vault.closed(), "the position is open again");
        assertEq(vault.reriskCount(), 1);
        assertEq(vault.protectionCount(), 3);
        assertEq(weth.balanceOf(address(swap)), 1_173_469_387_755_102_041, "desk keeps 10 - 8.8265... WETH");

        // --- Stage 4: second bleed -> EXIT again -------------------------------
        _pushPrice(90e18, T0 + 36000); // update 11: blind-window HOLD
        _pushPrice(80e18, T0 + 39600); // update 12: blind-window HOLD
        assertEq(sys.callbackCount(), 3, "the shipped model HOLDs the fresh-peak decline first");
        _pushPrice(74e18, T0 + 43200); // update 13: EXIT
        assertEq(sys.callbackCount(), 4);
        assertEq(_callbackAction(3), SentinelModelV2.EXIT);

        _deliver(3); // EXIT priced at $74
        assertEq(weth.balanceOf(address(vault)), 0);
        // 8_826_530_612_244_897_959 wei of WETH x $74, desk-exact.
        assertEq(usdc.balanceOf(address(vault)), 653_163_265_306_122_448_966);
        assertTrue(vault.closed());
        assertEq(vault.protectionCount(), 4);
        assertEq(vault.reriskCount(), 1, "exactly one re-risk in the whole cycle");
    }
}
