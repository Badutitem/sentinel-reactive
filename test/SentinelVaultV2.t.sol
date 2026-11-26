// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwap} from "../src/SentinelSwap.sol";
import {SentinelVaultV2} from "../src/SentinelVaultV2.sol";
import {SentinelReactive} from "../src/SentinelReactive.sol";
import {SentinelModel} from "../src/model/SentinelModel.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Unit tests for the real-asset vault: the position is a live WETH
///         balance, TRIM/EXIT move real tokens through the swap desk, and the
///         V1 double guard (callback proxy as caller + reactive contract as
///         injected sender) is unchanged.
contract SentinelVaultV2Test is Test {
    // Mirrors SentinelVaultV2.ACTION_TRIM / ACTION_EXIT (asserted in setUp).
    uint8 internal constant TRIM = 1;
    uint8 internal constant EXIT = 2;
    uint256 internal constant PRICE = 2000e18; // $2,000, 18-decimal USD convention.

    address internal proxy = makeAddr("callbackProxy");
    address internal reactive = makeAddr("sentinelReactive");
    address internal stranger = makeAddr("stranger");
    address internal user = makeAddr("user");

    MockPriceOracle internal oracle;
    MockERC20 internal weth; // WETH predeploy stand-in.
    MockUSDC internal usdc;
    SentinelSwap internal swap;
    SentinelVaultV2 internal vault;

    event ProtectionExecuted(address indexed reactive, uint8 action, uint256 positionBefore, uint256 positionAfter);
    event DeRisked(uint8 action, uint256 riskOut, uint256 safeIn);
    event ReserveShortfall(uint256 riskRequested, uint256 riskFilled);

    function setUp() public {
        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwap(address(weth), address(usdc), address(oracle), address(0));
        vault = new SentinelVaultV2(payable(proxy), reactive, address(weth), address(usdc), address(swap));
        swap.setVault(address(vault));
        oracle.setPrice(address(weth), PRICE);
        usdc.mint(address(swap), 1_000_000 ether);

        assertEq(vault.ACTION_TRIM(), TRIM);
        assertEq(vault.ACTION_EXIT(), EXIT);

        weth.mint(user, 100 ether);
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10 ether);
        vm.stopPrank();
    }

    function testDepositHoldsRealBalance() public {
        assertEq(weth.balanceOf(address(vault)), 10 ether);
        assertEq(vault.positionSize(), 10 ether, "positionSize is the live WETH balance");
        assertEq(weth.balanceOf(user), 90 ether);
        assertFalse(vault.closed());
        assertEq(vault.health(), 10 ether);
    }

    function testTrimMovesExactlyHalfToUsdc() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit DeRisked(TRIM, 5 ether, 10_000 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ProtectionExecuted(reactive, TRIM, 10 ether, 5 ether);
        vm.prank(proxy);
        vault.executeProtection(reactive, TRIM);

        assertEq(weth.balanceOf(address(vault)), 5 ether);
        assertEq(vault.positionSize(), 5 ether);
        assertEq(usdc.balanceOf(address(vault)), 10_000 ether, "5 WETH at $2,000, in USDC terms");
        assertEq(vault.safeBalance(), 10_000 ether);
        assertEq(weth.balanceOf(address(swap)), 5 ether);
        assertFalse(vault.closed());
        assertEq(vault.protectionCount(), 1);
    }

    function testExitEmptiesAndCloses() public {
        vm.prank(proxy);
        vault.executeProtection(reactive, EXIT);

        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(vault.positionSize(), 0);
        assertEq(usdc.balanceOf(address(vault)), 20_000 ether);
        assertTrue(vault.closed());
        assertEq(vault.health(), 0);
        assertEq(vault.protectionCount(), 1);
    }

    function testTrimThenExit() public {
        vm.prank(proxy);
        vault.executeProtection(reactive, TRIM);
        vm.prank(proxy);
        vault.executeProtection(reactive, EXIT);

        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 20_000 ether, "both halves sold at the same reference price");
        assertTrue(vault.closed());
        assertEq(vault.protectionCount(), 2);
    }

    function testWrongCallerReverts() public {
        // Caller is not the callback proxy -> AbstractPayer.NotAuthorized.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, proxy));
        vault.executeProtection(reactive, EXIT);
        assertEq(vault.positionSize(), 10 ether);
    }

    function testWrongSenderReverts() public {
        // Caller is the proxy, but the injected sender is not our reactive contract.
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, reactive));
        vault.executeProtection(stranger, EXIT);
        assertEq(vault.positionSize(), 10 ether);
    }

    function testCallbackOnEmptyVaultOnlyCounts() public {
        SentinelVaultV2 empty = new SentinelVaultV2(payable(proxy), reactive, address(weth), address(usdc), address(swap));
        vm.prank(proxy);
        empty.executeProtection(reactive, EXIT);
        assertEq(empty.protectionCount(), 1);
        assertEq(empty.positionSize(), 0);
        assertFalse(empty.closed(), "nothing to close: no position was open");
    }

    function testShortfallExitPartiallyFillsAndNeverReverts() public {
        // A desk whose $3,000 reserve covers only 1.5 of the 10 WETH position.
        SentinelSwap smallSwap = new SentinelSwap(address(weth), address(usdc), address(oracle), address(0));
        SentinelVaultV2 smallVault =
            new SentinelVaultV2(payable(proxy), reactive, address(weth), address(usdc), address(smallSwap));
        smallSwap.setVault(address(smallVault));
        usdc.mint(address(smallSwap), 3_000 ether);

        vm.startPrank(user);
        weth.approve(address(smallVault), type(uint256).max);
        smallVault.deposit(10 ether);
        vm.stopPrank();

        vm.expectEmit(false, false, false, true, address(smallSwap));
        emit ReserveShortfall(10 ether, 1.5 ether);
        vm.prank(proxy);
        smallVault.executeProtection(reactive, EXIT);

        assertEq(usdc.balanceOf(address(smallVault)), 3_000 ether, "the whole reserve, no more");
        assertEq(weth.balanceOf(address(smallVault)), 8.5 ether, "the uncovered remainder stays in the vault");
        assertTrue(smallVault.closed());
        assertEq(smallVault.protectionCount(), 1);

        // The remainder is recoverable by the owner instead of being stranded.
        smallVault.withdraw(address(weth), user, 8.5 ether);
        assertEq(weth.balanceOf(user), 88.5 ether); // 100 - 10 (main vault) - 10 (this vault) + 8.5 back
    }

    function testWithdrawOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SentinelVaultV2.NotOwner.selector, stranger));
        vault.withdraw(address(weth), stranger, 1 ether);
    }

    function testRepositAfterExitRearms() public {
        vm.prank(proxy);
        vault.executeProtection(reactive, EXIT);
        assertTrue(vault.closed());

        vm.startPrank(user);
        vault.deposit(4 ether);
        vm.stopPrank();
        assertFalse(vault.closed());
        assertEq(vault.positionSize(), 4 ether);
    }
}

/// @notice End-to-end: the full loop (oracle event -> reactive inference ->
///         network-style callback delivery) against VaultV2, asserting that
///         ERC20 balances actually move — the Release 1 upgrade over the V1
///         counter-only proof. Prices use the 18-decimal USD convention the
///         swap desk prices with; the model's ratio features are scale-free.
contract SentinelVaultV2EndToEndTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant PRICE_TOPIC0 = uint256(keccak256("PriceUpdated(address,uint256,uint256)"));
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant T0 = 1_700_000_000;

    address internal proxy = makeAddr("baseSepoliaCallbackProxy");

    MockSystemContract internal sys;
    MockPriceOracle internal oracle;
    MockERC20 internal weth;
    MockUSDC internal usdc;
    SentinelSwap internal swap;
    SentinelReactive internal reactive;
    SentinelVaultV2 internal vault;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));

        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwap(address(weth), address(usdc), address(oracle), address(0));
        reactive = new SentinelReactive(BASE_SEPOLIA, address(oracle), address(weth), BASE_SEPOLIA, 3600);
        vault = new SentinelVaultV2(payable(proxy), address(reactive), address(weth), address(usdc), address(swap));
        swap.setVault(address(vault));
        reactive.setVault(address(vault));

        usdc.mint(address(swap), 1_000_000 ether);
        weth.mint(address(this), 10 ether);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10 ether);
    }

    function _pushPrice(uint256 price, uint256 ts) internal {
        vm.warp(ts);
        oracle.setPrice(address(weth), price);
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(oracle),
            topic0: PRICE_TOPIC0,
            topic1: uint256(uint160(address(weth))),
            topic2: 0,
            topic3: 0,
            data: abi.encode(price, ts),
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
    }

    function _deliver(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) internal {
        assertEq(cfg.chainId, BASE_SEPOLIA);
        assertEq(cfg.recipient, address(vault));
        bytes memory body = new bytes(cfg.payload.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = cfg.payload[i + 4];
        }
        (address placeholder, uint8 action) = abi.decode(body, (address, uint8));
        assertEq(placeholder, address(0), "payload must reserve the sender slot");
        bytes memory delivered = abi.encodeWithSignature("executeProtection(address,uint8)", address(reactive), action);
        vm.prank(proxy);
        (bool ok,) = address(vault).call(delivered);
        assertTrue(ok, "callback delivery failed");
    }

    function testFullLoopCrashMovesRealTokens() public {
        _pushPrice(100e18, T0); // $100.0
        _pushPrice(100.5e18, T0 + 60);
        _pushPrice(99.8e18, T0 + 120);
        _pushPrice(100.2e18, T0 + 180);
        _pushPrice(100.1e18, T0 + 240);
        assertEq(sys.callbackCount(), 0, "calm market: no protection");

        _pushPrice(92e18, T0 + 300); // -8%  -> TRIM
        _pushPrice(81e18, T0 + 360); // -12% -> TRIM, cooldown
        _pushPrice(76e18, T0 + 420); // -6%  -> EXIT (escalation)
        assertEq(reactive.lastAction(), SentinelModel.EXIT);
        assertEq(sys.callbackCount(), 2, "TRIM + EXIT callbacks requested");

        // The swap desk prices at delivery time off the same oracle: $76.
        _deliver(sys.callbackAt(0)); // TRIM: sell 5 WETH at $76
        assertEq(weth.balanceOf(address(vault)), 5 ether);
        assertEq(usdc.balanceOf(address(vault)), 380 ether);
        assertFalse(vault.closed());

        _deliver(sys.callbackAt(1)); // EXIT: sell the remaining 5 WETH at $76
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 760 ether);
        assertTrue(vault.closed());
        assertEq(vault.protectionCount(), 2);
    }
}
