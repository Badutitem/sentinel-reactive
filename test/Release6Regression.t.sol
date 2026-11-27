// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwapV3} from "../src/SentinelSwapV3.sol";
import {SentinelVaultV6} from "../src/SentinelVaultV6.sol";
import {SentinelReactiveV6} from "../src/SentinelReactiveV6.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Release 6 regression suite (V6-DESIGN.md §4). Every test below
///         fails on the Release 8 code (V5/V2/V5) and passes on V6:
///         the old-code behaviour is the AttackerHunt PoC record
///         (H12 20 callbacks, H2 dust sale, H3 revert, H4a/b/c theft,
///         H5a/b redirection). No existing test file is modified.
contract Release6RegressionTest is Test {
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
    SentinelSwapV3 internal swap;
    SentinelVaultV6 internal vault;

    MockSystemContract internal sys;
    SentinelReactiveV6 internal reactive;
    uint256 internal _nonce;

    function setUp() public {
        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwapV3(address(weth), address(usdc), address(oracle), address(0));
        vault = new SentinelVaultV6(payable(proxy), reactiveAddr, address(weth), address(usdc), address(swap));
        swap.setVault(address(vault));
        oracle.setPrice(address(weth), 2000e18);
        usdc.mint(address(swap), 1_000_000 ether);

        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));
        reactive = new SentinelReactiveV6(ORIGIN_CHAIN, address(oracle), address(weth), ORIGIN_CHAIN, 300);
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

    /// @notice Pushes a price through the oracle AND feeds the log to the
    ///         brain (mirrors the live driver: push, then react).
    function _push(uint256 price, uint256 ts) internal {
        oracle.setPrice(address(weth), price);
        _feedWithNonce(price, ts, ++_nonce);
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

    /// @notice Delivers every callback the brain has requested since
    ///         `fromIdx` (in order), returning the new count.
    function _deliverFrom(uint256 fromIdx) internal returns (uint256) {
        uint256 n = sys.callbackCount();
        for (uint256 i = fromIdx; i < n; i++) _callback(_callbackAction(i));
        return n;
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

    // --- AH-2: the bleed collapses from 20 callbacks to 3 -----------------

    function testAH2_BleedCallbacksCollapse() public {
        uint256 price = 2000e18;
        for (uint256 i = 0; i < 40; i++) {
            _push(price, T0 + i * 3600);
            price = price * 99 / 100;
        }
        assertEq(reactive.updates(), 40, "all 40 gentle prints ingested");
        assertEq(reactive.lastAction(), 2, "final vote is EXIT");
        assertEq(sys.callbackCount(), 3, "V6: 2 TRIM + 1 EXIT (V5 asked 20)");
        uint256 trims;
        uint256 exits;
        for (uint256 i = 0; i < sys.callbackCount(); i++) {
            if (_callbackAction(i) == 1) trims++;
            if (_callbackAction(i) == 2) exits++;
        }
        assertEq(trims, 2, "both TRIMs fire before the EXIT");
        assertEq(exits, 1, "exactly one EXIT - the repeats are latched");
        assertTrue(reactive.exitLatched(), "latch is set after the EXIT");
        console.log("AH2 V6 callbacks:", sys.callbackCount());
        console.log("AH2 V6 trims:", trims);
        console.log("AH2 V6 exits:", exits);
    }

    function testAH2_SuppressedExitVotesStillDecide() public {
        vm.recordLogs();
        uint256 price = 2000e18;
        for (uint256 i = 0; i < 40; i++) {
            _push(price, T0 + i * 3600);
            price = price * 99 / 100;
        }
        // Decisions start at update 3 (MIN_UPDATES): 38 Decision events
        // for 40 updates, even though only 3 callbacks were requested.
        // The votes stand; only the callbacks are withheld.
        bytes32 decisionTopic = keccak256("Decision(uint256,uint256,uint8,int256,int256,int256)");
        uint256 decisions;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == decisionTopic) decisions++;
        }
        assertEq(decisions, 38, "every ingested update still decides");
        assertEq(sys.callbackCount(), 3, "but only 3 callbacks requested");
    }

    // --- AH-2: the latch clears on tranche-1, fresh EXIT protects again ----

    /// @notice The V5R 31-push series, updates 1-20 only (RELEASE5.md):
    ///         calm x5, bleed x0.98 x10 (TRIM at 7, EXIT at 15), recovery
    ///         (90, 93, 96.5, 99.5, 103.5; tranche-1 at 18, tranche-2 at 19).
    ///         Callbacks are delivered promptly after each push (a TRIM
    ///         delivered after the vault closed is a no-op).
    function _feedV5RHead() internal {
        uint256 delivered;
        uint256 price = 100e18;
        uint256[5] memory calm = [uint256(100e18), 1005e17, 998e17, 1002e17, 1001e17];
        for (uint256 i = 0; i < 5; i++) {
            _push(calm[i], T0 + i * 3600);
            delivered = _deliverFrom(delivered);
        }
        price = 1001e17;
        for (uint256 i = 0; i < 10; i++) {
            price = price * 98 / 100;
            _push(price, T0 + (5 + i) * 3600);
            delivered = _deliverFrom(delivered);
        }
        uint256[5] memory rec = [uint256(90e18), 93e18, 965e17, 995e17, 1035e17];
        for (uint256 i = 0; i < 5; i++) {
            _push(rec[i], T0 + (15 + i) * 3600);
            delivered = _deliverFrom(delivered);
        }
    }

    function testAH2_LatchClearsOnTranche1AndFreshExitProtects() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        _feedV5RHead();
        // Latch set by EXIT@15, cleared by tranche-1 @18.
        assertEq(sys.callbackCount(), 4, "TRIM, EXIT, RERISK, RERISK_FINAL");
        assertEq(_callbackAction(0), 1);
        assertEq(_callbackAction(1), 2);
        assertEq(_callbackAction(2), 3);
        assertEq(_callbackAction(3), 4);
        assertFalse(reactive.exitLatched(), "latch cleared by tranche-1");
        assertEq(reactive.reriskCount(), 2, "both tranches fired");
        // Fresh crash from the $103.5 high: the restored position must
        // be protected again — a new EXIT fires and re-latches.
        uint256 price = 1035e17;
        uint256 before = sys.callbackCount();
        for (uint256 i = 0; i < 15; i++) {
            price = price * 98 / 100;
            _push(price, T0 + (20 + i) * 3600);
            if (sys.callbackCount() > before && _callbackAction(sys.callbackCount() - 1) == 2) break;
        }
        assertGt(sys.callbackCount(), before, "fresh crash fires again");
        assertEq(_callbackAction(sys.callbackCount() - 1), 2, "the fresh fire is EXIT");
        assertTrue(reactive.exitLatched(), "latch set again by the fresh EXIT");
    }

    // --- AH-2: full V5R cycle survives the latch ---------------------------

    function testAH2_LatchClearsOnTranche2AndFreshTrimFires() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        _feedV5RHead();
        assertFalse(reactive.exitLatched(), "latch cleared after tranche-2 close");
        // Stage D: bleed x0.98 x11 from $103.5 (updates 21-31).
        uint256 delivered = sys.callbackCount();
        uint256 price = 1035e17;
        for (uint256 i = 0; i < 11; i++) {
            price = price * 98 / 100;
            _push(price, T0 + (20 + i) * 3600);
            delivered = _deliverFrom(delivered);
            if (i == 4) assertEq(sys.callbackCount(), 5, "TRIM@25 fires after tranche-2");
            if (i == 4) assertEq(_callbackAction(4), 1, "the update-25 fire is TRIM");
        }
        assertEq(sys.callbackCount(), 6, "TRIM, EXIT, RERISK, RERISK_FINAL, TRIM, EXIT");
        assertEq(_callbackAction(4), 1);
        assertEq(_callbackAction(5), 2);
        assertTrue(reactive.exitLatched(), "latch set again by EXIT@31");
        assertEq(vault.protectionCount(), 6, "all six callbacks executed");
        assertEq(reactive.reriskCount(), 2, "two tranches, one episode");
        assertTrue(vault.closed(), "final EXIT closes the vault");
    }

    // --- AH-3: the 1-wei cliff is gone -------------------------------------

    function testAH3_OneWeiPriceConsumedNotIngested() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        assertEq(vault.managedRisk(), 10 ether);
        _push(2000e18, T0);
        _push(2000e18, T0 + 3600);
        _push(2000e18, T0 + 7200);
        assertEq(reactive.updates(), 3, "three calm prints ingested");
        assertEq(reactive.lastAction(), 0, "calm votes HOLD");
        // A 1-wei print: consumed (marked seen), never ingested.
        oracle.setPrice(address(weth), 1);
        _feed(1, T0 + 10800);
        assertEq(reactive.updates(), 3, "1-wei print is NOT ingested");
        assertEq(sys.callbackCount(), 0, "no callback on the 1-wei print");
        assertEq(reactive.lastAction(), 0, "last vote still HOLD");
        // The brain keeps working on sane prints.
        _push(2000e18, T0 + 14400);
        _push(2000e18, T0 + 18000);
        assertEq(reactive.updates(), 5, "sane prints ingest after the poison");
        // The $1 boundary itself is inclusive: it ingests.
        _push(1e18, T0 + 21600);
        assertEq(reactive.updates(), 6, "$1 exactly ingests");
        assertEq(vault.managedRisk(), 10 ether, "position never sold");
    }

    function testAH3_SwapRefusesSubDollarFill() public {
        // Direct desk probe: a second swap wired to this test contract
        // (V6 setVault is single-use, so the main desk cannot be
        // re-pointed for probing — by design).
        SentinelSwapV3 probe = new SentinelSwapV3(address(weth), address(usdc), address(oracle), address(this));
        usdc.mint(address(probe), 1_000_000 ether);
        weth.mint(address(this), 10 ether);
        weth.approve(address(probe), type(uint256).max);
        usdc.mint(address(this), 10_000 ether);
        usdc.approve(address(probe), type(uint256).max);

        oracle.setPrice(address(weth), 1);
        vm.expectEmit(true, false, false, true, address(probe));
        emit SentinelSwapV3.InsanePriceRefused(1);
        assertEq(probe.swapRiskForSafe(1 ether), 0, "1-wei fill refused");
        oracle.setPrice(address(weth), 5e17); // $0.50
        assertEq(probe.swapRiskForSafe(1 ether), 0, "$0.50 fill refused");
        assertEq(probe.swapSafeForRisk(1000 ether), 0, "$0.50 reverse refused");
        oracle.setPrice(address(weth), 1e18); // exactly $1: boundary inclusive
        assertEq(probe.swapRiskForSafe(1 ether), 1 ether, "$1 fills exactly 1 mUSDC");
        oracle.setPrice(address(weth), 2000e18);
        assertEq(probe.swapRiskForSafe(1 ether), 2000 ether, "$2000 fills normally");
    }

    // --- AH-4: an absurd price cannot brick the callback -------------------

    function testAH4_AbsurdPriceCannotBrickCallback() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        // Bleed until the brain fires EXIT (same shape as H12).
        uint256 price = 2000e18;
        for (uint256 i = 0; i < 40; i++) {
            _push(price, T0 + i * 3600);
            price = price * 99 / 100;
            if (sys.callbackCount() > 0 && _callbackAction(sys.callbackCount() - 1) == 2) break;
        }
        assertGe(sys.callbackCount(), 1, "brain fired");
        assertEq(_callbackAction(sys.callbackCount() - 1), 2, "the fire is EXIT");
        // Between the decision and the callback landing, the price is
        // pushed absurd (2^200). On V5 the swap overflowed and the
        // callback reverted; on V6 it refuses fail-soft.
        oracle.setPrice(address(weth), 2 ** 200);
        _callback(2); // must NOT revert
        assertEq(vault.protectionCount(), 1, "callback executed (no-op fill)");
        assertEq(vault.managedRisk(), 10 ether, "nothing sold at the absurd price");
        assertTrue(vault.closed(), "EXIT still closes, like the stale path");
        // Both swap directions refuse at 2^200 and fill once sane.
        SentinelSwapV3 probe = new SentinelSwapV3(address(weth), address(usdc), address(oracle), address(this));
        usdc.mint(address(probe), 1_000_000 ether);
        weth.mint(address(this), 10 ether);
        weth.approve(address(probe), type(uint256).max);
        usdc.mint(address(this), 10_000 ether);
        usdc.approve(address(probe), type(uint256).max);
        assertEq(probe.swapRiskForSafe(1 ether), 0, "2^200 forward refused");
        assertEq(probe.swapSafeForRisk(1000 ether), 0, "2^200 reverse refused");
        oracle.setPrice(address(weth), 2000e18);
        assertEq(probe.swapRiskForSafe(1 ether), 2000 ether, "sane price fills again");
    }

    // --- AH-5: the 20% band -----------------------------------------------

    function testAH5_Pump20PercentTheftIsSmall() public {
        _mixedPool();
        // Pump exactly +20% to the band edge, then deposit 5 WETH and
        // redeem it at the true $2000.
        oracle.setPrice(address(weth), 2400e18);
        _fund(attacker, 5 ether);
        uint256 shares = vault.sharesOf(attacker);
        vm.prank(attacker);
        vault.deposit(5 ether);
        shares = vault.sharesOf(attacker) - shares;
        uint256 wBefore = weth.balanceOf(attacker);
        uint256 sBefore = usdc.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeemAll();
        uint256 value = _valueAt2000(weth.balanceOf(attacker) - wBefore, usdc.balanceOf(attacker) - sBefore);
        // The steal: poolEq at $2400 = 5 + 10000/2400 = 9.1667 WETH,
        // so 5 WETH mints 5.4545 shares; redeemed at true $2000 that
        // is ~5.28 WETH eq. V5 (50% band) stole +12.5% (5.625).
        console.log("AH5a V6 pump +20%: attacker value (WETH eq):", value);
        console.log("AH5a V6 shares minted:", shares);
        assertEq(value, 5294117647058823528, "V6 pump value, pinned exact");
        assertEq(shares, 5454545454545454545, "V6 pump shares, pinned exact");
        assertLt(value, 5625000000000000000, "theft at the 20% edge is small (V5: 5.625)");
    }

    function testAH5_Dump20PercentVictimLossIsSmall() public {
        _mixedPool();
        // Dump exactly -20% to the band edge, then Bob deposits 5 WETH
        // and redeems at the true $2000.
        oracle.setPrice(address(weth), 1600e18);
        _fund(bob, 5 ether);
        vm.prank(bob);
        vault.deposit(5 ether);
        uint256 wBefore = weth.balanceOf(bob);
        uint256 sBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.redeemAll();
        uint256 value = _valueAt2000(weth.balanceOf(bob) - wBefore, usdc.balanceOf(bob) - sBefore);
        console.log("AH5b V6 dump -20%: victim value (WETH eq):", value);
        assertEq(value, 4615384615384615383, "V6 dump value, pinned exact");
        assertGt(value, 3787000000000000000, "victim keeps far more than V5's 3.787");
    }

    function testAH5_Walk12StepsTheftIsSmall() public {
        _mixedPool();
        // Walk +20% per step, 12 steps, settling 0.1 WETH each time.
        // V5 walked to ~100x and stole +41.2%; V6 reaches only ~8.9x.
        uint256 price = 2000e18;
        for (uint256 i = 0; i < 12; i++) {
            price = price * 6 / 5;
            oracle.setPrice(address(weth), price);
            _fund(attacker, 0.1 ether);
            vm.prank(attacker);
            vault.deposit(0.1 ether);
            // Each deposit settles at its own price (anchor moves), so
            // the walk proceeds +20% per step, exactly like the V5 PoC.
        }
        oracle.setPrice(address(weth), price);
        _fund(attacker, 5 ether);
        vm.prank(attacker);
        vault.deposit(5 ether);
        uint256 wBefore = weth.balanceOf(attacker);
        uint256 sBefore = usdc.balanceOf(attacker);
        vm.prank(attacker);
        vault.redeemAll();
        uint256 value = _valueAt2000(weth.balanceOf(attacker) - wBefore, usdc.balanceOf(attacker) - sBefore);
        console.log("AH5c V6 walk 12x20%: attacker value (WETH eq):", value);
        console.log("AH5c V6 walked price:", vault.lastSettledPrice());
        // The 20% band does NOT crush the walk — it only slows it. After
        // 12 steps the price is 8.9x ($17,832) instead of V5's 129.7x
        // ($259,492), and the theft is 8.286 (+33.6% on 6.2 in) instead
        // of V5's 8.754 (+41.2%). The band is a speed bump, not a wall:
        // ~25 steps still reach ~100x. (V6-DESIGN.md section 6, risk 4.)
        assertEq(value, 8286116313305057708, "V6 walk value, pinned exact");
        assertLt(value, 8753517106336923682, "walk theft below V5's 8.754");
        assertLt(vault.lastSettledPrice(), 20000e18, "12 steps at 20% reach only 8.9x");
    }

    function testAH5_BandEdgeRevertsBeyond20Percent() public {
        _mixedPool();
        // +21% reverts, +20% passes; the +20% deposit moves the anchor
        // to $2400, so the dump side is measured from $2400: -21% ($1896)
        // reverts, -20% ($1920) passes.
        oracle.setPrice(address(weth), 2420e18);
        _fund(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(SentinelVaultV6.PriceDeviation.selector, 2420e18, 2000e18));
        vault.deposit(1 ether);
        oracle.setPrice(address(weth), 2400e18);
        vm.prank(attacker);
        vault.deposit(1 ether); // exactly +20%: boundary inclusive
        assertEq(vault.lastSettledPrice(), 2400e18, "the deposit settles the anchor");
        oracle.setPrice(address(weth), 1896e18);
        _fund(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SentinelVaultV6.PriceDeviation.selector, 1896e18, 2400e18));
        vault.deposit(1 ether);
        oracle.setPrice(address(weth), 1920e18);
        vm.prank(bob);
        vault.deposit(1 ether); // exactly -20% from the moved anchor
    }

    // --- AH-6: wiring is single-use ---------------------------------------

    function testAH6_SetVaultSecondCallReverts() public {
        assertTrue(swap.vaultLocked(), "swap wiring locked at deploy");
        assertTrue(reactive.vaultLocked(), "brain wiring locked at deploy");
        assertEq(address(swap.vault()), address(vault), "swap wired to the vault");
        assertEq(reactive.vault(), address(vault), "brain wired to the vault");
        vm.expectRevert(
            abi.encodeWithSignature("VaultAlreadySet(address)", address(vault))
        );
        swap.setVault(attacker);
        vm.expectRevert(
            abi.encodeWithSignature("VaultAlreadySet(address)", address(vault))
        );
        reactive.setVault(attacker);
        assertEq(address(swap.vault()), address(vault), "swap wiring unchanged");
        assertEq(reactive.vault(), address(vault), "brain wiring unchanged");
    }

    function testAH6_RedirectionAttemptKeepsProtection() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether);
        // Both redirection attempts fail; protection still fires.
        vm.expectRevert(
            abi.encodeWithSignature("VaultAlreadySet(address)", address(vault))
        );
        swap.setVault(attacker);
        vm.expectRevert(
            abi.encodeWithSignature("VaultAlreadySet(address)", address(vault))
        );
        reactive.setVault(attacker);
        uint256 price = 2000e18;
        for (uint256 i = 0; i < 40; i++) {
            _push(price, T0 + i * 3600);
            price = price * 99 / 100;
            if (sys.callbackCount() > 0) break;
        }
        assertGe(sys.callbackCount(), 1, "brain still fires after redirection attempts");
        assertEq(sys.lastCallback().recipient, address(vault), "callback still targets the real vault");
        _callback(_callbackAction(0));
        assertEq(vault.protectionCount(), 1, "protection executes on the real vault");
        assertEq(vault.managedRisk(), 5 ether, "TRIM sold half");
    }

    // --- June 2022 core, mirror-exact --------------------------------------

    /// @notice Replays the exact June 2022 56-push stream (klines 120-175)
    ///         with the R8 choreography: A 0.003 before push 1, B 0.002
    ///         after TRIM at 9, A partial redeem 1e15 after TRIM at 32, C 0.0015
    ///         after TRIM at 44. Expected: TRIM at 9/21/32/44/55, EXIT at 56,
    ///         30 suppressed, reconciliation to the wei — identical to R8.
    function testV6_JuneCoreMirrorExact() public {
        uint256[56] memory prices = [
            uint256(167928e16), 167600e16, 167388e16, 166963e16, 167740e16, 166895e16, 166570e16, 166746e16,
            157819e16, 159673e16, 158681e16, 157596e16, 155324e16, 157242e16, 152662e16, 151760e16,
            153575e16, 153395e16, 155118e16, 154648e16, 152334e16, 153945e16, 154813e16, 153289e16,
            153764e16, 151385e16, 145329e16, 146697e16, 145285e16, 143103e16, 145833e16, 147126e16,
            147062e16, 146386e16, 146048e16, 146898e16, 146309e16, 144776e16, 151010e16, 152592e16,
            150661e16, 152150e16, 151279e16, 147959e16, 147742e16, 147446e16, 145641e16, 143484e16,
            138740e16, 136436e16, 133941e16, 135083e16, 134969e16, 132304e16, 132435e16, 128346e16
        ];
        // Expected action per update (0 = no callback): TRIM@9/21/32/44/55, EXIT@56.
        uint8[56] memory expected = [
            uint8(0), 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 1, 2
        ];
        vm.recordLogs();
        _fund(alice, 0.003 ether);
        _fund(bob, 0.002 ether);
        _fund(stranger, 0.0015 ether);
        vm.prank(alice);
        vault.deposit(0.003 ether);
        assertEq(vault.totalShares(), 3e15, "A seeds 1:1");
        uint256 delivered;
        for (uint256 i = 0; i < 56; i++) {
            uint256 before = sys.callbackCount();
            _push(prices[i], T0 + i * 3600);
            delivered = _deliverFrom(delivered);
            uint256 afterCount = sys.callbackCount();
            if (expected[i] != 0) {
                assertEq(afterCount, before + 1, "exactly one callback at the expected update");
                assertEq(_callbackAction(afterCount - 1), expected[i], "callback action matches the mirror");
            } else {
                assertEq(afterCount, before, "no callback on this update");
            }
            if (i == 8) {
                assertEq(vault.managedRisk(), 0.0015 ether, "TRIM@9 halves risk");
                assertEq(vault.managedSafe(), 2367285e12, "TRIM@9 safe");
                vm.prank(bob);
                vault.deposit(0.002 ether);
                assertEq(vault.totalShares(), 5e15, "B joins 1:1");
            }
            if (i == 20) {
                assertEq(vault.managedRisk(), 0.00175 ether, "TRIM@21");
                assertEq(vault.managedSafe(), 5033130e12, "TRIM@21 safe");
            }
            if (i == 31) {
                assertEq(vault.managedRisk(), 0.000875 ether, "TRIM@32");
                assertEq(vault.managedSafe(), 63204825e11, "TRIM@32 safe");
                uint256 aRisk = weth.balanceOf(alice);
                uint256 aSafe = usdc.balanceOf(alice);
                vm.prank(alice);
                vault.redeem(1e15);
                assertEq(weth.balanceOf(alice) - aRisk, 0.000175 ether, "A partial: WETH");
                assertEq(usdc.balanceOf(alice) - aSafe, 12640965e11, "A partial: mUSDC");
                assertEq(vault.managedRisk(), 0.0007 ether, "after partial redeem");
                assertEq(vault.managedSafe(), 5056386e12, "after partial redeem safe");
            }
            if (i == 43) {
                assertEq(vault.managedRisk(), 0.00035 ether, "TRIM@44");
                assertEq(vault.managedSafe(), 55742425e11, "TRIM@44 safe");
                vm.prank(stranger);
                vault.deposit(0.0015 ether);
                assertEq(vault.sharesOf(stranger), 1457221886906302, "C shares at the TRIM at 44 fill");
            }
            if (i == 54) {
                assertEq(vault.managedRisk(), 0.000925 ether, "TRIM@55");
                assertEq(vault.managedSafe(), 679926625e10, "TRIM@55 safe");
            }
        }
        assertEq(reactive.updates(), 56, "56 updates ingested");
        assertEq(reactive.lastAction(), 2, "final vote EXIT");
        assertEq(sys.callbackCount(), 6, "six callbacks total");
        assertTrue(vault.closed(), "EXIT@56 closes the vault");
        assertEq(vault.totalShares(), 5.457221886906302e15, "shares outstanding");
        assertEq(vault.managedRisk(), 0, "risk drained");
        assertEq(vault.managedSafe(), 798646675e10, "safe = 7.98646675 mUSDC");
        // 30 TrimSuppressed events, exactly as the mirror predicts.
        bytes32 suppressedTopic = keccak256("TrimSuppressed(uint256,uint256,uint256)");
        uint256 suppressed;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == suppressedTopic) suppressed++;
        }
        assertEq(suppressed, 30, "30 TRIM votes suppressed");
        // Final redemption: reconciliation to the wei.
        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeemAll();
        assertEq(usdc.balanceOf(alice) - aBefore, 2926934955370680890, "A final mUSDC");
        uint256 bBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.redeemAll();
        assertEq(usdc.balanceOf(bob) - bBefore, 2926934955370680890, "B final mUSDC (= A, INV-4)");
        uint256 cBefore = usdc.balanceOf(stranger);
        vm.prank(stranger);
        vault.redeemAll();
        assertEq(usdc.balanceOf(stranger) - cBefore, 2132596839258638220, "C final mUSDC");
        assertEq(vault.totalShares(), 0, "pool resets");
        assertEq(vault.managedRisk(), 0, "risk resets");
        assertEq(vault.managedSafe(), 0, "safe resets");
        assertEq(usdc.balanceOf(address(swap)), 99999074943675e10, "desk mUSDC");
        assertEq(weth.balanceOf(address(swap)), 0.006325 ether, "desk WETH");
        // Conservation (forge seed is 1,000,000 mUSDC, live seed 1,000):
        // users 0.000175 WETH + desk 0.006325 = 0.0065;
        // users 9.25056325 mUSDC + desk 999,990.74943675 = 1,000,000.
        console.log("June V6 callbacks:", sys.callbackCount());
        console.log("June V6 suppressed:", suppressed);
        console.log("June V6 updates:", reactive.updates());
    }
}
