#!/usr/bin/env bash
# FLAGSHIP SWAP deploy driver — RESUME (v2).
# v1 deployed the swap desk successfully, then aborted on a forge-create
# --json parse failure (tooling only; swap verified on-chain afterwards:
# 0x17700999733F766968EA252D5a17ac39F96F2C28, tx 0x5966d9ad...dda63,
# priceSource = adapter). This driver asserts that swap, then deploys
# the brain + VaultV5 via `cast send --create` (nonce-derived addresses,
# getter-verified), wires, seeds, and makes the owner seed deposit.
# Any failed expectation ABORTS (exit 1) with state preserved.
# Transcript: goal hidden_files/flagship-v5-deploy.log (appended).
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
DEV="0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
ADAPTER="0xAb9c7a5178B444cd1C1fD705e5eBeCf4b9A1C25F"
PROXY="0x476F44b11F5C942c58f4c8E3d0300E5710743585"
SWAP="0x17700999733F766968EA252D5a17ac39F96F2C28"
SWAP_TX="0x5966d9ad15f5cd5e76efdfe6c4f79121915ae7d71a1a9d628b376fa1461dda63"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/flagship-v5-deploy.log}"
exec > >(tee -a "$LOG") 2>&1

fail() { echo "!!! ABORT: $*"; echo "!!! State preserved; nothing further will be sent."; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] $*"; }
lc() { echo "$1" | tr 'A-F' 'a-f'; }
cv() { cast call "$1" "$2" --rpc-url "$3" 2>/dev/null | awk '{print $1}'; }
bal() { cast balance "$1" --rpc-url "$2" 2>/dev/null; }

send() { # send <rpc> <to> <sig> [args...] -> tx hash (dev key)
  local rpc="$1" to="$2" sig="$3"; shift 3
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}

deploy() { # deploy <rpc> <inspect-path> <argsig> <value-wei> [abi-encode args...] -> echoes "addr txhash"
  local rpc="$1" path="$2" sig="$3" value="$4"; shift 4
  local nonce bc enc out h addr
  nonce=$(cast nonce "$DEV" --rpc-url "$rpc" 2>/dev/null) || fail "nonce read failed for $path"
  bc=$(forge inspect "$path" bytecode 2>/dev/null) || fail "forge inspect failed for $path"
  enc=$(cast abi-encode "$sig" "$@" 2>/dev/null) || fail "abi-encode failed for $path"
  out=$(cast send --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --value "$value" --json --create "${bc}${enc#0x}" 2>/dev/null) || fail "create send failed for $path"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "create reverted for $path"
  addr=$(cast compute-address "$DEV" --nonce "$nonce" --rpc-url "$rpc" 2>/dev/null | awk '{print $NF}')
  [ -n "$addr" ] || fail "compute-address failed for $path"
  [ "$(cast code "$addr" --rpc-url "$rpc" 2>/dev/null | tr -d '\n' | wc -c)" -gt 4 ] || fail "no code at computed address $addr for $path"
  echo "$addr $h"
}

say "=== FLAGSHIP V5 DEPLOY RESUME (v2) ==="
say "preflight: dev BaseSep=$(bal "$DEV" "$BASE_RPC") dev Lasna=$(bal "$DEV" "$LASNA_RPC")"

# --- 0. Assert the v1 swap ---
[ "$(cast code "$SWAP" --rpc-url "$BASE_RPC" 2>/dev/null | tr -d '\n' | wc -c)" -gt 4 ] || fail "v1 swap has no code"
[ "$(lc "$(cv "$SWAP" "priceSource()(address)" "$BASE_RPC")")" = "$(lc "$ADAPTER")" ] || fail "v1 swap priceSource mismatch"
[ "$(cv "$SWAP" "vault()(address)" "$BASE_RPC")" = "0x0000000000000000000000000000000000000000" ] || fail "v1 swap already wired — unexpected"
say "SWAP asserted: $SWAP tx=$SWAP_TX priceSource=adapter vault=unset"

# --- 1. Brain on Lasna (adapter origin, 1.15 lREACT attached) ---
# Deployed manually during v2 debugging (flag order for --create found:
# all options precede --create). Tx 0x38cd921e...c52d7, nonce 23.
REACTIVE="0x37EeF5e3179E55c0e96E1528180B55Fa20DC150B"
REACTIVE_TX="0x38cd921ef3bb091803fa763014800e2c5973d9b5efe423c9d865def5774c52d7"
say "REACTIVE asserted: $REACTIVE tx=$REACTIVE_TX balance=$(bal "$REACTIVE" "$LASNA_RPC")"
[ "$(lc "$(cv "$REACTIVE" "oracle()(address)" "$LASNA_RPC")")" = "$(lc "$ADAPTER")" ] || fail "reactive oracle mismatch"
[ "$(cv "$REACTIVE" "originChainId()(uint256)" "$LASNA_RPC")" = "84532" ] || fail "reactive originChainId mismatch"
[ "$(cv "$REACTIVE" "destChainId()(uint256)" "$LASNA_RPC")" = "84532" ] || fail "reactive destChainId mismatch"
[ "$(cv "$REACTIVE" "cooldownSeconds()(uint256)" "$LASNA_RPC")" = "300" ] || fail "reactive cooldown mismatch"
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "0" ] || fail "reactive updates not 0 at birth"
[ "$(bal "$REACTIVE" "$LASNA_RPC")" = "1150000000000000000" ] || fail "reactive balance != 1.15 lREACT attached"

# --- 2. VaultV5 ---
read VAULT VAULT_TX <<< "$(deploy "$BASE_RPC" src/SentinelVaultV5.sol:SentinelVaultV5 "constructor(address,address,address,address,address)" 0 "$PROXY" "$REACTIVE" "$WETH" "$MUSDC" "$SWAP")"
say "VAULT deployed: $VAULT tx=$VAULT_TX"
[ "$(lc "$(cv "$VAULT" "riskAsset()(address)" "$BASE_RPC")")" = "$(lc "$WETH")" ] || fail "vault riskAsset mismatch"
[ "$(lc "$(cv "$VAULT" "safeAsset()(address)" "$BASE_RPC")")" = "$(lc "$MUSDC")" ] || fail "vault safeAsset mismatch"
[ "$(lc "$(cv "$VAULT" "swap()(address)" "$BASE_RPC")")" = "$(lc "$SWAP")" ] || fail "vault swap mismatch"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault totalShares not 0 at birth"

# --- 3. Wiring ---
H=$(send "$BASE_RPC" "$SWAP" "setVault(address)" "$VAULT"); say "swap.setVault tx=$H"
[ "$(lc "$(cv "$SWAP" "vault()(address)" "$BASE_RPC")")" = "$(lc "$VAULT")" ] || fail "swap vault mismatch after setVault"
H=$(send "$LASNA_RPC" "$REACTIVE" "setVault(address)" "$VAULT"); say "reactive.setVault tx=$H"
[ "$(lc "$(cv "$REACTIVE" "vault()(address)" "$LASNA_RPC")")" = "$(lc "$VAULT")" ] || fail "reactive vault mismatch after setVault"

# --- 4. Seed desk exactly 1,000 mUSDC + vault billing 0.0001 ETH ---
H=$(send "$BASE_RPC" "$MUSDC" "mint(address,uint256)" "$SWAP" 1000000000000000000000); say "desk seed mint tx=$H"
[ "$(cast call "$MUSDC" "balanceOf(address)(uint256)" "$SWAP" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')" = "1000000000000000000000" ] || fail "desk mUSDC != 1000e18 after seed"
H=$(cast send "$VAULT" --value 100000000000000 --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])" 2>/dev/null) || fail "vault billing fund failed"
say "vault billing fund tx=$H vaultETH=$(bal "$VAULT" "$BASE_RPC")"
[ "$(bal "$VAULT" "$BASE_RPC")" = "100000000000000" ] || fail "vault ETH != 0.0001 after billing fund"

# --- 5. Owner seed deposit 0.002 WETH via the public flow ---
H1=$(send "$BASE_RPC" "$WETH" "deposit()" --value 2000000000000000); say "wrap tx=$H1"
H2=$(send "$BASE_RPC" "$WETH" "approve(address,uint256)" "$VAULT" 2000000000000000); say "approve tx=$H2"
H3=$(send "$BASE_RPC" "$VAULT" "deposit(uint256)" 2000000000000000); say "deposit tx=$H3"
SH=$(cast call "$VAULT" "sharesOf(address)(uint256)" "$DEV" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')
say "owner shares=$SH totalShares=$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC") managedRisk=$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC") managedSafe=$(cv "$VAULT" "managedSafe()(uint256)" "$BASE_RPC") positionSize=$(cv "$VAULT" "positionSize()(uint256)" "$BASE_RPC") closed=$(cv "$VAULT" "closed()(bool)" "$BASE_RPC")"
[ "$SH" = "2000000000000000" ] || fail "owner shares != 0.002e18 (not 1:1)"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "2000000000000000" ] || fail "totalShares != 0.002e18"
[ "$(cv "$VAULT" "managedRisk()(uint256)" "$BASE_RPC")" = "2000000000000000" ] || fail "managedRisk != 0.002 WETH after seed deposit"

say "FLAGSHIP_ADDRESSES swap=$SWAP reactive=$REACTIVE vault=$VAULT"
say "FLAGSHIP_TXS swap=$SWAP_TX reactive=$REACTIVE_TX vault=$VAULT_TX wrap=$H1 approve=$H2 deposit=$H3"
say "post: dev BaseSep=$(bal "$DEV" "$BASE_RPC") dev Lasna=$(bal "$DEV" "$LASNA_RPC") brain Lasna=$(bal "$REACTIVE" "$LASNA_RPC")"
say "=== FLAGSHIP V5 DEPLOY COMPLETE ==="
