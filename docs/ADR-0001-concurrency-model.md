# ADR-0001: Modelo de concurrencia SWMR con consistencia por shard

- **Estado:** Aceptado — Fase 1 (seqlock por shard) implementada y verificada
- **Fecha:** 2026-01-24
- **Decidido por:** bk (agente terminal), junto con la persona a cargo del repo
- **Rama:** `feature/swmr-concurrency`

## Contexto

La Roca Micro-KV es un motor key-value en x86_64 Assembly puro (sin libc). El
servicio debe soportar múltiples hilos para aprovechar CPU y reducir el cuello
de botella del accept serial, **sin romper la consistencia** de los datos.

Estado actual verificado sobre la rama `feature/swmr-concurrency`:

1. Hay un intento de SWMR a medias: un writer thread (`sys_clone` en
   `src/main.asm`) + un ring buffer de 16 jobs (`src/core/worker.asm`) + un
   `seq_lock` global (`src/main.asm:68`).
2. **El seqlock no protege a nadie:** `src/handlers/set.asm` hace
   `lock inc [seq_lock]` antes/después del insert, pero **ningún reader lo lee**.
   `btree_find` (GET) y `handle_scan` leen el árbol sin validación de paridad.
3. **`btree_insert` muta en sitio** (shift-and-insert y split reasignan el root
   y reencadenan hojas). Un GET concurrente en pleno split ve estado transitorio.
4. **El ring buffer no tiene backpressure:** `enqueue_job` no chequea si la cola
   está llena; bajo ráfaga el productor pisa jobs sin consumir. El writer usa
   busy-poll con `nanosleep 1ms`, no futex.
5. **`flush_shard` hace `msync` de los 64MB del shard entero en cada SET y en
   cada DELETE** (`src/core/storage.asm:65`). Es el cuello de botella nº1 de
   escritura y anula la ganancia del writer thread.
6. El test de concurrencia actual (`tests/test_concurrency.sh`) solo cuenta
   HTTP 200; no detecta lecturas inconsistentes.

## Decisión

Adoptar **SWMR (Single Writer, Multiple Reader) por shard**, con estos pilares:

1. **Seqlock por shard** (`seq_locks[27]`), no un lock global. Un request que
   toca el shard `a` nunca compite con uno que toca el shard `b`. Esto convierte
   el particionamiento ya existente (27 shards en `src/core/storage.asm`) en
   paralelismo real.
2. **Protocolo seqlock completo:** el writer incrementa el lock del shard antes
   y después de mutar (haciéndolo impar/par); el reader lee el lock (debe ser
   par), lee los datos, relee el lock, y reintenta si cambió.
3. **Backpressure con futex** en el ring buffer: el productor espera en
   `sys_futex` cuando la cola está llena; el consumidor hace `wake` al avanzar.
   Se elimina el busy-poll y el overflow silencioso.
4. **Group commit:** el `msync` del shard sale del camino caliente. La
   durabilidad la garantiza el WAL (`O_DSYNC`); el `msync` se difiere a batches
   en el writer thread.
5. **Concurrencia del lado servidor:** acceptor + pool de N workers + `epoll`
   (y `io_uring` como follow-up optativo). GET corre en paralelo; SET serializa
   por shard.

## Alternativas consideradas

| Alternativa | Rechazada porque |
| --- | --- |
| Un solo lock global (mutex/spinlock) | Serializa los 27 shards; mata el paralelismo que ya existe gratis. |
| Lock por registro/slot | Contención y footprint de memoria altos; el shard es el grano natural del árbol. |
| Copy-on-write total del árbol | Costo de copiar nodos en cada escritura; se descarta como primera iteración pero se mantiene como opción para el split del B+Tree si el reintento del seqlock no alcanza. |
| io_uring directo sin epoll | Complejidad alta para un primer corte; queda como follow-up (Fase 4b). |

## Consecuencias

- **Positivas:** lecturas sin bloqueo (solo reintento en colisión), escrituras
  paralelas entre shards distintos, backpressure determinista, escritura sin
  `msync` por request.
- **Negativas / a vigilar:** el reader puede reintentar bajo escritura intensa
  en el mismo shard (tradeoff clásico de seqlock); el split del B+Tree sigue
  mutando en sitio, así que el seqlock debe cubrir el insert **entero**, no solo
  el slot.
- **Riesgo de migración:** no hay migración de datos; el cambio es de código de
  acceso, no de formato en disco. El header de shard (`offset 8/32`) no se toca.

## Referencias

- `docs/concurrency.md` — estado actual y modelo objetivo detallado.
- `ARCHITECTURE.md` — fundamentos del motor.
- `BENCHMARKS.md` — benchmarks previos (k6).
