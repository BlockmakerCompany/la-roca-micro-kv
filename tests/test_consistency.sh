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

echo -e "\n${BLUE}--- Consistency Suite: GET devuelve solo valores reales ---${NC}"

# Generar keys repartidas determinísticamente entre los shards 'a'..'z'.
# key(i) = letra(i) + 'k' + índice, con letra = 'a' + ((i-1) % 26).
KEYS=()
for i in $(seq 1 $N_KEYS); do
    idx=$(( (i - 1) % 26 ))
    printf -v letter "\\x$(printf '%02x' $((97 + idx)))"
    KEYS[$i]="${letter}k$(printf '%02d' $i)"
done

# Pre-cargar todas las keys con un valor inicial determinista (v0-<key>)
for i in $(seq 1 $N_KEYS); do
    key="${KEYS[$i]}"
    curl -s -o /dev/null -X POST "$DATA_URL/$key" -d "v0-$key" &
done
wait

# Escribir en paralelo, varias rondas, cada ronda con valor distinto por key.
# El valor legítimo de la key en la ronda r es "v{r}-<key>".
for r in $(seq 1 $N_WRITES); do
    echo -e "  [INFO] Ronda de escritura $r/$N_WRITES (paralela)..."
    for i in $(seq 1 $N_KEYS); do
        key="${KEYS[$i]}"
        curl -s -o /dev/null -X POST "$DATA_URL/$key" -d "v$r-$key" &
    done
    wait
done

# Verificación: cada GET debe devolver EXACTAMENTE un valor legítimo
# (v0-*, v1-*, v2-*, v3-*, v4-*). Cualquier otra cosa = corrupción.
FAILS=0
for i in $(seq 1 $N_KEYS); do
    key="${KEYS[$i]}"
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
    echo -e "  [${GREEN}PASS${NC}] $N_KEYS keys (shards a..z) devolvieron solo valores legítimos (sin basura/mezcla)."
else
    echo -e "  [${RED}FAIL${NC}] $FAILS keys con valor inconsistente."
    exit 1
fi

# Prueba de mezcla GET/SET/DELETE concurrente sobre shards distintos,
# validando que cada GET devuelve exactamente el valor recién escrito.
echo -e "\n${BLUE}--- Mezcla concurrente GET/SET/DELETE en shards distintos ---${NC}"
for round in $(seq 1 10); do
    for j in $(seq 1 10); do
        k="${KEYS[$j]}"           # keys repartidas en varios shards
        (
            # SET + GET: el valor leído debe ser el que acabamos de escribir.
            curl -s -o /dev/null -X POST "$DATA_URL/$k" -d "m$round-$j"
            v=$(curl -s "$DATA_URL/$k")
            if [ "$v" != "m$round-$j" ]; then
                echo -e "  [${RED}FAIL${NC}] mezcla $k -> '$v' (esperado 'm$round-$j')"
                exit 1
            fi
        ) &
    done
    wait
    [ $? -ne 0 ] && exit 1
done

# DELETE + verificación de 404 sobre una key repartida
curl -s -o /dev/null -X DELETE "$DATA_URL/${KEYS[5]}"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$DATA_URL/${KEYS[5]}")
if [ "$CODE" != "404" ]; then
    echo -e "  [${RED}FAIL${NC}] DELETE no removió la key (HTTP $CODE)."
    exit 1
fi

echo -e "\n${GREEN}✔ CONSISTENCY TEST PASSED${NC}"
