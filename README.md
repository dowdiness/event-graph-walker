# Event Graph Walker

MoonBit package `dowdiness/event-graph-walker` implements collaborative editing CRDTs:

- `dowdiness/event-graph-walker/text` - text editing facade built on eg-walker and FugueMax
- `dowdiness/event-graph-walker/tree` - movable-tree facade for document trees, outlines, and block editors
- `dowdiness/event-graph-walker/undo` - undo/redo support for text documents
- `dowdiness/event-graph-walker/container` - higher-level document API combining tree nodes, block text, sync, and undo
- `dowdiness/event-graph-walker/history` - read-only `CausalSnapshot` view over a document's causal DAG (for visualization and history-aware tooling)
- `dowdiness/event-graph-walker/sync` - shared synchronization limits and failure classifications
- `dowdiness/event-graph-walker/peer_sync` - peer-free one-peer synchronization policy
- `dowdiness/event-graph-walker/peer_sync/text` - text façade report and error adapter
- `dowdiness/event-graph-walker/peer_sync/container` - container façade report and error adapter

Package metadata in `moon.mod`:

- Version: `0.7.1`
- Repository: <https://github.com/dowdiness/event-graph-walker>
- License: `Apache-2.0`
- Description: `Implementation of the eg-walker CRDT algorithm with FugueMax sequence CRDT`

This repository is also used as a git submodule in [dowdiness/canopy](https://github.com/dowdiness/canopy). The [live demo](https://canopy-ideal.pages.dev) is a collaborative editor built on top of this library.

## Start Here

Use the public facade packages first:

1. Start with the short text or tree example below.
2. Continue with [worked examples](docs/EXAMPLES.md) for sync, undo/redo, and historical checkout.
3. Use the generated `.mbti` files as the exact API reference:
   - [`text/pkg.generated.mbti`](text/pkg.generated.mbti)
   - [`tree/pkg.generated.mbti`](tree/pkg.generated.mbti)
   - [`undo/pkg.generated.mbti`](undo/pkg.generated.mbti)
   - [`container/pkg.generated.mbti`](container/pkg.generated.mbti)
   - [`history/pkg.generated.mbti`](history/pkg.generated.mbti)
   - [`peer_sync/pkg.generated.mbti`](peer_sync/pkg.generated.mbti)
   - [`peer_sync/text/pkg.generated.mbti`](peer_sync/text/pkg.generated.mbti)
   - [`peer_sync/container/pkg.generated.mbti`](peer_sync/container/pkg.generated.mbti)
4. Use the [docs index](docs/README.md) to find deeper implementation, benchmark, roadmap, and historical/spec material.

## Text Quick Start

```moonbit
import "dowdiness/event-graph-walker/text"

fn main() -> Unit raise {
  let doc = @text.TextState::new("alice-laptop-001")

  doc.insert(@text.Pos::at(0), "Hello")
  doc.insert(@text.Pos::at(5), " World")
  println(doc.text()) // "Hello World"

  doc.delete(@text.Pos::at(5))
  println(doc.text()) // "HelloWorld"
}
```

Construct and delete a range with explicit error handling:

```moonbit
fn delete_span(doc : @text.TextState, start : Int, end : Int) -> Unit raise {
  let range = @text.Range::from_ints(start, end) catch {
    @text.TextError::InvalidRange(start~, end~) => {
      println("Failed: start \{start} > end \{end}")
      return
    }
    error => raise error
  }
  doc.delete_range(range) catch {
    @text.TextError::InvalidPosition(pos~, len~) =>
      println("Failed: endpoint \{pos} exceeds document length \{len}")
    error => raise error
  }
}
```

Sync through `TextState::sync()`:

```moonbit
fn main() -> Unit raise {
  let alice = @text.TextState::new("alice-laptop-001")
  alice.insert(@text.Pos::at(0), "Hello")

  let bob = @text.TextState::new("bob-laptop-001")

  let alice_sync = alice.sync()
  let initial = alice_sync.export_all()
  bob.sync().apply(initial)
  println(bob.text()) // "Hello"

  let bob_version = bob.version()
  alice.insert(@text.Pos::at(5), "!")

  let delta = alice_sync.export_since(bob_version)
  bob.sync().apply(delta)
  println(bob.text()) // "Hello!"
}
```

## Tree Quick Start

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

## Public Packages

### `text`

Primary text-editing API.

- `TextState::new(replica_id)` creates a local replica. The ID must be non-empty and globally unique per replica instance.
- `insert(Pos::at(n), text)`, `delete(Pos::at(n))`, `delete_range(range)`, and `replace_range(range, text)` mutate text.
- `text()`, `len()`, and `is_empty()` inspect current state.
- `version()` returns a `Version` for later checkout or incremental sync.
- `sync().export_all()`, `sync().export_since(version)`, and `sync().apply(message)` exchange operations between replicas.
- `checkout(version)` returns a read-only `TextView`.
- `SyncMessage::to_json_string` / `from_json_string` provide the strict v1 transport codec; `to_canonical_bytes` provides deterministic bytes for hashing or signing.

### `tree`

Primary movable-tree API.

- `TreeState::new(replica_id)` creates a local replica.
- `create_node(parent~)` and `create_node_after(parent~, after~)` add nodes.
- `move_node(target~, new_parent~)` and `delete_node(id)` update structure.
- `children(id)`, `is_alive(id)`, `set_property(id, key, value)`, `get_property(id, key)`, and `properties(id)` inspect or annotate nodes. `properties(id)` returns an owning `Array[(String, String)]` snapshot of the current winning key/value pairs, sorted by MoonBit's deterministic shortlex `String` comparison. Missing nodes return `[]`; nodes retained under the trash sentinel keep their current properties.
- `sync().export_all()`, `sync().export_since(version)`, and `sync().apply(message)` exchange tree operations between replicas.
- `root_id` is the root sentinel; deleted nodes move under the trash sentinel.

### `undo`

Undo/redo support for text documents.

- `UndoManager::new(agent_id)` creates an undo manager for local edits.
- Use `TextState::insert_and_record`, `delete_and_record`, `replace_range_and_record`, or `delete_range_and_record` to record local edits.
- Call `UndoManager::stop_capturing()` to force the next recorded edit to begin
  a new undo group. Calling it before and after a multi-operation batch isolates
  that batch from adjacent input while preserving grouping within the batch.
- `can_undo()`, `can_redo()`, `undo(doc)`, and `redo(doc)` drive UI undo/redo controls.

See [docs/EXAMPLES.md](docs/EXAMPLES.md) for a complete undo/redo example.

### `container`

Advanced document-level API that combines movable tree nodes, per-block text, sync messages, and undo/redo.

- `Document::new(replica_id)` creates a document replica.
- `create_node(parent~)`, `move_node(...)`, and `delete_node(id)` manage the document tree.
- `insert_text(block, pos, text)`, `delete_text(block, pos)`, `replace_text(block, text)`, `get_text(block)`, and `text_len(block)` manage text inside a node.
- `set_property(block, key, value)`, `get_property(block, key)`, and `properties(block)` annotate nodes. `properties(block)` returns an owning `Array[(String, String)]` snapshot of the current winning key/value pairs, sorted by MoonBit's deterministic shortlex `String` comparison. Missing nodes return `[]`; nodes retained under the trash sentinel keep their current properties.
- `sync().export_all()`, `sync().export_since(version)`, and `sync().apply(message)` exchange tree and text operations.
- `undo()`, `redo()`, `can_undo()`, and `can_redo()` provide document-level undo/redo.

### `sync`

Shared protocol policy types.

- `Limits()` uses defaults of 16 MiB encoded input, 100,000 decoded operations, 10,000 pending operations, and 256 parents per operation.
- `Limits(...)` is a validating custom constructor for overriding those budgets.
- `Failure` classifies malformed content, missing dependencies, conflicting stable identities, and exceeded limits.

### Peer synchronization companion

`peer_sync` provides a peer-free policy core. Start with `@peer_sync.State()`.
Apply semantic methods including `State::handshake_started`,
`State::version_compared`, `State::applied`, and `State::failed`.

Each method returns the next policy value and a fresh `Array[Decision]` for the
surrounding runtime to route. The runtime/provider owns retry budgets, peer IDs,
connectivity, scheduling, and fan-out, while the application owns projection
and product state.

At the façade boundary, use `peer_sync/text` or `peer_sync/container`.
`apply_disposition` maps `SyncReport` values, while `classify_error` maps sync
errors. Local editing or document errors return `None`.

Missing dependencies are recoverable. Malformed, invalid, conflicting, and
limit failures are terminal. The adapters do not encode messages or own
transport.

## Repository Layout

```text
event-graph-walker/
├── justfile              # Local and CI command entry points
├── scripts/              # Nushell verification implementations
├── text/                 # Public text CRDT facade
├── tree/                 # Public movable-tree facade
├── undo/                 # Public undo/redo package
├── container/            # Advanced document API: tree + block text + sync + undo
├── peer_sync/            # Peer-free synchronization policy and façade adapters
├── internal/             # Implementation packages, not the first-time API path
├── docs/                 # User docs, design notes, benchmarks, and historical material
└── moon.mod
```

The generated `.mbti` files are the authoritative public API surface. Prefer the facade packages above unless you are modifying internals.

## Commands

Run the checks from this package root:

```bash
just verify
```

Build and validate the publish archive:

```bash
just verify-publish
```

Run the complete pipeline used by CI:

```bash
just ci
```

`just` provides the command entry points; the verification logic is implemented
in the Nushell scripts under `scripts/`.

For performance work:

```bash
moon bench --release
```

## Deeper Documentation

- [Documentation index](docs/README.md) - reading order and audience split
- [Worked examples](docs/EXAMPLES.md) - sync, undo/redo, historical checkout
- [v0.5 migration guide](docs/MIGRATING_TO_0.5.md) - source migration from v0.4; unchanged v0.4 wire envelopes
- [Undoable API migration guide](docs/MIGRATING_UNDO_API.md) - migrate custom Undoable adapters to Applied/Stale results
- [Walker usage](docs/WALKER_USAGE.md) - lower-level walker and oplog APIs
- [Benchmarks](docs/BENCHMARKS.md) - benchmark commands and notes

## References

- [Eg-walker paper](https://arxiv.org/abs/2409.14252)
- [Fugue paper](https://arxiv.org/abs/2305.00583)
- [Reference implementation](https://github.com/josephg/eg-walker-reference)
- [Loro eg-walker docs](https://loro.dev/docs/advanced/event_graph_walker)

## License

Apache-2.0. See [LICENSE](LICENSE).
