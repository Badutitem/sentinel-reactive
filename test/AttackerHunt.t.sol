// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
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

/// @notice Attacker-hunt lane, 2026-11-27. Think like an attacker, not a
///         re-checker: every test below is a NEW path beyond F1-F5/L3/L8.
///         Tests are named H1..H12; the report maps each to a finding,
///         an open lead, or a cleared angle.
contract AttackerHuntTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));
    uint256 internal constant ORIGIN_CHAIN = 84532;
    uint256 internal constant T0 = 1_700_000_000;

    address internal proxy = makeAddr("callbackProxy");
    address internal reactiveAddr = makeAddr("sentinelReactive");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
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

    function _valueAt2000(uint256 risk, uint256 safe) internal pure returns (uint256) {
        return risk + safe / 2000;
    }

    function _mixedPool() internal {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        _callback(1); // TRIM at $2000: 5 WETH + 10,000 mUSDC, anchor $2000
        assertEq(vault.managedRisk(), 5 ether);
        assertEq(vault.managedSafe(), 10_000 ether);
        assertEq(vault.lastSettledPrice(), 2000e18);
    }

    // --- H1: heartbeat griefing — a stranger forces brain reactions --------

    function testH1_HeartbeatGriefing_StrangerForcesEmissions() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8);
        feed.setRound(2000e8, block.timestamp);
        ChainlinkPriceAdapter adapter = new ChainlinkPriceAdapter(
            address(feed), address(weth), 10, 60, 300, 3600
        );
        // Flat price forever: the feed never moves.
        adapter.sync();
        assertEq(adapter.lastPrice(), 2000e18, "first sync emits");
        uint256 emissions = 1;

        // Control: spam inside minInterval emits nothing.
        vm.prank(stranger);
        adapter.sync();
        vm.prank(stranger);
        adapter.sync();
        assertEq(adapter.lastEmittedAt(), block.timestamp, "spam inside 60 s emits nothing");

        // Attack: the stranger pokes sync() once per heartbeat (300 s).
        // Every poke emits (heartbeat rule) even though the price NEVER moved.
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 300);
            uint256 before = adapter.lastEmittedAt();
            vm.prank(stranger);
            adapter.sync();
            if (adapter.lastEmittedAt() != before) emissions++;
        }
        assertEq(emissions, 11, "10 stranger pokes at heartbeat cadence = 10 forced emissions");
        // Each emission is one reactive transaction billed to the brain.
        // Measured HOLD react cost (June-core audit): 0.0295521 lREACT.
        // 11 emissions = 0.3250731 lREACT; flagship 11.5613437 lREACT lasts
        // ~391 heartbeat emissions = ~32.6 h of one poke per 300 s.
        console.log("H1 emissions forced by stranger:", emissions);
    }

    // --- H2: near-zero (1 wei) price — the F4 zero-guard has a cliff -------

    function testH2_OneWeiPriceDumpsPositionForDust() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        assertEq(vault.managedRisk(), 10 ether);

        // Calm prints, then a 1-wei print. Price 1 is NOT zero, so the F4
        // guard admits it into the window.
        _feed(2000e18, T0);
        _feed(2000e18, T0 + 3600);
        _feed(2000e18, T0 + 7200);
        oracle.setPrice(address(weth), 1); // desk now prices at 1 wei
        _feed(1, T0 + 10800);
        assertEq(reactive.updates(), 4, "1-wei print is ingested, not ignored");
        console.log("H2 action on 1-wei print:", reactive.lastAction());
        // If the first 1-wei print only votes TRIM, a second one escalates
        // to EXIT (2 > 1 bypasses the cooldown).
        if (sys.callbackCount() == 0 || _callbackAction(sys.callbackCount() - 1) != 2) {
            _feed(1, T0 + 14400);
        }
        assertGe(sys.callbackCount(), 1, "brain fires on the near-zero path");
        assertEq(_callbackAction(sys.callbackCount() - 1), 2, "final vote is EXIT");
        // Deliver the EXIT the way the network would: the vault sells all
        // 10 WETH at the 1-wei reference price.
        _callback(2);
        assertEq(vault.managedRisk(), 0, "position fully sold");
        assertLe(vault.managedSafe(), 100, "sold for dust (<= 100 wei mUSDC)");
        console.log("H2 managedSafe after 1-wei EXIT:", vault.managedSafe());
    }

    // --- H3: absurd price bricks the in-flight callback ---------------------

    function testH3_AbsurdPriceBricksCallbackAndBrainWontRefire() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        // Crash path the brain recognises (same shape as the F3 PoC).
        _feed(10_000_000_000, T0);
        _feed(10_050_000_000, T0 + 400);
        _feed(9_980_000_000, T0 + 800);
        _feed(10_020_000_000, T0 + 1200);
        _feed(10_010_000_000, T0 + 1600);
        _feed(9_200_000_000, T0 + 2000);
        _feed(8_100_000_000, T0 + 2400);
        assertEq(sys.callbackCount(), 2, "TRIM then EXIT requested");
        assertEq(_callbackAction(1), 2, "second callback is EXIT");

        // Between the brain's decision and the callback landing, the price
        // is pushed absurd (2^200). The swap's pricing math overflows.
        oracle.setPrice(address(weth), 2 ** 200);
        vm.prank(proxy);
        vm.expectRevert(); // arithmetic overflow panic in swapRiskForSafe
        vault.executeProtection(reactiveAddr, 2);
        assertEq(vault.managedRisk(), 10 ether, "bricked EXIT moved nothing");
        assertEq(vault.protectionCount(), 0, "bricked callback counts nothing");

        // The brain already recorded the EXIT fire: one more crash print
        // 1 s later does NOT refire inside the 300 s cooldown.
        oracle.setPrice(address(weth), 2000e18);
        _feed(7_600_000_000, T0 + 2401);
        assertEq(sys.callbackCount(), 2, "no refire inside the cooldown");
        // Recovery is possible once the price is sane again AND the
        // cooldown passes — but the position rode the crash unprotected.
        _feed(7_600_000_000, T0 + 2701);
        assertEq(sys.callbackCount(), 3, "refire only after the cooldown");
    }

    // --- H4a: within-band pump — depositor gains at holders' expense -------

    function testH4a_Pump50pcLetsDepositorStealFromHolders() public {
        _mixedPool(); // Alice: 10 shares, pool 5 WETH + 10,000 mUSDC @ $2000
        // Pusher moves the price to exactly 1.5x the anchor: the guard's
        // strict `price > anchor * 3 / 2` lets it through.
        oracle.setPrice(address(weth), 3000e18);
        _fund(attacker, 5 ether);
        vm.prank(attacker);
        uint256 atkShares = vault.deposit(5 ether);
        // PoolEq at $3000 = 5 + 10000/3000 = 8.333... WETH; 5 WETH mints
        // 6 shares minus 1 wei of ceil-division dust in _poolRiskEq.
        assertEq(atkShares, 5999999999999999999, "6 shares minus 1 wei of ceil dust");
        vm.prank(attacker);
        (uint256 riskOut, uint256 safeOut) = vault.redeem(atkShares);
        uint256 atkValue = _valueAt2000(riskOut, safeOut);
        assertGt(atkValue, 5 ether, "attacker extracts more than deposited");
        assertEq(atkValue, 5624999999999999998, "exactly 5.625 WETH eq (+0.625)");
        (uint256 aRisk, uint256 aSafe) = vault.claimOf(alice);
        assertEq(_valueAt2000(aRisk, aSafe), 9375000000000000001, "Alice left with 9.375 WETH eq (-0.625)");
    }

    // --- H4b: within-band dump — victim depositor takes the haircut --------

    function testH4b_Dump49pcHaircutsVictimDepositor() public {
        _mixedPool(); // Alice: 10 shares, pool 5 WETH + 10,000 mUSDC @ $2000
        // Pusher dumps the price to $1020 (just above the anchor/2 floor).
        oracle.setPrice(address(weth), 1020e18);
        _fund(bob, 5 ether);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(5 ether);
        // PoolEq at $1020 = 5 + 10000/1020 = 14.8039... WETH; 5 WETH mints ~3.378 shares.
        assertLt(bobShares, 5 ether, "victim mints fewer shares than WETH deposited");
        vm.prank(bob);
        (uint256 riskOut, uint256 safeOut) = vault.redeem(bobShares);
        uint256 bobValue = _valueAt2000(riskOut, safeOut);
        assertLt(bobValue, 4 ether, "victim redeems under 4 WETH eq for 5 deposited");
        console.log("H4b victim shares:", bobShares);
        console.log("H4b victim redeem value at true $2000:", bobValue);
    }

    // --- H4c: anchor walk — price the FIX-DESIGN residual -------------------

    function testH4c_AnchorWalkTo100x() public {
        _mixedPool(); // Alice: 10 shares, pool 5 WETH + 10,000 mUSDC @ $2000
        // Walk +50% per settlement: each step is a small deposit that
        // settles the anchor at the new price (the guard allows <= 1.5x).
        uint256 price = 2000e18;
        uint256 attackerDeposited;
        for (uint256 i = 0; i < 12; i++) {
            price = price * 3 / 2;
            oracle.setPrice(address(weth), price);
            _fund(attacker, 0.1 ether);
            vm.prank(attacker);
            vault.deposit(0.1 ether);
            attackerDeposited += 0.1 ether;
        }
        console.log("H4c walked price:", price);
        console.log("H4c attacker walk deposits:", attackerDeposited);
        console.log("H4c anchor after walk:", vault.lastSettledPrice());
        // Final big deposit at the walked price, then redeem everything
        // the attacker holds and value it at the TRUE $2000.
        _fund(attacker, 5 ether);
        vm.prank(attacker);
        vault.deposit(5 ether);
        attackerDeposited += 5 ether;
        uint256 atkShares = vault.sharesOf(attacker);
        vm.prank(attacker);
        (uint256 riskOut, uint256 safeOut) = vault.redeem(atkShares);
        uint256 atkValue = _valueAt2000(riskOut, safeOut);
        (uint256 aRisk, uint256 aSafe) = vault.claimOf(alice);
        console.log("H4c attacker total deposited:", attackerDeposited);
        console.log("H4c attacker redeem value at true $2000:", atkValue);
        console.log("H4c Alice claim value at true $2000:", _valueAt2000(aRisk, aSafe));
        assertGt(atkValue, attackerDeposited, "walk ends in profit at the true price");
    }

    // --- H5a: swap.setVault redirection bricks the real vault's fills ------

    function testH5a_SwapSetVaultBricksRealVaultCallbacks() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        // Swap owner (dev) points the desk at an attacker contract.
        swap.setVault(attacker);
        assertEq(swap.vault(), attacker, "desk now answers to the attacker");
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSignature("NotVault(address)", address(vault)));
        vault.executeProtection(reactiveAddr, 1);
        assertEq(vault.managedRisk(), 10 ether, "TRIM moved nothing");
        assertEq(vault.protectionCount(), 0, "reverted callback counts nothing");
    }

    // --- H5b: reactive.setVault redirection sinks the brain's callbacks ----

    function testH5b_ReactiveSetVaultSinksCallbacks() public {
        reactive.setVault(attacker);
        assertEq(reactive.vault(), attacker, "brain now calls the attacker");
        _feed(10_000_000_000, T0);
        _feed(10_050_000_000, T0 + 400);
        _feed(9_980_000_000, T0 + 800);
        _feed(10_020_000_000, T0 + 1200);
        _feed(10_010_000_000, T0 + 1600);
        _feed(9_200_000_000, T0 + 2000);
        assertEq(sys.callbackCount(), 1, "TRIM requested");
        assertEq(sys.lastCallback().recipient, attacker, "callback recipient is the attacker, not the vault");
        assertEq(vault.protectionCount(), 0, "real vault never hears it");
    }

    // --- H6: owner drains the desk — protection fills go to zero -----------

    function testH6_OwnerDrainsDeskFillsGoToZero() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        // Swap owner pulls the whole 1,000 mUSDC reserve in one call.
        swap.withdraw(address(usdc), address(this), 1_000_000 ether);
        assertEq(usdc.balanceOf(address(swap)), 0, "desk reserve empty");
        _callback(1); // TRIM: fills 0, succeeds as a no-op
        assertEq(vault.managedRisk(), 10 ether, "nothing sold");
        assertEq(vault.managedSafe(), 0, "nothing bought");
        assertEq(vault.protectionCount(), 1, "no-op still counts as a protection");
    }

    // --- H7: V5 surplus cap holds — even after redirections ----------------

    function testH7_SurplusCapHoldsAfterRedirections() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        // Donations create surplus; the cap is exactly the surplus.
        weth.mint(address(vault), 3 ether);
        usdc.mint(address(vault), 500 ether);
        assertEq(vault.surplusRisk(), 3 ether);
        assertEq(vault.surplusSafe(), 500 ether);
        // Over-surplus withdraws revert for both pool assets.
        vm.expectRevert(abi.encodeWithSignature("ExceedsSurplus(address,uint256,uint256)", address(weth), 3 ether + 1, 3 ether));
        vault.withdraw(address(weth), address(this), 3 ether + 1);
        vm.expectRevert(abi.encodeWithSignature("ExceedsSurplus(address,uint256,uint256)", address(usdc), 501 ether, 500 ether));
        vault.withdraw(address(usdc), address(this), 501 ether);
        // Exact-surplus withdraw succeeds; managed backing untouched.
        vault.withdraw(address(weth), address(this), 3 ether);
        assertEq(vault.managedRisk(), 10 ether, "managed risk untouched by surplus skim");
        assertEq(vault.surplusRisk(), 0);
        // Redirect both setVaults first — the cap still binds.
        swap.setVault(attacker);
        reactive.setVault(attacker);
        vm.expectRevert(abi.encodeWithSignature("ExceedsSurplus(address,uint256,uint256)", address(usdc), 501 ether, 500 ether));
        vault.withdraw(address(usdc), address(this), 501 ether);
        // A non-pool token is rescuable in full (by design).
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(vault), 7 ether);
        vault.withdraw(address(other), address(this), 7 ether);
        assertEq(other.balanceOf(address(this)), 7 ether, "other-token rescue in full");
    }

    // --- H8: callback auth + replay — vault has no idempotency -------------

    function testH8_CallbackAuthHoldsButReplayDoubleExecutes() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        // Stranger calling directly: reverts (not the proxy).
        vm.prank(stranger);
        vm.expectRevert();
        vault.executeProtection(reactiveAddr, 1);
        // Proxy calling with the WRONG sender: reverts.
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSignature("CallbackNotAuthorized(address,address)", attacker, reactiveAddr));
        vault.executeProtection(attacker, 1);
        // Brain-side: a stranger cannot call react() directly.
        vm.prank(stranger);
        vm.expectRevert();
        reactive.react(
            IReactive.LogRecord({
                chainId: ORIGIN_CHAIN,
                contractAddress: address(oracle),
                topic0: PRICE_TOPIC0,
                topic1: uint256(uint160(address(weth))),
                topic2: 0,
                topic3: 0,
                data: abi.encode(2000e18, T0),
                blockNumber: 1,
                opCode: 2,
                blockHash: 0,
                txHash: 123,
                logIndex: 0
            })
        );
        // Replay: delivering the SAME callback twice executes twice.
        // (Whether the network ever redelivers is a platform question —
        // the vault itself carries no nonce or idempotency key.)
        _callback(1);
        assertEq(vault.managedRisk(), 5 ether, "first TRIM sells half");
        _callback(1);
        assertEq(vault.managedRisk(), 2.5 ether, "replayed TRIM sells half of what is left");
        assertEq(vault.protectionCount(), 2, "both deliveries counted");
    }

    // --- H9: fail-closed on a halted feed — redeem still works -------------

    function testH9_HaltedFeedFailsClosedButRedeemWorks() public {
        _mixedPool(); // Alice: 10 shares, 5 WETH + 10,000 mUSDC
        vm.warp(block.timestamp + 3601); // no fresh push for > 3600 s
        assertTrue(swap.priceStale(), "price is stale after the halt");
        // Deposits into the mixed pool revert; the desk refuses fills.
        _fund(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("StalePrice(uint256)", 3601));
        vault.deposit(1 ether);
        // Direct desk calls need the caller to be the desk's vault: point
        // the desk at this test contract (it is the swap owner) for the probe.
        swap.setVault(address(this));
        weth.mint(address(this), 1 ether);
        weth.approve(address(swap), type(uint256).max);
        assertEq(swap.swapRiskForSafe(1 ether), 0, "desk refuses the stale fill");
        assertEq(swap.swapSafeForRisk(1000 ether), 0, "reverse likewise refuses");
        // Redemption never touches the price: Alice exits in full.
        vm.prank(alice);
        (uint256 riskOut, uint256 safeOut) = vault.redeemAll();
        assertEq(riskOut, 5 ether, "full risk claim out");
        assertEq(safeOut, 10_000 ether, "full safe claim out");
        assertEq(vault.totalShares(), 0, "pool reset to zero");
    }

    // --- H10: donations move nothing ---------------------------------------

    function testH10_DonationsMoveNothing() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        (uint256 r0, uint256 s0) = vault.claimOf(alice);
        // Donate both pool assets to the vault.
        weth.mint(address(vault), 100 ether);
        usdc.mint(address(vault), 50_000 ether);
        (uint256 r1, uint256 s1) = vault.claimOf(alice);
        assertEq(r1, r0, "WETH donation does not move the risk claim");
        assertEq(s1, s0, "mUSDC donation does not move the safe claim");
        // A deposit right after the donation mints exactly the fair shares.
        _fund(bob, 10 ether);
        vm.prank(bob);
        uint256 shares = vault.deposit(10 ether);
        assertEq(shares, 10 ether, "deposit after a 100-WETH donation still mints 1:1");
        // Donate to the desk: fills do not overpay.
        weth.mint(address(swap), 100 ether);
        usdc.mint(address(swap), 50_000 ether);
        swap.setVault(address(this)); // direct desk probe needs vault-as-caller
        weth.mint(address(this), 1 ether);
        weth.approve(address(swap), type(uint256).max);
        assertEq(swap.swapRiskForSafe(1 ether), 2000 ether, "desk fill unchanged by donations");
    }

    // --- H11: share-pricing edges ------------------------------------------

    function testH11_SharePricingEdges() public {
        // 1-wei first deposit mints exactly 1 share.
        weth.mint(alice, 1);
        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        assertEq(vault.deposit(1), 1, "1-wei first deposit mints 1 share");
        // Dust into a mixed pool reverts instead of donating itself.
        _callback(1); // TRIM the 1-wei position: sells 0 (1/2 floors to 0)... managedSafe stays 0
        _fund(bob, 10 ether);
        vm.prank(bob);
        vault.deposit(10 ether);
        _callback(1); // real TRIM: pool mixed now
        assertGt(vault.managedSafe(), 0, "pool is mixed");
        // Dust reverts only when the pool is worth MORE than totalShares:
        // after a price drop the safe leg reprices up (poolEq 15 WETH vs
        // 10 shares), so 1 wei * shares / poolEq floors to 0.
        oracle.setPrice(address(weth), 1000e18); // exactly anchor/2: passes the guard
        _fund(bob, 1); // bob spent his 10 WETH above; fund the 1-wei dust
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("ZeroShares()"));
        vault.deposit(1); // 1 wei * shares / poolEq floors to 0 shares
        // Deposit into a closed vault re-arms it (known L6 behaviour).
        _callback(2); // EXIT closes the vault
        assertTrue(vault.closed(), "EXIT closes the vault");
        _fund(bob, 1 ether);
        vm.prank(bob);
        vault.deposit(1 ether);
        assertFalse(vault.closed(), "a 1-WETH deposit re-arms the closed vault");
    }

    // --- H12: gentle-bleed probe — how small a move fires the model? ------

    function testH12_GentleBleedProbe() public {
        // -1% per update for 40 updates: anchor decays 0.1%/update, so the
        // anchor drawdown grows ~0.9%/update. Record what the model does.
        uint256 price = 2000e18;
        for (uint256 i = 0; i < 40; i++) {
            _feed(price, T0 + i * 3600);
            price = price * 99 / 100;
        }
        console.log("H12 updates:", reactive.updates());
        console.log("H12 lastAction (0=HOLD 1=TRIM 2=EXIT):", reactive.lastAction());
        console.log("H12 callbacks requested:", sys.callbackCount());
        uint256 trims;
        uint256 exits;
        for (uint256 i = 0; i < sys.callbackCount(); i++) {
            if (_callbackAction(i) == 1) trims++;
            if (_callbackAction(i) == 2) exits++;
        }
        console.log("H12 TRIM callbacks:", trims);
        console.log("H12 EXIT callbacks:", exits);
        console.log("H12 anchorPeak:", reactive.anchorPeak());
        assertEq(reactive.updates(), 40, "all 40 gentle prints ingested");
    }
}
