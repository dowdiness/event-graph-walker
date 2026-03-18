# CRDT Text Append Performance Optimization — Results

**Date:** 2026-03-18
**Environment:** WSL2 Linux 6.6.87, MoonBit, `moon bench --release`

## Summary

The 1000-character sequential append benchmark improved from **4.08 seconds to ~1.5–2.5 milliseconds** — a **~2000x speedup**. All other benchmarks also improved significantly.

## Results

| Benchmark | Baseline | After Optimization | Speedup |
|-----------|----------|-------------------|---------|
| **insert append (1000 chars)** | **4.08s** | **1.48ms – 2.54ms** | **~2000x** |
| insert append (100 chars) | 4.48ms | 89µs – 213µs | ~30x |
| insert prepend (100 chars) | 4.50ms | 1.08ms – 2.07ms | ~3x |
| text() (1000-char doc) | 13.10ms | 250µs – 499µs | ~40x |
| text() (100-char doc) | 107µs | 16µs – 25µs | ~5x |
| delete (100 deletes) | 15.94ms | 2.14ms – 4.49ms | ~5x |

Ranges reflect variance between runs (WSL2 system load).

## Optimizations Applied

### Step 1: Children Index
- Added `HashMap[Lv, Array[Lv]]` to FugueTree for O(1) child lookup
- Eliminated O(n) HashMap scan in `get_children()` / `traverse_tree()`
- All traversals (to_text, position cache, fold) now O(n) instead of O(n²)

### Step 2: Cursor Fast-Path
- Added InsertCursor to Document caching last insert position/LV
- Sequential end-of-document appends skip both `position_to_lv()` and `lv_at_position()`
- Mid-document sequential inserts get partial benefit (origin_left cached)

### Step 3: Batch Cache Invalidation
- Moved `invalidate_cache()` out of per-character insert loop
- Cursor-hit iterations: no cache invalidation (cache never read)
- Cursor-miss iterations: invalidate before reading (same as before)
- Single final invalidation after loop

### Step 4: LCA Index
- Euler Tour + Sparse Table for O(1) `is_ancestor()` queries
- Lazy build on first `is_ancestor()` call after mutation
- `batch_inserting` flag prevents rebuild thrash during merge/checkout/advance
- Zero overhead for sequential append (is_ancestor never called)

## Root Cause Analysis

The O(n²) was caused by three compounding issues in the per-character insert loop:

1. **O(n) cache rebuild** on every char (position_to_lv triggers full tree traversal)
2. **O(n) child scan** in tree traversal (get_children filtered entire HashMap)
3. **O(n) ancestor walk** for concurrent inserts (linear parent pointer chain)

Steps 1-3 eliminated issues 1-2 for sequential appends. Step 4 addressed issue 3 for concurrent/remote ops.

## Checkpoint Decision

Performance is sufficient for interactive editing. A single O(n) cache rebuild per `Document.insert()` call remains — acceptable for all practical document sizes. Incremental position cache (originally planned as Step 5) is **deferred** — blocked by `VisibleRun.can_merge()` safety constraint and not needed given current performance.
