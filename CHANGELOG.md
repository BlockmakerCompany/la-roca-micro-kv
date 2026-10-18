# Changelog

Todas las modificaciones notables de este proyecto se documentan en este archivo.
El formato sigue Keep a Changelog y este proyecto usa versionado semántico.

## [Unreleased]

### Changed
- fair k6 stress test and HTTP-layer scaling for high concurrency

- Rewrite tests/stress_test.js to exercise the SWMR model: keys spread
  across the 26 alphabetic shards, 80/20 GET/POST mixed load, and tunable
  VUs/DURATION/READ_RATIO via env (default 500 VUs / 30s). Threshold is now
  http_req_failed < 0.1% instead of the p95 latency (loopback saturates
  before the engine does).
- Raise FLUSH_EVERY 32 -> 128: the shard msync is already MS_ASYNC and off
  the hot path, so deferring it further clears the write path. Per-write
  durability is still guaranteed by the O_DSYNC WAL.
- Scale the accept layer to absorb high VU load without transport failures:
  NUM_READERS 4 -> 16, listen backlog 128 -> 4096, and keep-alive
  SO_RCVTIMEO 10ms -> 1s. At 500 VUs this drops http_req_failed from ~1%
  (EOF/RST) to 0.00%.

Verified: make clean; k6 500 VUs / 30s -> 0 failed requests (19609 total),
100% checks (GET 200 + POST 200). The earlier intermittent 404 was a test
artifact (multiple SO_REUSEPORT instances), not an engine bug.

### Fixed
- address PR #19 review feedback
- set.asm: fix double close on error paths (handle_400/handle_507 already close)
- del.asm: fix fd leak on key-miss (handle_404 responds but does not close)
- worker.asm: bound FUTEX_WAIT with a 1s timeout so a dead writer cannot hang readers
- config_runtime.asm: validate key size (1..32), value size (<=985) and node max keys (<=65535) before layout math; refuse to start on violation
- storage.asm: use MS_ASYNC for the periodic shard flush (no ~1.7GB stall); document seqlock memory barriers
- tests: test_consistency spreads keys across shards and validates GETs; test_config_persistence uses key sizes within the WAL limit
- docs: clarify durability bound, benchmark table, README speedup attribution, complete truncated changelog entries

## [v1.2.0] - 2026-10-17

### Added
- per-shard seqlock with full reader-side protocol
- futex-based ring buffer backpressure (no busy-poll, no overflow)
- group-commit shard msync, remove per-request 64MB flush (SET ~5.3x faster)

### Changed
- ignore db/ data directory and untrack shard files

### Fixed
- dynamic key geometry for SWMR (rt_key_size)
- B-tree entries now use rt_key_size instead of hardcoded 32-byte keys
- Handlers/routers (set, del, scan, router_keys, router_keys_get) enforce the key length limit from rt_key_size instead of a fixed 31
- Fixes test_config_persistence.sh: with ROCK_KEY_SIZE=64, POST wrote the slot but GET returned Not Found because the index was still 32-wide

### Docs
- add concurrency ADR, model, and local benchmark baseline
- document measured SWMR performance
- README: add measured results (GET ~1224 req/s, SET ~885 req/s, k6 50 VUs ~1437 req/s / p95 39.45ms) and clarify read vs write latency
- ARCHITECTURE: add §3.4 SWMR concurrency model (per-shard seqlock, futex backpressure, group commit); note dynamic B+Tree key geometry
- docs/benchmarks-local.md: record final phase (GET 1224, SET 885) and the k6 stress test run
