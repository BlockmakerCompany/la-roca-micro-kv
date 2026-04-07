#!/bin/bash

# -----------------------------------------------------------------------------
# Script: tests/test_recovery.sh
# Project: La Roca Micro-KV
# Responsibility: WAL Durability & Integrity Validation.
#                 1. Verifies resurrection after SIGKILL.
#                 2. Verifies CRC32 hardware protection against corruption.
# -----------------------------------------------------------------------------

# --- Environment Pre-flight ---
PORT=8085
IMAGE_NAME="blockmaker/la-roca-kv:1.1.0"

# Persistent volume for real disk I/O testing
TEST_DIR="$(pwd)/asm_kv_recovery_test_$$"
TEST_KEY="immortal_key"
TEST_VAL="This_data_survives_the_apocalypse_$(date +%s)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'

echo -e "${BOLD}${BLUE}====================================================${NC}"
echo -e "${BOLD}${BLUE}   La Roca: WAL Durability & Integrity Suite        ${NC}"
echo -e "${BOLD}${BLUE}====================================================${NC}"

mkdir -p "$TEST_DIR"
echo -e "[INFO] Local volume initialized at: $TEST_DIR"

# Cleanup function
cleanup() {
    echo -e "\n[INFO] Performing post-test cleanup..."
    docker stop asm_kv_test_run > /dev/null 2>&1
    docker rm asm_kv_test_run > /dev/null 2>&1
    rm -rf "$TEST_DIR"
    echo -e "${BLUE}--- Test environment purged ---${NC}"
}
trap cleanup EXIT

# --- PHASE 1: PERSISTENCE COMMIT ---
echo -e "\n${YELLOW}PHASE 1: Launching & Initial Write${NC}"
docker run -d --name asm_kv_test_run \
    -p $PORT:8080 \
    -v "$TEST_DIR:/app/db" \
    $IMAGE_NAME > /dev/null

sleep 2

echo -e "[INFO] Committing atomic key to /keys/$TEST_KEY..."
curl -s -X POST "http://localhost:$PORT/keys/$TEST_KEY" -d "$TEST_VAL" > /dev/null

# Immediate verification (RAM-state check)
CHECK1=$(curl -s "http://localhost:$PORT/keys/$TEST_KEY")
if [ "$CHECK1" != "$TEST_VAL" ]; then
    echo -e "${RED}[FAIL] Critical: Data not found in RAM after initial write.${NC}"
    exit 1
fi
echo -e "  [${GREEN}OK${NC}] Data confirmed in memory."

# --- PHASE 2: CATASTROPHIC SIMULATION ---
echo -e "\n${YELLOW}PHASE 2: Simulating Catastrophic Crash (SIGKILL)${NC}"
docker stop -t 0 asm_kv_test_run > /dev/null
docker rm asm_kv_test_run > /dev/null
echo -e "  [${RED}💥${NC}] Process killed. Data now only exists in the WAL on disk."

# --- PHASE 3: THE RESURRECTION (WAL REPLAY) ---
echo -e "\n${YELLOW}PHASE 3: Relaunching & WAL Replay${NC}"
docker run -d --name asm_kv_test_run \
    -p $PORT:8080 \
    -v "$TEST_DIR:/app/db" \
    $IMAGE_NAME > /dev/null

sleep 2

echo -e "[INFO] Querying the namespace after resurrection..."
CHECK2=$(curl -s "http://localhost:$PORT/keys/$TEST_KEY")

if [ "$CHECK2" = "$TEST_VAL" ]; then
    echo -e "  [${GREEN}PASS${NC}] WAL Recovery Successful! Data resurrected correctly."
else
    echo -e "  [${RED}FAIL${NC}] Data lost during recovery."
    exit 1
fi

# --- PHASE 4: INTEGRITY GUARD (CRC32 CORRUPTION TEST) ---
echo -e "\n${YELLOW}PHASE 4: Hardware Integrity Verification (CRC32)${NC}"

# 1. Stop the engine again
docker stop -t 0 asm_kv_test_run > /dev/null
docker rm asm_kv_test_run > /dev/null

# 💣 2. Wipe B-Tree shards to force strict WAL replay!
echo -e "[INFO] Wiping B-Tree shards to force strict WAL replay..."
find "$TEST_DIR" -type f ! -name 'wal.log' -delete

# 💉 3. INJECT CORRUPTION (Dockerized to bypass Host root permissions)
echo -e "[INFO] Manually corrupting WAL byte at offset 50..."
docker run --rm -v "$TEST_DIR:/app/db" alpine sh -c 'printf "X" | dd of=/app/db/wal.log bs=1 seek=50 count=1 conv=notrunc'

# 4. Relaunch
echo -e "[INFO] Relaunching engine with corrupted WAL..."
docker run -d --name asm_kv_test_run \
    -p $PORT:8080 \
    -v "$TEST_DIR:/app/db" \
    $IMAGE_NAME > /dev/null

sleep 2

# 5. Audit: The key MUST be ignored because the CRC32 won't match
echo -e "[INFO] Querying corrupted key (Expected: 404)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/keys/$TEST_KEY")

if [ "$HTTP_CODE" == "404" ]; then
    echo -e "  [${GREEN}PASS${NC}] Corruption detected! Engine refused to load invalid data."
else
    echo -e "  [${RED}FAIL${NC}] Integrity breach! Engine loaded corrupted data (Code: $HTTP_CODE)."
    echo -e "\n--- 🕵️ ENGINE LOGS (PHASE 4) ---"
    docker logs asm_kv_test_run
    exit 1
fi

# 6. Check logs for the alert
if docker logs asm_kv_test_run 2>&1 | grep -qiE "integrity|corruption|CRC"; then
    echo -e "  [${GREEN}PASS${NC}] Engine logged the integrity violation."
else
    echo -e "  [${YELLOW}WARN${NC}] Data blocked, but no integrity alert found in logs."
fi

echo -e "\n${BOLD}${GREEN}====================================================${NC}"
echo -e "${BOLD}${GREEN}   ✔ RECOVERY & INTEGRITY SUITE PASSED             ${NC}"
echo -e "${BOLD}${GREEN}====================================================${NC}"