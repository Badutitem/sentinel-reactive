// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelReactiveV3} from "../src/SentinelReactiveV3.sol";
import {SentinelReactive} from "../src/SentinelReactive.sol";
import {SentinelModelV2} from "../src/model/SentinelModelV2.sol";
import {SentinelModel} from "../src/model/SentinelModel.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {SentinelSwap} from "../src/SentinelSwap.sol";
import {SentinelVaultV2} from "../src/SentinelVaultV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice End-to-end for SentinelReactiveV3: the v2 e2e scenario (a
///         steady -2%/step bleed a v1 reactive structurally cannot
///         EXIT) through the repair-release contract, with the firing
///         semantics updated for REPAIR 3 (TRIM suppression):
///         v2 fired 29 callbacks on this stream (every vote); v3 fires
///         21 — the first TRIM, then the EXIT at update 12 and every
///         EXIT after it (each EXIT resets the fired state, and EXITs
///         are never suppressed), while the eight repeat TRIM votes at
///         updates 4-11 are suppressed. The vault still ends fully
///         closed with every wei of WETH sold: suppression costs no
///         protection on a real bleed, it only stops paying callback
///         fees for repeat TRIMs.
/// @dev Log identities are unique per push (dedup is active in v3).
contract SentinelReactiveV3EndToEndTest is Test {
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
    SentinelReactiveV3 internal reactive;
    SentinelReactive internal reactiveV1;
    SentinelVaultV2 internal vault;
    uint256 internal _nonce;

    function setUp() public {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        sys = MockSystemContract(payable(SYSTEM_ADDR));

        oracle = new MockPriceOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockUSDC();
        swap = new SentinelSwap(address(weth), address(usdc), address(oracle), address(0));
        reactive = new SentinelReactiveV3(BASE_SEPOLIA, address(oracle), address(weth), BASE_SEPOLIA, 300);
        reactiveV1 = new SentinelReactive(BASE_SEPOLIA, address(oracle), address(weth), BASE_SEPOLIA, 300);
        vault = new SentinelVaultV2(payable(proxy), address(reactive), address(weth), address(usdc), address(swap));
        swap.setVault(address(vault));
        reactive.setVault(address(vault));
        // reactiveV1 deliberately gets no vault: it is the control group.
        // NOTE: v1 has no dedup, so sharing one log stream is safe for it;
        // v3 receives each log exactly once, as the network would deliver.

        usdc.mint(address(swap), 1_000_000 ether);
        weth.mint(address(this), 10 ether);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(10 ether);
    }

    function _pushPrice(uint256 price, uint256 ts) internal {
        vm.warp(ts);
        oracle.setPrice(address(weth), price);
        _nonce++;
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
            txHash: _nonce * 7919,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
        vm.prank(SYSTEM_ADDR);
        reactiveV1.react(log_);
        if (reactiveV1.updates() >= 3) {
            assertTrue(reactiveV1.lastAction() != SentinelModel.EXIT, "v1 must never EXIT a slow bleed");
        }
    }

    function _callbackAction(ISystemContract.CallbackConfiguration_V_1_0 memory cfg) internal pure returns (uint8) {
        bytes memory body = new bytes(cfg.payload.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = cfg.payload[i + 4];
        }
        (, uint8 action) = abi.decode(body, (address, uint8));
        return action;
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

    function testSlowBleedExitClosesVault() public {
        // $100 falling exactly 2% per step (integer recurrence p * 98 / 100),
        // 31 prices — the v2 e2e series, unchanged.
        uint256[31] memory prices = [
            uint256(100000000000000000000),
            uint256(98000000000000000000),
            uint256(96040000000000000000),
            uint256(94119200000000000000),
            uint256(92236816000000000000),
            uint256(90392079680000000000),
            uint256(88584238086400000000),
            uint256(86812553324672000000),
            uint256(85076302258178560000),
            uint256(83374776213014988800),
            uint256(81707280688754689024),
            uint256(80073135074979595243),
            uint256(78471672373480003338),
            uint256(76902238926010403271),
            uint256(75364194147490195205),
            uint256(73856910264540391300),
            uint256(72379772059249583474),
            uint256(70932176618064591804),
            uint256(69513533085703299967),
            uint256(68123262423989233967),
            uint256(66760797175509449287),
            uint256(65425581231999260301),
            uint256(64117069607359275094),
            uint256(62834728215212089592),
            uint256(61578033650907847800),
            uint256(60346472977889690844),
            uint256(59139543518331897027),
            uint256(57956752647965259086),
            uint256(56797617595005953904),
            uint256(55661665243105834825),
            uint256(54548431938243718128)
        ];
        for (uint256 i = 0; i < prices.length; i++) {
            _pushPrice(prices[i], T0 + i * 3600);
        }

        assertEq(reactive.lastAction(), SentinelModelV2.EXIT);
        assertEq(reactiveV1.lastAction(), SentinelModel.TRIM, "v1 ends the bleed still only trimming");
        // V3 firing on this stream (mirror-measured): TRIM at update 3,
        // TRIM votes at updates 4-11 suppressed, EXIT at update 12 and
        // every update after (20 EXITs). 21 callbacks, vs v2's 29.
        assertEq(sys.callbackCount(), 21);
        assertEq(_callbackAction(sys.callbackAt(0)), SentinelModelV2.TRIM);
        assertEq(_callbackAction(sys.callbackAt(1)), SentinelModelV2.EXIT, "first EXIT callback");
        assertEq(reactive.duplicatesIgnored(), 0);

        for (uint256 i = 0; i < 21; i++) {
            _deliver(sys.callbackAt(i));
        }
        // All 10 WETH sold: the TRIM took half, the first EXIT the rest,
        // every fill priced at the final oracle print ($54.5484...).
        // The total is exactly 2 fills of 5 WETH x the final price with
        // no division dust (545_484_319_382_437_181_280) — 3 wei MORE
        // than v2's 29-callback ratchet produced on the same stream,
        // because v2's repeated halving shed 3 wei of integer dust that
        // v3's two clean fills do not.
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 545_484_319_382_437_181_280);
        assertTrue(vault.closed());
        assertEq(vault.protectionCount(), 21);
    }
}
