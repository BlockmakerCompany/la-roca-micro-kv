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
| 1 (seqlock por shard) | — | — | |
| 2 (futex) | — | — | |
| 3 (group commit) | — | — | |
| 4 (acceptor+workers+epoll) | — | — | |
