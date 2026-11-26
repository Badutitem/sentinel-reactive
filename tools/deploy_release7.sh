#!/usr/bin/env bash
# RELEASE 7 (June core) deploy driver — fresh parallel set, same V5 code.
#   1. MockPriceOracle (Base Sepolia)
#   2. SentinelSwapV2 (Base Sepolia, priceSource = oracle, vault = 0)
#   3. SentinelReactiveV5 (Lasna, mock origin, 2.00 lREACT attached)
#   4. SentinelVaultV5 (Base Sepolia)
#   5. swap.setVault + reactive.setVault (verified by reads)
#   6. desk seeded exactly 1,000 mUSDC; vault billing 0.0001 ETH
# Faucet round is a separate pre-step (design §7/R-1); this script
# GATES on dev Lasna >= 2.18 lREACT before any deploy.
# Any failed expectation ABORTS (exit 1) with state preserved.
# Transcript: goal hidden_files/release7-deploy.log.
# FLAGSHIP SET IS NEVER TOUCHED by this script.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a

BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
DEV="0x75c328F0354fFC73bee24F61F7166a33Bf90Bf94"
WETH="0x4200000000000000000000000000000000000006"
MUSDC="0x96E467Ff7958851d307D28118EBAAD333CAb85B2"
PROXY="0x476F44b11F5C942c58f4c8E3d0300E5710743585"
FLAGSHIP_BRAIN="0x37EeF5e3179E55c0e96E1528180B55Fa20DC150B"
LOG="${LOG:-$HOME/workspace/goals/reactive-omni-buildathon-sentinel/hidden_files/release7-deploy.log}"
exec > >(tee -a "$LOG") 2>&1

fail() { echo "!!! ABORT: $*"; echo "!!! State preserved; nothing further will be sent."; exit 1; }
say() { echo "[$(date -u +%H:%M:%S)] $*"; }

cv() { # cv <addr> <sig> [args...] <rpc> — last arg is always the RPC URL
  local addr="$1" sig="$2"; shift 2
  local rpc="${@: -1}" nargs=$(($# - 1)) args=()
  if [ "$nargs" -gt 0 ]; then args=("${@:1:$nargs}"); fi
  cast call "$addr" "$sig" "${args[@]}" --rpc-url "$rpc" 2>/dev/null | awk '{print $1}'
}
bal() { cast balance "$1" --rpc-url "$2" 2>/dev/null; }

create() { # create <rpc> <contract> [forge-create args...] -> echoes "addr txhash"
  local rpc="$1" contract="$2"; shift 2
  local out
  out=$(forge create "$contract" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --broadcast --json "$@" 2>/dev/null) \
    || fail "forge create $contract failed"
  echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);a=d.get('deployedTo') or d.get('contractAddress');h=d.get('transactionHash');assert a and h;print(a,h)" 2>/dev/null \
    || fail "could not parse forge create output for $contract: $out"
}

send() { # send <rpc> <to> <sig> [args...] -> tx hash or FAIL (dev key)
  local rpc="$1" to="$2" sig="$3"; shift 3
  local out h
  out=$(cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --json 2>/dev/null) || fail "send failed: $sig to $to"
  h=$(echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1','status '+d['status'];print(d['transactionHash'])" 2>/dev/null) || fail "tx reverted: $sig to $to"
  echo "$h"
}

say "=== RELEASE 7 DEPLOY START (June core) ==="
DEVBASE=$(bal "$DEV" "$BASE_RPC")
DEVLASNA=$(bal "$DEV" "$LASNA_RPC")
say "preflight: dev BaseSep=$DEVBASE dev Lasna=$DEVLASNA flagshipBrainUpdates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") flagshipBrainLastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC")"
python3 -c "exit(0 if $DEVBASE >= 10000000000000000 else 1)" || fail "dev Base Sepolia balance below 0.01 ETH"
python3 -c "exit(0 if $DEVLASNA >= 2180000000000000000 else 1)" || fail "FAUCET GATE: dev Lasna $DEVLASNA < 2.18 lREACT — deploy does not start"

# --- 1. MockPriceOracle (no constructor args) ---
# Resume: R7_ORACLE set reuses an already-deployed oracle (incident 1).
if [ -n "${R7_ORACLE:-}" ]; then
  ORACLE="$R7_ORACLE"; ORACLE_TX="(pre-deployed, see incident 1)"
  say "ORACLE reused: $ORACLE"
else
  read ORACLE ORACLE_TX <<< "$(create "$BASE_RPC" src/MockPriceOracle.sol:MockPriceOracle)"
  say "ORACLE deployed: $ORACLE tx=$ORACLE_TX"
fi
[ "$(cv "$ORACLE" "latestPrice(address)(uint256)" "$WETH" "$BASE_RPC")" = "0" ] || fail "oracle price not 0 at birth"

# --- 2. Swap desk (vault = 0, wired later; priceSource = fresh oracle) ---
read SWAP SWAP_TX <<< "$(create "$BASE_RPC" src/SentinelSwapV2.sol:SentinelSwapV2 --constructor-args "$WETH" "$MUSDC" "$ORACLE" 0x0000000000000000000000000000000000000000)"
say "SWAP deployed: $SWAP tx=$SWAP_TX"
[ "$(cv "$SWAP" "priceSource()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$ORACLE" | tr 'A-F' 'a-f')" ] || fail "swap priceSource mismatch"

# --- 3. Brain on Lasna, mock origin, 2.00 lREACT attached ---
read REACTIVE REACTIVE_TX <<< "$(create "$LASNA_RPC" src/SentinelReactiveV5.sol:SentinelReactiveV5 --value 2000000000000000000 --constructor-args 84532 "$ORACLE" "$WETH" 84532 300)"
say "REACTIVE deployed: $REACTIVE tx=$REACTIVE_TX balance=$(bal "$REACTIVE" "$LASNA_RPC")"
[ "$(cv "$REACTIVE" "oracle()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "$(echo "$ORACLE" | tr 'A-F' 'a-f')" ] || fail "reactive oracle mismatch"
[ "$(cv "$REACTIVE" "updates()(uint256)" "$LASNA_RPC")" = "0" ] || fail "reactive updates not 0 at birth"
[ "$(cv "$FLAGSHIP_BRAIN" "oracle()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "0xab9c7a5178b444cd1c1fd705e5ebecf4b9a1c25f" ] || fail "R-7: flagship brain oracle changed (expected Chainlink adapter)"
[ "$(cv "$FLAGSHIP_BRAIN" "oracle()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" != "$(echo "$ORACLE" | tr 'A-F' 'a-f')" ] || fail "R-7: flagship brain now points at fresh oracle"

# --- 4. VaultV5 ---
read VAULT VAULT_TX <<< "$(create "$BASE_RPC" src/SentinelVaultV5.sol:SentinelVaultV5 --constructor-args "$PROXY" "$REACTIVE" "$WETH" "$MUSDC" "$SWAP")"
say "VAULT deployed: $VAULT tx=$VAULT_TX"
[ "$(cv "$VAULT" "totalShares()(uint256)" "$BASE_RPC")" = "0" ] || fail "vault totalShares not 0 at birth"

# --- 5. Wiring ---
H=$(send "$BASE_RPC" "$SWAP" "setVault(address)" "$VAULT"); say "swap.setVault tx=$H"
[ "$(cv "$SWAP" "vault()(address)" "$BASE_RPC" | tr 'A-F' 'a-f')" = "$(echo "$VAULT" | tr 'A-F' 'a-f')" ] || fail "swap vault mismatch after setVault"
H=$(send "$LASNA_RPC" "$REACTIVE" "setVault(address)" "$VAULT"); say "reactive.setVault tx=$H"
[ "$(cv "$REACTIVE" "vault()(address)" "$LASNA_RPC" | tr 'A-F' 'a-f')" = "$(echo "$VAULT" | tr 'A-F' 'a-f')" ] || fail "reactive vault mismatch after setVault"
# R-7: flagship brain must still point at its own adapter, untouched.
say "flagship brain after wiring: updates=$(cv "$FLAGSHIP_BRAIN" "updates()(uint256)" "$LASNA_RPC") lastAction=$(cv "$FLAGSHIP_BRAIN" "lastAction()(uint8)" "$LASNA_RPC")"

# --- 6. Seed desk exactly 1,000 mUSDC + vault billing 0.0001 ETH ---
H=$(send "$BASE_RPC" "$MUSDC" "mint(address,uint256)" "$SWAP" 1000000000000000000000); say "desk seed mint tx=$H"
[ "$(cast call "$MUSDC" "balanceOf(address)(uint256)" "$SWAP" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}')" = "1000000000000000000000" ] || fail "desk mUSDC balance != 1000e18 after seed"
H=$(cast send "$VAULT" --value 100000000000000 --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['status']=='0x1';print(d['transactionHash'])" 2>/dev/null) || fail "vault billing fund failed"
say "vault billing fund tx=$H vaultETH=$(bal "$VAULT" "$BASE_RPC")"

say "RELEASE7_ADDRESSES oracle=$ORACLE swap=$SWAP reactive=$REACTIVE vault=$VAULT"
say "RELEASE7_TXS oracle=$ORACLE_TX swap=$SWAP_TX reactive=$REACTIVE_TX vault=$VAULT_TX"
say "post: dev BaseSep=$(bal "$DEV" "$BASE_RPC") dev Lasna=$(bal "$DEV" "$LASNA_RPC") brain Lasna=$(bal "$REACTIVE" "$LASNA_RPC")"
say "=== RELEASE 7 DEPLOY COMPLETE ==="
