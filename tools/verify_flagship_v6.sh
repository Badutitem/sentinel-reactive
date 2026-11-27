#!/usr/bin/env bash
# FLAGSHIP MIGRATION Sourcify verification — all four new contracts, v2 via forge.
# Any failure ABORTS (exit 1).
# Transcript: goal hidden_files/flagship-migration-v6-verify.log.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a

ADAPTER="${MIG_ADAPTER:?MIG_ADAPTER not set}"
REACTIVE="${MIG_REACTIVE:?MIG_REACTIVE not set}"
SWAP="${MIG_SWAP:?MIG_SWAP not set}"
VAULT="${MIG_VAULT:?MIG_VAULT not set}"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
PROXY="0x476F44b11F5C942c58f4c8E3d0300E5710743585"
FEED="0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/flagship-migration-v6-verify.log}"
exec > >(tee -a "$LOG") 2>&1

fail() { echo "!!! ABORT: $*"; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] $*"; }

forge build || fail "forge build failed"
say "=== FLAGSHIP MIGRATION V6 SOURCIFY VERIFY START ==="

ADAPTER_ARGS=$(cast abi-encode "constructor(address,address,uint256,uint256,uint256,uint256)" "$FEED" "$WETH" 10 60 3600 3600)
say "verifying adapter $ADAPTER (84532)..."
forge verify-contract "$ADAPTER" src/ChainlinkPriceAdapter.sol:ChainlinkPriceAdapter --chain-id 84532 --verifier sourcify --constructor-args "$ADAPTER_ARGS" || fail "adapter verify failed"

SWAP_ARGS=$(cast abi-encode "constructor(address,address,address,address)" "$WETH" "$MUSDC" "$ADAPTER" 0x0000000000000000000000000000000000000000)
say "verifying swap $SWAP (84532)..."
forge verify-contract "$SWAP" src/SentinelSwapV3.sol:SentinelSwapV3 --chain-id 84532 --verifier sourcify --constructor-args "$SWAP_ARGS" || fail "swap verify failed"

BRAIN_ARGS=$(cast abi-encode "constructor(uint256,address,address,uint256,uint256)" 84532 "$ADAPTER" "$WETH" 84532 300)
say "verifying brain $REACTIVE (5318007)..."
forge verify-contract "$REACTIVE" src/SentinelReactiveV6.sol:SentinelReactiveV6 --chain-id 5318007 --verifier sourcify --constructor-args "$BRAIN_ARGS" || fail "brain verify failed"

VAULT_ARGS=$(cast abi-encode "constructor(address,address,address,address,address)" "$PROXY" "$REACTIVE" "$WETH" "$MUSDC" "$SWAP")
say "verifying vault $VAULT (84532)..."
forge verify-contract "$VAULT" src/SentinelVaultV6.sol:SentinelVaultV6 --chain-id 84532 --verifier sourcify --constructor-args "$VAULT_ARGS" || fail "vault verify failed"

say "=== FLAGSHIP MIGRATION V6 SOURCIFY VERIFY COMPLETE (forge accepted all four) ==="
