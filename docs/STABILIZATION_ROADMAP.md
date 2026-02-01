# Roadmap to v1.0 Stable

The library has all core algorithms implemented, 329+ tests (including property tests), and a 138x walker optimization. The remaining work is hardening, not building new features.

## Phase 1: Error Handling & API Hardening

- **Strongly type CausalGraph errors** — currently uses `CausalGraphError(error~ : String)` instead of structured variants. Every other module has proper suberror types.
- **Seal internal APIs** — `TextDoc::inner_document()`, `inner_branch()`, and direct field access on `Document.tree` / `Document.oplog` leak implementation details. These should be `priv` or removed from the public `.mbti` interface before v1.0.
- **Add timeout/cancellation errors** for sync operations.

## Phase 2: Test Coverage Gaps

| Gap | Where Noted |
|-----|-------------|
| Undo-redo roundtrip property tests | `UNDO_MANAGER_DESIGN.md:552-554` |
| Concurrent undo/redo with network sync | `UNDO_MANAGER_DESIGN.md` Phase 3 |
| Large document stress tests (100k+ ops) | Benchmarks currently cap at 10k |
| Network reconnection/sync recovery | `NETWORK_SYNC.md` TODO |
| Cascading error propagation in mid-merge | Not tested anywhere |

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

1. **Seal the public API surface** — breaking changes get harder after v1.0
2. **Fill property test gaps for undo-redo** — correctness guarantee
3. **Validate network sync in a real browser environment**

The core algorithm implementation and test coverage are already production-quality.
