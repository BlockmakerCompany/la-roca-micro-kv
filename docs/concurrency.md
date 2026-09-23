# Concurrencia en La Roca Micro-KV

Documento de trabajo de la rama `feature/swmr-concurrency`. Describe el estado
actual del camino de lectura/escritura, los problemas de consistencia
verificados y el modelo objetivo por fases. Las decisiones formales están en
[`ADR-0001-concurrency-model.md`](ADR-0001-concurrency-model.md).

## Estado actual (verificado)

### Camino de escritura

```
cliente → accept (main.asm, serial)
        → http_parser
        → router_keys_set.asm
        → enqueue_job (ring buffer de 16 jobs, worker.asm)
        → writer thread (sys_clone) → handle_set / handle_del
              → btree_insert/delete (mutación en sitio)
              → flush_shard (msync 64MB POR request)
```

- `src/main.asm:114-125` spawnea el writer thread con `sys_clone`
  (`CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD`).
- `src/core/worker.asm` implementa el ring buffer: 16 jobs de 8208 bytes.
  `enqueue_job` escribe sin chequear si la cola está llena.
- `src/handlers/set.asm:198,209` hace `lock inc [seq_lock]` (global) pero nadie
  lo lee del lado lector.
- `src/handlers/set.asm:216-217` y `src/handlers/del.asm:53` llaman
  `flush_shard` (msync de 64MB) en cada escritura.

### Camino de lectura

- `src/routers/router_keys_get.asm` → `btree_find` (búsqueda O(log N)).
- `src/data/search_engine.asm` → `btree_find` recorre el B+Tree **sin ningún
  protocolo de consistencia**.
- `src/handlers/scan.asm` → `handle_scan` recorre la lista enlazada de hojas,
  también sin protección.

### Problemas de consistencia

1. **Seqlock decorativo:** el writer marca par/impar pero el reader no valida
   paridad ni reintenta.
2. **Mutación en sitio:** `btree_insert` reordena claves y reasigna root/hojas;
   un GET concurrente ve estado transitorio.
3. **Sin backpressure:** overflow silencioso del ring buffer bajo ráfaga.
4. **msync por request:** escritura dominada por el flush de 64MB.

## Modelo objetivo (por fases)

### Fase 1 — Seqlock por shard

```
seq_locks[27]  (reemplaza al seq_lock único en main.asm:68)

Writer (handle_set / handle_del):
  1. shard_idx = primera letra de la key (mismo criterio que get_shard_ptr)
  2. lock inc [seq_locks + shard_idx*8]   ; impar = escritura en curso
  3. btree_insert / btree_delete          ; mutación protegida
  4. lock inc [seq_locks + shard_idx*8]   ; par = consistente

Reader (btree_find / handle_scan):
  loop:
    seq1 = [seq_locks + shard_idx*8]
    if (seq1 & 1) continue                 ; escritura en curso
    resultado = leer datos
    seq2 = [seq_locks + shard_idx*8]
    if (seq1 != seq2) continue             ; hubo escritura, reintentar
    return resultado
```

> El seqlock debe cubrir el insert **entero** (incluido el split), no solo el
> slot, porque el árbol se muta en sitio.

**Estado Fase 1: IMPLEMENTADA.** Cambios:

- `src/core/storage.asm`: `seq_locks[27]`, `get_shard_index`, `shard_seq_inc`,
  `shard_seq_read`.
- `src/main.asm`: se eliminó el `seq_lock` global.
- `src/handlers/set.asm` y `del.asm`: writer toma/suelta el lock del shard
  correcto alrededor de la mutación.
- `src/handlers/get.asm`: protocolo seqlock completo (paridad + reintento).
- `src/handlers/scan.asm`: barrera seqlock antes de cada salto de hoja
  (evita navegar el árbol durante un split/rebalance).

> Nota de consistencia del scan: la barrera evita leer punteros a medio mutar,
> pero un range-scan sobre datos mutando **no** es snapshot-consistente (un SET
> entre dos hojas puede dar un rango ligeramente desalineado). Es un tradeoff
> aceptado y documentado; el GET punto-a-punto sí es atómicamente consistente.

Verificación Fase 1: `test_engine.sh`, `test_security.sh`, `test_concurrency.sh`
y el nuevo `test_consistency.sh` pasan.

### Fase 2 — Backpressure con futex

- `enqueue_job`: si `tail - head >= 16`, `sys_futex(FUTEX_WAIT)`.
- writer: al avanzar `head`, `sys_futex(FUTEX_WAKE)`.
- Se elimina el `nanosleep` busy-poll.

### Fase 3 — Group commit

- Quitar `flush_shard` de SET/DELETE.
- Durabilidad vía WAL (`O_DSYNC`); `msync` diferido a batch en el writer thread.

### Fase 4 — Concurrencia del servidor

- 4a: acceptor + pool de N workers + `epoll`. GET en paralelo, SET por shard.
- 4b: `io_uring` (optativo, follow-up).

### Fase 5 — Tests

- GET/SET/DELETE mezclados a keys de shards distintos; cada GET debe devolver un
  valor realmente escrito (jamás basura ni mezcla).
- Crash-recovery con WAL.
- Benchmark antes/después.

## Cómo verificar

```bash
make all                                  # compila
cd tests && ./run_all_tests.sh            # suite completa
# benchmark local (sin wrk/ab): docs/benchmarks-local.md
```
