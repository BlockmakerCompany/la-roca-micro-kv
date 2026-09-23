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

### Docs
- add concurrency ADR, model, and local benchmark baseline
