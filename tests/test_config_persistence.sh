#!/bin/bash

# -----------------------------------------------------------------------------
# Script: tests/test_config_persistence.sh
# Project: La Roca Micro-KV
# Responsibility: Disk Authority & Namespace Isolation Validation.
#                 1. Verifies Disk Geometry (Slot/Key size) persistence.
#                 2. Validates that /keys/ prefix prevents system collisions.
# -----------------------------------------------------------------------------

# --- Environment Pre-flight ---
PORT=8086
IMAGE_NAME="blockmaker/la-roca-kv:1.1.0"

TEST_DIR="$(pwd)/asm_kv_config_test_$$"
# Keys for testing (Note: No leading slash here, handled by the API path)
GEOM_KEY="persistence_check"
COLLISION_KEY="stats"

TEST_VAL="Data_protected_by_disk_authority"
COLLISION_VAL="User_data_named_stats"

INITIAL_SLOT_SIZE=2048
INITIAL_KEY_SIZE=64

POISON_SLOT_SIZE=4096
POISON_KEY_SIZE=128

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'

echo -e "${BLUE}--- Starting Configuration Hierarchy & Namespace Isolation Test ---${NC}"

mkdir -p "$TEST_DIR"

cleanup() {
    echo -e "\n[INFO] Performing post-test cleanup..."
    docker stop asm_kv_config_run > /dev/null 2>&1
    docker rm asm_kv_config_run > /dev/null 2>&1
    rm -rf "$TEST_DIR"
    echo -e "${BLUE}--- Test environment purged ---${NC}"
}
trap cleanup EXIT

# --- Phase 1: Initial Boot & Data Injection ---
echo -e "\n[INFO] Phase 1: Launching engine with Geometry: Slot=$INITIAL_SLOT_SIZE, Key=$INITIAL_KEY_SIZE"
docker run -d --name asm_kv_config_run \
    -p $PORT:8080 \
    -e ROCK_SLOT_SIZE=$INITIAL_SLOT_SIZE \
    -e ROCK_KEY_SIZE=$INITIAL_KEY_SIZE \
    -v "$TEST_DIR:/app/db" \
    $IMAGE_NAME > /dev/null

sleep 2

# 1.1 Verify initial geometry via system endpoint
STATS1=$(curl -s "http://localhost:$PORT/stats")
SLOT_VAL1=$(echo "$STATS1" | grep -Eo '"slot_size_bytes":[0-9]+' | cut -d':' -f2)
if [ "$SLOT_VAL1" != "$INITIAL_SLOT_SIZE" ]; then
    echo -e "${RED}[FAIL] Phase 1: Engine failed to apply initial Slot Size.${NC}"
    exit 1
fi

# 1.2 Write to the new /keys/ namespace
echo -e "[INFO] Writing data to /keys/$GEOM_KEY..."
curl -s -X POST "http://localhost:$PORT/keys/$GEOM_KEY" -d "$TEST_VAL" > /dev/null

# 1.3 THE COLLISION TEST: Write to /keys/stats
echo -e "[INFO] Writing 'collision' data to /keys/$COLLISION_KEY..."
curl -s -X POST "http://localhost:$PORT/keys/$COLLISION_KEY" -d "$COLLISION_VAL" > /dev/null

# --- Phase 2: Reboot with Poisoned Env ---
echo -e "\n[INFO] ${YELLOW}Rebooting with envenomed Environment Variables...${NC}"
docker stop asm_kv_config_run > /dev/null
docker rm asm_kv_config_run > /dev/null

docker run -d --name asm_kv_config_run \
    -p $PORT:8080 \
    -e ROCK_SLOT_SIZE=$POISON_SLOT_SIZE \
    -e ROCK_KEY_SIZE=$POISON_KEY_SIZE \
    -v "$TEST_DIR:/app/db" \
    $IMAGE_NAME > /dev/null

sleep 2

# --- Phase 3: Final Audit ---
echo -e "[INFO] Performing Final Audit..."

# 3.1 Check if Disk Authority held the line
STATS_FINAL=$(curl -s "http://localhost:$PORT/stats")
SLOT_FINAL=$(echo "$STATS_FINAL" | grep -Eo '"slot_size_bytes":[0-9]+' | cut -d':' -f2)
KEY_FINAL=$(echo "$STATS_FINAL" | grep -Eo '"key_size_bytes":[0-9]+' | cut -d':' -f2)

if [ "$SLOT_FINAL" = "$INITIAL_SLOT_SIZE" ]; then
    echo -e "  [${GREEN}PASS${NC}] Disk Authority: Geometry remains immutable."
else
    echo -e "  [${RED}FAIL${NC}] Geometry Poisoning successful! Expected $INITIAL_SLOT_SIZE, got $SLOT_FINAL"
    exit 1
fi

# 3.2 Check Data Integrity (Correct Offsets)
READ_VAL=$(curl -s "http://localhost:$PORT/keys/$GEOM_KEY")
if [ "$READ_VAL" = "$TEST_VAL" ]; then
    echo -e "  [${GREEN}PASS${NC}] Data Integrity: Correct value retrieved from /keys/ namespace."
else
    echo -e "  [${RED}FAIL${NC}] Data Corruption or Offset Mismatch! Got: '$READ_VAL'"
    exit 1
fi

# 3.3 Check Namespace Isolation (The 'stats' test)
# GET /stats should return JSON
# GET /keys/stats should return COLLISION_VAL
SYSTEM_STATS=$(curl -s "http://localhost:$PORT/stats")
USER_STATS=$(curl -s "http://localhost:$PORT/keys/$COLLISION_KEY")

if [[ "$SYSTEM_STATS" == *"engine"* ]] && [[ "$USER_STATS" == "$COLLISION_VAL" ]]; then
    echo -e "  [${GREEN}PASS${NC}] Namespace Isolation: System /stats and /keys/stats coexist perfectly."
else
    echo -e "  [${RED}FAIL${NC}] Namespace Collision detected!"
    echo "System /stats: $SYSTEM_STATS"
    echo "User /keys/stats: $USER_STATS"
    exit 1
fi

echo -e "\n${GREEN}✔ All persistence and namespace tests PASSED.${NC}"