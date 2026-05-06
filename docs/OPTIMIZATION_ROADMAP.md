# Performance Optimization Roadmap

> **Status (2026-03-24):** Phases 1, 2b, 3, and binary lifting LCA are all complete. This roadmap was written during Phase 1 and has not been updated with details of later phases. See the archived plans in the parent canopy repo's `docs/archive/` (e.g. `2026-03-17-rle-phase*.md`, `2026-03-18-crdt-append-performance*.md`, `2026-03-18-lww-delete-undelete.md`) for implementation details of each phase.

**Status**: Phase 1 **COMPLETED** ✅ (2026-01-09)
**For detailed performance data**: See [BENCHMARKS.md](./BENCHMARKS.md) and [benchmarks/](./benchmarks/) for snapshots.

---

## 🎉 Major Achievement

**Walker optimization complete - 138x speedup achieved!**

The critical O(n²) bottleneck in topological sort has been eliminated by building a children map for O(1) child lookups instead of O(n) scanning.

### Key Results
| Size | Before | After | Speedup |
|------|--------|-------|---------|
| 100 ops | 259 µs | 54.92 µs | 4.7x |
| 1,000 ops | 26.5 ms | 1.04 ms | 25x |
| **10,000 ops** | **3.93 s** | **28.42 ms** | **138x** ✅ |

**Complexity**: O(n²) → O(n + edges) - Linear scaling restored

---

## Implementation Summary

### ✅ Completed (2026-01-09)

**Walker O(n²) Fix** (`internal/causal_graph/walker.mbt` lines 87-177)
- Built children map: `HashMap[Int, Array[Int]]` during initialization
- Replaced nested loop `for candidate in versions` with direct map lookup
- Impact: 138x speedup at 10k ops, linear scaling across all sizes
- Files: `internal/causal_graph/walker.mbt`
- Tests: All tests passing (current count: 524 across the workspace)

### ✅ Completed (2026-02-04)

**Document Position Cache** (`internal/document/document.mbt`)
- Added lazy `position_cache: OrderTree[VisibleRun]?` for visible items
- O(log n) position→LV lookup via `OrderTree::find`
- Automatically invalidated on any mutation (insert, delete, sync apply)
- Cache invalidation happens *before* tree mutations for exception safety
- Files: `internal/document/document.mbt`, `internal/document/document_wbtest.mbt`

### ✅ Completed (2026-03-31)

**Incremental Position Cache for Non-Sequential Inserts** ([PR #16](https://github.com/dowdiness/event-graph-walker/pull/16))
- Non-sequential inserts (click to new position, then type) previously invalidated cache → O(n) rebuild
- Root cause: defensive `invalidate_cache()` before lookups was unnecessary — cache is always valid at `insert()` entry
- Fix: remove invalidation, use existing cache for lookups, maintain via `OrderTree.insert_at`
- Result: O(n) → O(log n). Single non-seq insert: 1.47ms → 4.79µs (306x) at 1000 chars
- See `docs/benchmarks/2026-03-31-incremental-position-cache.md`

**Zero-Copy Reference Methods** — *Not shipped.* This item was previously
marked ✅ but `Branch::frontier_ref()` and `OpLog::ops_ref()` were never
added. Public `get_frontier()` and `get_all_ops()` still return defensive
copies. Re-evaluate whether internal zero-copy reads are worth introducing
when a profiling case justifies them.

**Code Change**:
```moonbit
// Before: O(n²) - scan all versions for each processed node
for candidate in versions.iter() {
  if entry.parents.contains(current) { /* process */ }
}

// After: O(1) - direct map lookup
match children.get(current) {
  Some(child_list) => for child in child_list { /* process */ }
}
```

---

## Future Work (Optional)

### Priority: Medium - Based on Real-World Usage

**1. Branch Advance Variance** (If real-time issues observed)
- Issue: 55% variance in repeated advance
- Fix: Profile memory/GC, implement incremental updates
- Effort: 2-3 days

**2. Memory Optimizations** (If memory becomes a concern)
- Run-Length Encoding: 50-80% memory reduction
- Object Pooling: Reduce GC pauses
- Effort: 3-5 days each

**3. Advanced Features** (Nice-to-have)
- B-tree indexing for large graphs
- Lazy loading for huge documents (100k+ ops)
- Delta encoding (version vectors already handle this well)
- Compression (if storage is bottleneck)

---

## Current Status

### Production Readiness: ✅ Ready

| Metric | Status |
|--------|--------|
| 10,000 ops | 28ms (target: <500ms) ✅ |
| 100,000 ops | ~280ms (estimated) ✅ |
| Linear scaling | O(n + edges) ✅ |
| Tests | 524 passing ✅ |
| Memory | Stable ✅ |

### Recommendation

✅ **Ship current version** - Performance is excellent for production use
- Walker optimization eliminated the critical bottleneck
- 10k ops in 28ms exceeds target by 17.6x
- Further optimization can be data-driven based on real usage

---

## References

**Detailed Analysis**: [BENCHMARKS.md](./BENCHMARKS.md)
- Current benchmark commands and categories
- Snapshots archived under [benchmarks/](./benchmarks/)

**Architecture**: [EG_WALKER_IMPLEMENTATION.md](./EG_WALKER_IMPLEMENTATION.md)
- Eg-walker CRDT algorithm details
- Implementation guidance

**Testing**: [BENCHMARKS.md](./BENCHMARKS.md)
- How to run benchmarks
- Performance testing guide
