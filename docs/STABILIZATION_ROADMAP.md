# Roadmap to v1.0 Stable

The library has all core algorithms implemented, 329+ tests (including property tests), and a 138x walker optimization. The remaining work is hardening, not building new features.

## Phase 1: Error Handling & API Hardening ✅

- ~~**Strongly type CausalGraph errors**~~ — `CausalGraphError` now has structured variants (`MissingParent`, `MissingEntry`). The text error layer pattern-matches on these variants instead of stringifying.
- ~~**Seal internal APIs**~~ — `TextDoc::inner_document()` and `TextView::inner_branch()` removed from public API. `Document.tree` and `Document.oplog` are now `priv`. Public delegate methods added (`visible_count`, `get_all_ops`, `diff_and_collect`, `checkout_branch`, `get_visible_items`, `lv_to_position`). New `TextDoc::apply_remote()` method provides clean remote op application.
- ~~**Add timeout/cancellation errors**~~ — `SyncFailure::Timeout` and `SyncFailure::Cancelled` variants added with proper `message()`, `help()`, and `is_retryable()` support.

## Phase 2: Test Coverage Gaps (Partially Complete)

| Gap | Status |
|-----|--------|
| Undo-redo roundtrip property tests | ✅ Added: `prop_undo_redo_roundtrip_insert`, `prop_undo_redo_roundtrip_mixed`, `prop_undo_ops_sync_to_peer` |
| Concurrent undo/redo with network sync | Remaining — `UNDO_MANAGER_DESIGN.md` Phase 3 |
| Large document stress tests (100k+ ops) | Remaining — Benchmarks currently cap at 10k |
| Network reconnection/sync recovery | Remaining — `NETWORK_SYNC.md` TODO |
| Cascading error propagation in mid-merge | Remaining — Not tested anywhere |

Property tests are the highest priority — they protect the core CRDT invariants (convergence, commutativity, idempotence) under undo/redo.

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
3. **Validate network sync in a real browser environment**

The core algorithm implementation and test coverage are already production-quality.
