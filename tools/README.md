# tools/

Off-chain tooling. Nothing in here is part of the running system — the model
runs fully on-chain; these tools only *produce* its weights.

## Release 1: `train.py` (done — this is how the shipped weights were made)

```bash
python3 tools/train.py   # numpy only; seeded, byte-reproducible output
```

What it does:

1. **Mirror proof first.** Before training, it verifies its integer Python
   reference (features + forward pass, trunc-toward-zero division) bit-for-bit
   against the Release 1 Solidity behaviour (the exact logits/hidden values and
   crash-path features/scores pinned in the Foundry tests, using a frozen copy
   of the Release 1 weights). Any drift aborts the run.
2. Generates synthetic price series (calm, uptrend, chop, grind-down, crash,
   V-recovery), slides the on-chain window over them exactly like
   `SentinelReactive` does, computes the same six integer features as
   `SentinelReactive._features()`, and labels each window with the stop-loss
   policy ladder (drawdown >= 21% -> EXIT; 3-21% and still falling -> TRIM;
   recovering -> HOLD; otherwise HOLD).
3. Trains the 6 -> 8 -> 3 MLP in float (numpy, full-batch Adam), quantizes
   the weights (x1000; biases x1e6), and evaluates the *integer* model — the
   one that ships. If quantization breaks a canonical acceptance check
   (standard vectors + the Foundry tests' price paths), a short
   quantization-aware fine-tune (straight-through estimator) runs until it
   passes.
4. Regenerates `src/model/SentinelWeights.sol` in the Release 1 codegen format
   (training metrics in the header comment) and writes `tools/vectors.json`
   with the fresh expected logits/scores used to re-pin the Foundry tests.

Current shipped model: float accuracy 97.10% held-out; integer accuracy
97.47% held-out (HOLD 96.9% / TRIM 99.1% / EXIT 100% per class), 24/24
Foundry tests pass.
