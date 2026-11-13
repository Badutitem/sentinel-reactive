// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title SentinelWeights — quantized weights for the Sentinel MLP (6 -> 8 -> 3).
/// @notice TRAINED 2026-11-13 on synthetic price series by tools/train.py
///         (seed 20261113; 540 series across calm / uptrend /
///         chop / grind-down / crash / V-recovery scenarios, labelled by the
///         stop-loss policy ladder: drawdown >= 21% -> EXIT, 3-21% and still
///         falling -> TRIM, recovering -> HOLD, otherwise HOLD).
///         Dataset: 24051 train / 6001 held-out
///         windows. Float model accuracy: train 0.9716,
///         held-out 0.9710. Quantized integer model
///         (this file): train 0.9749, held-out
///         0.9747. The training script verified its integer
///         reference implementation bit-for-bit against the phase-1 Solidity
///         behaviour before training, and the shipped weights pass the
///         canonical acceptance vectors (calm -> HOLD, grind -> TRIM,
///         crash -> EXIT). Do not hand-edit the tables — regenerate them with
///         tools/train.py.
/// @dev Quantization: weights are integers scaled by 1000 (e.g. -1500 means
///      -1.5); biases are expressed in the activation scale (features/logits
///      are scaled by 1e6). Output layout: index 0 = HOLD, 1 = TRIM, 2 = EXIT.
library SentinelWeights {
    /// @notice Layer 1 weights, row-major [hidden][feature], 8 * 6 = 48 entries.
    ///         Feature order: [lastReturn, meanReturn, volatility, drawdown, momentum, priceVsMean].
    function weights1() internal pure returns (int256[48] memory w) {
        w = [
            int256(-3659),
            int256(-459),
            int256(-1531),
            int256(1230),
            int256(-2204),
            int256(-813), // h0
            int256(-1395),
            int256(1163),
            int256(2225),
            int256(-4455),
            int256(4545),
            int256(2266), // h1
            int256(2421),
            int256(-47),
            int256(894),
            int256(922),
            int256(-1064),
            int256(-68), // h2
            int256(3587),
            int256(-747),
            int256(2976),
            int256(4126),
            int256(-4274),
            int256(-871), // h3
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0),
            int256(0), // h4
            int256(2045),
            int256(620),
            int256(-694),
            int256(-3616),
            int256(3337),
            int256(81), // h5
            int256(-3797),
            int256(-622),
            int256(-3087),
            int256(1196),
            int256(-2484),
            int256(-1130), // h6
            int256(-694),
            int256(877),
            int256(3573),
            int256(-2889),
            int256(4605),
            int256(3414) // h7
        ];
    }

    /// @notice Layer 1 biases (activation scale, 1e6 = 1.0).
    function biases1() internal pure returns (int256[8] memory b) {
        b = [
            int256(-1520), // h0
            int256(478510), // h1
            int256(-87359), // h2
            int256(-542907), // h3
            int256(-118915), // h4
            int256(1910075), // h5
            int256(1320165), // h6
            int256(1393238) // h7
        ];
    }

    /// @notice Layer 2 weights, row-major [action][hidden], 3 * 8 = 24 entries.
    function weights2() internal pure returns (int256[24] memory w) {
        w = [
            int256(-2917),
            int256(4991),
            int256(1802),
            int256(5757),
            int256(0),
            int256(2374),
            int256(-4197),
            int256(4672), // HOLD
            int256(349),
            int256(-5786),
            int256(-1532),
            int256(-5834),
            int256(0),
            int256(3189),
            int256(2609),
            int256(-5455), // TRIM
            int256(2290),
            int256(-1254),
            int256(-1121),
            int256(969),
            int256(0),
            int256(-4409),
            int256(1953),
            int256(-951) // EXIT
        ];
    }

    /// @notice Layer 2 biases (logit scale, 1e6 = 1.0).
    function biases2() internal pure returns (int256[3] memory b) {
        b = [int256(-54781), int256(2228972), int256(-3539770)];
    }
}
