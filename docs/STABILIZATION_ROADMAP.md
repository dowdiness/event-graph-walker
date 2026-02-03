# Roadmap to v1.0 Stable

The library has all core algorithms implemented, 318 tests (including property tests), and a 138x walker optimization. The remaining work is hardening, not building new features.

## Phase 1: Error Handling & API Hardening ✅

- ~~**Strongly type CausalGraph errors**~~ — `CausalGraphError` now has structured variants (`MissingParent`, `MissingEntry`). The text error layer pattern-matches on these variants instead of stringifying.
- ~~**Seal internal APIs**~~ — `TextDoc::inner_document()` and `TextView::inner_branch()` removed from public API. `Document.tree` and `Document.oplog` are now `priv`. Public delegate methods added (`visible_count`, `get_all_ops`, `diff_and_collect`, `checkout_branch`, `get_visible_items`, `lv_to_position`). New `TextDoc::apply_remote()` method provides clean remote op application.
- ~~**Add timeout/cancellation errors**~~ — `SyncFailure::Timeout` and `SyncFailure::Cancelled` variants added with proper `message()`, `help()`, and `is_retryable()` support.

## Phase 1.5: Code Quality & Correctness Issues

Issues identified during codebase analysis that should be addressed before v1.0:

### High Priority

| Issue | Location | Description |
|-------|----------|-------------|
| ~~Missing remote batch validation~~ | `oplog/oplog.mbt:192-216` | ✅ Fixed: Added HashSet-based duplicate detection with `DuplicateOperation` error. |
| Inconsistent error handling in origin mapping | `branch/branch_merge.mbt:100` | Re-examined: Both `origin_left` and `origin_right` consistently raise `MissingOrigin`. No fix needed. |

### Medium Priority

| Issue | Location | Description |
|-------|----------|-------------|
| ~~Undocumented private functions~~ | `walker.mbt:30,81`, `tree.mbt:152,159,213`, `runs.mbt:88,109` | ✅ Fixed: Added `///|` doc comments with invariants and complexity analysis. |
| ~~Unclear delete operation semantics~~ | `core/operation.mbt:39-47` | ✅ Fixed: Added doc comment explaining `origin_left` is the tombstone ID. |
| ~~Asymmetric sync API~~ | `text/sync.mbt` | ✅ Fixed: Added module-level documentation explaining the sender-side filtering pattern. |

### Low Priority

| Issue | Location | Description |
|-------|----------|-------------|
| ~~Frontier allows duplicates~~ | `core/graph_types.mbt:7` | ✅ Fixed: Added `from_array_dedup()` constructor and `has_duplicates()` validation. Documented uniqueness invariant. |
| ~~Inconsistent doc formatting~~ | Multiple files | ✅ Fixed: Standardized on `///|` for module headers and public APIs. |

## Phase 2: Test Coverage Gaps ✅

| Gap | Status |
|-----|--------|
| ~~Undo-redo roundtrip property tests~~ | ✅ Added: `prop_undo_redo_roundtrip_insert`, `prop_undo_redo_roundtrip_mixed`, `prop_undo_ops_sync_to_peer` |
| ~~Concurrent undo/redo with network sync~~ | ✅ Added 5 tests: concurrent undo while peer inserts, concurrent undelete (add-wins), three-agent concurrent undos, undo ops sync to peer, redo after peer sync |
| ~~Large document stress tests (100k+ ops)~~ | ✅ Added 4 benchmarks: walker linear 100k ops, walker concurrent 100k ops (5 agents), oplog sequential typing 100k chars, oplog diff_and_collect 100k ops |
| ~~Network reconnection/sync recovery~~ | ✅ Added 5 tests: peer reconnects after divergence, partial operation log, stale version vector, network partition reunion (3 peers), bidirectional delta after disconnect |
| ~~Cascading error propagation in mid-merge~~ | ✅ Added 4 tests: missing op during apply, apply operations succeeds for valid ops, state unchanged after failure, retreat with missing item |
| ~~Empty version vector operations~~ | ✅ Added 12 tests covering comparison, merge, concurrent, includes, agents, increment, set, to_frontier, from_frontier, and JSON roundtrip on empty VersionVector |
| ~~Frontier with duplicates~~ | ✅ Added `has_duplicates()` validation and `from_array_dedup()` constructor with tests |
| ~~Undelete idempotency~~ | ✅ Added 3 tests: undelete idempotent on visible items, undelete after delete changes state, undelete on missing item raises MissingItem |

All Phase 2 test coverage gaps have been addressed. Property tests protect the core CRDT invariants (convergence, commutativity, idempotence) under undo/redo.

## Phase 3: Network Production Readiness

From `EG_WALKER_IMPLEMENTATION.md` and `NETWORK_SYNC.md`:

1. **Browser peer testing** — verify with 2+ real browser peers over WebRTC
2. **Reconnection scenarios** — test disconnection, partial sync, recovery
3. **Operation compression** — gzip/brotli for `SyncMessage` payloads (currently uncompressed)
4. **Signaling server** — production-grade signaling (currently noted as TODO)

## Phase 4: Performance at Scale

From `OPTIMIZATION_ROADMAP.md` and `EG_WALKER_IMPLEMENTATION.md`:

1. **Branch advance variance** — 55% variance noted; profile and stabilize
2. **B-tree indexing** — needed for documents with 100k+ operations
3. **Lazy loading** — avoid loading entire operation history for large docs
4. **Delta encoding for checkout** — item 17 in `EG_WALKER_IMPLEMENTATION.md:371`

### Specific Performance Issues Identified

| Issue | Location | Severity | Description |
|-------|----------|----------|-------------|
| ~~O(n²) frontier comparison~~ | `branch/branch.mbt:141-158` | High | ✅ Fixed: Now uses sorted array comparison O(n log n) instead of O(n²) nested `.contains()`. Preserves element multiplicity. |
| Unnecessary array copies | `branch.mbt:71,108,124`, `oplog.mbt:159` | Medium | `frontier.0.copy()` and `operations.copy()` in hot paths. Use in-place sort or return iterators. |
| O(n) position mapping | `document/document.mbt:59-79` | Medium | `position_to_lv()` does full tree traversal via `get_visible_items()` on every insert/delete. Cache position→LV mappings. |
| Repeated prefix sum rebuilds | `rle/rle.mbt:45-60` | Low | Already mitigated by lazy `prefix: PrefixSums?` cache, but worth monitoring. |

## Phase 5: Ecosystem Integration

1. **TypeScript/FFI bindings** — README mentions MoonBit FFI but no examples or docs exist
2. **Deployment guide** — Cloudflare Durable Objects referenced but not documented
3. **Persistent storage** — operation log replay from disk (not started)

## Post-v1.0 (Feature Additions)

- Presence awareness (cursor positions, user names)
- Multi-document rooms/channels
- GC/compaction for long-lived documents
- Undo manager Phase 3 (TypeScript wire-up, compaction support)

## Priority Summary

For a stable v1.0, focus on Phases 1–3. Phases 4–5 are optimizations and integrations that can come in point releases. The critical path is:

1. ~~**Seal the public API surface**~~ — Done. Breaking changes get harder after v1.0
2. ~~**Fill property test gaps for undo-redo**~~ — Done. Core roundtrip and sync convergence properties tested
3. ~~**Address Phase 1.5 high-priority issues**~~ — Done. Duplicate operation detection added; error handling verified consistent
4. ~~**Fix O(n²) frontier comparison**~~ — Done. Uses sorted comparison O(n log n) with multiplicity preservation
5. ~~**Fill Phase 2 test coverage gaps**~~ — Done. All 8 gaps addressed with 33 new tests and 4 benchmarks
6. **Validate network sync in a real browser environment** — Remaining

The core algorithm implementation and test coverage are production-quality. Next priority is Phase 3 (browser testing) and Phase 4 (performance optimizations).
