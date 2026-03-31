# Incremental Position Cache for Non-Sequential Inserts

**Date:** 2026-03-31
**PR:** [#16](https://github.com/dowdiness/event-graph-walker/pull/16)

## Problem

Non-sequential inserts (clicking to a new cursor position then typing) invalidated the position cache and forced a full O(n) rebuild via `traverse_tree` + `OrderTree.from_array`.

## Fix

Remove defensive `invalidate_cache()` from cursor-miss and partial-cursor-hit paths. Use existing cache for lookups, maintain incrementally via `OrderTree.insert_at`.

## Position cache benchmarks

### Before (origin/main, O(n) rebuild)

| Benchmark | Time |
|-----------|------|
| cache - sequential append (1000 chars) | 827µs |
| cache - alternating pos (1000 chars) | 87.86ms |
| cache - jump every 10 chars (1000 chars) | 115.95ms |
| cache - single non-seq insert on 1000-char doc | 1.47ms |
| cache - single non-seq insert on 5000-char doc | 4.99ms |

### After (O(log n) incremental)

| Benchmark | Time |
|-----------|------|
| cache - sequential append (1000 chars) | 1.29ms |
| cache - alternating pos (1000 chars) | 2.33ms |
| cache - jump every 10 chars (1000 chars) | 1.59ms |
| cache - single non-seq insert on 1000-char doc | 4.79µs |
| cache - single non-seq insert on 5000-char doc | 4.69µs |

### Improvement

| Benchmark | Before | After | Speedup |
|-----------|--------|-------|---------|
| Alternating positions (1000) | 87.86ms | 2.33ms | **37.7x** |
| Jump every 10 chars (1000) | 115.95ms | 1.59ms | **72.9x** |
| Single non-seq (1000-char) | 1.47ms | 4.79µs | **306x** |
| Single non-seq (5000-char) | 4.99ms | 4.69µs | **1064x** |

5000-char ≈ 1000-char confirms O(log n) scaling.

## Full text benchmark suite (no regressions)

| Benchmark | Time |
|-----------|------|
| text - insert append (100 chars) | 84.29µs |
| text - insert append (1000 chars) | 1.42ms |
| text - insert prepend (100 chars) | 126.11µs |
| text - delete (100 deletes from 100-char doc) | 215.18µs |
| text - text() (100-char doc) | 12.13µs |
| text - text() (1000-char doc) | 133.66µs |
| text - sync export_all (100 ops) | 0.09µs |
| text - sync export_all (1000 ops) | 0.08µs |
| text - sync export_since (50-op delta, 1000-op base) | 29.11µs |
| text - sync apply (50 remote ops) | 47.36µs |
| text - sync apply (500 remote ops) | 611.60µs |
| text - bidirectional sync (2 peers, 50 ops each) | 102.49µs |
| text - checkout (midpoint of 100-op doc) | 12.21µs |
| text - checkout (midpoint of 1000-op doc) | 149.94µs |

## Environment

- Platform: Linux 6.6.87.2-microsoft-standard-WSL2
- Command: `moon bench --package text --release`
