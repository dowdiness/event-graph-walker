# Event Graph Walker Documentation

Welcome to the Event Graph Walker documentation. This index organizes user guides, architecture references, migration notes, and contributor resources.

---

## 1. Getting Started & User Guides (`guides/`)

Practical how-to guides for integrating and using the library:

- **[Guides Overview](guides/README.md)**: Index and recommended learning path.
- **[Worked Examples](guides/examples.md)**: Code walkthroughs for text/tree sync, undo/redo, checkout, and error handling.
- **[Network Synchronization](guides/network-sync.md)**: WebSocket/WebRTC integration patterns around `TextState::sync()`.
- **[Walker Usage](guides/walker-usage.md)**: Lower-level causal graph and oplog traversal APIs.

---

## 2. Architecture & Design (`architecture/`)

In-depth conceptual documentation explaining how the CRDT algorithms work:

- **[Architecture Overview](architecture/README.md)**: Algorithm specifications and invariant models.
- **[eg-walker Implementation](architecture/eg-walker.md)**: Event graph walker mechanics and FugueMax sequence convergence.
- **[Undo Manager Design](architecture/undo-manager.md)**: Selective undo/redo preserving concurrent remote edits.
- **[Formal Specification](architecture/formal-specification.md)**: Mathematical models, algebraic laws, and invariant definitions.
- **[RLE Design Plan](architecture/rle-design.md)**: Data compression exploratory design.

---

## 3. Migration Guides (`migration/`)

Upgrade instructions for breaking protocol changes and major versions:

- **[Migration Index](migration/README.md)**: Version upgrade recommendations and breaking change summaries.
- **[Text Schema 2](migration/text-schema-2.md)**: Upgrading to exact causality and domain-separated wire encoding.
- **[v0.5 Migration](migration/to-v0.5.md)**: Opaque `text.Range` constructors with validation.
- **[v0.4 Migration](migration/to-v0.4.md)**: Stable identity transition and schema 1 envelopes.
- **[Undo API Migration](migration/undo-api.md)**: Compensating edit results (`Applied` / `Stale`).

---

## 4. API Reference

The generated `.mbti` interface files represent the authoritative public API surface:

- [`text/pkg.generated.mbti`](../text/pkg.generated.mbti) - Public text CRDT API.
- [`tree/pkg.generated.mbti`](../tree/pkg.generated.mbti) - Public movable-tree API.
- [`undo/pkg.generated.mbti`](../undo/pkg.generated.mbti) - Public undo/redo API.
- [`container/pkg.generated.mbti`](../container/pkg.generated.mbti) - Unified document API (tree + block text + sync + undo).
- [`history/pkg.generated.mbti`](../history/pkg.generated.mbti) - Read-only causal history snapshots.
- [`sync/pkg.generated.mbti`](../sync/pkg.generated.mbti) - Shared limits and error classifications.
- [`peer_sync/pkg.generated.mbti`](../peer_sync/pkg.generated.mbti) - Peer-free synchronization policy core.
- [`peer_sync/text/pkg.generated.mbti`](../peer_sync/text/pkg.generated.mbti) - Text sync adapter.
- [`peer_sync/container/pkg.generated.mbti`](../peer_sync/container/pkg.generated.mbti) - Container sync adapter.

---

## 5. Contributor & Project Resources

Resources for hacking on internals, profiling performance, and tracking project state:

- **[Contributing Guide](../CONTRIBUTING.md)**: Local dev setup, testing recipes, and PR guidelines.
- **[Benchmarks](BENCHMARKS.md)**: Benchmark commands, baselines, and profiling notes.
- **[Stabilization Roadmap](STABILIZATION_ROADMAP.md)**: Invariant hardening and verification status.
- **[Optimization Roadmap](OPTIMIZATION_ROADMAP.md)**: Performance milestones and targets.
- **[Decisions Needed](decisions-needed.md)**: Open architectural questions.
- **[ADR Records](adr/)**: Architectural Decision Records.
