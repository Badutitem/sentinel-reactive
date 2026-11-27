// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwapV2} from "../src/SentinelSwapV2.sol";
import {SentinelVaultV4} from "../src/SentinelVaultV4.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";

/// @notice Unit tests for the scale-in re-risk vault (variant B):
///         TRIM/EXIT behave exactly as SentinelVaultV2/V3, and the
///         buyback lands in two tranches — action 3 (RERISK) spends
///         HALF the current safe balance, action 4 (RERISK_FINAL)
///         spends the entire remainder — each with the same desk math,
///         partial-fill and honest-no-op semantics V3 pinned for its
///         single-shot action 3.
contract SentinelVaultV4Test is Test {
    // Mirrors SentinelVaultV4.ACTION_* (asserted in setUp).
    uint8 internal constant TRIM = 1;
    uint8 internal constant EXIT = 2;
    uint8 internal constant RERISK = 3;
    uint8 internal constant RERISK_FINAL = 4;
    uint256 internal constant PRICE = 2000e18; // $2,000, 18-decimal USD convention.

    address internal proxy = makeAddr("callbackProxy");
    address internal reactive = makeAddr("sentinelReactive");
    address internal stranger = makeAddr("stranger");
    address internal user = makeAddr("user");

    MockPriceOracle internal oracle;
    MockERC20 internal weth; // WETH predeploy stand-in.
    MockUSDC internal usdc;
    SentinelSwapV2 internal swap;
    SentinelVaultV4 internal vault;

    event ProtectionExecuted(address indexed reactive, uint8 action, uint256 positionBefore, uint256 positionAfter);
    event DeRisked(uint8 action, uint256 riskOut, uint256 safeIn);
    event ReRisked(uint256 safeSpent, uint256 riskBought);
    event RiskShortfall(uint256 safeRequested, uint256 safeFilled);

    function setUp() public {
        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwapV2(address(weth), address(usdc), address(oracle), address(0));
        vault = new SentinelVaultV4(payable(proxy), reactive, address(weth), address(usdc), address(swap));
        swap.setVault(address(vault));
        oracle.setPrice(address(weth), PRICE);
        usdc.mint(address(swap), 1_000_000 ether);

        assertEq(vault.ACTION_TRIM(), TRIM);
        assertEq(vault.ACTION_EXIT(), EXIT);
        assertEq(vault.ACTION_RERISK(), RERISK);
        assertEq(vault.ACTION_RERISK_FINAL(), RERISK_FINAL);
        // The constructor grants the desk max allowances on BOTH assets:
        // risk for the forward swap, safe for the reverse (re-risk) swap.
        assertEq(weth.allowance(address(vault), address(swap)), type(uint256).max);
        assertEq(usdc.allowance(address(vault), address(swap)), type(uint256).max);

        weth.mint(user, 100 ether);
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10 ether);
        vm.stopPrank();
    }

    function _exit() internal {
        vm.prank(proxy);
        vault.executeProtection(reactive, EXIT);
    }

    // --- protection actions: V2/V3 behaviour carried over ---------------------------

    function testTrimAndExitUnchanged() public {
        vm.prank(proxy);
        vault.executeProtection(reactive, TRIM);
        assertEq(weth.balanceOf(address(vault)), 5 ether);
        assertEq(usdc.balanceOf(address(vault)), 10_000 ether);
        assertFalse(vault.closed());

        _exit();
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 20_000 ether);
        assertTrue(vault.closed());
        assertEq(vault.protectionCount(), 2);
        assertEq(vault.reriskCount(), 0);
    }

    // --- tranche 1: half spend ---------------------------------------------------------

    /// @notice After EXIT at $2,000 the vault holds 20,000 USDC. At a
    ///         $2,500 reference price, tranche 1 spends exactly HALF of
    ///         it (10,000) and buys 4 WETH; the other half stays in the
    ///         vault for the confirmation tranche.
    function testTranche1SpendsHalfTheSafeBalance() public {
        _exit();
        assertEq(usdc.balanceOf(address(vault)), 20_000 ether);
        assertTrue(vault.closed());

        oracle.setPrice(address(weth), 2500e18);
        vm.expectEmit(false, false, false, true, address(vault));
        emit ReRisked(10_000 ether, 4 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ProtectionExecuted(reactive, RERISK, 0, 4 ether);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK);

        assertEq(weth.balanceOf(address(vault)), 4 ether, "10,000 USDC at $2,500 buys exactly 4 WETH");
        assertEq(usdc.balanceOf(address(vault)), 10_000 ether, "the second half is NOT spent by tranche 1");
        assertFalse(vault.closed(), "risk changed hands: the position is open again");
        assertEq(vault.reriskCount(), 1);
        assertEq(vault.protectionCount(), 2);
    }

    /// @notice Tranche 1 also applies after a TRIM (the vault was never
    ///         closed): half of the trimmed half's proceeds buy back
    ///         alongside the surviving half-position.
    function testTranche1AfterTrimSpendsHalfTheProceeds() public {
        vm.prank(proxy);
        vault.executeProtection(reactive, TRIM);
        assertEq(weth.balanceOf(address(vault)), 5 ether);
        assertEq(usdc.balanceOf(address(vault)), 10_000 ether);

        oracle.setPrice(address(weth), 2500e18);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK);

        assertEq(weth.balanceOf(address(vault)), 7 ether, "5 surviving + 5,000/2,500 = 2 bought back");
        assertEq(usdc.balanceOf(address(vault)), 5_000 ether, "half the proceeds remain for tranche 2");
        assertFalse(vault.closed());
        assertEq(vault.reriskCount(), 1);
    }

    // --- tranche 2: spend the rest --------------------------------------------------------

    /// @notice The full scale-in: tranche 1 at $2,500 buys 4 WETH with
    ///         half the proceeds; tranche 2 spends the remaining 10,000
    ///         for 4 more — the two tranches together restore exactly
    ///         what V3's single-shot action 3 restored (8 WETH), but
    ///         only the first half was exposed before the new anchor
    ///         high confirmed the recovery.
    function testTranche2SpendsTheRemainingHalf() public {
        _exit();
        oracle.setPrice(address(weth), 2500e18);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK);
        assertEq(weth.balanceOf(address(vault)), 4 ether);
        assertEq(usdc.balanceOf(address(vault)), 10_000 ether);

        vm.expectEmit(false, false, false, true, address(vault));
        emit ReRisked(10_000 ether, 4 ether);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK_FINAL);

        assertEq(weth.balanceOf(address(vault)), 8 ether, "both tranches together: 20,000 USDC at $2,500");
        assertEq(usdc.balanceOf(address(vault)), 0, "nothing left unspent after tranche 2");
        assertEq(vault.safeBalance(), 0);
        assertFalse(vault.closed());
        assertEq(vault.reriskCount(), 2, "each tranche that moved risk counts");
        assertEq(vault.protectionCount(), 3);
        assertEq(weth.balanceOf(address(swap)), 2 ether, "desk inventory paid out 8 of its 10 WETH");
    }

    /// @notice Tranche 2 does not depend on tranche 1 having run: on its
    ///         own it spends the entire safe balance, exactly V3's
    ///         single-shot semantics (the reactive machine never sends
    ///         it first, but the vault action is honest standalone).
    function testTrancheFinalAloneSpendsEverything() public {
        _exit();
        oracle.setPrice(address(weth), 2500e18);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK_FINAL);

        assertEq(weth.balanceOf(address(vault)), 8 ether);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertFalse(vault.closed());
        assertEq(vault.reriskCount(), 1);
    }

    // --- tranche edge cases -----------------------------------------------------------------

    /// @notice Desk inventory caps tranche 1 like any buyback: after
    ///         EXIT at $2,000 the desk holds exactly the 10 WETH it
    ///         bought; at $500 the tranche's 10,000 USDC wants 20 WETH,
    ///         so the fill is partial — 5,000 USDC spent, 10 WETH back,
    ///         the rest of the safe balance stays, nothing reverts.
    function testTranche1PartialFillWhenDeskInventoryShort() public {
        _exit();
        oracle.setPrice(address(weth), 500e18);

        vm.expectEmit(false, false, false, true, address(swap));
        emit RiskShortfall(10_000 ether, 5_000 ether);
        vm.expectEmit(false, false, false, true, address(vault));
        emit ReRisked(5_000 ether, 10 ether);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK);

        assertEq(weth.balanceOf(address(vault)), 10 ether, "the whole desk inventory");
        assertEq(usdc.balanceOf(address(vault)), 15_000 ether, "unspent tranche half + unspendable filled half stay");
        assertFalse(vault.closed(), "risk changed hands, so the position counts as reopened");
        assertEq(vault.reriskCount(), 1);
    }

    /// @notice Tranches with no safe balance are counted no-ops: no
    ///         ReRisked event, no reriskCount, nothing moves.
    function testTranchesWithNoSafeBalanceOnlyCount() public {
        SentinelVaultV4 empty =
            new SentinelVaultV4(payable(proxy), reactive, address(weth), address(usdc), address(swap));
        vm.prank(proxy);
        empty.executeProtection(reactive, RERISK);
        vm.prank(proxy);
        empty.executeProtection(reactive, RERISK_FINAL);
        assertEq(empty.protectionCount(), 2);
        assertEq(empty.reriskCount(), 0);
        assertEq(empty.positionSize(), 0);
        assertFalse(empty.closed());
    }

    /// @notice A tranche that buys nothing (reference price gone)
    ///         leaves the closed position and its proceeds exactly as
    ///         they were — the counters only move when risk changes
    ///         hands. Pinned for both tranche actions.
    function testTranchesAtZeroPriceLeaveClosedPositionUntouched() public {
        _exit();
        oracle.setPrice(address(weth), 0);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK_FINAL);

        assertEq(usdc.balanceOf(address(vault)), 20_000 ether);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertTrue(vault.closed(), "nothing bought back: still closed");
        assertEq(vault.reriskCount(), 0);
        assertEq(vault.protectionCount(), 3, "the callbacks themselves still count");
    }

    /// @notice After both tranches, protection works on the restored
    ///         position: a second EXIT sells the bought-back risk like
    ///         any other.
    function testProtectionWorksAgainAfterBothTranches() public {
        _exit();
        oracle.setPrice(address(weth), 2500e18);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK_FINAL);
        assertEq(weth.balanceOf(address(vault)), 8 ether);

        oracle.setPrice(address(weth), PRICE);
        _exit();
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 16_000 ether, "8 WETH sold again at $2,000");
        assertTrue(vault.closed());
        assertEq(vault.protectionCount(), 4);
        assertEq(vault.reriskCount(), 2);
    }

    // --- guards (all actions, including both tranches) ---------------------------------------

    function testWrongCallerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, proxy));
        vault.executeProtection(reactive, RERISK);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, proxy));
        vault.executeProtection(reactive, RERISK_FINAL);
    }

    function testWrongSenderReverts() public {
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, reactive));
        vault.executeProtection(stranger, RERISK);
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, reactive));
        vault.executeProtection(stranger, RERISK_FINAL);
    }
}
