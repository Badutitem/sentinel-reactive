// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelVault} from "../src/SentinelVault.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";

/// @notice Unit tests for the destination-side vault: the de-risk actions and,
///         most importantly, the double authentication guard (callback proxy as
///         caller + reactive contract as injected sender). If either check can
///         be bypassed, anyone could force-close the position.
contract SentinelVaultTest is Test {
    // Mirrors SentinelVault.ACTION_TRIM / ACTION_EXIT (asserted in setUp).
    // Plain literals are used at call sites so a vm.prank is never consumed
    // by a getter call before the real call.
    uint8 internal constant TRIM = 1;
    uint8 internal constant EXIT = 2;

    address internal proxy = makeAddr("callbackProxy");
    address internal reactive = makeAddr("sentinelReactive");
    address internal stranger = makeAddr("stranger");

    SentinelVault internal vault;

    event ProtectionExecuted(address indexed reactive, uint8 action, uint256 positionBefore, uint256 positionAfter);

    function setUp() public {
        vault = new SentinelVault(payable(proxy), reactive);
        assertEq(vault.ACTION_TRIM(), TRIM);
        assertEq(vault.ACTION_EXIT(), EXIT);
        vault.openPosition(1000);
    }

    function testTrimHalvesPosition() public {
        vm.prank(proxy);
        vault.executeProtection(reactive, TRIM);
        assertEq(vault.positionSize(), 500);
        assertFalse(vault.closed());
        assertEq(vault.protectionCount(), 1);
    }

    function testExitClosesPosition() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit ProtectionExecuted(reactive, EXIT, 1000, 0);
        vm.prank(proxy);
        vault.executeProtection(reactive, EXIT);
        assertEq(vault.positionSize(), 0);
        assertTrue(vault.closed());
        assertEq(vault.health(), 0);
    }

    function testTrimThenExit() public {
        vm.prank(proxy);
        vault.executeProtection(reactive, TRIM);
        vm.prank(proxy);
        vault.executeProtection(reactive, EXIT);
        assertEq(vault.positionSize(), 0);
        assertTrue(vault.closed());
        assertEq(vault.protectionCount(), 2);
    }

    function testWrongCallerReverts() public {
        // Caller is not the callback proxy -> AbstractPayer.NotAuthorized.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, proxy));
        vault.executeProtection(reactive, EXIT);
        assertEq(vault.positionSize(), 1000);
    }

    function testWrongSenderReverts() public {
        // Caller is the proxy, but the injected sender is not our reactive contract.
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, reactive));
        vault.executeProtection(stranger, EXIT);
        assertEq(vault.positionSize(), 1000);
    }

    function testReopenAfterExit() public {
        vm.prank(proxy);
        vault.executeProtection(reactive, EXIT);
        vault.openPosition(750);
        assertEq(vault.positionSize(), 750);
        assertFalse(vault.closed());
    }
}
