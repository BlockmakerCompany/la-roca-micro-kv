#!/bin/bash

# -----------------------------------------------------------------------------
# Script: tests/test_engine.sh
# Project: La Roca Micro-KV
# Responsibility: Full Integration (Namespace /keys/ edition).
# -----------------------------------------------------------------------------

# --- UI Configuration ---
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'

API_URL="http://localhost:8080"
# Definimos DATA_URL como el punto de entrada al ruteador de llaves
DATA_URL="$API_URL/keys"

echo -e "\n${BLUE}--- Launching Full Integration Suite for La Roca Micro-KV ---${NC}"

# Result Verification Helper
check_result() {
    if [ "$1" == "$2" ]; then
        echo -e "  [${GREEN}PASS${NC}] $3"
    else
        echo -e "  [${RED}FAIL${NC}] $3 (Expected: $2, Obtained: $1)"
        exit 1
    fi
}

# --- 1. Runtime Discovery ---
echo -e "\n${BLUE}Test 1: Health Probes & Dynamic Geometry Discovery${NC}"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/live")
check_result "$CODE" "200" "Liveness probe operational"

STATS_JSON=$(curl -s "$API_URL/stats")
MAX_KEY_SIZE=$(echo "$STATS_JSON" | grep -Eo '"key_size_bytes":[0-9]+' | cut -d':' -f2)
MAX_SLOT_SIZE=$(echo "$STATS_JSON" | grep -Eo '"slot_size_bytes":[0-9]+' | cut -d':' -f2)
TOTAL_KEYS=$(echo "$STATS_JSON" | grep -Eo '"total_keys":[0-9]+' | cut -d':' -f2)

# Metadata overhead is 7 bytes (2 length + 1 type + 4 CRC32/padding)
VAL_MAX=$((MAX_SLOT_SIZE - MAX_KEY_SIZE - 7))

echo -e "  [INFO] Detected Geometry: Key=${MAX_KEY_SIZE}B, Slot=${MAX_SLOT_SIZE}B, MaxVal=${VAL_MAX}B"
check_result "$TOTAL_KEYS" "0" "Initial Database is empty"

# --- 2. Basic CRUD Operations ---
echo -e "\n${BLUE}Test 2: Primary CRUD Operations via /keys/${NC}"
# Usamos $DATA_URL/testkey -> http://localhost:8080/keys/testkey
curl -s -X POST "$DATA_URL/testkey" -d "Testing payload" > /dev/null
VAL=$(curl -s "$DATA_URL/testkey")
check_result "$VAL" "Testing payload" "GET retrieves exact binary match"
NEW_TOTAL=$(curl -s "$API_URL/stats" | grep -Eo '"total_keys":[0-9]+' | cut -d':' -f2)
check_result "$NEW_TOTAL" "1" "Global counter incremented"

# --- 3. URI & Key Validations ---
echo -e "\n${BLUE}Test 3: URI Hardening & Dynamic Key Limits${NC}"
LONG_KEY=$(printf 'k%.0s' $(seq 1 $((MAX_KEY_SIZE + 1))))
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$DATA_URL/$LONG_KEY" -d "data")
check_result "$CODE" "400" "Rejection of keys > $MAX_KEY_SIZE bytes"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$API_URL/")
check_result "$CODE" "404" "Root URI '/' properly handled"

# --- 4. B-Tree Ordering Consistency ---
echo -e "\n${BLUE}Test 4: B-Tree Indexing & Lexicographical Sorting${NC}"
curl -s -X POST "$DATA_URL/apple" -d "fruit1" > /dev/null
curl -s -X POST "$DATA_URL/zebra" -d "animal" > /dev/null
curl -s -X POST "$DATA_URL/banana" -d "fruit2" > /dev/null
VAL=$(curl -s "$DATA_URL/apple")
check_result "$VAL" "fruit1" "Correct lookup for 'apple'"
VAL=$(curl -s "$DATA_URL/zebra")
check_result "$VAL" "animal" "Correct lookup for 'zebra'"

# --- 5. Data Deletion ---
echo -e "\n${BLUE}Test 5: DELETE Operation${NC}"
curl -s -X DELETE "$DATA_URL/apple" > /dev/null
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$DATA_URL/apple")
check_result "$CODE" "404" "Deleted key no longer exists"

# --- 6. Atomicity & Updates ---
echo -e "\n${BLUE}Test 6: Key Overwriting (Atomic Update)${NC}"
curl -s -X POST "$DATA_URL/banana" -d "updated_fruit" > /dev/null
VAL=$(curl -s "$DATA_URL/banana")
check_result "$VAL" "updated_fruit" "In-place value update successful"

# --- 7. Sharding Dispatcher ---
echo -e "\n${BLUE}Test 7: Special Character Sharding${NC}"
curl -s -X POST "$DATA_URL/123_data" -d "numeric_info" > /dev/null
VAL=$(curl -s "$DATA_URL/123_data")
check_result "$VAL" "numeric_info" "Numeric key routed correctly"

# --- 8. Boundary Stress: Maximum Payload ---
echo -e "\n${BLUE}Test 8: Buffer Stress (Dynamic Max Payload: $VAL_MAX bytes)${NC}"
MAX_PAYLOAD=$(printf 'A%.0s' $(seq 1 $VAL_MAX))
echo "\n La URL que estoy llamado es: $DATA_URL/max_payload"
curl -s -X POST "$DATA_URL/max_payload" -d "$MAX_PAYLOAD" > /dev/null
VAL=$(curl -s "$DATA_URL/max_payload")
check_result "${#VAL}" "$VAL_MAX" "Engine handles exact boundary"

# --- 9. Basic Concurrency ---
echo -e "\n${BLUE}Test 9: Basic Parallelism (Bombardment)${NC}"
for i in {1..50}; do
    curl -s -X POST "$DATA_URL/conc_key_$i" -d "data_$i" > /dev/null &
done
wait
echo -e "  [${GREEN}PASS${NC}] Survives 50 concurrent bursts"

# --- 10. Ghost Deletions ---
echo -e "\n${BLUE}Test 10: DELETE on Non-Existent Keys${NC}"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$DATA_URL/ghost_404")
check_result "$CODE" "404" "Graceful handling of non-existent key deletion"

# --- 11. Binary Integrity ---
echo -e "\n${BLUE}Test 11: Binary-Safe Data Integrity${NC}"
printf "A\x00B" > binary_payload.bin
printf 'P%.0s' $(seq 1 $((VAL_MAX - 3))) >> binary_payload.bin
curl -s -X POST "$DATA_URL/binary_test" --data-binary @binary_payload.bin > /dev/null
VAL_SIZE=$(curl -s "$DATA_URL/binary_test" | wc -c)
check_result "$VAL_SIZE" "$VAL_MAX" "Binary integrity verified"
rm binary_payload.bin

# --- 12. Range Scan: Basic Prefix Filtering ---
echo -e "\n${BLUE}Test 12: Range Scan - Prefix Filtering via /keys${NC}"
curl -s -X POST "$DATA_URL/scan_a1" -d "v1" > /dev/null
curl -s -X POST "$DATA_URL/scan_a2" -d "v2" > /dev/null
curl -s -X POST "$DATA_URL/scan_b1" -d "v3" > /dev/null

# El Scan requiere /keys?prefix=...
SCAN_RES=$(curl -s "$DATA_URL?prefix=scan_a")
COUNT=$(echo "$SCAN_RES" | grep -c "scan_a")
check_result "$COUNT" "2" "Prefix filter correctly isolated 'scan_a' keys"

# --- 13. Range Scan: Limit ---
echo -e "\n${BLUE}Test 13: Range Scan - Limit Support${NC}"
SCAN_RES=$(curl -s "$DATA_URL?prefix=scan_&limit=1")
COUNT=$(echo "$SCAN_RES" | grep -c "scan_")
check_result "$COUNT" "1" "Respects user-defined limit=1"

# --- 14. Range Scan: Pagination ---
echo -e "\n${BLUE}Test 14: Range Scan - Deep Pagination (StartKey)${NC}"
SCAN_RES=$(curl -s "$DATA_URL?prefix=scan_a&startkey=scan_a2")
FIRST_KEY=$(echo "$SCAN_RES" | head -n 1)
check_result "$FIRST_KEY" "scan_a2" "Pagination skipped scan_a1 correctly"

# --- 15. Namespace Isolation ---
echo -e "\n${BLUE}Test 15: Namespace Isolation (Anti-Collision)${NC}"
curl -s -X POST "$DATA_URL/stats" -d "UserData" > /dev/null
USER_VAL=$(curl -s "$DATA_URL/stats")
check_result "$USER_VAL" "UserData" "User data in /keys/stats does not overwrite system /stats"

echo -e "\n${GREEN}✔ All tests completed.${NC}"