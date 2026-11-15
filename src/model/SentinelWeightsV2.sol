// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title SentinelWeightsV2 — CANDIDATE quantized weights for the Sentinel
///        MLP v2 (7 -> 12 -> 3). NOT wired into any contract; the shipped
///        model remains SentinelWeights (v1). See ANCHOR.md for the full
///        design + validation report.
/// @notice TRAINED 2026-11-16 (offline) by tools/train.py v2 path
///         (seed 20261116; 900 series across calm /
///         uptrend / chop / grind-down / crash / V-recovery / slow-grind /
///         staircase / bleed-with-recoveries / sawtooth, labelled by teacher v2: the
///         v1 ladder — drawdown >= 21% -> EXIT, 3-21% -> TRIM, recovering
///         -> HOLD — plus anchor bands on feature 6 (anchorDrawdown, from
///         a leaky peak decaying x999/1000 per update): anchorDrawdown
///         >= 18% with negative window momentum -> EXIT, >= 10% -> TRIM).
///         Dataset: 43433 train / 10443
///         held-out windows. Float model accuracy: train
///         0.9515, held-out 0.9541.
///         Quantized integer model (this file): train
///         0.9514, held-out 0.9541.
///         Do not hand-edit the tables — regenerate with
///         `python3 tools/train.py v2`.
/// @dev Quantization: weights are integers scaled by 1000; biases are in
///      the activation scale (features/logits scaled by 1e6). Output
///      layout: index 0 = HOLD, 1 = TRIM, 2 = EXIT.
library SentinelWeightsV2 {
    /// @notice Layer 1 weights, row-major [hidden][feature], 12 * 7 = 84 entries.
    ///         Feature order: [lastReturn, meanReturn, volatility, drawdown, momentum, priceVsMean, anchorDrawdown].
    function weights1() internal pure returns (int256[84] memory w) {
        w = [
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0), // h0
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0), // h1
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0), // h2
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0), // h3
            int256(0),
            int256(0),
            int256(0),
            int256(-68),
            int256(68),
            int256(14),
            int256(435), // h4
            int256(-106),
            int256(-900),
            int256(-3285),
            int256(1178),
            int256(-1332),
            int256(-864),
            int256(2686), // h5
            int256(2355),
            int256(236),
            int256(7656),
            int256(5705),
            int256(1141),
            int256(1624),
            int256(3192), // h6
            int256(-2137),
            int256(435),
            int256(1361),
            int256(-482),
            int256(-391),
            int256(-477),
            int256(-9716), // h7
            int256(2880),
            int256(843),
            int256(-2666),
            int256(-6449),
            int256(748),
            int256(2472),
            int256(-1446), // h8
            int256(1199),
            int256(-699),
            int256(622),
            int256(3954),
            int256(-1661),
            int256(-2686),
            int256(-5381), // h9
            int256(-120),
            int256(-762),
            int256(-2769),
            int256(1307),
            int256(-1633),
            int256(-929),
            int256(2681), // h10
            int256(-2383),
            int256(-416),
            int256(-1058),
            int256(1705),
            int256(-5995),
            int256(-2658),
            int256(-313) // h11
        ];
    }

    /// @notice Layer 1 biases (activation scale, 1e6 = 1.0).
    function biases1() internal pure returns (int256[12] memory b) {
        b = [
            int256(-136815), // h0
            int256(-64010), // h1
            int256(-356004), // h2
            int256(-101782), // h3
            int256(-338639), // h4
            int256(381198), // h5
            int256(-642933), // h6
            int256(1929447), // h7
            int256(444265), // h8
            int256(884013), // h9
            int256(283592), // h10
            int256(348124) // h11
        ];
    }

    /// @notice Layer 2 weights, row-major [action][hidden], 3 * 12 = 36 entries.
    function weights2() internal pure returns (int256[36] memory w) {
        w = [
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(29),
            int256(-3415),
            int256(7883),
            int256(6283),
            int256(6500),
            int256(1570),
            int256(-3536),
            int256(-2113), // HOLD
            int256(0),
            int256(0),
            int256(-2),
            int256(0),
            int256(159),
            int256(1931),
            int256(-5496),
            int256(2718),
            int256(-5259),
            int256(5088),
            int256(885),
            int256(-4747), // TRIM
            int256(0),
            int256(0),
            int256(1),
            int256(0),
            int256(-321),
            int256(1553),
            int256(-3928),
            int256(-6328),
            int256(-993),
            int256(-4951),
            int256(795),
            int256(3715) // EXIT
        ];
    }

    /// @notice Layer 2 biases (logit scale, 1e6 = 1.0).
    function biases2() internal pure returns (int256[3] memory b) {
        b = [int256(276631), int256(572040), int256(-1248887)];
    }
}
