// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwapV2} from "../src/SentinelSwapV2.sol";
import {SentinelVaultV5} from "../src/SentinelVaultV5.sol";
import {SentinelReactiveV5} from "../src/SentinelReactiveV5.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Lead-triage PoCs for the Sentinel full audit (2026-11-27), written
///         for the Release 8 fix-design gate. Each test PASSES iff the
///         described behaviour is present in the code under audit.
///           L1-L2  anchor decay is per-update, not per-second (cadence effect)
///           L1-L3  TRIM suppression is cycle-blind (fresh crash leg after a
///                   full re-risk is still suppressed)
///           L1-L5  vault max-approval to the swap (onlyVault-gated)
///           L1-L6  a 1-wei deposit re-arms a closed position
///           L1-L7  cooldown reads origin timestamps, not wall time
///           L1-L8  extreme prices (> 2^255-1) wrap int256 in _features
///         Dispositions (see FIX-DESIGN.md): L3 and L8 were PROMOTED to
///         findings and fixed in R8 — their PoCs in this file are RETIRED
///         (replaced by test/Release8Regression.t.sol); L2 is a confirmed
///         model-validity limitation (no R8 code fix — redesign +
///         revalidation needed, replay unaffected); L5/L6/L7 are confirmed
///         behaviour, benign or by design (no fix).
contract AuditLeadsTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));
    uint256 internal constant ORIGIN_CHAIN = 84532;
    uint256 internal constant T0 = 1_700_000_000;

    address internal proxy = makeAddr("callbackProxy");
    address internal reactiveAddr = makeAddr("sentinelReactive");
    address internal alice = makeAddr("alice");
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

    function _feedTo(SentinelReactiveV5 r, uint256 price, uint256 ts) internal {
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
        r.react(log_);
    }

    function _feed(uint256 price, uint256 ts) internal {
        _feedTo(reactive, price, ts);
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
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = cfg.payload[i + 4];
        }
        (, uint8 action) = abi.decode(body, (address, uint8));
        return action;
    }

    function _countAction(uint8 action) internal view returns (uint256 count) {
        for (uint256 i = 0; i < sys.callbackCount(); i++) {
            if (_callbackAction(i) == action) count++;
        }
    }

    function _fund(address u, uint256 amt) internal {
        weth.mint(u, amt);
        vm.prank(u);
        weth.approve(address(vault), type(uint256).max);
    }

    // --- L1-L2: anchor decay is per-update, not per-second ----------------------
    // Same 51-print price path, two brains: origin timestamps 1 s apart vs
    // 3600 s apart. If decay were per-second the anchors would differ by
    // ~50 hours of decay; they are identical, proving decay is per-update.
    function testLeadL2_AnchorDecayIsPerUpdateNotPerSecond() public {
        SentinelReactiveV5 fast =
            new SentinelReactiveV5(ORIGIN_CHAIN, address(oracle), address(weth), ORIGIN_CHAIN, 300);
        SentinelReactiveV5 slow =
            new SentinelReactiveV5(ORIGIN_CHAIN, address(oracle), address(weth), ORIGIN_CHAIN, 300);
        _feedTo(fast, 100e18, T0);
        _feedTo(slow, 100e18, T0);
        for (uint256 i = 0; i < 50; i++) {
            _feedTo(fast, 90e18, T0 + 1 + i); // 1 s apart
            _feedTo(slow, 90e18, T0 + 3600 + i * 3600); // 1 h apart
        }
        assertEq(fast.anchorPeak(), slow.anchorPeak(), "anchor identical despite 50h of origin-time difference");
        // 100 * 0.999^50 = 95.12... — the peak decayed 50 update-steps in both.
        assertGt(fast.anchorPeak(), 95e18);
        assertLt(fast.anchorPeak(), 95.2e18);
        assertEq(fast.updates(), 51);
        assertEq(slow.updates(), 51);
    }

    // --- L1-L3: RETIRED in Release 8 (FIX-DESIGN.md §3/§8) ----------------------
    // testLeadL3_TrimSuppressionIsCycleBlind asserted the buggy behaviour
    // (suppression never resets on a tranche-2 close). Replaced by
    // testL3_FreshTrimFiresAfterFullRerisk + testL3_CooldownStillGatesAfterReset
    // in test/Release8Regression.t.sol.

    // --- L1-L5: max approval is onlyVault-gated ----------------------------------
    function testLeadL5_MaxApprovalIsOnlyVaultGated() public {
        assertEq(weth.allowance(address(vault), address(swap)), type(uint256).max, "vault grants max allowance");
        vm.prank(stranger);
        vm.expectRevert();
        swap.swapRiskForSafe(1 ether);
        vm.prank(stranger);
        vm.expectRevert();
        swap.swapSafeForRisk(1 ether);
    }

    // --- L1-L6: a 1-wei deposit re-arms a closed position -------------------------
    function testLeadL6_DustDepositRearmsClosedPosition() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        vm.prank(proxy);
        vault.executeProtection(reactiveAddr, 2); // EXIT: closed = true
        assertTrue(vault.closed());
        vm.prank(alice);
        vault.redeemAll();
        assertEq(vault.totalShares(), 0);

        weth.mint(alice, 1); // 1 wei of fresh WETH for the dust deposit
        vm.prank(alice);
        uint256 shares = vault.deposit(1); // 1 wei
        assertEq(shares, 1);
        assertFalse(vault.closed(), "1 wei re-arms the closed position");
        assertEq(vault.managedRisk(), 1);

        vm.prank(proxy);
        vault.executeProtection(reactiveAddr, 1); // TRIM sells 1/2 = 0 wei
        assertEq(vault.managedRisk(), 1, "TRIM on a 1-wei position moves nothing");
    }

    // --- L1-L7: cooldown reads origin timestamps, not wall time -------------------
    function testLeadL7_CooldownReadsOriginTimestampsNotWallTime() public {
        _feed(10_000_000_000, T0);
        _feed(10_050_000_000, T0 + 3600);
        _feed(9_980_000_000, T0 + 7200);
        _feed(10_020_000_000, T0 + 10800);
        _feed(10_010_000_000, T0 + 14400);
        _feed(9_200_000_000, T0 + 18000); // TRIM fires, originTs T0+18000
        assertEq(sys.callbackCount(), 1);

        // Wall clock jumps 10,000 s, but origin timestamps advance 1 s per
        // print: the cooldown (300 s, origin-time) has NOT passed.
        vm.warp(T0 + 28000);
        for (uint256 i = 0; i < 10; i++) {
            _feed(9_200_000_000, T0 + 18001 + i);
        }
        assertEq(reactive.updates(), 16);

        // Update 17: suppression expired (17-6=11>10), model votes TRIM on a
        // fresh fall to $85 — but originTs is only T0+18011, inside the
        // 300 s origin-time cooldown, so no callback despite 10,000 s of
        // wall time having passed.
        _feed(8_500_000_000, T0 + 18011);
        assertEq(reactive.lastAction(), SentinelModelV2.TRIM, "model votes TRIM at update 17");
        assertEq(sys.callbackCount(), 1, "no callback: origin-time cooldown not passed");

        // Update 18: originTs T0+18301 — 301 s after the TRIM, cooldown
        // passed in origin time. Wall time has barely moved since update 17.
        _feed(8_400_000_000, T0 + 18301);
        assertEq(sys.callbackCount(), 2, "callback fires once origin-time cooldown passes");
        assertEq(_callbackAction(1), SentinelModelV2.TRIM);
    }

    // --- L1-L8: RETIRED in Release 8 (FIX-DESIGN.md §3/§8) ----------------------
    // testLeadL8_ExtremePriceRevertsReact asserted the buggy behaviour (a 2^255
    // print reverts react()). Closed by the F4 upper bound with no extra code;
    // covered by testF4_HugePriceIgnoredBrainKeepsWorking in
    // test/Release8Regression.t.sol.
}
