#!/usr/bin/env bash
# RESUME driver for the Release 5 rehearsal: the original rehearse_v5.sh
# run was killed by a service restart after update 22 (stage D push 2).
# On-chain state was verified before resuming (updates=22, oracle last
# price 99.401, vault 0.000381598666909677 WETH / 0 mUSDC, prot=4,
# rerisk=2). This script pushes ONLY the remaining stage D prices:
# updates 23..31 (TRIM expected at 25, EXIT at 31).
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a
BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"

updates() { cast call "$REACTIVE" "updates()(uint256)" --rpc-url "$LASNA_RPC" 2>/dev/null | awk '{print $1}'; }
last_action() { cast call "$REACTIVE" "lastAction()(uint8)" --rpc-url "$LASNA_RPC" 2>/dev/null | awk '{print $1}'; }
prot_count() { cast call "$VAULT" "protectionCount()(uint256)" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }
rerisk_count() { cast call "$VAULT" "reriskCount()(uint256)" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }
pos() { cast call "$VAULT" "positionSize()(uint256)" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }
safe() { cast call "$VAULT" "safeBalance()(uint256)" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }

push() {
  local price="$1" before after n=0 hash
  before=$(updates)
  hash=$(cast send "$ORACLE" "setPrice(address,uint256)" "$TOKEN" "$price" \
    --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])" 2>/dev/null || echo "SEND_FAILED")
  after="$before"
  while [ "$after" = "$before" ] && [ $n -lt 22 ]; do sleep 2; after=$(updates); n=$((n+1)); done
  echo "push $price origin_tx=$hash updates=$after action=$(last_action) protections=$(prot_count) rerisks=$(rerisk_count) position=$(pos) safe=$(safe)"
}

echo "== Stage D (resumed): bleed -2%/step, pushes 23..31 =="
for p in 97.413 95.465 93.556 91.685 89.851 88.054 86.293 84.567 82.876; do push "$(python3 -c "print(int(round($p * 10**18)))")"; done
echo "== Rehearsal resume complete =="
