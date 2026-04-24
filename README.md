# Event Graph Walker

MoonBit package `dowdiness/event-graph-walker` implements collaborative editing CRDTs:

- `dowdiness/event-graph-walker/text` - text editing facade built on eg-walker and FugueMax
- `dowdiness/event-graph-walker/tree` - movable-tree facade for document trees, outlines, and block editors
- `dowdiness/event-graph-walker/undo` - undo/redo support for text documents
- `dowdiness/event-graph-walker/container` - higher-level document API combining tree nodes, block text, sync, and undo

Package metadata in `moon.mod.json`:

- Version: `0.2.0`
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
4. Use the [docs index](docs/README.md) to find deeper implementation, benchmark, roadmap, and historical/spec material.

## Text Quick Start

```moonbit
import "dowdiness/event-graph-walker/text"

fn main() -> Unit raise {
  let doc = @text.TextState::new("alice")

  doc.insert(@text.Pos::at(0), "Hello")
  doc.insert(@text.Pos::at(5), " World")
  println(doc.text()) // "Hello World"

  doc.delete(@text.Pos::at(5))
  println(doc.text()) // "HelloWorld"
}
```

Sync through `TextState::sync()`:

```moonbit
fn main() -> Unit raise {
  let alice = @text.TextState::new("alice")
  alice.insert(@text.Pos::at(0), "Hello")

  let bob = @text.TextState::new("bob")

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
  for op in doc.export_ops() {
    peer.apply_remote_op(op)
  }

  println(peer.get_property(project, "name")) // Some("my-project")
  println(peer.children(project).length())    // 2

  doc.delete_node(test)
  println(doc.is_alive(test)) // false
}
```

## Public Packages

### `text`

Primary text-editing API.

- `TextState::new(agent_id)` creates a local replica.
- `insert(Pos::at(n), text)`, `delete(Pos::at(n))`, `delete_range(range)`, and `replace_range(range, text)` mutate text.
- `text()`, `len()`, and `is_empty()` inspect current state.
- `version()` returns a `Version` for later checkout or incremental sync.
- `sync().export_all()`, `sync().export_since(version)`, and `sync().apply(message)` exchange operations between replicas.
- `checkout(version)` returns a read-only `TextView`.

### `tree`

Primary movable-tree API.

- `TreeState::new(replica_id)` creates a local replica.
- `create_node(parent~)` and `create_node_after(parent~, after~)` add nodes.
- `move_node(target~, new_parent~)` and `delete_node(id)` update structure.
- `children(id)`, `is_alive(id)`, `set_property(id, key, value)`, and `get_property(id, key)` inspect or annotate nodes.
- `export_ops()` and `apply_remote_op(op)` exchange tree operations between replicas.
- `root_id` is the root sentinel; deleted nodes move under the trash sentinel.

### `undo`

Undo/redo support for text documents.

- `UndoManager::new(agent_id)` creates an undo manager for local edits.
- Use `TextState::insert_and_record`, `delete_and_record`, `replace_range_and_record`, or `delete_range_and_record` to record local edits.
- `can_undo()`, `can_redo()`, `undo(doc)`, and `redo(doc)` drive UI undo/redo controls.

See [docs/EXAMPLES.md](docs/EXAMPLES.md) for a complete undo/redo example.

### `container`

Advanced document-level API that combines movable tree nodes, per-block text, sync messages, and undo/redo.

- `Document::new(replica_id)` creates a document replica.
- `create_node(parent~)`, `move_node(...)`, and `delete_node(id)` manage the document tree.
- `insert_text(block, pos, text)`, `delete_text(block, pos)`, `replace_text(block, text)`, `get_text(block)`, and `text_len(block)` manage text inside a node.
- `export_sync_message()`, `export_sync_message_since(version)`, and `apply_remote_sync_message(message)` exchange tree and text operations.
- `undo()`, `redo()`, `can_undo()`, and `can_redo()` provide document-level undo/redo.

## Repository Layout

```text
event-graph-walker/
├── text/                 # Public text CRDT facade
├── tree/                 # Public movable-tree facade
├── undo/                 # Public undo/redo package
├── container/            # Advanced document API: tree + block text + sync + undo
├── internal/             # Implementation packages, not the first-time API path
├── docs/                 # User docs, design notes, benchmarks, and historical material
└── moon.mod.json
```

The generated `.mbti` files are the authoritative public API surface. Prefer the facade packages above unless you are modifying internals.

## Commands

Run the checks from this package root:

```bash
moon check
moon test
```

For performance work:

```bash
moon bench --release
```

## Deeper Documentation

- [Documentation index](docs/README.md) - reading order and audience split
- [Worked examples](docs/EXAMPLES.md) - sync, undo/redo, historical checkout
- [Walker usage](docs/WALKER_USAGE.md) - lower-level walker and oplog APIs
- [Benchmarks](docs/BENCHMARKS.md) - benchmark commands and notes

## References

- [Eg-walker paper](https://arxiv.org/abs/2409.14252)
- [Fugue paper](https://arxiv.org/abs/2305.00583)
- [Reference implementation](https://github.com/josephg/eg-walker-reference)
- [Loro eg-walker docs](https://loro.dev/docs/advanced/event_graph_walker)

## License

Apache-2.0. See [LICENSE](LICENSE).
