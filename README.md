# Event Graph Walker

A high-performance collaborative editing CRDT library for [MoonBit](https://www.moonbitlang.com/), implementing the [eg-walker](https://arxiv.org/abs/2409.14252) event graph algorithm with [FugueMax](https://arxiv.org/abs/2305.00583) sequence convergence.

Used as the core CRDT engine in [dowdiness/canopy](https://github.com/dowdiness/canopy) ([live demo](https://canopy-ideal.pages.dev)).

---

## Features

- **Sequence CRDT (`@text`)**: FugueMax-based collaborative text editing with low memory overhead and provable convergence.
- **Movable Tree CRDT (`@tree`)**: Conflict-free hierarchy movement, cycle prevention, and node metadata for outlines and block editors.
- **Selective Undo/Redo (`@undo`)**: Local undo and redo stacks that gracefully preserve concurrent remote edits.
- **Unified Document Model (`@container`)**: Higher-level document abstraction combining movable trees, per-block text, synchronization, and undo transactions.
- **Causal Synchronization (`@sync`, `@peer_sync`)**: Delta synchronization (`export_since`), strict Schema 2 wire transport, and transport-agnostic peer policy logic.

---

## Installation

Add the dependency to your project using the MoonBit CLI:

```bash
moon add dowdiness/event-graph-walker
```

Or add it directly to your `moon.mod`:

```moonbit
import {
  "dowdiness/event-graph-walker@0.8.0",
}
```

Then import the packages you need in your `moon.pkg`:

```moonbit
import {
  "dowdiness/event-graph-walker/text",
  "dowdiness/event-graph-walker/tree",
}
```

---

## Quick Start

### 1. Collaborative Text Editing

```moonbit
import "dowdiness/event-graph-walker/text"

fn main() -> Unit raise {
  let doc = @text.TextState::new("alice-laptop-001")

  // Insert and delete text
  doc.insert(@text.Pos::at(0), "Hello")
  doc.insert(@text.Pos::at(5), " World")
  println(doc.text()) // "Hello World"

  doc.delete(@text.Pos::at(5))
  println(doc.text()) // "HelloWorld"
}
```

### 2. Peer Synchronization

Exchange document mutations through `TextState::sync()`:

```moonbit
fn sync_peers() -> Unit raise {
  let alice = @text.TextState::new("alice-laptop-001")
  alice.insert(@text.Pos::at(0), "Hello")

  let bob = @text.TextState::new("bob-laptop-001")

  // Full initial synchronization
  let alice_sync = alice.sync()
  bob.sync().apply(alice_sync.export_all())
  println(bob.text()) // "Hello"

  // Incremental delta synchronization
  let bob_version = bob.version()
  alice.insert(@text.Pos::at(5), "!")
  bob.sync().apply(alice_sync.export_since(bob_version))
  println(bob.text()) // "Hello!"
}
```

### 3. Hierarchical Tree Documents

```moonbit
import "dowdiness/event-graph-walker/tree"

fn main() -> Unit raise {
  let doc = @tree.TreeState::new("alice-laptop-001")

  let project = doc.create_node(parent=@tree.root_id)
  let src = doc.create_node(parent=project)
  let test = doc.create_node(parent=project)

  doc.set_property(project, "name", "my-project")
  doc.set_property(src, "name", "src")
  doc.set_property(test, "name", "test")

  let peer = @tree.TreeState::new("bob-laptop-001")
  peer.sync().apply(doc.sync().export_all())

  println(peer.get_property(project, "name")) // Some("my-project")
  println(peer.children(project).length())    // 2

  doc.delete_node(test)
  println(doc.is_alive(test)) // false
}
```

> [!TIP]
> For advanced scenarios including undo/redo, container documents, historical checkout, and detailed error handling, see [Worked Examples](docs/EXAMPLES.md).

---

## Packages Overview

The library provides modular public facade packages targeting different collaborative editing layers:

| Package | Description | API Contract |
| :--- | :--- | :--- |
| [`text`](text/) | Concurrent text editing facade (insert, delete, range replace, delta sync, checkout) | [`text/pkg.generated.mbti`](text/pkg.generated.mbti) |
| [`tree`](tree/) | Movable-tree CRDT facade (nodes, hierarchy moves, sorted properties) | [`tree/pkg.generated.mbti`](tree/pkg.generated.mbti) |
| [`undo`](undo/) | Local undo/redo manager preserving concurrent remote mutations | [`undo/pkg.generated.mbti`](undo/pkg.generated.mbti) |
| [`container`](container/) | Advanced document API combining tree nodes, per-block text, sync, and undo | [`container/pkg.generated.mbti`](container/pkg.generated.mbti) |
| [`history`](history/) | Read-only `CausalSnapshot` for DAG visualization and history inspection | [`history/pkg.generated.mbti`](history/pkg.generated.mbti) |
| [`sync`](sync/) | Shared sync limits, wire envelopes, and structured failure classifications | [`sync/pkg.generated.mbti`](sync/pkg.generated.mbti) |
| [`peer_sync`](peer_sync/) | Transport-free synchronization decision engine and façade adapters (`peer_sync/text`, `peer_sync/container`) | [`peer_sync/pkg.generated.mbti`](peer_sync/pkg.generated.mbti) |

The generated `.mbti` files are the authoritative public API surface. Prefer the facade packages above unless you are modifying internals.

### Choosing the Right Package

Depending on your application's architecture:

- **Plain collaborative text**: Start with [`@text`](text/). Add [`@undo`](undo/) when local undo/redo history is needed.
- **Hierarchical outlines or movable file trees**: Use [`@tree`](tree/).
- **Block-based editors (Notion-like) or rich documents**: Use [`@container`](container/). It integrates movable tree nodes, per-block text, property maps, peer synchronization, and undo transactions into a single cohesive document model.
- **Custom transport & network routing**: Use [`@peer_sync`](peer_sync/) with [`@sync`](sync/) to manage convergence state machines without tight coupling to transport protocols.

---

## Repository Layout

```text
event-graph-walker/
├── text/                 # Public text CRDT facade
├── tree/                 # Public movable-tree facade
├── undo/                 # Public undo/redo package
├── container/            # Advanced document API: tree + block text + sync + undo
├── history/              # Read-only causal history snapshots
├── sync/                 # Shared sync limits and error definitions
├── peer_sync/            # Peer-free synchronization policy and adapters
├── internal/             # Core algorithms and data structures (internal only)
├── docs/                 # Documentation, guides, benchmarks, and architecture notes
├── scripts/              # Nushell verification implementations
├── justfile              # Project recipe entry points
└── moon.mod
```

---

## Documentation

- **[Documentation Index](docs/README.md)**: Reading order, learning path, and audience split.
- **[Worked Examples](docs/EXAMPLES.md)**: Step-by-step examples for sync, undo/redo, checkout, and error handling.
- **[Migration Guides](docs/migration/README.md)**: Upgrading between major versions and protocol schemas.
- **[Walker Usage](docs/WALKER_USAGE.md)**: Lower-level causal graph and oplog traversal APIs.
- **[Network Synchronization](docs/NETWORK_SYNC.md)**: Transport integration patterns (WebSocket / WebRTC).
- **[Benchmarks](docs/BENCHMARKS.md)**: Performance benchmarks and methodologies.

---

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on local development setup, running tests and CI checks, and submitting changes.

---

## References

- [Eg-walker paper](https://arxiv.org/abs/2409.14252)
- [Fugue paper](https://arxiv.org/abs/2305.00583)
- [Reference implementation](https://github.com/josephg/eg-walker-reference)
- [Loro eg-walker docs](https://loro.dev/docs/advanced/event_graph_walker)

---

## License

Apache-2.0. See [LICENSE](LICENSE).
