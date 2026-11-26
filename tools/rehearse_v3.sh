#!/usr/bin/env bash
# Live testnet rehearsal driver for Sentinel Release 4 (SentinelReactiveV3,
# mock origin). Pushes the mirror-validated price series into the Release
# #4 rehearsal MockPriceOracle on Base Sepolia and waits for the Lasna
# reactive to ingest each push before continuing:
#   Stage A calm x5            -> HOLD, no callbacks
#   Stage B bleed -2%/step x10 -> TRIM fires (position halved), then
#                                 EXIT fires (position closed); repeat
#                                 TRIM votes in between are suppressed
#                                 (repair 3) — watch CallbackRequested
#   --- re-arm: deposit a fresh position on the rehearsal vault ---
#   Stage C recovery x4        -> new high, no votes
#   Stage C decline -3%/step x8-> HOLD x7 (the still-open V-recovery
#                                 blind window, RELEASE4.md), EXIT at
#                                 step 8 fires inside stage B's old
#                                 cooldown (re-arm after EXIT reset)
# Required env: ORACLE, REACTIVE, VAULT, TOKEN, PRIVATE_KEY via
# .env.local. REARM=1 (default) deposits REARM_AMOUNT wei of WETH into
# the vault between stages B and C (caller must hold + have approved).
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
set -a; source .env.local; set +a
BASE_RPC="https://sepolia.base.org"
LASNA_RPC="https://lasna-rpc.rnk.dev"
WETH="0x4200000000000000000000000000000000000006"

updates() { cast call "$REACTIVE" "updates()(uint256)" --rpc-url "$LASNA_RPC" 2>/dev/null | awk '{print $1}'; }
last_action() { cast call "$REACTIVE" "lastAction()(uint8)" --rpc-url "$LASNA_RPC" 2>/dev/null | awk '{print $1}'; }
prot_count() { cast call "$VAULT" "protectionCount()(uint256)" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }
pos() { cast call "$VAULT" "positionSize()(uint256)" --rpc-url "$BASE_RPC" 2>/dev/null | awk '{print $1}'; }

push() {
  local price="$1" before after n=0 hash
  before=$(updates)
  hash=$(cast send "$ORACLE" "setPrice(address,uint256)" "$TOKEN" "$price" \
    --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" --json 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])" 2>/dev/null || echo "SEND_FAILED")
  after="$before"
  while [ "$after" = "$before" ] && [ $n -lt 22 ]; do sleep 2; after=$(updates); n=$((n+1)); done
  echo "push $price origin_tx=$hash updates=$after action=$(last_action) protections=$(prot_count) position=$(pos)"
}

E18="000000000000000000"
echo "== Stage A: calm (expect HOLD, no callbacks) =="
for p in 100 100.5 99.8 100.2 100.1; do push "$(python3 -c "print(int($p * 10**18))")"; done

echo "== Stage B: bleed -2%/step (expect TRIM then EXIT) =="
for p in 98.098 96.136 94.213 92.329 90.483 88.673 86.899 85.161 83.458 81.789; do push "$(python3 -c "print(int(round($p * 10**18)))")"; done

if [ "${REARM:-1}" = "1" ]; then
  echo "== Re-arm: deposit ${REARM_AMOUNT} wei WETH =="
  cast send "$VAULT" "deposit(uint256)" "${REARM_AMOUNT}" --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" | grep -E "transactionHash|status"
  echo "position after re-arm: $(pos)"
fi

echo "== Stage C: recovery to a new high (expect no votes) =="
for p in 83.7 91.2 97.6 104; do push "$(python3 -c "print(int(round($p * 10**18)))")"; done

echo "== Stage C: decline -3%/step (expect HOLD x7, EXIT at step 8) =="
for p in 100.88 97.854 94.918 92.071 89.309 86.630 84.031 81.510; do push "$(python3 -c "print(int(round($p * 10**18)))")"; done
echo "== Rehearsal pushes complete =="
