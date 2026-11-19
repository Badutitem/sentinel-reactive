#!/usr/bin/env bash
# Live testnet rehearsal driver for Sentinel trio #5 (SentinelReactiveV5,
# variant-B scale-in re-risk, mock origin). Pushes the mirror-validated
# price series (tools/rerisk_variants.py, variant B, live position size)
# into the trio #5 rehearsal MockPriceOracle on Base Sepolia and waits
# for the Lasna reactive to ingest each push before continuing:
#   Stage A calm x5            -> HOLD, no callbacks
#   Stage B bleed -2%/step x10 -> TRIM fires (position halved), repeat
#                                 TRIM votes suppressed, EXIT fires
#                                 (position closed, episode opens)
#   Stage C recovery           -> 90 / 93 no votes; 96.5 = >=97% reclaim
#                                 of the 99.201 episode anchor -> RERISK
#                                 tranche 1 (half the safe balance);
#                                 99.5 = new high above the episode
#                                 anchor -> tranche 2 (the rest); 103.5
#                                 HOLD at the new high
#   --- re-arm: deposit a fresh 0.0002 WETH on the rehearsal vault ---
#   Stage D bleed -2%/step x11 -> TRIM fires at step 5, EXIT at step 11
#                                 (position closed)
# Expected callback sequence (mirror): (7,TRIM) (15,EXIT) (18,RERISK)
# (19,RERISK_FINAL) (25,TRIM) (31,EXIT); protectionCount 6,
# reriskCount 2; final vault 0 WETH / 0.033663108000104059 mUSDC; desk
# 0.0004 WETH / 999.966336891999895941 mUSDC (exact conservation).
# Required env: ORACLE, REACTIVE, VAULT, TOKEN, PRIVATE_KEY via
# .env.local. REARM=1 (default) deposits REARM_AMOUNT wei of WETH into
# the vault between stages C and D (caller must hold + have approved).
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

echo "== Stage A: calm (expect HOLD, no callbacks) =="
for p in 100 100.5 99.8 100.2 100.1; do push "$(python3 -c "print(int($p * 10**18))")"; done

echo "== Stage B: bleed -2%/step (expect TRIM at push 7, EXIT at push 15) =="
for p in 98.098 96.136 94.213 92.329 90.483 88.673 86.899 85.161 83.458 81.789; do push "$(python3 -c "print(int(round($p * 10**18)))")"; done

echo "== Stage C: recovery (expect RERISK tranche 1 at 96.5, tranche 2 at 99.5) =="
for p in 90 93 96.5 99.5 103.5; do push "$(python3 -c "print(int(round($p * 10**18)))")"; done

if [ "${REARM:-1}" = "1" ]; then
  echo "== Re-arm: deposit ${REARM_AMOUNT} wei WETH =="
  cast send "$VAULT" "deposit(uint256)" "${REARM_AMOUNT}" --rpc-url "$BASE_RPC" --private-key "$PRIVATE_KEY" | grep -E "transactionHash|status"
  echo "position after re-arm: $(pos)"
fi

echo "== Stage D: bleed -2%/step (expect TRIM at step 5, EXIT at step 11) =="
for p in 101.43 99.401 97.413 95.465 93.556 91.685 89.851 88.054 86.293 84.567 82.876; do push "$(python3 -c "print(int(round($p * 10**18)))")"; done
echo "== Rehearsal pushes complete =="
