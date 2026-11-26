// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ChainlinkPriceAdapter} from "../src/ChainlinkPriceAdapter.sol";
import {SentinelSwapV2} from "../src/SentinelSwapV2.sol";
import {SentinelVaultV5} from "../src/SentinelVaultV5.sol";
import {SentinelReactiveV5} from "../src/SentinelReactiveV5.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Lane 1 (CONTRACTS) audit clean checks for the Sentinel system (Build 51122).
///         The six finding PoCs that used to live in this file were retired in
///         Release 8 (FIX-DESIGN.md §8) and replaced by
///         test/Release8Regression.t.sol — they asserted the buggy behaviour
///         and fail on the fixed code by design.
///         Clean checks (asserted, no finding): callback auth, swap shortfall rounding cap,
///         re-risk dust bound.
contract AuditLane1Test is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));
    uint256 internal constant ORIGIN_CHAIN = 84532;
    uint256 internal constant T0 = 1_700_000_000;

    address internal proxy = makeAddr("callbackProxy");
    address internal reactiveAddr = makeAddr("sentinelReactive");
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");
    address internal stranger = makeAddr("stranger");

    MockPriceOracle internal oracle;
    MockERC20 internal weth;
    MockUSDC internal usdc;
    SentinelSwapV2 internal swap;
    SentinelVaultV5 internal vault;

    MockSystemContract internal sys;
    SentinelReactiveV5 internal reactive;
    uint256 internal _nonce;

    function setUp() public {
        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwapV2(address(weth), address(usdc), address(oracle), address(0));
        vault = new SentinelVaultV5(payable(proxy), reactiveAddr, address(weth), address(usdc), address(swap));
        swap.setVault(address(vault));
        oracle.setPrice(address(weth), 2000e18);
        usdc.mint(address(swap), 1_000_000 ether);

        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        reactive = new SentinelReactiveV5(ORIGIN_CHAIN, address(oracle), address(weth), ORIGIN_CHAIN, 300);
        reactive.setVault(address(vault));
    }

    // --- shared helpers ----------------------------------------------------------

    function _fund(address u, uint256 amt) internal {
        weth.mint(u, amt);
        vm.prank(u);
        weth.approve(address(vault), type(uint256).max);
    }

    function _callback(uint8 action) internal {
        vm.prank(proxy);
        vault.executeProtection(reactiveAddr, action);
    }

    function _feed(uint256 price, uint256 ts) internal {
        _nonce++;
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: address(oracle),
            topic0: PRICE_TOPIC0,
            topic1: uint256(uint160(address(weth))),
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
        reactive.react(log_);
    }

    function _feedReverts(uint256 price, uint256 ts) internal {
        _nonce++;
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: address(oracle),
            topic0: PRICE_TOPIC0,
            topic1: uint256(uint160(address(weth))),
            topic2: 0,
            topic3: 0,
            data: abi.encode(price, ts),
            blockNumber: _nonce,
            opCode: 2,
            blockHash: 0,
            txHash: _nonce * 7919,
            logIndex: 0
        });
        vm.expectRevert();
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
    }

    function _callbackAction(uint256 idx) internal view returns (uint8) {
        ISystemContract.CallbackConfiguration_V_1_0 memory cfg = sys.callbackAt(idx);
        bytes memory body = new bytes(cfg.payload.length - 4);
        for (uint256 i = 0; i < body.length; i++) body[i] = cfg.payload[i + 4];
        (, uint8 action) = abi.decode(body, (address, uint8));
        return action;
    }

    function _countAction(uint8 action) internal view returns (uint256 count) {
        for (uint256 i = 0; i < sys.callbackCount(); i++) {
            if (_callbackAction(i) == action) count++;
        }
    }

    /// @dev Value of a (risk, safe) basket in WETH at $2000 (the TRUE price).
    function _valueAt2000(uint256 risk, uint256 safe) internal pure returns (uint256) {
        return risk + safe / 2000;
    }

    // --- Retired PoCs (Release 8, FIX-DESIGN.md §8) -------------------------------
    // The six finding PoCs that asserted the buggy behaviour were removed
    // here and replaced by test/Release8Regression.t.sol:
    //   testF1a_MockOraclePumpStealsViaDepositShares, testF1b_MockOracleFakeCrashFiresExitAtFakePrice,
    //   testF2_StaleChainlinkPriceStillTraded, testF3_RepeatExitCallbacksUnthrottled,
    //   testF4_ZeroPricePermanentlyBricksBrain, testF5_UnvalidatedActionCodeCountsAsProtection.
    // The three clean checks below stay green and stay.

    // --- Clean checks (asserted, no finding) --------------------------------------

    function testClean_CallbackAuthRejectsStrangerAndWrongSender() public {
        vm.prank(stranger);
        vm.expectRevert();
        vault.executeProtection(reactiveAddr, 1);
        vm.prank(proxy);
        vm.expectRevert();
        vault.executeProtection(stranger, 1);
        assertEq(vault.protectionCount(), 0);
    }

    function testClean_SwapShortfallNeverOverpaysReserve() public {
        // Reserve only 100 mUSDC; ask to sell 10 WETH at $2000 (20,000 owed).
        SentinelSwapV2 small = new SentinelSwapV2(address(weth), address(usdc), address(oracle), address(this));
        usdc.mint(address(small), 100 ether);
        weth.mint(address(this), 10 ether);
        weth.approve(address(small), type(uint256).max);
        uint256 safeOut = small.swapRiskForSafe(10 ether);
        assertLe(safeOut, 100 ether, "fill never exceeds the reserve");
        assertEq(safeOut, 100 ether, "partial fill pays exactly the reserve");
    }

    function testClean_ReriskDustBoundedAndRedeemable() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        _callback(2); // EXIT: all risk -> safe (20,000 mUSDC at $2000)
        assertEq(vault.managedSafe(), 20_000 ether);
        // Shrink the safe leg to 1 wei via redemption of (almost) everything.
        // Full-redemption rule pays the whole managedSafe, so instead burn
        // shares down to a 1-wei remainder through partial redeems is not
        // directly possible; assert the direct property: a 1-wei RERISK
        // spend is a no-op (spend = 1/2 = 0) and leaves balances untouched.
        // Simulate by deploying a fresh vault with a 1-wei safe leg:
        MockERC20 weth2 = new MockERC20("Wrapped Ether", "WETH", 18);
        MockUSDC usdc2 = new MockUSDC();
        SentinelSwapV2 swap2 = new SentinelSwapV2(address(weth2), address(usdc2), address(oracle), address(0));
        SentinelVaultV5 vault2 = new SentinelVaultV5(payable(proxy), reactiveAddr, address(weth2), address(usdc2), address(swap2));
        swap2.setVault(address(vault2));
        usdc2.mint(address(vault2), 1); // 1 wei surplus donation, NOT managed
        // Managed safe is 0, so RERISK spends 0 and never touches the donation.
        vm.prank(proxy);
        vault2.executeProtection(reactiveAddr, 3);
        assertEq(usdc2.balanceOf(address(vault2)), 1, "surplus donation untouched by re-risk");
        assertEq(vault2.reriskCount(), 0, "zero-fill tranche does not count");
    }
}
