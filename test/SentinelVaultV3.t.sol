// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwapV2} from "../src/SentinelSwapV2.sol";
import {SentinelVaultV3} from "../src/SentinelVaultV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";

/// @notice Unit tests for the re-risk vault: TRIM/EXIT behave exactly as
///         SentinelVaultV2 (same desk math, same guards), and action 3
///         (RERISK) spends the entire safe balance back into risk through
///         the two-way desk — full fill at a changed price, partial fill
///         on short desk inventory, honest no-ops when there is nothing
///         to buy with or nothing to buy.
contract SentinelVaultV3Test is Test {
    // Mirrors SentinelVaultV3.ACTION_* (asserted in setUp).
    uint8 internal constant TRIM = 1;
    uint8 internal constant EXIT = 2;
    uint8 internal constant RERISK = 3;
    uint256 internal constant PRICE = 2000e18; // $2,000, 18-decimal USD convention.

    address internal proxy = makeAddr("callbackProxy");
    address internal reactive = makeAddr("sentinelReactive");
    address internal stranger = makeAddr("stranger");
    address internal user = makeAddr("user");

    MockPriceOracle internal oracle;
    MockERC20 internal weth; // WETH predeploy stand-in.
    MockUSDC internal usdc;
    SentinelSwapV2 internal swap;
    SentinelVaultV3 internal vault;

    event ProtectionExecuted(address indexed reactive, uint8 action, uint256 positionBefore, uint256 positionAfter);
    event DeRisked(uint8 action, uint256 riskOut, uint256 safeIn);
    event ReRisked(uint256 safeSpent, uint256 riskBought);
    event RiskShortfall(uint256 safeRequested, uint256 safeFilled);

    function setUp() public {
        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwapV2(address(weth), address(usdc), address(oracle), address(0));
        vault = new SentinelVaultV3(payable(proxy), reactive, address(weth), address(usdc), address(swap));
        swap.setVault(address(vault));
        oracle.setPrice(address(weth), PRICE);
        usdc.mint(address(swap), 1_000_000 ether);

        assertEq(vault.ACTION_TRIM(), TRIM);
        assertEq(vault.ACTION_EXIT(), EXIT);
        assertEq(vault.ACTION_RERISK(), RERISK);
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

    // --- protection actions: V2 behaviour carried over ---------------------------

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

    // --- re-risk -------------------------------------------------------------------

    /// @notice The headline flow: EXIT at $2,000, then the desk's reference
    ///         price rises to $2,500 before the re-risk lands. The vault
    ///         spends its ENTIRE safe balance and gets back exactly
    ///         20,000 / 2,500 = 8 WETH — less than it sold, because the
    ///         desk prices both ways at the current reference price.
    function testReriskAfterExitRestoresRiskAtChangedPrice() public {
        _exit();
        assertEq(usdc.balanceOf(address(vault)), 20_000 ether);
        assertTrue(vault.closed());
        assertEq(weth.balanceOf(address(swap)), 10 ether, "the desk holds the sold position as inventory");

        oracle.setPrice(address(weth), 2500e18);
        vm.expectEmit(false, false, false, true, address(vault));
        emit ReRisked(20_000 ether, 8 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ProtectionExecuted(reactive, RERISK, 0, 8 ether);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK);

        assertEq(weth.balanceOf(address(vault)), 8 ether, "20,000 USDC at $2,500 buys exactly 8 WETH");
        assertEq(usdc.balanceOf(address(vault)), 0, "the entire safe balance was spent");
        assertEq(vault.safeBalance(), 0);
        assertFalse(vault.closed(), "the position is open again");
        assertEq(vault.health(), 8 ether);
        assertEq(vault.reriskCount(), 1);
        assertEq(vault.protectionCount(), 2);
        assertEq(weth.balanceOf(address(swap)), 2 ether, "desk inventory paid out 8 of its 10 WETH");
    }

    /// @notice Re-risk also applies after a TRIM (the vault was never
    ///         closed): the safe proceeds buy back alongside the surviving
    ///         half-position.
    function testReriskAfterTrimBuysBackAlongsidePosition() public {
        vm.prank(proxy);
        vault.executeProtection(reactive, TRIM);
        assertEq(weth.balanceOf(address(vault)), 5 ether);
        assertEq(usdc.balanceOf(address(vault)), 10_000 ether);

        oracle.setPrice(address(weth), 2500e18);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK);

        assertEq(weth.balanceOf(address(vault)), 9 ether, "5 surviving + 10,000/2,500 = 4 bought back");
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertFalse(vault.closed());
        assertEq(vault.reriskCount(), 1);
    }

    /// @notice Desk inventory caps the buyback: after EXIT at $2,000 the
    ///         desk holds exactly the 10 WETH it bought; at $1,000 the
    ///         vault's 20,000 USDC wants 20 WETH, so the fill is partial —
    ///         10,000 USDC spent, 10 WETH back, the rest of the safe
    ///         balance stays in the vault, and nothing reverts.
    function testReriskPartialFillWhenDeskInventoryShort() public {
        _exit();
        oracle.setPrice(address(weth), 1000e18);

        vm.expectEmit(false, false, false, true, address(swap));
        emit RiskShortfall(20_000 ether, 10_000 ether);
        vm.expectEmit(false, false, false, true, address(vault));
        emit ReRisked(10_000 ether, 10 ether);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK);

        assertEq(weth.balanceOf(address(vault)), 10 ether, "the whole desk inventory");
        assertEq(usdc.balanceOf(address(vault)), 10_000 ether, "the unspendable half of the proceeds stays");
        assertFalse(vault.closed(), "risk changed hands, so the position counts as reopened");
        assertEq(vault.reriskCount(), 1);
    }

    /// @notice A re-risk with no safe balance is a counted no-op: no
    ///         ReRisked event, no reriskCount, nothing moves.
    function testReriskWithNoSafeBalanceOnlyCounts() public {
        SentinelVaultV3 empty = new SentinelVaultV3(payable(proxy), reactive, address(weth), address(usdc), address(swap));
        vm.prank(proxy);
        empty.executeProtection(reactive, RERISK);
        assertEq(empty.protectionCount(), 1);
        assertEq(empty.reriskCount(), 0);
        assertEq(empty.positionSize(), 0);
        assertFalse(empty.closed());
    }

    /// @notice A re-risk that buys nothing (reference price gone) leaves
    ///         the closed position and its proceeds exactly as they were —
    ///         the counters only move when risk changes hands.
    function testReriskAtZeroPriceLeavesClosedPositionUntouched() public {
        _exit();
        oracle.setPrice(address(weth), 0);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK);

        assertEq(usdc.balanceOf(address(vault)), 20_000 ether);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertTrue(vault.closed(), "nothing bought back: still closed");
        assertEq(vault.reriskCount(), 0);
        assertEq(vault.protectionCount(), 2, "the callback itself still counts");
    }

    /// @notice After a re-risk, protection works on the restored position:
    ///         a second EXIT sells the bought-back risk like any other.
    function testProtectionWorksAgainAfterRerisk() public {
        _exit();
        oracle.setPrice(address(weth), 2500e18);
        vm.prank(proxy);
        vault.executeProtection(reactive, RERISK);
        assertEq(weth.balanceOf(address(vault)), 8 ether);

        oracle.setPrice(address(weth), PRICE);
        _exit();
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 16_000 ether, "8 WETH sold again at $2,000");
        assertTrue(vault.closed());
        assertEq(vault.protectionCount(), 3);
        assertEq(vault.reriskCount(), 1);
    }

    // --- guards (all actions, including RERISK) --------------------------------------

    function testWrongCallerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, proxy));
        vault.executeProtection(reactive, RERISK);
    }

    function testWrongSenderReverts() public {
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, reactive));
        vault.executeProtection(stranger, RERISK);
    }
}
