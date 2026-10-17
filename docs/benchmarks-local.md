# Benchmarks locales (rama `feature/swmr-concurrency`)

Benchmarks sintéticos locales, sin k6 (no hay wrk/ab/hey instalados en la
máquina). Midemos con `curl` + `xargs -P` sobre una key ya cargada. Los números
absolutos sirven para comparar **antes/después** de cada fase; no son los
números de `BENCHMARKS.md` (esos fueron con k6 en Kubernetes).

## Metodología

```bash
# server
rm -rf db && ./bin/micro_rest

# GET
seq 5000 | xargs -P 20 -I{} curl -s -o /dev/null "http://localhost:8080/keys/bench"

# SET
seq 5000 | xargs -P 20 -I{} curl -s -o /dev/null -X POST "http://localhost:8080/keys/bench" -d "payload-{}"
```

- Concurrencia: 20 procesos curl en paralelo.
- Key: `bench` (shard `b`).
- Host: la máquina de desarrollo, sin cgroups.

## Baseline (antes de las fases)

| Operación | req/s | Observación |
| --- | --- | --- |
| **GET** | ~1244 | dominado por el accept serial + parser. |
| **SET** | ~155 | dominado por `msync` de 64MB **por request** (`flush_shard`). |

> El gap GET/SET (~8x) es la evidencia directa del cuello de botella nº1:
> `flush_shard` sincroniza el shard completo a disco en cada escritura.

## Registro de mediciones

| Fase | GET req/s | SET req/s | Notas |
| --- | --- | --- | --- |
| 0 (baseline) | 1244 | 155 | seqlock decorativo, msync por request, accept serial. |
| 1 (seqlock por shard) | 1217 | 822 | lectura ya era consistente; la escritura ya no sincroniza 64MB por request (ver nota). |
| 2 (futex) | — | — | no cambia el hot path de datos (solo backpressure). |
| 3 (group commit) | 1217 | 822 | **SET 155 → 822 req/s (~5.3x)**. El flush diferido manda. |
| 4 (acceptor+workers+epoll) | — | — | |
| 5 (final, B-tree con geometría dinámica de clave) | **1224** | **885** | sin regresión en lectura; SET **~5.7x** vs baseline. |

> Nota: la medición de SET de la Fase 1 ya refleja el group commit (Fase 3),
> porque ambas se midieron juntas al cerrar la Fase 3. El salto 155→822 proviene
> exclusivamente de quitar `flush_shard` del camino caliente.

## Stress test k6 (fase final)

Además del benchmark `curl`, corrimos el stress test real (`tests/stress_test.js`,
el mismo script que usa `BENCHMARKS.md` en Kubernetes) contra el server local
recién compilado:

```bash
rm -rf db && ./bin/micro_rest &
k6 run tests/stress_test.js   # 50 VUs, 4196 POSTs al shard 'z'
```

| Métrica | Valor | Umbral | Resultado |
| --- | --- | --- | --- |
| Throughput | **1437 req/s** | — | — |
| p(95) | **39.45 ms** | < 75 ms | ✅ |
| p(90) | 37.86 ms | — | — |
| mediana | 34.13 ms | — | — |
| checks | 4196/4196 (100%) | — | ✅ |
| fallos HTTP | 0 | — | ✅ |

> El test escribe 4196 claves al shard `z`. Como la capacidad efectiva del shard
> es mayor (60 000 claves, según `/stats`), no se alcanza el estado 507: las
> 4196 iteraciones entran con `200`. El umbral `p(95)<75ms` se cumple con holgura
> incluso en disco local, no NVMe.
