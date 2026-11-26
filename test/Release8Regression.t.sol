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

/// @notice Release 8 regression tests (FIX-DESIGN.md §1 + §3).
///         Each test FAILS on the unfixed code and PASSES on the fixed code,
///         except the two no-behaviour-change guards (F1 driver, F2 fresh
///         price), which pass on both by design.
///         New getters/errors are reached through the local interfaces
///         below (and encodeWithSignature for new custom errors) so this
///         file compiles against the UNFIXED code too, making the
///         fail-before run per-test instead of a compile error.
///           F1 (High)   allowlisted oracle + deposit deviation guard
///           F4 (High)   zero / absurd price ignored, brain keeps working
///           F2 (Medium) 3600 s staleness bound at consumption
///           F3 (Medium) repeat-EXIT cooldown-gated
///           F5 (Info)   unknown action reverts
///           L3          TRIM suppression resets on tranche-2 episode close
///           L8          closed by the F4 upper bound (see F4 huge-price test)
///         NOTE (design-text correction): FIX-DESIGN.md §1 F4 says the
///         zero-price test reaches "updates 8" after the fix; its own fix
///         spec says updates does NOT advance for the ignored print, so
///         the correct post-fix count is 3 calm + 4 follow-ups = 7.
///         This file asserts 7.
interface IOracleR8 {
    function owner() external view returns (address);
    function pricePushers(address pusher) external view returns (bool);
    function allowPusher(address pusher_) external;
    function revokePusher(address pusher_) external;
    function priceUpdatedAt(address token) external view returns (uint256);
}

interface ISwapR8 {
    function priceStale() external view returns (bool);
    function priceAge() external view returns (uint256);
    function MAX_PRICE_AGE() external view returns (uint256);
}

interface IVaultR8 {
    function lastSettledPrice() external view returns (uint256);
}

contract Release8RegressionTest is Test {
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

    event StalePriceRefused(uint256 ageSeconds, uint256 boundSeconds);

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
        _feedWithNonce(price, ts, ++_nonce);
    }

    function _feedWithNonce(uint256 price, uint256 ts, uint256 nonce_) internal {
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: address(oracle),
            topic0: PRICE_TOPIC0,
            topic1: uint256(uint160(address(weth))),
            topic2: 0,
            topic3: 0,
            data: abi.encode(price, ts),
            blockNumber: nonce_,
            opCode: 2,
            blockHash: 0,
            txHash: nonce_ * 7919,
            logIndex: 0
        });
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

    // --- F1: allowlisted oracle + deposit deviation guard ------------------------

    function testF1_StrangerCannotPushPrice() public {
        IOracleR8 o = IOracleR8(address(oracle));
        assertEq(o.owner(), address(this), "deployer is the oracle owner");
        assertTrue(o.pricePushers(address(this)), "deployer is allowlisted at construction");
        assertFalse(o.pricePushers(stranger), "stranger is not allowlisted");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotPusher(address)", stranger));
        oracle.setPrice(address(weth), 200_000e18);
        assertEq(oracle.latestPrice(address(weth)), 2000e18, "stranger push did not move the price");
    }

    function testF1_PumpedPriceCannotStealViaDeposit() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        assertEq(vault.totalShares(), 10 ether);

        // Mixed pool: TRIM sells half the risk at the true $2000.
        _callback(1);
        assertEq(vault.managedRisk(), 5 ether);
        assertEq(vault.managedSafe(), 10_000 ether);

        // Attacker tries the 100x pump through the oracle: reverts now.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotPusher(address)", attacker));
        oracle.setPrice(address(weth), 200_000e18);
        assertEq(oracle.latestPrice(address(weth)), 2000e18, "price still the true $2000");

        // Attacker deposits 5 WETH at the true price: exactly the fair shares.
        _fund(attacker, 5 ether);
        vm.prank(attacker);
        uint256 atkShares = vault.deposit(5 ether);
        assertEq(atkShares, 5 ether, "fair shares at the true price: 5 WETH into a 10-WETH-eq pool");

        // No theft: redeeming pays back the 5 WETH deposited, to within the
        // vault's documented 1-wei floor-rounding dust on a partial redeem.
        vm.prank(attacker);
        (uint256 riskOut, uint256 safeOut) = vault.redeem(atkShares);
        uint256 atkValue = _valueAt2000(riskOut, safeOut);
        assertGe(atkValue, 5 ether - 1, "attacker extracts (at most) what they put in");
        assertLe(atkValue, 5 ether, "attacker extracts no more than they put in");
        (uint256 aRisk, uint256 aSafe) = vault.claimOf(alice);
        uint256 aliceValue = _valueAt2000(aRisk, aSafe);
        assertGe(aliceValue, 10 ether - 1, "victim undiluted, to within 1 wei of floor dust");
        assertLe(aliceValue, 10 ether, "victim undiluted");
    }

    function testF1_DeviationGuardTripsAt60PassesAt40() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        _callback(1); // TRIM fill at $2000 sets the anchor
        assertEq(IVaultR8(address(vault)).lastSettledPrice(), 2000e18, "TRIM fill anchors at $2000");

        // Owner (allowed pusher) pushes +60%: the deposit reverts.
        oracle.setPrice(address(weth), 3200e18);
        _fund(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("PriceDeviation(uint256,uint256)", 3200e18, 2000e18));
        vault.deposit(1 ether);
        assertEq(IVaultR8(address(vault)).lastSettledPrice(), 2000e18, "reverted deposit does not move the anchor");

        // Owner pushes +40% instead: the same deposit succeeds at the right shares.
        // Pool 5 WETH + 10,000 mUSDC, 10 shares; at $2800 the safe leg is
        // worth ceil(10000/2800) = 3.571428571428571429 WETH, pool 8.571428571428571429,
        // so 1 WETH mints 1 * 10 / 8.571428571428571429 = 1.166666666666666666 shares.
        oracle.setPrice(address(weth), 2800e18);
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether);
        assertEq(shares, 1166666666666666666, "correct shares at +40%");
        assertEq(IVaultR8(address(vault)).lastSettledPrice(), 2800e18, "successful deposit settles the anchor");
    }

    function testF1_AllowlistedDriverStillWorks() public {
        IOracleR8 o = IOracleR8(address(oracle));
        // Deployer pushes still work, and the June-shape push sequence ingests.
        oracle.setPrice(address(weth), 2000e18);
        assertEq(oracle.latestPrice(address(weth)), 2000e18);
        _feed(2000e18, T0);
        _feed(2010e18, T0 + 3600);
        _feed(1996e18, T0 + 7200);
        assertEq(reactive.updates(), 3, "push sequence ingests");

        // Allowlist administration: allow, push, revoke, push reverts again.
        o.allowPusher(stranger);
        assertTrue(o.pricePushers(stranger));
        vm.prank(stranger);
        oracle.setPrice(address(weth), 2001e18);
        assertEq(oracle.latestPrice(address(weth)), 2001e18);
        o.revokePusher(stranger);
        assertFalse(o.pricePushers(stranger));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotPusher(address)", stranger));
        oracle.setPrice(address(weth), 2002e18);
    }

    // --- F4: zero / absurd price ignored, brain keeps working --------------------

    function testF4_ZeroPriceIgnoredBrainKeepsWorking() public {
        _feed(100e18, T0);
        _feed(100.5e18, T0 + 3600);
        _feed(99.8e18, T0 + 7200);
        assertEq(reactive.updates(), 3);

        // The zero print is consumed (marked seen) but never enters the window.
        uint256 zeroNonce = ++_nonce;
        _feedWithNonce(0, T0 + 10800, zeroNonce);
        assertEq(reactive.updates(), 3, "ignored zero does not advance updates");
        assertEq(reactive.duplicatesIgnored(), 0, "consumed, not reverted");
        // Redelivery of the same zero log is a duplicate, not a brick.
        _feedWithNonce(0, T0 + 10800, zeroNonce);
        assertEq(reactive.duplicatesIgnored(), 1, "zero log was marked seen");
        assertEq(reactive.updates(), 3);

        // All four follow-ups ingest normally.
        _feed(90e18, T0 + 14400);
        _feed(95e18, T0 + 18000);
        _feed(100e18, T0 + 21600);
        _feed(50e18, T0 + 25200);
        assertEq(reactive.updates(), 7, "3 calm + 4 follow-ups ingested; the zero never counted");
    }

    function testF4_HugePriceIgnoredBrainKeepsWorking() public {
        _feed(100e18, T0);
        _feed(100.5e18, T0 + 3600);
        _feed(99.8e18, T0 + 7200);
        assertEq(reactive.updates(), 3);

        // The L8 case: a single 2^255 print is ignored, not a revert.
        _feed(2 ** 255, T0 + 10800);
        assertEq(reactive.updates(), 3, "absurd price does not advance updates");

        _feed(90e18, T0 + 14400);
        _feed(95e18, T0 + 18000);
        _feed(100e18, T0 + 21600);
        _feed(50e18, T0 + 25200);
        assertEq(reactive.updates(), 7, "brain keeps working after the absurd print");
    }

    function testF4_ZeroFirstPriceIsIgnored() public {
        _feed(0, T0);
        assertEq(reactive.updates(), 0, "zero first print ignored");
        assertEq(reactive.anchorPeak(), 0, "no anchor from a zero print");

        _feed(2000e18, T0 + 3600);
        assertEq(reactive.updates(), 1, "next sane price ingests");
        assertEq(reactive.anchorPeak(), 2000e18, "sane price initialises the anchor normally");
        _feed(2010e18, T0 + 7200);
        _feed(1990e18, T0 + 10800);
        assertEq(reactive.updates(), 3);
    }

    // --- F2: 3600 s staleness bound at consumption --------------------------------

    function testF2_StalePriceRefusesFill() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8);
        feed.setRound(2000e8, block.timestamp); // $2000, fresh round
        ChainlinkPriceAdapter adapter = new ChainlinkPriceAdapter(
            address(feed), address(weth), 10, 60, 300, 3600 // maxStaleness 1h
        );
        adapter.sync();
        assertEq(adapter.latestPrice(address(weth)), 2000e18);

        // Feed HALTS: no new round for 30 days.
        feed.setRound(1000e8, block.timestamp); // answer moves, timestamp does not advance
        vm.warp(block.timestamp + 30 days);
        adapter.sync(); // adapter itself refuses the stale round...
        assertEq(adapter.latestPrice(address(weth)), 2000e18, "adapter still reports the 30-day-old price");

        // ...and now the desk refuses it too instead of trading on it.
        SentinelSwapV2 staleSwap = new SentinelSwapV2(address(weth), address(usdc), address(adapter), address(0));
        staleSwap.setVault(address(this));
        usdc.mint(address(staleSwap), 1_000_000 ether);
        weth.mint(address(this), 10 ether);
        weth.approve(address(staleSwap), type(uint256).max);
        usdc.mint(address(this), 10_000 ether);
        usdc.approve(address(staleSwap), type(uint256).max);

        ISwapR8 s = ISwapR8(address(staleSwap));
        assertTrue(s.priceStale(), "30-day-old price is stale");
        assertEq(s.priceAge(), 30 days, "age is the full 30 days");
        assertEq(s.MAX_PRICE_AGE(), 3600, "bound is 3600 s");

        vm.expectEmit(false, false, false, true, address(staleSwap));
        emit StalePriceRefused(30 days, 3600);
        assertEq(staleSwap.swapRiskForSafe(1 ether), 0, "stale fill refuses with 0, never reverts");

        vm.expectEmit(false, false, false, true, address(staleSwap));
        emit StalePriceRefused(30 days, 3600);
        assertEq(staleSwap.swapSafeForRisk(1000 ether), 0, "stale reverse fill likewise refuses");
    }

    function testF2_StalePriceRevertsDeposit() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        _callback(1); // mixed pool: 5 WETH + 10,000 mUSDC
        assertEq(vault.managedSafe(), 10_000 ether);

        // Warp past the bound with no fresh push: deposit reverts StalePrice.
        vm.warp(block.timestamp + 3601);
        _fund(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("StalePrice(uint256)", 3601));
        vault.deposit(1 ether);

        // A fresh push clears it and the same deposit succeeds.
        oracle.setPrice(address(weth), 2000e18);
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether);
        assertEq(shares, 1 ether, "1 WETH into a 10-WETH-eq pool with 10 shares out");
    }

    function testF2_FreshPriceStillFills() public {
        // Bound minus one second (age 3599): fills and deposits behave exactly as before.
        SentinelSwapV2 freshSwap = new SentinelSwapV2(address(weth), address(usdc), address(oracle), address(this));
        usdc.mint(address(freshSwap), 1_000_000 ether);
        weth.mint(address(this), 10 ether);
        weth.approve(address(freshSwap), type(uint256).max);
        assertFalse(ISwapR8(address(freshSwap)).priceStale(), "age 0 is fresh");

        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        _callback(1); // mixed pool

        vm.warp(block.timestamp + 3599); // age 3599, inside the bound
        assertFalse(ISwapR8(address(freshSwap)).priceStale(), "age 3599 is still fresh");
        assertEq(freshSwap.swapRiskForSafe(1 ether), 2000 ether, "fill at the live price");
        _fund(alice, 1 ether);
        vm.prank(alice);
        uint256 shares = vault.deposit(1 ether);
        assertEq(shares, 1 ether, "deposit at the live price");
    }

    function testF2_NeverPushedIsStale() public {
        // Forge starts block.timestamp at 1, where "never pushed" would
        // read as 1 s old; warp to a realistic wall-clock first — on any
        // live chain the timestamp is far past the bound already.
        vm.warp(T0);
        MockPriceOracle freshOracle = new MockPriceOracle(); // never pushed
        SentinelSwapV2 freshSwap = new SentinelSwapV2(address(weth), address(usdc), address(freshOracle), address(0));
        freshSwap.setVault(address(this));
        usdc.mint(address(freshSwap), 1_000_000 ether);
        weth.mint(address(this), 10 ether);
        weth.approve(address(freshSwap), type(uint256).max);
        usdc.mint(address(this), 10_000 ether);
        usdc.approve(address(freshSwap), type(uint256).max);

        ISwapR8 s = ISwapR8(address(freshSwap));
        assertTrue(s.priceStale(), "a source that never pushed is stale from deploy");
        assertEq(s.priceAge(), block.timestamp, "age is the full block timestamp");
        // Control: a fresh push on the setUp oracle reads fresh again.
        oracle.setPrice(address(weth), 2000e18);
        assertEq(ISwapR8(address(swap)).priceStale(), false, "control: the pushed oracle is fresh");
        assertEq(freshSwap.swapRiskForSafe(1 ether), 0, "refuses fills with no price ever pushed");
        assertEq(freshSwap.swapSafeForRisk(1000 ether), 0, "reverse likewise refuses");
    }

    // --- F3: repeat-EXIT cooldown-gated -------------------------------------------

    function _bleedToExit() internal {
        _feed(10_000_000_000, T0);
        _feed(10_050_000_000, T0 + 400);
        _feed(9_980_000_000, T0 + 800);
        _feed(10_020_000_000, T0 + 1200);
        _feed(10_010_000_000, T0 + 1600);
        _feed(9_200_000_000, T0 + 2000); // TRIM fires
        _feed(8_100_000_000, T0 + 2400); // EXIT fires
        assertEq(sys.callbackCount(), 2, "TRIM then EXIT");
        assertEq(_countAction(SentinelModelV2.EXIT), 1);
    }

    function testF3_RepeatExitIsCooldownGated() public {
        _bleedToExit();
        // Sustained crash: 10 more prints, each 1 s after the EXIT (and 1 s
        // apart) — far inside the 300 s cooldown.
        for (uint256 i = 0; i < 10; i++) {
            _feed(7_600_000_000, T0 + 2401 + i);
        }
        assertEq(sys.callbackCount(), 2, "no repeat EXIT inside the cooldown");
        assertEq(_countAction(SentinelModelV2.EXIT), 1, "exactly one EXIT for one sustained crash");
    }

    function testF3_ExitFiresAgainAfterCooldown() public {
        _bleedToExit();
        for (uint256 i = 0; i < 10; i++) {
            _feed(7_600_000_000, T0 + 2401 + i);
        }
        assertEq(sys.callbackCount(), 2, "gated inside the cooldown");
        // One more crash print at originTs EXIT + 301 s: the gate is a
        // cooldown, not a blanket suppression.
        _feed(7_600_000_000, T0 + 2701);
        assertEq(sys.callbackCount(), 3, "exactly one more EXIT after the cooldown");
        assertEq(_countAction(SentinelModelV2.EXIT), 2);
        assertEq(_callbackAction(2), SentinelModelV2.EXIT);
    }

    function testF3_NewPositionFirstTrimWaits() public {
        _bleedToExit();
        // Sideways prints decay the anchor (0.1% per update) while origin
        // time stays inside the 300 s cooldown: no callback can fire.
        for (uint256 i = 0; i < 105; i++) {
            _feed(8_100_000_000, T0 + 2401 + i);
        }
        assertEq(sys.callbackCount(), 2, "sideways prints inside the cooldown fire nothing");

        // A fresh drop now votes TRIM (anchor decayed to ~9.0e9; 7.8e9 is
        // ~13% down) — but at +106 s after the EXIT it must wait.
        _feed(7_800_000_000, T0 + 2506);
        assertEq(reactive.lastAction(), SentinelModelV2.TRIM, "model votes TRIM on the fresh drop");
        assertEq(sys.callbackCount(), 2, "first TRIM of the new position waits out the cooldown");

        // The same shape at +301 s after the EXIT fires.
        _feed(7_700_000_000, T0 + 2701);
        assertEq(reactive.lastAction(), SentinelModelV2.TRIM, "model still votes TRIM");
        assertEq(sys.callbackCount(), 3, "TRIM fires once the cooldown passes");
        assertEq(_callbackAction(2), SentinelModelV2.TRIM);
    }

    // --- F5: unknown action reverts ------------------------------------------------

    function testF5_UnknownActionReverts() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);

        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSignature("UnknownAction(uint8)", 9));
        vault.executeProtection(reactiveAddr, 9);
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSignature("UnknownAction(uint8)", 0));
        vault.executeProtection(reactiveAddr, 0);
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSignature("UnknownAction(uint8)", 5));
        vault.executeProtection(reactiveAddr, 5);

        assertEq(vault.protectionCount(), 0, "no phantom protection counted");
        assertEq(vault.managedRisk(), 10 ether, "balances unchanged");
        assertEq(vault.managedSafe(), 0);
    }

    function testF5_KnownActionsStillWork() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        _callback(1); // TRIM
        assertEq(vault.protectionCount(), 1);
        assertEq(vault.managedRisk(), 5 ether);
        _callback(2); // EXIT
        assertEq(vault.protectionCount(), 2);
        assertTrue(vault.closed());
        assertEq(vault.managedSafe(), 20_000 ether);
        _callback(3); // RERISK
        assertEq(vault.protectionCount(), 3);
        assertEq(vault.reriskCount(), 1);
        assertEq(vault.managedRisk(), 5 ether);
        _callback(4); // RERISK_FINAL
        assertEq(vault.protectionCount(), 4);
        assertEq(vault.reriskCount(), 2);
        assertEq(vault.managedRisk(), 10 ether);
        assertEq(vault.managedSafe(), 0);
    }

    // --- L3: TRIM suppression resets on tranche-2 episode close -------------------

    function testL3_FreshTrimFiresAfterFullRerisk() public {
        // Crash leg 1: TRIM fires at update 6 (same shape as the F3 PoC).
        _feed(10_000_000_000, T0);
        _feed(10_050_000_000, T0 + 3600);
        _feed(9_980_000_000, T0 + 7200);
        _feed(10_020_000_000, T0 + 10800);
        _feed(10_010_000_000, T0 + 14400);
        _feed(9_200_000_000, T0 + 18000);
        assertEq(sys.callbackCount(), 1, "TRIM fired at update 6");
        assertEq(_callbackAction(0), SentinelModelV2.TRIM);
        assertEq(reactive.lastTrimFiredUpdate(), 6);

        // Recovery: tranche 1 at update 9, tranche 2 at update 10.
        _feed(9_500_000_000, T0 + 21600);
        _feed(9_700_000_000, T0 + 25200);
        _feed(9_800_000_000, T0 + 28800);
        assertEq(sys.callbackCount(), 2, "tranche 1 fired at update 9");
        assertEq(_callbackAction(1), reactive.ACTION_RERISK());
        _feed(10_100_000_000, T0 + 32400);
        assertEq(sys.callbackCount(), 3, "tranche 2 fired at update 10");
        assertEq(_callbackAction(2), reactive.ACTION_RERISK_FINAL());
        assertFalse(reactive.episodeActive(), "episode closed by tranche 2");
        assertEq(reactive.reriskCount(), 2, "full re-risk complete");
        assertEq(reactive.lastTrimFiredUpdate(), 0, "tranche-2 close resets suppression");

        // Fresh crash leg: TRIM fires at update 11 (count 4, action TRIM).
        _feed(9_600_000_000, T0 + 36000);
        assertEq(reactive.lastAction(), SentinelModelV2.TRIM, "model votes TRIM on the fresh leg");
        assertEq(sys.callbackCount(), 4, "fresh TRIM fires at update 11");
        assertEq(_callbackAction(3), SentinelModelV2.TRIM);
        assertEq(reactive.lastTrimFiredUpdate(), 11, "new suppression window opens at 11");

        // Updates 12-13 still vote TRIM but are suppressed by the new window.
        _feed(9_100_000_000, T0 + 39600);
        _feed(8_700_000_000, T0 + 43200);
        assertEq(sys.callbackCount(), 4, "fresh suppression window holds through update 13");
    }

    function testL3_CooldownStillGatesAfterReset() public {
        // Same scenario compressed to 1 s origin spacing: the whole run
        // happens inside 300 s of the TRIM@6 origin timestamp.
        _feed(10_000_000_000, T0);
        _feed(10_050_000_000, T0 + 1);
        _feed(9_980_000_000, T0 + 2);
        _feed(10_020_000_000, T0 + 3);
        _feed(10_010_000_000, T0 + 4);
        _feed(9_200_000_000, T0 + 5); // TRIM@6
        assertEq(sys.callbackCount(), 1);
        _feed(9_500_000_000, T0 + 6);
        _feed(9_700_000_000, T0 + 7);
        _feed(9_800_000_000, T0 + 8); // tranche 1 @9
        assertEq(sys.callbackCount(), 2);
        _feed(10_100_000_000, T0 + 9); // tranche 2 @10, episode closes
        assertEq(sys.callbackCount(), 3);
        assertFalse(reactive.episodeActive());
        assertEq(reactive.lastTrimFiredUpdate(), 0, "tranche-2 close resets suppression");

        // Fresh leg votes TRIM at updates 11-13, but the cooldown from
        // TRIM@6 (originTs T0+5) has not passed: no callback yet.
        _feed(9_600_000_000, T0 + 10);
        _feed(9_100_000_000, T0 + 11);
        _feed(8_700_000_000, T0 + 12);
        assertEq(reactive.lastAction(), SentinelModelV2.TRIM, "model votes TRIM on the fresh leg");
        assertEq(sys.callbackCount(), 3, "no callback until the cooldown passes");
        _feed(8_450_000_000, T0 + 13);
        _feed(8_400_000_000, T0 + 14);
        assertEq(sys.callbackCount(), 3, "still gated through update 15");

        // Deep print at originTs TRIM + 301 s: EXIT vote, cooldown passed.
        _feed(6_000_000_000, T0 + 306);
        assertEq(reactive.lastAction(), SentinelModelV2.EXIT, "deep print votes EXIT");
        assertEq(sys.callbackCount(), 4, "callback fires once the cooldown passes");
        assertEq(_callbackAction(3), SentinelModelV2.EXIT);
    }
}
