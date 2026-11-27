// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwapV2} from "../src/SentinelSwapV2.sol";
import {SentinelVaultV5} from "../src/SentinelVaultV5.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";

/// @notice Tests for the pooled per-user vault (VAULTV5-DESIGN.md).
///         Three layers: (1) share accounting — minting, pro-rata
///         claims, exact to-the-wei reconciliation (INV-2/3/5);
///         (2) guard parity — V4's callback behaviour on managed
///         balances (INV-4/7); (3) adversarial — donation neutrality
///         and the classic first-depositor inflation attack (INV-1/6).
contract SentinelVaultV5Test is Test {
    // Mirrors SentinelVaultV5.ACTION_* (asserted in setUp).
    uint8 internal constant TRIM = 1;
    uint8 internal constant EXIT = 2;
    uint8 internal constant RERISK = 3;
    uint8 internal constant RERISK_FINAL = 4;
    uint256 internal constant PRICE = 2000e18; // $2,000, 18-decimal USD convention.

    address internal proxy = makeAddr("callbackProxy");
    address internal reactive = makeAddr("sentinelReactive");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    MockPriceOracle internal oracle;
    MockERC20 internal weth; // WETH predeploy stand-in.
    MockUSDC internal usdc;
    SentinelSwapV2 internal swap;
    SentinelVaultV5 internal vault;

    event SharesMinted(address indexed user, uint256 amount, uint256 shares);
    event SharesRedeemed(address indexed user, uint256 shares, uint256 riskOut, uint256 safeOut);
    event ReRisked(uint256 safeSpent, uint256 riskBought);

    function setUp() public {
        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwapV2(address(weth), address(usdc), address(oracle), address(0));
        vault = new SentinelVaultV5(payable(proxy), reactive, address(weth), address(usdc), address(swap));
        swap.setVault(address(vault));
        oracle.setPrice(address(weth), PRICE);
        usdc.mint(address(swap), 1_000_000 ether);

        assertEq(vault.ACTION_TRIM(), TRIM);
        assertEq(vault.ACTION_EXIT(), EXIT);
        assertEq(vault.ACTION_RERISK(), RERISK);
        assertEq(vault.ACTION_RERISK_FINAL(), RERISK_FINAL);
        // Constructor grants the desk max allowances on BOTH assets (as V4).
        assertEq(weth.allowance(address(vault), address(swap)), type(uint256).max);
        assertEq(usdc.allowance(address(vault), address(swap)), type(uint256).max);
    }

    // --- helpers -----------------------------------------------------------------

    function _fund(address u, uint256 amt) internal {
        weth.mint(u, amt);
        vm.prank(u);
        weth.approve(address(vault), type(uint256).max);
    }

    function _deposit(address u, uint256 amt) internal returns (uint256 shares) {
        vm.prank(u);
        shares = vault.deposit(amt);
    }

    function _callback(uint8 action) internal {
        vm.prank(proxy);
        vault.executeProtection(reactive, action);
    }

    /// @dev INV-1: raw balances always cover the managed totals.
    function _assertBacking() internal view {
        assertGe(weth.balanceOf(address(vault)), vault.managedRisk(), "INV-1 risk backing");
        assertGe(usdc.balanceOf(address(vault)), vault.managedSafe(), "INV-1 safe backing");
    }

    // --- share minting --------------------------------------------------------------

    function testFirstDepositMintsOneToOne() public {
        _fund(alice, 10 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SharesMinted(alice, 10 ether, 10 ether);
        uint256 shares = _deposit(alice, 10 ether);

        assertEq(shares, 10 ether, "first deposit mints 1:1");
        assertEq(vault.sharesOf(alice), 10 ether);
        assertEq(vault.totalShares(), 10 ether);
        assertEq(vault.managedRisk(), 10 ether);
        assertEq(vault.managedSafe(), 0);
        assertEq(vault.positionSize(), 10 ether);
        assertFalse(vault.closed());
        _assertBacking();
    }

    function testSecondDepositSamePriceMintsProRata() public {
        _fund(alice, 10 ether);
        _fund(bob, 10 ether);
        _deposit(alice, 10 ether);
        uint256 bobShares = _deposit(bob, 10 ether);

        assertEq(bobShares, 10 ether);
        (uint256 aRisk, uint256 aSafe) = vault.claimOf(alice);
        (uint256 bRisk, uint256 bSafe) = vault.claimOf(bob);
        assertEq(aRisk, 10 ether);
        assertEq(bRisk, 10 ether);
        assertEq(aSafe, 0);
        assertEq(bSafe, 0);
    }

    function testDepositZeroReverts() public {
        _fund(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SentinelVaultV5.ZeroAmount.selector);
        vault.deposit(0);
    }

    /// @notice A deposit too small to mint even one share (against a
    ///         pool whose per-share value ballooned after a price
    ///         crash) reverts instead of donating itself to the pool.
    ///         Release 8 (F1-B): the price here ($1 vs the $2000 anchor)
    ///         is far outside the 50% deviation band, so the deviation
    ///         guard now fires first — the deposit still reverts rather
    ///         than donating, with `PriceDeviation` instead of `ZeroShares`.
    function testDustDepositMintingZeroSharesReverts() public {
        _fund(alice, 1 ether);
        _deposit(alice, 1 ether);
        _callback(EXIT); // pool: 2,000 USDC, 1 ether of shares
        assertEq(vault.managedSafe(), 2_000 ether);

        oracle.setPrice(address(weth), 1e18); // $1: the pool is now "worth" 2,000 WETH
        _fund(bob, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("PriceDeviation(uint256,uint256)", 1e18, 2000e18));
        vault.deposit(1);
    }

    // --- guard actions under pooling (INV-4/7) ---------------------------------------

    function testTrimKeepsFractionsShiftsComposition() public {
        _fund(alice, 10 ether);
        _fund(bob, 10 ether);
        _deposit(alice, 10 ether);
        _deposit(bob, 10 ether);

        _callback(TRIM);
        assertEq(vault.managedRisk(), 10 ether, "half the pool sold");
        assertEq(vault.managedSafe(), 20_000 ether);
        // Fractions unchanged; composition shifted identically for both.
        assertEq(vault.sharesOf(alice), 10 ether);
        assertEq(vault.sharesOf(bob), 10 ether);
        (uint256 aRisk, uint256 aSafe) = vault.claimOf(alice);
        assertEq(aRisk, 5 ether);
        assertEq(aSafe, 10_000 ether);
        _assertBacking();
    }

    function testRedeemAfterTrimPaysProRataBothAssets() public {
        _fund(alice, 10 ether);
        _fund(bob, 10 ether);
        _deposit(alice, 10 ether);
        _deposit(bob, 10 ether);
        _callback(TRIM); // pool: 10 WETH + 20,000 USDC

        vm.expectEmit(true, false, false, true, address(vault));
        emit SharesRedeemed(alice, 10 ether, 5 ether, 10_000 ether);
        vm.prank(alice);
        (uint256 riskOut, uint256 safeOut) = vault.redeemAll();

        assertEq(riskOut, 5 ether);
        assertEq(safeOut, 10_000 ether);
        assertEq(weth.balanceOf(alice), 5 ether);
        assertEq(usdc.balanceOf(alice), 10_000 ether);
        // Bob's claim is now the whole remaining pool.
        assertEq(vault.managedRisk(), 5 ether);
        assertEq(vault.managedSafe(), 10_000 ether);
        (uint256 bRisk, uint256 bSafe) = vault.claimOf(bob);
        assertEq(bRisk, 5 ether);
        assertEq(bSafe, 10_000 ether);
        _assertBacking();
    }

    /// @notice Tranche spends are computed on the MANAGED safe balance:
    ///         a 10,000-USDC donation sitting in the vault is surplus
    ///         and is never put at risk by the brain.
    function testTrancheSpendsManagedSafeOnlyNotDonations() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);
        _callback(EXIT); // managed safe: 20,000
        usdc.mint(address(vault), 10_000 ether); // donation (raw transfer in)
        assertEq(vault.surplusSafe(), 10_000 ether);

        oracle.setPrice(address(weth), 2500e18);
        vm.expectEmit(false, false, false, true, address(vault));
        emit ReRisked(10_000 ether, 4 ether); // half of MANAGED 20,000 — not of raw 30,000
        _callback(RERISK);

        assertEq(vault.managedRisk(), 4 ether);
        assertEq(vault.managedSafe(), 10_000 ether);
        assertEq(vault.surplusSafe(), 10_000 ether, "the donation was not spent");
        assertEq(vault.reriskCount(), 1);
        _assertBacking();
    }

    /// @notice V4's partial-fill behaviour under pooling: desk inventory
    ///         caps the buyback; the managed totals track the fill.
    function testPartialFillCallbackUnderPooling() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);
        _callback(EXIT); // desk inventory now exactly 10 WETH
        oracle.setPrice(address(weth), 500e18); // tranche wants 20 WETH for 10,000 USDC

        _callback(RERISK);
        assertEq(vault.managedRisk(), 10 ether, "the whole desk inventory");
        assertEq(vault.managedSafe(), 15_000 ether, "unspent half + unspendable half stay managed");
        assertEq(vault.reriskCount(), 1);
        (uint256 risk, uint256 safe) = vault.claimOf(alice);
        assertEq(risk, 10 ether);
        assertEq(safe, 15_000 ether);
        _assertBacking();
    }

    function testCallbackGuardsParityWithV4() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, proxy));
        vault.executeProtection(reactive, TRIM);
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, reactive));
        vault.executeProtection(stranger, TRIM);
    }

    // --- deposits into non-trivial pool states -----------------------------------------

    /// @notice Depositing after EXIT buys a slice of the de-risked pool
    ///         at the current price and re-arms the position (V4's
    ///         deposit semantics), with shares priced off the safe leg.
    function testDepositAfterExitBuysIntoDeriskedPool() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);
        _callback(EXIT);
        assertTrue(vault.closed());
        assertEq(vault.managedSafe(), 20_000 ether);

        _fund(bob, 5 ether);
        uint256 shares = _deposit(bob, 5 ether); // poolRiskEq = 20,000 / 2,000 = 10
        assertEq(shares, 5 ether, "5 WETH against a 10-WETH-equivalent pool, 10 shares outstanding");
        assertFalse(vault.closed(), "fresh risk re-arms the position");
        assertEq(vault.managedRisk(), 5 ether);
        assertEq(vault.managedSafe(), 20_000 ether);
        _assertBacking();
    }

    /// @notice The safe leg is valued at the CURRENT desk price: after
    ///         the price rises 25%, the same USDC pool is worth less WETH,
    ///         so the same deposit mints more shares.
    ///         Release 8 (F1-B): a deposit more than 50% from the last
    ///         settled price reverts `PriceDeviation` — the old 2x case
    ///         in this test now reverts instead of minting double shares.
    function testDepositValuesSafeLegAtCurrentPrice() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);
        _callback(EXIT); // 20,000 USDC pool, 10 shares

        _fund(bob, 13 ether);
        oracle.setPrice(address(weth), 4000e18); // +100%: outside the 50% band
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("PriceDeviation(uint256,uint256)", 4000e18, 2000e18));
        vault.deposit(5 ether);

        oracle.setPrice(address(weth), 2500e18); // +25%: inside the band
        uint256 shares = _deposit(bob, 8 ether); // poolRiskEq = 20,000 / 2,500 = 8
        assertEq(shares, 10 ether, "8 WETH against an 8-WETH-equivalent pool");
        (uint256 bRisk, uint256 bSafe) = vault.claimOf(bob);
        assertEq(bRisk, 4 ether, "half of the 8 WETH pool, exact in wei");
        assertEq(bSafe, 10_000 ether, "bob owns half the safe leg");
    }

    /// @notice Price-0 handling: deposits into a risk-only pool never
    ///         consult the price; deposits into a MIXED pool revert
    ///         (the safe leg cannot be valued); redemptions still work.
    ///         Release 8 (F1-B): with an anchor set by the TRIM fill, a
    ///         $0 price is outside the 50% deviation band, so the
    ///         deviation guard now fires first (`PriceDeviation` instead
    ///         of `NoReferencePrice`) — the deposit still reverts.
    function testZeroPriceDepositRules() public {
        oracle.setPrice(address(weth), 0);
        _fund(alice, 10 ether);
        uint256 shares = _deposit(alice, 10 ether); // risk-only pool: no price needed
        assertEq(shares, 10 ether);

        oracle.setPrice(address(weth), PRICE);
        _callback(TRIM); // pool now mixed: 5 WETH + 10,000 USDC
        oracle.setPrice(address(weth), 0);
        _fund(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("PriceDeviation(uint256,uint256)", 0, 2000e18));
        vault.deposit(1 ether);

        vm.prank(alice);
        (uint256 riskOut, uint256 safeOut) = vault.redeemAll(); // redemption needs no price
        assertEq(riskOut, 5 ether);
        assertEq(safeOut, 10_000 ether);
    }

    // --- redemption flows -----------------------------------------------------------------

    /// @notice Leaving mid-episode pays the current composition and
    ///         does not disturb the episode for the remaining holders:
    ///         the subsequent EXIT acts on exactly what is left.
    function testWithdrawMidEpisodeThenExitActsOnRemainder() public {
        _fund(alice, 10 ether);
        _fund(bob, 10 ether);
        _deposit(alice, 10 ether);
        _deposit(bob, 10 ether);
        _callback(TRIM); // pool: 10 WETH + 20,000 USDC

        vm.prank(alice);
        vault.redeem(5 ether); // half of alice's shares, mid-episode
        assertEq(weth.balanceOf(alice), 2.5 ether);
        assertEq(usdc.balanceOf(alice), 5_000 ether);
        assertEq(vault.managedRisk(), 7.5 ether);
        assertEq(vault.managedSafe(), 15_000 ether);

        _callback(EXIT); // sells the remaining 7.5 WETH at $2,000
        assertEq(vault.managedRisk(), 0);
        assertEq(vault.managedSafe(), 30_000 ether);
        assertTrue(vault.closed());
        assertEq(vault.protectionCount(), 2);
        _assertBacking();
    }

    function testRedeemWhileClosedWorksAndKeepsFlag() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);
        _callback(EXIT);
        assertTrue(vault.closed());

        vm.prank(alice);
        (uint256 riskOut, uint256 safeOut) = vault.redeemAll();
        assertEq(riskOut, 0);
        assertEq(safeOut, 20_000 ether);
        assertTrue(vault.closed(), "redemption never touches the episode flag");
        assertEq(vault.totalShares(), 0);
        assertEq(vault.managedSafe(), 0);
    }

    function testRedeemGuards() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(SentinelVaultV5.ZeroShares.selector);
        vault.redeem(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SentinelVaultV5.InsufficientShares.selector, alice, 11 ether, 10 ether));
        vault.redeem(11 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SentinelVaultV5.InsufficientShares.selector, bob, 1, 0));
        vault.redeem(1);
    }

    /// @notice One user holding everything exits with the entire pool
    ///         and the vault resets to a pristine first-deposit state.
    function testSoleHolderWithdrawAllResetsPool() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);
        _callback(TRIM);

        vm.prank(alice);
        (uint256 riskOut, uint256 safeOut) = vault.redeemAll();
        assertEq(riskOut, 5 ether);
        assertEq(safeOut, 10_000 ether);
        assertEq(vault.totalShares(), 0);
        assertEq(vault.managedRisk(), 0);
        assertEq(vault.managedSafe(), 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);

        // INV-2: the next deposit is a first deposit again (1:1).
        _fund(bob, 3 ether);
        assertEq(_deposit(bob, 3 ether), 3 ether);
    }

    // --- exact reconciliation (INV-3) -------------------------------------------------------

    /// @notice The full Release-5-shaped cycle with three users entering
    ///         at different times and prices, both re-risk tranches and
    ///         a second TRIM, then a mixed full/partial redemption
    ///         sequence: every wei of the managed totals is paid out,
    ///         and the vault ends at exactly zero.
    function testFullCycleReconciliationToTheWei() public {
        _fund(alice, 10 ether);
        _fund(bob, 10 ether);
        _fund(carol, 5 ether);
        _deposit(alice, 10 ether);
        _deposit(bob, 10 ether);
        _callback(TRIM); // pool: 10 WETH + 20,000 USDC, 20 shares

        // Carol enters the de-risked pool at $2,000: poolRiskEq = 10 + 10 = 20.
        assertEq(_deposit(carol, 5 ether), 5 ether);
        assertEq(vault.managedRisk(), 15 ether);
        assertEq(vault.totalShares(), 25 ether);

        _callback(EXIT); // pool: 0 WETH + 50,000 USDC
        assertEq(vault.managedSafe(), 50_000 ether);

        oracle.setPrice(address(weth), 2500e18);
        _callback(RERISK); // spends 25,000 -> 10 WETH
        _callback(RERISK_FINAL); // spends 25,000 -> 10 WETH
        assertEq(vault.managedRisk(), 20 ether);
        assertEq(vault.managedSafe(), 0);

        oracle.setPrice(address(weth), PRICE);
        _callback(TRIM); // pool: 10 WETH + 20,000 USDC
        assertEq(vault.managedRisk(), 10 ether);
        assertEq(vault.managedSafe(), 20_000 ether);
        _assertBacking();

        uint256 paidRisk;
        uint256 paidSafe;
        uint256 r;
        uint256 s;
        vm.prank(alice);
        (r, s) = vault.redeemAll(); // 10/25 shares: floors 4 WETH / 8,000 USDC
        paidRisk += r;
        paidSafe += s;
        assertEq(r, 4 ether);
        assertEq(s, 8_000 ether);
        vm.prank(bob);
        (r, s) = vault.redeem(5 ether); // partial: floors 2 / 4,000
        paidRisk += r;
        paidSafe += s;
        assertEq(r, 2 ether);
        assertEq(s, 4_000 ether);
        vm.prank(carol);
        (r, s) = vault.redeemAll(); // 5/10 remaining: floors 2 / 4,000
        paidRisk += r;
        paidSafe += s;
        vm.prank(bob);
        (r, s) = vault.redeemAll(); // last holder sweeps the dust exactly
        paidRisk += r;
        paidSafe += s;
        assertEq(r, 2 ether);
        assertEq(s, 4_000 ether);

        assertEq(paidRisk, 10 ether, "INV-3: every managed WETH wei paid out");
        assertEq(paidSafe, 20_000 ether, "INV-3: every managed USDC wei paid out");
        assertEq(vault.totalShares(), 0);
        assertEq(vault.managedRisk(), 0);
        assertEq(vault.managedSafe(), 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    /// @notice INV-3 under fuzzed deposit sizes: TRIM + EXIT, then all
    ///         holders leave in order — total paid equals the managed
    ///         snapshot to the wei.
    function testFuzzSequentialRedemptionReconciles(uint256 a1, uint256 a2, uint256 a3) public {
        uint256 x1 = bound(a1, 1e15, 50 ether);
        uint256 x2 = bound(a2, 1e15, 50 ether);
        uint256 x3 = bound(a3, 1e15, 50 ether);
        _fund(alice, x1);
        _fund(bob, x2);
        _fund(carol, x3);
        _deposit(alice, x1);
        _deposit(bob, x2);
        _deposit(carol, x3);
        _callback(TRIM);
        _callback(EXIT);

        uint256 snapRisk = vault.managedRisk();
        uint256 snapSafe = vault.managedSafe();
        uint256 paidRisk;
        uint256 paidSafe;
        uint256 r;
        uint256 s;
        vm.prank(alice);
        (r, s) = vault.redeemAll();
        paidRisk += r;
        paidSafe += s;
        vm.prank(bob);
        (r, s) = vault.redeemAll();
        paidRisk += r;
        paidSafe += s;
        vm.prank(carol);
        (r, s) = vault.redeemAll();
        paidRisk += r;
        paidSafe += s;

        assertEq(paidRisk, snapRisk);
        assertEq(paidSafe, snapSafe);
        assertEq(vault.totalShares(), 0);
        assertEq(vault.managedRisk(), 0);
        assertEq(vault.managedSafe(), 0);
        _assertBacking();
    }

    // --- adversarial (INV-1/6) -----------------------------------------------------------------

    /// @notice A direct transfer to the vault moves no share price, no
    ///         claim and no managed total — and the brain later trades
    ///         only the managed position, not the donation.
    function testDonationIsInvisibleToSharesAndBrain() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);
        weth.mint(address(vault), 100 ether); // donation straight to the vault
        assertEq(vault.managedRisk(), 10 ether);
        assertEq(vault.positionSize(), 10 ether);
        assertEq(vault.surplusRisk(), 100 ether);
        (uint256 risk, uint256 safe) = vault.claimOf(alice);
        assertEq(risk, 10 ether);
        assertEq(safe, 0);

        _fund(bob, 10 ether);
        assertEq(_deposit(bob, 10 ether), 10 ether, "the donation did not move the entry price");

        _callback(TRIM); // sells half of MANAGED 20 WETH, not of raw 120
        assertEq(vault.managedRisk(), 10 ether);
        assertEq(vault.managedSafe(), 20_000 ether);
        assertEq(vault.surplusRisk(), 100 ether, "donation still untouched surplus after the callback");
        _assertBacking();
    }

    /// @notice The classic ERC-4626 inflation attack, replayed: first
    ///         depositor mints 1 share for 1 wei, donates 100 WETH to
    ///         inflate the price, victim deposits. Under managed-total
    ///         accounting the donation never enters the price: the
    ///         victim mints full shares and leaves whole, the attacker
    ///         recovers only their 1 wei, and the donation is stranded
    ///         as surplus.
    function testInflationAttackFails() public {
        _fund(attacker, 200 ether);
        vm.prank(attacker);
        assertEq(vault.deposit(1), 1, "attacker seeds with 1 wei");
        vm.prank(attacker);
        weth.transfer(address(vault), 100 ether); // the donation

        _fund(victim, 10 ether);
        vm.prank(victim);
        uint256 victimShares = vault.deposit(10 ether);
        assertEq(victimShares, 10 ether, "victim mints full shares - price never moved");
        (uint256 vRisk,) = vault.claimOf(victim);
        assertEq(vRisk, 10 ether);

        vm.prank(attacker);
        (uint256 aRisk,) = vault.redeemAll();
        assertEq(aRisk, 1, "attacker recovers exactly their 1 wei");
        vm.prank(victim);
        (uint256 outRisk,) = vault.redeemAll();
        assertEq(outRisk, 10 ether, "victim leaves whole");
        assertEq(vault.surplusRisk(), 100 ether, "the donation is stranded surplus, not loot");
        assertEq(vault.totalShares(), 0);
    }

    // --- owner rescue, narrowed -------------------------------------------------------------------

    /// @notice The owner can skim surplus and rescue stray tokens, but
    ///         can never pull share-backed (managed) funds — the
    ///         deliberate V5 break from V4's unrestricted rescue.
    function testOwnerRescueCappedAtSurplus() public {
        _fund(alice, 10 ether);
        _deposit(alice, 10 ether);

        vm.expectRevert(abi.encodeWithSelector(SentinelVaultV5.ExceedsSurplus.selector, address(weth), 1, 0));
        vault.withdraw(address(weth), address(this), 1);

        weth.mint(address(vault), 50 ether); // donation -> surplus
        vault.withdraw(address(weth), address(this), 50 ether); // skim exactly the surplus: fine
        assertEq(vault.surplusRisk(), 0);
        assertEq(vault.managedRisk(), 10 ether, "user backing untouched");

        vm.expectRevert(abi.encodeWithSelector(SentinelVaultV5.ExceedsSurplus.selector, address(weth), 1, 0));
        vault.withdraw(address(weth), address(this), 1);

        // Stray (non-pool) tokens rescue in full, as V4.
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(vault), 7 ether);
        vault.withdraw(address(stray), address(this), 7 ether);
        assertEq(stray.balanceOf(address(this)), 7 ether);

        // Non-owner cannot rescue at all.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SentinelVaultV5.NotOwner.selector, stranger));
        vault.withdraw(address(stray), stranger, 1);
    }
}
