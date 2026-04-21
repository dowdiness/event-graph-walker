# Event Graph Walker Docs

This index separates current user guidance from contributor notes, design work, benchmarks, and historical/spec material. If a deeper document conflicts with the public facade API or generated `.mbti` files, trust the public API first.

## Reading Order

- [Package README](../README.md) - package overview, quick starts, public packages, and commands.
- [Worked examples](EXAMPLES.md) - sync error handling, undo/redo, historical checkout, and incremental catch-up.

## Learning Path

- [Examples](EXAMPLES.md) - practical usage of `text` and `undo`.
- [Walker usage](WALKER_USAGE.md) - lower-level causal graph and oplog traversal APIs. Read this after the public `text` facade unless you are working on internals.
- [Network synchronization](NETWORK_SYNC.md) - Canopy demo/integration notes for WebSocket/WebRTC wiring around `TextState::sync()`. This depends on parent `canopy` repo infrastructure, not just this package.

## API And Reference

- [`text/pkg.generated.mbti`](../text/pkg.generated.mbti) - public text API.
- [`tree/pkg.generated.mbti`](../tree/pkg.generated.mbti) - public movable-tree API.
- [`undo/pkg.generated.mbti`](../undo/pkg.generated.mbti) - public undo/redo API.
- [`container/pkg.generated.mbti`](../container/pkg.generated.mbti) - advanced document API combining tree nodes, block text, sync, and undo.
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

- [Formal specification](FORMAL_SPECIFICATION.md) - includes path drift and aspirational/unverified notes.
- [RLE design plan](RLE_DESIGN_PLAN.md) - planned/exploratory RLE design material.

## Current User Path

For application code, prefer this order:

1. Use `dowdiness/event-graph-walker/text` for collaborative text.
2. Use `dowdiness/event-graph-walker/tree` for collaborative trees.
3. Add `dowdiness/event-graph-walker/undo` when local text undo/redo is needed.
4. Use `dowdiness/event-graph-walker/container` only when you need the combined tree + block text document API.
5. Consult generated `.mbti` files for exact names and signatures.
6. Move into `internal/` docs only when contributing to the implementation.
