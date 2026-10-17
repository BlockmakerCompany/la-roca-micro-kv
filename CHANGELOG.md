# Changelog

Todas las modificaciones notables de este proyecto se documentan en este archivo.
El formato sigue Keep a Changelog y este proyecto usa versionado semántico.

## [Unreleased]

### Added
- per-shard seqlock with full reader-side protocol
- futex-based ring buffer backpressure (no busy-poll, no overflow)
- group-commit shard msync, remove per-request 64MB flush (SET ~5.3x faster)

### Changed
- ignore db/ data directory and untrack shard files

### Fixed
- dynamic key geometry for SWMR (rt_key_size)

- B-tree entries now use rt_key_size instead of hardcoded 32-byte keys
  (btree.asm, search_engine.asm): entry width and node capacity are
  recomputed in config_runtime.asm (rt_entry_size, rt_node_max_keys).
- Handlers/routers (set, del, scan, router_keys, router_keys_get) enforce
  the key length limit from rt_key_size instead of a fixed 31.
- Fixes test_config_persistence.sh: with ROCK_KEY_SIZE=64, POST wrote the
  slot but GET returned Not Found because the index was still 32-wide.

Verificado: ./tests/run_all_tests.sh -> 6/6 suites en verde.

### Docs
- add concurrency ADR, model, and local benchmark baseline
