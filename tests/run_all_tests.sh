#!/bin/bash

# -----------------------------------------------------------------------------
# Script: run_all_tests.sh
# Project: La Roca Micro-KV
# Responsibility: Master Test Orchestrator. Executes all suites and optional
#                 K6 stress testing.
# -----------------------------------------------------------------------------

# --- UI Configuration ---
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'

echo -e "${BOLD}${BLUE}====================================================${NC}"
echo -e "${BOLD}${BLUE}   La Roca Micro-KV: Full Validation Pipeline       ${NC}"
echo -e "${BOLD}${BLUE}====================================================${NC}"

# Helper to run scripts and check exit codes
run_suite() {
    local script_path=$1
    local description=$2

    echo -e "\n${YELLOW}🚀 Running: $description...${NC}"

    if [ ! -f "$script_path" ]; then
        echo -e "${RED}  [ERROR] Script not found: $script_path${NC}"
        exit 1
    fi

    chmod +x "$script_path"
    ./"$script_path"

    if [ $? -ne 0 ]; then
        echo -e "\n${RED}❌ $description FAILED. Aborting pipeline.${NC}"
        exit 1
    fi
}

# --- 1. Core Test Suites (Mandatory) ---
run_suite "tests/test_config_persistence.sh" "Config & Persistence Integrity"
run_suite "tests/test_engine.sh"             "Functional CRUD & B-Tree Suite"
run_suite "tests/test_recovery.sh"           "WAL & Fault Recovery"
run_suite "tests/test_security.sh"           "Security Hardening & Protocol"
run_suite "tests/test_concurrency.sh"        "Atomic Concurrency & Race Conditions"

# --- 2. Optional Stress Testing (K6) ---
if [[ "$1" == "--stress" ]]; then
    echo -e "\n${BOLD}${BLUE}🔥 Starting K6 Stress Test Session...${NC}"
    if command -v k6 &> /dev/null; then
        k6 run tests/stress_test.js
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Stress test failed to meet thresholds.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}  [ERROR] K6 is not installed. Skipping stress test.${NC}"
    fi
fi

echo -e "\n${BOLD}${GREEN}====================================================${NC}"
echo -e "${BOLD}${GREEN}   ✔ ALL SYSTEMS OPERATIONAL - ENGINE IS STABLE     ${NC}"
echo -e "${BOLD}${GREEN}====================================================${NC}"