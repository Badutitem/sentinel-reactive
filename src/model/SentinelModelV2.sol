// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {SentinelWeightsV2} from "./SentinelWeightsV2.sol";

/// @title SentinelModelV2 — tiny fixed-point MLP inference (7 -> 12 -> 3), pure Solidity.
/// @notice V2 of the Sentinel model (see ANCHOR.md): the v1 six features plus
///         anchorDrawdown (feature 6 — drawdown from a leaky peak, decay
///         x999/1000 per update), classified by a 12-unit hidden layer. Same
///         fixed-point scheme as SentinelModel: features and activations are
///         scaled by 1e6, weights by 1e3, each neuron accumulates exact
///         integer products with a single truncating division at the end
///         (Solidity `/` on int256 truncates toward zero — the off-chain
///         reference implementation in tools/train.py mirrors this exactly,
///         and the unit tests assert bit-exact logits).
library SentinelModelV2 {
    uint8 internal constant HOLD = 0;
    uint8 internal constant TRIM = 1;
    uint8 internal constant EXIT = 2;

    uint256 internal constant N_IN = 7;
    uint256 internal constant N_HIDDEN = 12;
    uint256 internal constant N_OUT = 3;
    int256 internal constant WEIGHT_DENOM = 1000;

    /// @notice Runs the forward pass.
    /// @param features Seven features scaled by 1e6:
    ///        [lastReturn, meanReturn, volatility, drawdown, momentum, priceVsMean, anchorDrawdown].
    /// @return action Argmax action: 0 = HOLD, 1 = TRIM, 2 = EXIT (ties resolve to the lowest index).
    /// @return logits The three output logits (1e6 scale), for on-chain observability.
    /// @return hidden The twelve hidden activations after ReLU (1e6 scale).
    function predict(int256[7] memory features)
        internal
        pure
        returns (uint8 action, int256[3] memory logits, int256[12] memory hidden)
    {
        int256[84] memory w1 = SentinelWeightsV2.weights1();
        int256[12] memory b1 = SentinelWeightsV2.biases1();
        int256[36] memory w2 = SentinelWeightsV2.weights2();
        int256[3] memory b2 = SentinelWeightsV2.biases2();

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
