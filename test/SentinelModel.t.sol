// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SentinelModel} from "../src/model/SentinelModel.sol";

/// @notice Unit tests for the MLP forward pass. Expected logits were computed
///         with the off-chain reference implementation in tools/train.py
///         (mirrors Solidity's truncating division exactly) for the trained
///         phase-2 weights in SentinelWeights.sol — these tests pin the
///         Solidity math bit-for-bit against the Python reference
///         (tools/vectors.json). Regenerate with tools/train.py, never by hand.
contract SentinelModelTest is Test {
    function _features(int256 a, int256 b, int256 c, int256 d, int256 e, int256 f)
        internal
        pure
        returns (int256[6] memory feats)
    {
        feats = [a, b, c, d, e, f];
    }

    function _check(int256[6] memory feats, uint8 expectedAction, int256[3] memory expectedLogits) internal {
        (uint8 action, int256[3] memory logits,) = SentinelModel.predict(feats);
        assertEq(action, expectedAction, "action");
        for (uint256 k = 0; k < 3; k++) {
            assertEq(logits[k], expectedLogits[k], "logit");
        }
    }

    function testZeroFeaturesHold() public {
        int256[3] memory expected = [int256(7836455), int256(1395740), int256(-11308029)];
        _check(_features(0, 0, 0, 0, 0, 0), SentinelModel.HOLD, expected);
    }

    function testCalmFeaturesHold() public {
        int256[3] memory expected = [int256(8101337), int256(1171424), int256(-11413828)];
        _check(_features(1000, 400, 2000, 1000, 3000, 1000), SentinelModel.HOLD, expected);
    }

    function testGrindFeaturesTrim() public {
        int256[3] memory expected = [int256(-944896), int256(5767392), int256(-5134463)];
        _check(_features(-12000, -12000, 12000, 92000, -92000, -40000), SentinelModel.TRIM, expected);
    }

    function testCrashFeaturesExit() public {
        int256[6] memory feats = _features(-60000, -33000, 65000, 240000, -240000, -100000);
        (uint8 action, int256[3] memory logits, int256[8] memory hidden) = SentinelModel.predict(feats);
        assertEq(action, SentinelModel.EXIT, "action");
        int256[3] memory expectedLogits = [int256(-3342971), int256(-691672), int256(4425017)];
        for (uint256 k = 0; k < 3; k++) {
            assertEq(logits[k], expectedLogits[k], "logit");
        }
        // Hidden activations for the crash vector (ReLU outputs, 1e6 scale).
        int256[8] memory expectedHidden = [
            int256(1039112),
            int256(0),
            int256(310482),
            int256(1563064),
            int256(0),
            int256(44985),
            int256(2364056),
            int256(0)
        ];
        for (uint256 i = 0; i < 8; i++) {
            assertEq(hidden[i], expectedHidden[i], "hidden");
        }
    }

    function testStrongUptrendHolds() public {
        // Rising market with healthy momentum: protection must NOT fire.
        (uint8 action,,) = SentinelModel.predict(_features(15000, 12000, 9000, 0, 110000, 45000));
        assertEq(action, SentinelModel.HOLD, "uptrend should hold");
    }
}
