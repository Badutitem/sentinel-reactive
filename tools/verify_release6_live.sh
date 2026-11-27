#!/usr/bin/env bash
# RELEASE 6 LIVE Sourcify verification — all four contracts, v2 endpoint via forge.
# Any failure ABORTS (exit 1); verification is a rehearsal gate.
# Transcript: goal hidden_files/release6-live-verify.log.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a

ORACLE="${R6LIVE_ORACLE:?R6LIVE_ORACLE not set}"
REACTIVE="${R6LIVE_REACTIVE:?R6LIVE_REACTIVE not set}"
SWAP="${R6LIVE_SWAP:?R6LIVE_SWAP not set}"
VAULT="${R6LIVE_VAULT:?R6LIVE_VAULT not set}"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
PROXY="0x476F44b11F5C942c58f4c8E3d0300E5710743585"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release6-live-verify.log}"
exec > >(tee -a "$LOG") 2>&1

fail() { echo "!!! ABORT: $*"; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] $*"; }

forge build || fail "forge build failed"
say "=== RELEASE 6 LIVE SOURCIFY VERIFY START ==="

say "verifying oracle $ORACLE (84532)..."
forge verify-contract "$ORACLE" src/MockPriceOracle.sol:MockPriceOracle --chain-id 84532 --verifier sourcify || fail "oracle verify failed"

SWAP_ARGS=$(cast abi-encode "constructor(address,address,address,address)" "$WETH" "$MUSDC" "$ORACLE" 0x0000000000000000000000000000000000000000)
say "verifying swap $SWAP (84532)..."
forge verify-contract "$SWAP" src/SentinelSwapV3.sol:SentinelSwapV3 --chain-id 84532 --verifier sourcify --constructor-args "$SWAP_ARGS" || fail "swap verify failed"

BRAIN_ARGS=$(cast abi-encode "constructor(uint256,address,address,uint256,uint256)" 84532 "$ORACLE" "$WETH" 84532 300)
say "verifying brain $REACTIVE (5318007)..."
forge verify-contract "$REACTIVE" src/SentinelReactiveV6.sol:SentinelReactiveV6 --chain-id 5318007 --verifier sourcify --constructor-args "$BRAIN_ARGS" || fail "brain verify failed"

VAULT_ARGS=$(cast abi-encode "constructor(address,address,address,address,address)" "$PROXY" "$REACTIVE" "$WETH" "$MUSDC" "$SWAP")
say "verifying vault $VAULT (84532)..."
forge verify-contract "$VAULT" src/SentinelVaultV6.sol:SentinelVaultV6 --chain-id 84532 --verifier sourcify --constructor-args "$VAULT_ARGS" || fail "vault verify failed"

say "=== RELEASE 6 LIVE SOURCIFY VERIFY COMPLETE (forge accepted all four) ==="
