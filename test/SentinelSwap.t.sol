// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwap} from "../src/SentinelSwap.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Unit tests for the fixed-price swap desk: reference-price math,
///         decimals normalisation, the onlyVault gate, and the non-reverting
///         reserve-shortfall path the vault's callback depends on.
contract SentinelSwapTest is Test {
    uint256 internal constant PRICE = 2000e18; // $2,000 in the 18-decimal USD convention.

    MockPriceOracle internal oracle;
    MockERC20 internal weth; // WETH predeploy stand-in (18 decimals).
    MockUSDC internal usdc;
    SentinelSwap internal swap;

    address internal vaultActor = makeAddr("vault");
    address internal stranger = makeAddr("stranger");

    event Swapped(uint256 riskFilled, uint256 safeOut, uint256 price);
    event ReserveShortfall(uint256 riskRequested, uint256 riskFilled);

    function setUp() public {
        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwap(address(weth), address(usdc), address(oracle), vaultActor);
        oracle.setPrice(address(weth), PRICE);

        usdc.mint(address(swap), 1_000_000 ether); // seed the reserve
        weth.mint(vaultActor, 100 ether);
        vm.prank(vaultActor);
        weth.approve(address(swap), type(uint256).max);
    }

    function testSwapAtReferencePrice() public {
        vm.expectEmit(false, false, false, true, address(swap));
        emit Swapped(10 ether, 20_000 ether, PRICE);
        vm.prank(vaultActor);
        uint256 safeOut = swap.swapRiskForSafe(10 ether);

        assertEq(safeOut, 20_000 ether);
        assertEq(weth.balanceOf(vaultActor), 90 ether);
        assertEq(weth.balanceOf(address(swap)), 10 ether);
        assertEq(usdc.balanceOf(vaultActor), 20_000 ether);
        assertEq(swap.reserve(), 1_000_000 ether - 20_000 ether);
    }

    function testOnlyVaultCanSwap() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SentinelSwap.NotVault.selector, stranger));
        swap.swapRiskForSafe(1 ether);
    }

    function testSetVaultOnlyOwner() public {
        address newVault = makeAddr("newVault");
        swap.setVault(newVault);
        assertEq(swap.vault(), newVault);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SentinelSwap.NotOwner.selector, stranger));
        swap.setVault(stranger);
    }

    function testShortfallFillsPartiallyAndNeverReverts() public {
        // A second desk whose reserve covers only $5,000 of a $20,000 request.
        SentinelSwap small = new SentinelSwap(address(weth), address(usdc), address(oracle), vaultActor);
        usdc.mint(address(small), 5_000 ether);
        vm.prank(vaultActor);
        weth.approve(address(small), type(uint256).max);

        vm.expectEmit(false, false, false, true, address(small));
        emit ReserveShortfall(10 ether, 2.5 ether);
        vm.prank(vaultActor);
        uint256 safeOut = small.swapRiskForSafe(10 ether);

        assertEq(safeOut, 5_000 ether, "pays out the whole reserve, no more");
        assertEq(weth.balanceOf(address(small)), 2.5 ether, "only the covered part of the position moved");
        assertEq(weth.balanceOf(vaultActor), 97.5 ether);
        assertEq(usdc.balanceOf(vaultActor), 5_000 ether);
        assertEq(small.reserve(), 0);
    }

    function testSixDecimalSafeAssetNormalised() public {
        MockERC20 usdc6 = new MockERC20("USD Coin", "USDC", 6);
        SentinelSwap swap6 = new SentinelSwap(address(weth), address(usdc6), address(oracle), vaultActor);
        usdc6.mint(address(swap6), 1_000_000 * 1e6);
        vm.prank(vaultActor);
        weth.approve(address(swap6), type(uint256).max);

        vm.prank(vaultActor);
        uint256 safeOut = swap6.swapRiskForSafe(1 ether);
        assertEq(safeOut, 2000 * 1e6, "1 WETH at $2,000 -> 2,000 USDC in 6-decimal units");
        assertEq(usdc6.balanceOf(vaultActor), 2000 * 1e6);
    }

    function testZeroPriceMovesNothing() public {
        oracle.setPrice(address(weth), 0);
        vm.prank(vaultActor);
        uint256 safeOut = swap.swapRiskForSafe(10 ether);
        assertEq(safeOut, 0);
        assertEq(weth.balanceOf(vaultActor), 100 ether);
        assertEq(usdc.balanceOf(vaultActor), 0);
    }

    function testZeroAmountIsNoOp() public {
        vm.prank(vaultActor);
        uint256 safeOut = swap.swapRiskForSafe(0);
        assertEq(safeOut, 0);
        assertEq(weth.balanceOf(vaultActor), 100 ether);
    }
}
