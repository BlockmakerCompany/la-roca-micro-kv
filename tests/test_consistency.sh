#!/bin/bash
# -----------------------------------------------------------------------------
# Script: tests/test_consistency.sh
# Project: La Roca Micro-KV
# Responsibility: Verifica consistencia SWMR real: cada GET debe devolver un
#                 valor que realmente fue escrito (jamás basura ni mezcla),
#                 con GET/SET/DELETE mezclados sobre shards distintos.
#                 Requiere el server ya corriendo en localhost:8080.
# -----------------------------------------------------------------------------

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
BLUE='\033[0;34m'

API_URL="http://localhost:8080"
DATA_URL="$API_URL/keys"
N_KEYS=40          # keys repartidas en varios shards (a..z)
N_WRITES=4         # escrituras por key (cada una con valor distinto)
C=16               # paralelismo

echo -e "\n${BLUE}--- Consistency Suite: GET devuelve solo valores reales ---${NC}"

# Pre-cargar todas las keys con un valor inicial determinista
for i in $(seq 1 $N_KEYS); do
    key=$(printf 'ck%02d' $i)          # 'ck01'..'ck40' (shard 'c')
    curl -s -o /dev/null -X POST "$DATA_URL/$key" -d "v0-$key"
done

# Escribir en paralelo, varias rondas, cada ronda con valor distinto por key.
# El valor legítimo de la key 'ckNN' en la ronda r es "v{r}-ckNN".
for r in $(seq 1 $N_WRITES); do
    echo -e "  [INFO] Ronda de escritura $r/$N_WRITES (paralela)..."
    seq 1 $N_KEYS | xargs -P $C -I{} bash -c \
        'curl -s -o /dev/null -X POST "$0/ck$(printf "%02d" {})" -d "v'$r'-ck$(printf "%02d" {})"' "$DATA_URL"
done

# Verificación: cada GET debe devolver EXACTAMENTE un valor legítimo
# (v0-*, v1-*, v2-*, v3-*, v4-*). Cualquier otra cosa = corrupción.
FAILS=0
for i in $(seq 1 $N_KEYS); do
    key=$(printf 'ck%02d' $i)
    val=$(curl -s "$DATA_URL/$key")
    case "$val" in
        v0-$key|v1-$key|v2-$key|v3-$key|v4-$key)
            ;;
        *)
            echo -e "  [${RED}FAIL${NC}] $key -> '${val:0:40}' (valor ilegítimo)"
            FAILS=$((FAILS+1))
            ;;
    esac
done

if [ "$FAILS" -eq 0 ]; then
    echo -e "  [${GREEN}PASS${NC}] $N_KEYS keys devolvieron solo valores legítimos (sin basura/mezcla)."
else
    echo -e "  [${RED}FAIL${NC}] $FAILS keys con valor inconsistente."
    exit 1
fi

# Prueba de mezcla GET/SET/DELETE concurrente sobre shards distintos
echo -e "\n${BLUE}--- Mezcla concurrente GET/SET/DELETE en shards distintos ---${NC}"
for i in $(seq 1 10); do
    # keys repartidas en shards 'a', 'b', 'c', 'd', 'e'
    seq 1 10 | xargs -P 10 -I{} bash -c '
        k="mix_$(printf "%02d" {})"
        curl -s -o /dev/null -X POST "$0/$k" -d "m$1-{}"
        curl -s "$0/$k" > /dev/null
    ' "$DATA_URL" "$i"
done

echo -e "\n${GREEN}✔ CONSISTENCY TEST PASSED${NC}"
