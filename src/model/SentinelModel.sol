// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {SentinelWeights} from "./SentinelWeights.sol";

/// @title SentinelModel — tiny fixed-point MLP inference (6 -> 8 -> 3), pure Solidity.
/// @notice This is the "AI" of Sentinel: a real (if small) neural network whose
///         forward pass runs inside the reactive contract on every price event.
///         Architecture: 6 features -> 8 ReLU hidden units -> 3 logits
///         (HOLD / TRIM / EXIT), argmax wins. All math is signed fixed point:
///         features and activations are scaled by 1e6, weights by 1e3, and each
///         neuron accumulates exact integer products with a single truncating
///         division at the end (Solidity `/` on int256 truncates toward zero —
///         the off-chain reference implementation mirrors this exactly, and the
///         unit tests assert bit-exact logits).
library SentinelModel {
    uint8 internal constant HOLD = 0;
    uint8 internal constant TRIM = 1;
    uint8 internal constant EXIT = 2;

    uint256 internal constant N_IN = 6;
    uint256 internal constant N_HIDDEN = 8;
    uint256 internal constant N_OUT = 3;
    int256 internal constant WEIGHT_DENOM = 1000;

    /// @notice Runs the forward pass.
    /// @param features Six features scaled by 1e6:
    ///        [lastReturn, meanReturn, volatility, drawdown, momentum, priceVsMean].
    /// @return action Argmax action: 0 = HOLD, 1 = TRIM, 2 = EXIT (ties resolve to the lowest index).
    /// @return logits The three output logits (1e6 scale), for on-chain observability.
    /// @return hidden The eight hidden activations after ReLU (1e6 scale).
    function predict(int256[6] memory features)
        internal
        pure
        returns (uint8 action, int256[3] memory logits, int256[8] memory hidden)
    {
        int256[48] memory w1 = SentinelWeights.weights1();
        int256[8] memory b1 = SentinelWeights.biases1();
        int256[24] memory w2 = SentinelWeights.weights2();
        int256[3] memory b2 = SentinelWeights.biases2();

        // Hidden layer: h = relu(W1 · f / 1000 + b1)
        for (uint256 i = 0; i < N_HIDDEN; i++) {
            int256 acc = 0;
            for (uint256 j = 0; j < N_IN; j++) {
                acc += w1[i * N_IN + j] * features[j];
            }
            acc = acc / WEIGHT_DENOM + b1[i];
            hidden[i] = acc > 0 ? acc : int256(0);
        }

        // Output layer: logits = W2 · h / 1000 + b2; argmax, first max wins ties.
        uint256 best = 0;
        for (uint256 k = 0; k < N_OUT; k++) {
            int256 acc = 0;
            for (uint256 i = 0; i < N_HIDDEN; i++) {
                acc += w2[k * N_HIDDEN + i] * hidden[i];
            }
            logits[k] = acc / WEIGHT_DENOM + b2[k];
            if (logits[k] > logits[best]) {
                best = k;
            }
        }
        action = uint8(best);
    }
}
