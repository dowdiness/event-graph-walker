# Examples

These examples use only v0.5 façade APIs. Equivalent cases are compiled as
tests in `examples/examples_test.mbt`.

## Text synchronization

Capture the receiving peer's version only after it has applied the baseline:

```moonbit
let alice = @text.TextState::new("alice-laptop")
let bob = @text.TextState::new("bob-laptop")

alice.insert(@text.Pos::at(0), "Hello")
bob.sync().apply(alice.sync().export_all())

let bob_version = bob.version()
alice.insert(@text.Pos::at(5), "!")
bob.sync().apply(alice.sync().export_since(bob_version))
```

For a network transport, encode the opaque message rather than inspecting its
operations:

```moonbit
let outbound = alice.sync().export_all().to_json_string()
let inbound = @text.SyncMessage::from_json_string(outbound)
let report = bob.sync().apply(inbound)
println(report.applied_operations())
```

On `TextError::SyncFailed(failure)`, use the shared `@sync.Failure`
classification. Malformed content, conflicting identities, and exceeded
limits are not retryable with the same payload. A message that remains pending
because dependencies have not arrived can be followed by an earlier or full
batch. Call `pending_sync_count()` to expose backpressure and
`clear_pending_sync()` only when intentionally discarding that valid queued
work.

## Tree synchronization

```moonbit
let alice = @tree.TreeState::new("alice-tree")
let project = alice.create_node(parent=@tree.root_id)
alice.set_property(project, "name", "project")

let bob = @tree.TreeState::new("bob-tree")
let report = bob.sync().apply(alice.sync().export_all())
println(report.applied_operations())
println(bob.get_property(project, "name"))
```

Tree JSON uses `event-graph-walker/tree-sync`; it is deliberately incompatible
with text and container envelopes.

## Text undo and redo

`UndoManager::undo` and `redo` return `Bool`: `false` means the corresponding
stack was empty or the popped group was entirely stale. A stale result consumes
the group, emits no CRDT operation, and creates no opposite history.

```moonbit
let document = @text.TextState::new("alice-undo")
let manager = @undo.UndoManager::new("alice-undo")

document.insert_and_record(
  @text.Pos::at(0),
  "Hello",
  manager,
  timestamp_ms=1_000,
)

let before_undo = document.version()
if manager.undo(document) {
  let inverse = document.sync().export_since(before_undo)
  // Send `inverse` to peers.
}

if manager.redo(document) {
  println(document.text())
}
```

Remote operations applied through `sync().apply()` never enter the local undo
manager.

## Container document and undo

```moonbit
let document = @container.Document::new("alice-document")
let paragraph = document.create_node(parent=@container.root_id)
document.set_property(paragraph, "type", "paragraph")
document.insert_text(paragraph, 0, "Hello")

if document.undo() {
  println(document.get_text(paragraph))
}
if document.redo() {
  println(document.get_text(paragraph))
}
```

Container undo/redo also returns `Bool`. A transaction groups its mutations as
one undo item:

```moonbit
document.transaction(fn() {
  document.set_property(paragraph, "status", "ready")
  document.insert_text(paragraph, document.text_len(paragraph), "!")
})
```

## Historical checkout

```moonbit
let document = @text.TextState::new("alice-history")
document.insert(@text.Pos::at(0), "Hello")
let saved = document.version()
document.insert(@text.Pos::at(5), "!")

let view = document.checkout(saved)
println(view.text())      // Hello
println(document.text())  // Hello!
```

Checkout requires every maximum sequence referenced by the version to exist
locally and raises `VersionNotFound` otherwise.
