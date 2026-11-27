// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactiveV5} from "../src/SentinelReactiveV5.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwapV2} from "../src/SentinelSwapV2.sol";
import {SentinelVaultV4} from "../src/SentinelVaultV4.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice End-to-end for the scale-in re-risk (variant B): the full
///         two-way cycle against real ERC20 balances —
///           bleed -> TRIM -> EXIT (vault fully in the safe asset)
///           -> recovery -> TRANCHE 1 (half the safe balance back in)
///           -> new anchor high -> TRANCHE 2 (the rest back in)
///           -> second bleed -> EXIT again on the restored position
///           -> second recovery -> the NEW episode's own tranche 1.
///         Callbacks are delivered stage by stage, so every fill
///         prices at its own stage's oracle print, and balances are
///         asserted after each stage. The stream was measured on the
///         evaluation mirror (tools/rerisk_variants.py, variant B)
///         before any number was pinned: TRIM at update 6, EXIT at 7,
///         tranche 1 at 10, tranche 2 at 11, the second bleed's EXITs
///         at 17 and 18 (after the blind-window HOLDs), and the second
///         episode's tranche 1 at update 24. Log identities are unique
///         per push (dedup is active in v5).
contract SentinelReactiveV5EndToEndTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant T0 = 1_700_000_000;

    uint8 internal constant RERISK = 3;
    uint8 internal constant RERISK_FINAL = 4;

    address internal proxy = makeAddr("baseSepoliaCallbackProxy");

    MockSystemContract internal sys;
    MockPriceOracle internal oracle;
    MockERC20 internal weth;
    MockUSDC internal usdc;
    SentinelSwapV2 internal swap;
    SentinelReactiveV5 internal reactive;
    SentinelVaultV4 internal vault;
    uint256 internal _nonce;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));

        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwapV2(address(weth), address(usdc), address(oracle), address(0));
        reactive = new SentinelReactiveV5(BASE_SEPOLIA, address(oracle), address(weth), BASE_SEPOLIA, 300);
        vault = new SentinelVaultV4(payable(proxy), address(reactive), address(weth), address(usdc), address(swap));
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

    function testFullCycleScaleInReriskAndSecondEpisode() public {
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

        // --- Stage 3: recovery -> TRANCHE 1 (half in) --------------------------
        _pushPrice(85e18, T0 + 25200); // update 8: 1 since the de-risk
        _pushPrice(90e18, T0 + 28800); // update 9: 2
        assertEq(sys.callbackCount(), 2, "reclaim band not yet reached / minimum not met");
        _pushPrice(98e18, T0 + 32400); // update 10: 98 >= 97% of the episode anchor -> TRANCHE 1
        assertEq(sys.callbackCount(), 3);
        assertEq(_callbackAction(2), RERISK);
        assertEq(reactive.reriskCount(), 1);
        assertTrue(reactive.episodeActive(), "the episode stays open for tranche 2");

        _deliver(2); // TRANCHE 1 priced at $98: spends HALF of the 865 USDC
        // 432.5 / 98 = 4.413265306... WETH (floor of the desk's integer math).
        assertEq(weth.balanceOf(address(vault)), 4_413_265_306_122_448_979);
        assertEq(usdc.balanceOf(address(vault)), 432.5 ether, "the other half waits for tranche 2");
        assertFalse(vault.closed(), "the position is open again");
        assertEq(vault.reriskCount(), 1);

        // --- Stage 4: new anchor high -> TRANCHE 2 (the rest in) -----------------
        _pushPrice(101e18, T0 + 36000); // update 11: anchor exceeds the episode anchor -> TRANCHE 2
        assertEq(sys.callbackCount(), 4);
        assertEq(_callbackAction(3), RERISK_FINAL);
        assertEq(reactive.reriskCount(), 2);
        assertFalse(reactive.episodeActive(), "tranche 2 closes the episode");

        _deliver(3); // TRANCHE 2 priced at $101: spends the remaining 432.5 USDC
        // 432.5 / 101 = 4.282178217... WETH; total restored 8.695443523... of 10.
        assertEq(weth.balanceOf(address(vault)), 8_695_443_523_944_231_157);
        assertEq(usdc.balanceOf(address(vault)), 0, "both tranches together spent the whole safe balance");
        assertEq(vault.reriskCount(), 2);
        assertEq(weth.balanceOf(address(swap)), 1_304_556_476_055_768_843, "desk keeps 10 - 8.6954... WETH");

        // --- Stage 5: second bleed -> EXIT again ----------------------------------
        _pushPrice(90e18, T0 + 39600); // update 12
        _pushPrice(80e18, T0 + 43200); // update 13
        _pushPrice(74e18, T0 + 46800); // update 14
        _pushPrice(74e18, T0 + 50400); // update 15
        _pushPrice(68e18, T0 + 54000); // update 16
        assertEq(sys.callbackCount(), 4, "the shipped model HOLDs the fresh-peak decline first (blind window)");
        _pushPrice(62e18, T0 + 57600); // update 17: EXIT
        assertEq(sys.callbackCount(), 5);
        assertEq(_callbackAction(4), SentinelModelV2.EXIT);
        _deliver(4); // EXIT priced at $62
        assertEq(weth.balanceOf(address(vault)), 0);
        // 8_695_443_523_944_231_157 wei of WETH x $62, desk-exact.
        assertEq(usdc.balanceOf(address(vault)), 539_117_498_484_542_331_734);
        assertTrue(vault.closed());
        assertEq(weth.balanceOf(address(swap)), 10 ether, "the desk holds the whole position again");

        _pushPrice(58e18, T0 + 61200); // update 18: EXIT again — refreshes the episode
        assertEq(sys.callbackCount(), 6);
        assertEq(_callbackAction(5), SentinelModelV2.EXIT);
        _deliver(5); // counted no-op on the closed, empty vault
        assertEq(usdc.balanceOf(address(vault)), 539_117_498_484_542_331_734);
        assertEq(reactive.episodeStartUpdate(), 18, "the operative episode is the freshest de-risk's");
        assertFalse(reactive.tranche1Fired());

        // --- Stage 6: second recovery -> the NEW episode's tranche 1 ------------------
        _pushPrice(66e18, T0 + 64800); // update 19
        _pushPrice(74e18, T0 + 68400); // update 20
        _pushPrice(82e18, T0 + 72000); // update 21
        _pushPrice(90e18, T0 + 75600); // update 22
        _pushPrice(96e18, T0 + 79200); // update 23: still below 97% of 100.295...
        assertEq(sys.callbackCount(), 6, "no tranche 1 yet in the second episode");
        _pushPrice(99e18, T0 + 82800); // update 24: 99 >= 97% of the second episode's anchor -> TRANCHE 1
        assertEq(sys.callbackCount(), 7);
        assertEq(_callbackAction(6), RERISK);

        _deliver(6); // TRANCHE 1 priced at $99: spends half of 539.117... USDC
        assertEq(weth.balanceOf(address(vault)), 2_722_815_648_911_829_958);
        assertEq(
            usdc.balanceOf(address(vault)),
            269_558_749_242_271_165_867,
            "the second half stays for this episode's tranche 2"
        );
        assertFalse(vault.closed());
        assertEq(vault.reriskCount(), 3, "two tranches in episode one, one so far in episode two");
        assertEq(vault.protectionCount(), 7);
        assertEq(reactive.reriskCount(), 3);
    }
}
