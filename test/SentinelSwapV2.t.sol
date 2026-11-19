// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwapV2} from "../src/SentinelSwapV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Unit tests for the two-way desk: the forward direction carried
///         from SentinelSwap, plus the reverse `swapSafeForRisk` the
///         re-risk feature spends through — full fill, partial fill on
///         short risk inventory (never reverts, mirrors ReserveShortfall),
///         the price-0 no-op, and the onlyVault gate on both directions.
contract SentinelSwapV2Test is Test {
    uint256 internal constant PRICE = 2000e18; // $2,000 in the 18-decimal USD convention.

    MockPriceOracle internal oracle;
    MockERC20 internal weth; // WETH predeploy stand-in (18 decimals).
    MockUSDC internal usdc;
    SentinelSwapV2 internal swap;

    address internal vaultActor = makeAddr("vault");
    address internal stranger = makeAddr("stranger");

    event Swapped(uint256 riskFilled, uint256 safeOut, uint256 price);
    event SwappedReverse(uint256 safeFilled, uint256 riskOut, uint256 price);
    event ReserveShortfall(uint256 riskRequested, uint256 riskFilled);
    event RiskShortfall(uint256 safeRequested, uint256 safeFilled);

    function setUp() public {
        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwapV2(address(weth), address(usdc), address(oracle), vaultActor);
        oracle.setPrice(address(weth), PRICE);

        usdc.mint(address(swap), 1_000_000 ether); // safe reserve (forward payouts)
        weth.mint(address(swap), 50 ether); // risk inventory (reverse payouts)
        weth.mint(vaultActor, 100 ether);
        usdc.mint(vaultActor, 100_000 ether);
        vm.startPrank(vaultActor);
        weth.approve(address(swap), type(uint256).max);
        usdc.approve(address(swap), type(uint256).max);
        vm.stopPrank();
    }

    // --- forward direction (carried from SentinelSwap) --------------------------

    function testForwardSwapStillWorks() public {
        vm.expectEmit(false, false, false, true, address(swap));
        emit Swapped(10 ether, 20_000 ether, PRICE);
        vm.prank(vaultActor);
        uint256 safeOut = swap.swapRiskForSafe(10 ether);

        assertEq(safeOut, 20_000 ether);
        assertEq(weth.balanceOf(address(swap)), 60 ether, "desk inventory grows by the bought risk");
        assertEq(usdc.balanceOf(vaultActor), 120_000 ether);
        assertEq(swap.reserve(), 1_000_000 ether - 20_000 ether);
    }

    // --- reverse direction --------------------------------------------------------

    function testSwapSafeForRiskFullFill() public {
        vm.expectEmit(false, false, false, true, address(swap));
        emit SwappedReverse(10_000 ether, 5 ether, PRICE);
        vm.prank(vaultActor);
        uint256 riskOut = swap.swapSafeForRisk(10_000 ether);

        assertEq(riskOut, 5 ether, "10,000 USDC at $2,000 buys 5 WETH");
        assertEq(usdc.balanceOf(vaultActor), 90_000 ether, "the full safeIn was pulled");
        assertEq(weth.balanceOf(vaultActor), 105 ether);
        assertEq(usdc.balanceOf(address(swap)), 1_010_000 ether, "desk safe reserve grows by the spend");
        assertEq(swap.riskReserve(), 45 ether, "desk paid 5 WETH out of inventory");
    }

    function testSwapSafeForRiskPartialFillOnLowInventory() public {
        // A desk holding only 2 WETH against a 10,000 USDC (5 WETH) request.
        SentinelSwapV2 small = new SentinelSwapV2(address(weth), address(usdc), address(oracle), vaultActor);
        weth.mint(address(small), 2 ether);
        vm.prank(vaultActor);
        usdc.approve(address(small), type(uint256).max);

        vm.expectEmit(false, false, false, true, address(small));
        emit RiskShortfall(10_000 ether, 4_000 ether);
        vm.prank(vaultActor);
        uint256 riskOut = small.swapSafeForRisk(10_000 ether);

        assertEq(riskOut, 2 ether, "pays out the whole inventory, no more");
        assertEq(usdc.balanceOf(vaultActor), 96_000 ether, "only the covered 4,000 USDC was pulled");
        assertEq(usdc.balanceOf(address(small)), 4_000 ether);
        assertEq(small.riskReserve(), 0);
    }

    function testSwapSafeForRiskEmptyInventoryMovesNothing() public {
        SentinelSwapV2 empty = new SentinelSwapV2(address(weth), address(usdc), address(oracle), vaultActor);
        vm.prank(vaultActor);
        usdc.approve(address(empty), type(uint256).max);

        vm.expectEmit(false, false, false, true, address(empty));
        emit RiskShortfall(10_000 ether, 0);
        vm.prank(vaultActor);
        uint256 riskOut = empty.swapSafeForRisk(10_000 ether);

        assertEq(riskOut, 0);
        assertEq(usdc.balanceOf(vaultActor), 100_000 ether, "nothing pulled, nothing paid, no revert");
    }

    function testSwapSafeForRiskZeroPriceMovesNothing() public {
        oracle.setPrice(address(weth), 0);
        vm.prank(vaultActor);
        uint256 riskOut = swap.swapSafeForRisk(10_000 ether);
        assertEq(riskOut, 0);
        assertEq(usdc.balanceOf(vaultActor), 100_000 ether);
        assertEq(weth.balanceOf(vaultActor), 100 ether);
    }

    function testSwapSafeForRiskZeroAmountIsNoOp() public {
        vm.prank(vaultActor);
        uint256 riskOut = swap.swapSafeForRisk(0);
        assertEq(riskOut, 0);
        assertEq(usdc.balanceOf(vaultActor), 100_000 ether);
    }

    function testOnlyVaultCanSwapEitherDirection() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SentinelSwapV2.NotVault.selector, stranger));
        swap.swapRiskForSafe(1 ether);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SentinelSwapV2.NotVault.selector, stranger));
        swap.swapSafeForRisk(1 ether);
    }

    function testReverseSixDecimalSafeAssetNormalised() public {
        MockERC20 usdc6 = new MockERC20("USD Coin", "USDC", 6);
        SentinelSwapV2 swap6 = new SentinelSwapV2(address(weth), address(usdc6), address(oracle), vaultActor);
        weth.mint(address(swap6), 10 ether);
        usdc6.mint(vaultActor, 100_000 * 1e6);
        vm.prank(vaultActor);
        usdc6.approve(address(swap6), type(uint256).max);

        vm.prank(vaultActor);
        uint256 riskOut = swap6.swapSafeForRisk(2000 * 1e6);
        assertEq(riskOut, 1 ether, "2,000 USDC (6-dec) at $2,000 buys 1 WETH");
        assertEq(usdc6.balanceOf(address(swap6)), 2000 * 1e6);
        assertEq(weth.balanceOf(vaultActor), 101 ether);
    }

    /// @notice The desk round-trip the re-risk feature relies on: risk sold
    ///         in through the forward swap can be bought back out through
    ///         the reverse swap at the same reference price, exactly.
    function testRoundTripAtSamePriceIsExact() public {
        vm.prank(vaultActor);
        uint256 safeOut = swap.swapRiskForSafe(10 ether);
        assertEq(safeOut, 20_000 ether);

        vm.prank(vaultActor);
        uint256 riskOut = swap.swapSafeForRisk(20_000 ether);
        assertEq(riskOut, 10 ether, "same price both ways: the full position comes back");
        assertEq(weth.balanceOf(vaultActor), 100 ether);
        assertEq(usdc.balanceOf(vaultActor), 100_000 ether);
    }
}
