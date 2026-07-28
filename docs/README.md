# Event Graph Walker Docs

This index separates current user guidance from contributor notes, design work, benchmarks, and historical/spec material. If a deeper document conflicts with the public facade API or generated `.mbti` files, trust the public API first.

## Reading Order

- [Package README](../README.md) - package overview, quick starts, public packages, and commands.
- [Worked examples](EXAMPLES.md) - sync error handling, undo/redo, historical checkout, and incremental catch-up.
- [Migrating to v0.5](MIGRATING_TO_0.5.md) - source migration from v0.4; wire-compatible.
- [Migrating the Undoable API](MIGRATING_UNDO_API.md) - source migration to Applied/Stale compensating-edit results; wire-compatible.
- [Migrating to v0.4](MIGRATING_TO_0.4.md) - required source and wire changes from v0.3.

## Learning Path

- [Examples](EXAMPLES.md) - practical usage of `text` and `undo`.
- [Walker usage](WALKER_USAGE.md) - lower-level causal graph and oplog traversal APIs. Read this after the public `text` facade unless you are working on internals.
- [Network synchronization](NETWORK_SYNC.md) - Canopy demo/integration notes for WebSocket/WebRTC wiring around `TextState::sync()`. This depends on parent `canopy` repo infrastructure, not just this package.

## API And Reference

- [`text/pkg.generated.mbti`](../text/pkg.generated.mbti) - public text API.
- [`tree/pkg.generated.mbti`](../tree/pkg.generated.mbti) - public movable-tree API.
- [`undo/pkg.generated.mbti`](../undo/pkg.generated.mbti) - public undo/redo API.
- [`container/pkg.generated.mbti`](../container/pkg.generated.mbti) - advanced document API combining tree nodes, block text, sync, and undo.
- [`history/pkg.generated.mbti`](../history/pkg.generated.mbti) - read-only causal history snapshots.
- [`sync/pkg.generated.mbti`](../sync/pkg.generated.mbti) - shared synchronization limits and failure classifications.
- [`peer_sync/pkg.generated.mbti`](../peer_sync/pkg.generated.mbti) - peer-free synchronization policy core.
- [`peer_sync/text/pkg.generated.mbti`](../peer_sync/text/pkg.generated.mbti) - text façade sync adapter.
- [`peer_sync/container/pkg.generated.mbti`](../peer_sync/container/pkg.generated.mbti) - container façade sync adapter.
- [Benchmarks](BENCHMARKS.md) - current benchmark commands and performance notes.

## Contributor And Deep Design Docs

These are useful when changing internals, reviewing algorithm choices, or planning performance work. They are not the first-time user path.

- [eg-walker implementation](EG_WALKER_IMPLEMENTATION.md)
- [Undo manager design](UNDO_MANAGER_DESIGN.md)
- [Stabilization roadmap](STABILIZATION_ROADMAP.md)
- [Optimization roadmap](OPTIMIZATION_ROADMAP.md)
- [Decisions needed](decisions-needed.md)
- [Decision records](decisions/)
- [Plans](plans/)
- [Benchmark records](benchmarks/)

## Historical, Spec, Or Exploratory Material

Read these with care. They contain formalization, planned work, or notes that may not describe current implemented behavior unless confirmed by code and current API docs.

- [Parse, Don't Validate audit and improvement plan](plans/archive/2026-07-21-parse-dont-validate-audit.md) - archived after phases 1–6a; operation identity remains deferred.
- [Formal specification](FORMAL_SPECIFICATION.md) - includes path drift and aspirational/unverified notes.
- [RLE design plan](RLE_DESIGN_PLAN.md) - planned/exploratory RLE design material.

## Current User Path

For application code, prefer this order:

1. Use `dowdiness/event-graph-walker/text` for collaborative text.
2. Use `dowdiness/event-graph-walker/tree` for collaborative trees.
3. Add `dowdiness/event-graph-walker/undo` when local text undo/redo is needed.
4. Use `dowdiness/event-graph-walker/container` only when you need the combined tree + block text document API.
5. Use `dowdiness/event-graph-walker/peer_sync` for shared synchronization decisions without owning transport.
6. Consult generated `.mbti` files for exact names and signatures.
7. Move into `internal/` docs only when contributing to the implementation.
