#!/bin/bash
# -----------------------------------------------------------------------------
# Script: tests/test_concurrency.sh
# Project: La Roca Micro-KV
# Responsibility: Stress testing & Race Condition detection.
# -----------------------------------------------------------------------------

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BLUE='\033[0;34m'

API_URL="http://localhost:8080/keys/stress_test"
CONCURRENT_REQUESTS=50

echo -e "\n${BLUE}--- Launching Concurrency & Stress Suite ---${NC}"
echo -e "Sending $CONCURRENT_REQUESTS simultaneous POST requests..."

# Función para enviar una petición
send_request() {
    local id=$1
    curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL" -d "value_from_worker_$id"
}

export -f send_request
export API_URL

# Lanzar peticiones en paralelo usando xargs o un loop de fondo
# Esto simula una ráfaga de tráfico real
RESULTS=$(seq 1 $CONCURRENT_REQUESTS | xargs -I {} -P $CONCURRENT_REQUESTS bash -c "send_request {}")

# Contar cuántos 200 OK obtuvimos
SUCCESS_COUNT=$(echo "$RESULTS" | grep -o "200" | wc -l)

if [ "$SUCCESS_COUNT" -eq "$CONCURRENT_REQUESTS" ]; then
    echo -e "  [${GREEN}PASS${NC}] Processed $SUCCESS_COUNT/$CONCURRENT_REQUESTS concurrent requests."
else
    echo -e "  [${RED}FAIL${NC}] Only $SUCCESS_COUNT/$CONCURRENT_REQUESTS requests succeeded."
    exit 1
fi

# Verificar si el servidor sigue vivo después del bombardeo
echo -e "Checking server stability..."
FINAL_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/stats")

if [ "$FINAL_CHECK" == "200" ]; then
    echo -e "  [${GREEN}PASS${NC}] Server is stable and responsive."
else
    echo -e "  [${RED}FAIL${NC}] Server crashed or is unresponsive after stress test."
    exit 1
fi

echo -e "\n${GREEN}✔ CONCURRENCY TEST PASSED${NC}"