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
| 1+3 (seqlock por shard + group commit) | 1217 | 822 | **SET 155 → 822 req/s (~5.3x)**; el salto proviene de quitar `flush_shard` del camino caliente. |
| 2 (futex) | — | — | no cambia el hot path de datos (solo backpressure). |
| 4 (acceptor+workers+epoll) | — | — | |
| 5 (final, B-tree con geometría dinámica de clave) | **1224** | **885** | sin regresión en lectura; SET **~5.7x** vs baseline. |

> Nota: el seqlock por shard (Fase 1) y el group commit (Fase 3) se midieron
> juntos al cerrar la Fase 3, por eso se reportan consolidados en una sola fila.
> El salto 155→822 proviene exclusivamente de quitar `flush_shard` del camino
> caliente (no del seqlock, que no toca la escritura).

## Stress test k6 (test justo para SWMR)

El stress test (`tests/stress_test.js`) fue reescrito para ejercitar la
arquitectura SWMR de 1.2.0 en vez de saturar un único shard. Ahora:

1. **Shards distribuidos:** las claves se reparten entre los 26 shards
   alfabéticos (`a`..`z`), de modo que cada shard compite sólo por su propio
   `seq_lock` y no por un candado global.
2. **Carga mixta:** ~80% GET (lectura lock-free con reintento por seqlock) y
   ~20% POST (camino de escritura con group commit), demostrando que los
   lectores siguen despachando mientras el writer hace su flush diferido.
3. **Concurrencia configurable:** `VUS` (default 500), `DURATION` (default
   `30s`), `READ_RATIO` (default 0.8) y `POOL_KEYS` vía variables de entorno.
4. **`FLUSH_EVERY` 32 → 128:** el `msync` de shards (ya `MS_ASYNC`, fuera del
   camino caliente) se difiere más, despejando aún más la escritura. La
   durabilidad por write la garantiza el WAL `O_DSYNC`.

```bash
rm -rf db && ./bin/micro_rest &
k6 run tests/stress_test.js           # 500 VUs, 30s, 80/20 GET/POST
k6 run -e VUS=1000 -e DURATION=60s tests/stress_test.js
```

### Resultados (500 VUs, 30s, disco local)

| Métrica | Valor | Umbral | Resultado |
| --- | --- | --- | --- |
| Fallos HTTP | **0 / 19 609** | `rate < 0.001` | ✅ |
| checks (GET 200 + POST 200) | 18 569 / 18 569 (100%) | — | ✅ |
| Throughput | **~339 req/s** | — | — |
| mediana | 40.95 ms | — | — |
| p(95) | 4.14 s | — | — |

> Con 500 VUs el server encola pedidos en el backlog: los p95 altos son *tiempo
> de cola*, no latencia del motor. La métrica que demuestra el punto de la demo
> es `http_req_failed = 0.00%`: el backpressure (futex) + la capa de aceptación
> aguantan el "tsunami" sin un solo fallo HTTP.

### Fix de capa HTTP (no era el motor)

Al subir la concurrencia aparecieron fallos de transporte (`EOF` y
`connection reset by peer`) a ~0.26-1%, **sin ningún 404/500 del motor**. La
causa era la capa de aceptación, no el SWMR:

- `NUM_READERS` 4 → **16** (los GET son síncronos: más readers = más lecturas
  lock-free concurrentes).
- Backlog de `listen` 128 → **4096** (evita RST por cola llena con 500+ VUs).
- `SO_RCVTIMEO` de keep-alive 10 ms → **1 s** (10 ms cerraba conexiones
  keep-alive a mitad de handshake bajo carga).

Tras el fix: `http_req_failed = 0.00%` a 500 VUs.
