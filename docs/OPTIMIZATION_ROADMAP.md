# Performance Optimization Roadmap

**Status**: Phase 1 **COMPLETED** ✅ (2026-01-09)
**For detailed performance data**: See [PERFORMANCE_ANALYSIS.md](./PERFORMANCE_ANALYSIS.md)

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

**Walker O(n²) Fix** (`causal_graph/walker.mbt` lines 87-177)
- Built children map: `HashMap[Int, Array[Int]]` during initialization
- Replaced nested loop `for candidate in versions` with direct map lookup
- Impact: 138x speedup at 10k ops, linear scaling across all sizes
- Files: `causal_graph/walker.mbt`
- Tests: All 330 tests passing

### ✅ Completed (2026-02-04)

**Document Position Cache** (`document/document.mbt`)
- Added lazy `position_cache: Array[(Int, @fugue.Item)]?` for visible items
- First access: O(n) tree traversal, subsequent lookups: O(1)
- Automatically invalidated on any mutation (insert, delete, sync apply)
- Cache invalidation happens *before* tree mutations for exception safety
- Files: `document/document.mbt`, `document/document_test.mbt`

**Zero-Copy Reference Methods** (`branch/branch.mbt`, `oplog/oplog.mbt`)
- Added `Branch::frontier_ref()` - returns frontier without copying
- Added `OpLog::ops_ref()` - returns operations without copying
- For internal/read-only use; callers must not mutate returned arrays
- Public methods (`get_frontier()`, `get_all_ops()`) still return defensive copies

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
| Tests | 330/330 passing ✅ |
| Memory | Stable ✅ |

### Recommendation

✅ **Ship current version** - Performance is excellent for production use
- Walker optimization eliminated the critical bottleneck
- 10k ops in 28ms exceeds target by 17.6x
- Further optimization can be data-driven based on real usage

---

## References

**Detailed Analysis**: [PERFORMANCE_ANALYSIS.md](./PERFORMANCE_ANALYSIS.md)
- Complete benchmark results (56 tests across 5 modules)
- Performance analysis for each component
- Optimization details and trade-offs

**Architecture**: [EG_WALKER_IMPLEMENTATION.md](./EG_WALKER_IMPLEMENTATION.md)
- Eg-walker CRDT algorithm details
- Implementation guidance

**Testing**: [BENCHMARKS.md](./BENCHMARKS.md)
- How to run benchmarks
- Performance testing guide
