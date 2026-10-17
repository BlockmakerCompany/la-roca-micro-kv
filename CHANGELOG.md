# Changelog

Todas las modificaciones notables de este proyecto se documentan en este archivo.
El formato sigue Keep a Changelog y este proyecto usa versionado semántico.

## [Unreleased]

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
- Handlers/routers (set, del, scan, router_keys, router_keys_get) enforce
- Fixes test_config_persistence.sh: with ROCK_KEY_SIZE=64, POST wrote the

### Docs
- add concurrency ADR, model, and local benchmark baseline
- document measured SWMR performance
- README: add measured results (GET ~1224 req/s, SET ~885 req/s, k6
- ARCHITECTURE: add §3.4 SWMR concurrency model (per-shard seqlock,
- docs/benchmarks-local.md: record final phase (GET 1224, SET 885) and
