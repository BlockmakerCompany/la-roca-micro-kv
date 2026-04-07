#!/bin/bash

# -----------------------------------------------------------------------------
# Script: tests/test_security.sh
# Project: La Roca Micro-KV
# Responsibility: Hardening & Protocol Boundary Validation (Keep-Alive Compatible).
# -----------------------------------------------------------------------------

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'

API_URL="http://localhost:8080"
DATA_URL="$API_URL/keys"

echo -e "\n${BLUE}--- Launching Security & Hardening Suite ---${NC}"

check_result() {
    if [ "$1" == "$2" ]; then
        echo -e "  [${GREEN}PASS${NC}] $3"
    else
        echo -e "  [${RED}FAIL${NC}] $3 (Expected: $2, Obtained: $1)"
        exit 1
    fi
}

# 1. Discover VAL_MAX for boundary testing
STATS_JSON=$(curl -s "$API_URL/stats")
MAX_KEY_SIZE=$(echo "$STATS_JSON" | grep -Eo '"key_size_bytes":[0-9]+' | cut -d':' -f2)
MAX_SLOT_SIZE=$(echo "$STATS_JSON" | grep -Eo '"slot_size_bytes":[0-9]+' | cut -d':' -f2)
VAL_MAX=$((MAX_SLOT_SIZE - MAX_KEY_SIZE - 3))

# --- S1. Content-Length Enforcement ---
echo -e "\n${YELLOW}S1. Protocol Enforcement (411 & 413)${NC}"

# Test: Missing Content-Length
CODE=$(echo -e "POST /keys/no_cl HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc -w 1 localhost 8080 | grep "HTTP/1.1" | awk '{print $2}')
check_result "$CODE" "411" "Rejection of POST without Content-Length (411)"

# Test: Oversized Payload
OVERSIZE=$((VAL_MAX + 100))
BIG_DATA=$(printf 'X%.0s' $(seq 1 $OVERSIZE))
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$DATA_URL/too_big" -d "$BIG_DATA")
check_result "$CODE" "413" "Rejection of oversized payload (413)"

# Test: Zero Length Payload
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$DATA_URL/zero" -H "Content-Length: 0")
check_result "$CODE" "400" "Rejection of zero-length body (400)"


# --- S2. Header Scan Protection ---
echo -e "\n${YELLOW}S2. Header & Memory Protection${NC}"

# Test: Header Scan Limit
GARBAGE_HEADERS=$(printf 'X-Garbage: abc\r\n%.0s' {1..400})
CODE=$(echo -e "POST /keys/limit HTTP/1.1\r\n${GARBAGE_HEADERS}\r\n" | nc -w 1 localhost 8080 | grep "HTTP/1.1" | awk '{print $2}')
check_result "$CODE" "411" "Header scan limit enforced at 1KB (411 fallback)"


# --- S3. Connection & Persistency Validation ---
echo -e "\n${YELLOW}S3. Connection & Persistency Validation${NC}"

# Test A: Happy Path -> The engine MUST offer Keep-Alive
# Send a valid POST request and capture the header.
HEADER_KA=$(curl -s -v -X POST "$DATA_URL/ka_test" -d "data" 2>&1 | grep -i "< Connection:" | awk '{print $3}' | tr -d '\r')

if [ -z "$HEADER_KA" ]; then
    # Fallback in case curl doesn't spit it out to stderr
    HEADER_KA=$(curl -s -i -X POST "$DATA_URL/ka_test" -d "data" | grep -i "Connection:" | awk '{print $2}' | tr -d '\r')
fi

check_result "$HEADER_KA" "keep-alive" "Success responses offer Keep-Alive"

# Test B: Error Path -> The engine MUST force closure for security (Guillotine)
# Force a 411 Error (Missing Content-Length) by sending a raw request with nc.
HEADER_ERR_CLOSE=$(echo -e "POST /keys/err_close HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc -w 1 localhost 8080 | grep -i "Connection:" | awk '{print $2}' | tr -d '\r')

check_result "$HEADER_ERR_CLOSE" "close" "Error responses still enforce Connection: close"


# --- S4. URI Path Traversal / Sanitization ---
echo -e "\n${YELLOW}S4. URI Path Sanitization${NC}"

# Test: Path Traversal attempt
CODE=$(curl -s -o /dev/null -w "%{http_code}" --path-as-is "$API_URL/keys/../stats")
check_result "$CODE" "404" "Rejection of path traversal (..)"

# Test: Invalid namespace
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/unauthorized/key")
check_result "$CODE" "404" "Rejection of non-routable namespace"


# --- S5. Integer Overflow Parsing ---
echo -e "\n${YELLOW}S5. Integer Overflow Resilience${NC}"
CODE=$(echo -e "POST /keys/overflow HTTP/1.1\r\nContent-Length: 18446744073709551616\r\n\r\n" | nc -w 1 localhost 8080 | grep "HTTP/1.1" | awk '{print $2}')
if [ -z "$CODE" ]; then CODE="CRASH"; fi
check_result "$CODE" "413" "Resilience to Integer Overflow in Content-Length"


# --- S6. Null Byte Poisoning ---
echo -e "\n${YELLOW}S6. Null Byte Injection in URI${NC}"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/keys/test%00secret")
check_result "$CODE" "404" "Null byte injection handled correctly"


# --- S7. Slow Body Attack Resilience ---
echo -e "\n${YELLOW}S7. Slow Body / Incomplete Payload Resilience${NC}"
(echo -e "POST /keys/slow HTTP/1.1\r\nContent-Length: 500\r\n\r\nData"; sleep 0.5) | nc -w 1 localhost 8080 > /dev/null 2>&1
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/live")
check_result "$CODE" "200" "Server remains responsive after slow-body drop"


# --- S8. Verb Tampering ---
echo -e "\n${YELLOW}S8. HTTP Verb Tampering${NC}"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X OPTIONS "$DATA_URL/any")
check_result "$CODE" "404" "Unsupported HTTP verbs return 404"

echo -e "\n${GREEN}✔ Security hardening suite completed successfully.${NC}"