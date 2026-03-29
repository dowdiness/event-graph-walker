# Event Graph Walker

- [Repository](https://github.com/dowdiness/event-graph-walker)
- Used as a git submodule in [dowdiness/crdt](https://github.com/dowdiness/crdt)
- [Demo App](https://lambda-editor.koji-ishimoto.workers.dev/) as Collaborative Editor

A MoonBit implementation of the **eg-walker** CRDT algorithm with **FugueMax** sequence CRDT for collaborative text editing, and **Kleppmann's movable-tree CRDT** for collaborative tree editing.

## Overview

This module provides two independent collaborative editing CRDTs:

- **Text CRDT** — eg-walker + FugueMax for collaborative text editing. The event graph walker replays operations in causal order; FugueMax maintains a conflict-free ordered sequence.
- **Movable Tree CRDT** — Kleppmann's undo-do-redo algorithm with fractional indexing for collaborative tree editing (documents, outlines, block editors).

## Architecture

### Package Structure

```
event-graph-walker/
├── text/                          # Text CRDT facade (recommended)
├── tree/                          # Tree CRDT facade (recommended)
├── undo/                          # Undo/redo support for text
├── internal/
│   ├── fractional_index/          # Dense sibling ordering for tree
│   ├── movable_tree/              # Movable tree + Kleppmann conflict resolution
│   ├── document/                  # Low-level text document API
│   ├── oplog/                     # Operation log and eg-walker
│   ├── causal_graph/              # Causal graph and topological sorting
│   ├── branch/                    # Document snapshots at any frontier
│   ├── fugue/                     # FugueMax sequence CRDT
│   └── core/                      # Shared core types
└── moon.mod.json
```

### Package Layers

```
┌───────────────────────┬─────────────────────────────┐
│  text (Facade)        │  tree (Facade)               │
│  TextState, SyncMessage │  TreeState                     │
├───────────────────────┤                              │
│  undo                 │                              │
│  UndoManager          │                              │
├───────────────────────┤─────────────────────────────┤
│  internal/document    │  internal/movable_tree       │
│  Document             │  MovableTree, TreeOpLog      │
├───────────┬───────────┤─────────────────────────────┤
│ internal/ │ internal/ │  internal/fractional_index  │
│ branch    │ oplog     │  FractionalIndex             │
├───────────┴───────────┴─────────────────────────────┤
│  internal/causal_graph                               │
│  CausalGraph, Frontier, VersionVector                │
├──────────────────────────────────────────────────────┤
│  internal/fugue         │  internal/core             │
│  FugueTree              │  Shared types              │
└──────────────────────────────────────────────────────┘
```

### Key Data Structures

All internal fields are encapsulated (`priv`). Use the public methods documented below or in the `.mbti` interface files.

#### TextState (text package)
User-friendly facade for collaborative text editing. Wraps `Document`, `OpLog`, `CausalGraph`, and `FugueTree` behind a clean API.

- `insert(Pos::at(n), text)` — insert text at position
- `delete(Pos::at(n))` — delete character at position
- `text()` — current document string
- `version()` — current `Version` (version vector)
- `sync().export_all()` / `sync().export_since(version)` — export ops for peers
- `sync().apply(msg)` — apply ops from a peer
- `checkout(version)` — read-only view at a historical version

#### TreeState (tree package)
Facade for collaborative movable-tree editing. Each structural mutation (create/move/delete) is a Lamport-timestamped operation that can be replicated to any number of peers.

- `create_node(parent~)` — create a child node as last sibling, returns its `TreeNodeId`
- `create_node_after(parent~, after~)` — create a child positioned after a given sibling
- `move_node(target~, new_parent~)` — move a node to a new parent
- `delete_node(id)` — move a node to the trash sentinel
- `children(id)` — sorted children of a node (by `FractionalIndex`)
- `is_alive(id)` — true if the node is reachable from root (not in trash)
- `set_property(id, key, value)` / `get_property(id, key)` — LWW properties
- `export_ops()` — all ops in timestamp order for peer sync
- `apply_remote_op(op)` — apply a remote op, handles out-of-order delivery

Mutating methods raise `TreeError` on invalid input (missing parent, missing target, cycle detected).

#### CausalGraph (internal/causal_graph)
Tracks causality between operations. Assigns local versions (LV) and maintains the Frontier (set of heads not yet referenced as a parent by any later op).

#### FugueTree (internal/fugue)
FugueMax sequence CRDT. Stores all items including tombstones, indexed by LV. Ensures deterministic ordering of concurrent insertions without requiring coordination.

#### MovableTree + TreeOpLog (internal/movable_tree)
Low-level tree structure and Kleppmann's undo-do-redo conflict resolution log. `TreeOpLog::apply` maintains entries sorted by (timestamp, agent) and replays ops in total order to guarantee convergence under arbitrary delivery reordering.

## Algorithm Components

### 1. Event Graph Walker
**Location:** `internal/causal_graph/walker.mbt`, `internal/oplog/walker.mbt`

The core algorithm that traverses the operation graph in topological (causal) order:

- `CausalGraph::walk_from_frontier(frontier)` - Returns operations reachable from frontier in causal order
- `OpLog::walk_and_collect(frontier)` - Collects actual operations at a frontier
- `OpLog::diff_and_collect(from, to)` - Computes diff between two frontiers

Uses topological sorting that preserves causal order without reordering by
local LV; the paper suggests a DFS-based ordering that keeps branches
consecutive when possible.

### 2. Branch System
**Location:** `internal/branch/branch.mbt`

Efficient document state computation at any frontier:

- `Branch::checkout(oplog, frontier)` - Reconstruct document at frontier
- `Branch::advance(target_frontier)` - Efficiently move branch forward (incremental when possible)

The branch system uses the walker to replay operations, avoiding expensive full tree reconstructions when advancing forward.

### 3. Version Vectors
**Location:** `internal/causal_graph/version_vector.mbt`

Compact representation of known versions per agent:

```moonbit
pub struct VersionVector(Map[String, Int])  // Max seq per agent (newtype wrapper)
```

- Enables efficient network sync optimization
- Compare: `vv1.op_le(vv2)` - Checks if vv1 ≤ vv2 (already synced)
- Merge: `vv1.merge(vv2)` - Combines knowledge from two peers

### 4. Merge Algorithm
**Location:** `internal/branch/branch_merge.mbt`

Three-phase merge for concurrent edits:

1. **Retreat** - Remove operations from current frontier not in target
2. **Advance** - Apply new operations up to target frontier
3. **Apply** - Final state at target frontier

```moonbit
pub fn merge_remote_ops(
  tree : @fugue.FugueTree[String],
  oplog : @oplog.OpLog,
  remote_ops : Array[@core.Op],
) -> Unit raise BranchError
```

## Usage

For complete worked examples (sync with error handling, undo/redo, historical checkout), see **[docs/EXAMPLES.md](docs/EXAMPLES.md)**.

### Tree Quick Start

```moonbit
import "dowdiness/event-graph-walker/tree"

// Create a document — replica_id must be unique per device/session
let doc = @tree.TreeState::new("alice-laptop-001")

// Build a tree
let project = doc.create_node(parent=@tree.root_id)
let src     = doc.create_node(parent=project)
let test    = doc.create_node(parent=project)
doc.set_property(project, "name", "my-project")
doc.set_property(src, "name", "src")
doc.set_property(test, "name", "test")

// Sync to another peer
let bob = @tree.TreeState::new("bob-laptop-001")
for op in doc.export_ops() {
  bob.apply_remote_op(op)
}

// Bob sees the same tree
println(bob.get_property(project, "name"))  // "my-project"
println(bob.children(project).length())     // 2

// Delete a node
doc.delete_node(test)
println(doc.is_alive(test))  // false
```

### Quick Start (Recommended API)

The `text` package provides a user-friendly facade over the CRDT internals:

```moonbit
import "dowdiness/event-graph-walker/text"

// Create a document
let doc = @text.TextState::new("alice")

// Edit with type-safe positions
doc.insert(@text.Pos::at(0), "Hello")
doc.insert(@text.Pos::at(5), " World")
println(doc.text())  // "Hello World"

// Delete a character
doc.delete(@text.Pos::at(5))
println(doc.text())  // "HelloWorld"
```

### Syncing Between Peers

```moonbit
// Alice's document
let alice_doc = @text.TextState::new("alice")
alice_doc.insert(@text.Pos::at(0), "Hello")

// Bob's document
let bob_doc = @text.TextState::new("bob")

// Alice sends her changes to Bob
let message = alice_doc.sync().export_all()
bob_doc.sync().apply(message)
println(bob_doc.text())  // "Hello"

// Incremental sync (only new changes since last sync)
let bob_version = bob_doc.version()
alice_doc.insert(@text.Pos::at(5), "!")
let delta = alice_doc.sync().export_since(bob_version)
bob_doc.sync().apply(delta)
println(bob_doc.text())  // "Hello!"
```

### Historical Checkout (Time Travel)

```moonbit
let doc = @text.TextState::new("alice")
doc.insert(@text.Pos::at(0), "Hello")
let v1 = doc.version()  // Save this version

doc.insert(@text.Pos::at(5), " World")
println(doc.text())  // "Hello World"

// View document at earlier version
let old_view = doc.checkout(v1)
println(old_view.text())  // "Hello"
println(doc.text())       // "Hello World" (unchanged)
```

### Error Handling

```moonbit
let doc = @text.TextState::new("alice")
try {
  doc.delete(@text.Pos::at(100))  // Invalid position
} catch {
  @text.TextError::InvalidPosition(pos~, len~) => {
    println("Error: position \{pos} out of bounds (doc length: \{len})")
    println("Help: " + err.help())
    if err.is_retryable() {
      // Retry logic
    }
  }
  err => println(err.message())
}
```

---

## Low-Level API (Advanced)

The following sections document the internal APIs. Most users should use the `text` package above.

### Basic Editing (Document API)

```moonbit
// Create document for an agent
let doc = @document.Document::new("user-1")

// Insert text at position
doc.insert(0, "Hello")

// Get current text
let text = doc.to_text()  // "Hello"

// Delete at position
doc.delete(0)
let text = doc.to_text()  // "ello"
```

### Network Collaboration (Low-Level)

```moonbit
// Diff between frontiers
let (retreat, advance) = doc.diff_and_collect(old_frontier, new_frontier)
```

### Snapshotting/Branching (Low-Level)

```moonbit
// Get current frontier
let frontier = doc.get_frontier()

// Checkout state at previous frontier
let old_branch = doc.checkout_branch(previous_frontier)

// Advance to new frontier
let new_branch = old_branch.advance(target_frontier)
```

---

## Migration Guide

### From Document to TextState

If you're using the low-level `Document` API, here's how to migrate to `TextState`:

| Old (Document) | New (TextState) |
|---------------|---------------|
| `Document::new(agent)` | `TextState::new(agent)` |
| `doc.insert(pos, text)` | `doc.insert(Pos::at(pos), text)` |
| `doc.delete(pos)` | `doc.delete(Pos::at(pos))` |
| `doc.to_text()` | `doc.text()` |
| `doc.get_frontier()` | `doc.version().to_frontier()` |

**Key Benefits of TextState:**

1. **Type-safe positions** - `Pos` prevents accidental misuse of raw integers
2. **Cleaner sync** - `SyncMessage` bundles ops and heads together
3. **Better errors** - `TextError` provides `message()`, `help()`, `is_retryable()`
4. **Historical views** - `checkout()` returns read-only `TextView`
5. **Encapsulated internals** - Document fields are private, accessed via delegate methods

**Remote ops:** When applying remote operations, buffer ops whose parents
are missing until all parent RawVersions are present, then map RawVersion
parents and anchors to local LVs before inserting into the causal graph.

## Key Features

- ✅ **Text CRDT** — FugueMax ensures deterministic ordering of concurrent inserts
- ✅ **Movable Tree CRDT** — Kleppmann's undo-do-redo guarantees convergent, acyclic trees
- ✅ **Causal Consistency** — Operations ordered by causal dependencies
- ✅ **Efficient** — Walker and branch systems avoid full tree reconstruction
- ✅ **Network Optimized** — Version vectors minimize sync overhead
- ✅ **Peer-to-Peer** — Works with any number of collaborators

## Properties

The implementation guarantees CRDT properties:

- **Convergence** - All peers reach same state given same operation set
- **Commutativity** - Operation order in network doesn't matter
- **Idempotence** - Replaying operations multiple times is safe
- **Causality** - Operations respect causal dependencies

## Testing

Run tests with:

```bash
moon test
```

The module includes:
- 395 unit and property-based tests across all components
- QuickCheck convergence properties for both the text CRDT and the movable-tree CRDT
- Benchmarks for performance profiling

## Performance

- **Small documents** (≤1000 ops) - Excellent performance
- **Walker** - O(n) for topological sort on DAG
- **Version vectors** - O(m) where m = number of agents
- **Branch advance** - O(k) where k = new operations
- **Position mapping** - O(1) after first access (lazy cache, invalidated on mutation)

See the performance documentation in the [crdt monorepo](https://github.com/dowdiness/crdt/tree/main/docs/performance) for detailed benchmarks.

## Integration

This module is designed to be used with:

- **Parser** - Integrates with incremental parser
- **Web UI** - Exposed via MoonBit FFI to JavaScript
- **Network** - Handles WebRTC/WebSocket sync via JavaScript bridge

## References

- [Eg-walker paper](https://arxiv.org/abs/2409.14252)
- [Reference implementation](https://github.com/josephg/eg-walker-reference)
- [Loro eg-walker docs](https://loro.dev/docs/advanced/event_graph_walker)

## Design Decisions

### Character-Level Operations
Each insert/delete operates on a single character. This ensures:
- Minimal conflicts in collaborative editing
- Clear dependency tracking
- Simpler merge semantics

### Logical Versions (LV)
Operations indexed by LV (array index) rather than agent/sequence pairs for:
- O(1) operation lookup
- Simple frontier representation
- Efficient walker traversal

## Contributing

When modifying this module:

1. Keep components independent (internal/document, internal/oplog, internal/causal_graph, internal/fugue, internal/branch)
2. Update tests alongside implementation changes
3. Run `moon test` to verify CRDT properties
4. Use `moon bench --release` for performance-critical changes (always `--release`)

## License

Apache 2.0 - See LICENSE file in repository root
