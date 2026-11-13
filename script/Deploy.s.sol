// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {SentinelReactive} from "../src/SentinelReactive.sol";
import {SentinelVault} from "../src/SentinelVault.sol";

/// @title Deploy — single-chain rehearsal deployment.
/// @notice Deploys oracle + reactive + vault on ONE chain and wires them, for
///         local rehearsal (anvil) and flow checks. PRODUCTION deployment is
///         split across chains (oracle + vault on Base Sepolia, reactive on
///         Lasna) in the order: reactive -> vault -> setVault -> fund; see the
///         README's deployment section. On a plain EVM chain the constructor's
///         subscribe call lands on an empty system address and is a no-op —
///         subscriptions only take effect on Reactive Lasna.
/// @dev Env vars (all optional):
///        ORIGIN_CHAIN_ID (84532), DEST_CHAIN_ID (84532),
///        TOKEN (0x...dEaD stand-in), CALLBACK_PROXY (Base Sepolia proxy),
///        COOLDOWN_SECONDS (300), POSITION_SIZE (1000),
///        REACTIVE_FUNDING (0.05 ether, paid to SentinelReactive at deploy).
contract Deploy is Script {
    function run() external {
        uint256 originChain = vm.envOr("ORIGIN_CHAIN_ID", uint256(84532));
        uint256 destChain = vm.envOr("DEST_CHAIN_ID", uint256(84532));
        address token = vm.envOr("TOKEN", address(0x000000000000000000000000000000000000dEaD));
        address proxy = vm.envOr("CALLBACK_PROXY", address(0x476F44b11F5C942c58f4c8E3d0300E5710743585));
        uint256 cooldown = vm.envOr("COOLDOWN_SECONDS", uint256(300));
        uint256 position = vm.envOr("POSITION_SIZE", uint256(1000));
        uint256 funding = vm.envOr("REACTIVE_FUNDING", uint256(0.05 ether));

        vm.startBroadcast();
        MockPriceOracle oracle = new MockPriceOracle();
        SentinelReactive reactive =
            new SentinelReactive{value: funding}(originChain, address(oracle), token, destChain, cooldown);
        SentinelVault vault = new SentinelVault(payable(proxy), address(reactive));
        reactive.setVault(address(vault));
        vault.openPosition(position);
        vm.stopBroadcast();

        console.log("MockPriceOracle :", address(oracle));
        console.log("SentinelReactive:", address(reactive));
        console.log("SentinelVault   :", address(vault));
    }
}
