# Examples

These examples demonstrate common tasks using only public façade APIs. Equivalent test suites are compiled in `examples/examples_test.mbt`.

---

## Contents

- [Text operations and error handling](#text-operations-and-error-handling)
- [Text synchronization](#text-synchronization)
- [Accepted text history persistence](#accepted-text-history-persistence)
- [Tree synchronization](#tree-synchronization)
- [Text undo and redo](#text-undo-and-redo)
- [Container document and undo](#container-document-and-undo)
- [Historical checkout](#historical-checkout)

---

## Text operations and error handling

Constructing ranges or addressing out-of-bounds positions raises explicit `TextError` variants:

```moonbit
let doc = @text.TextState::new("alice-laptop")
doc.insert(@text.Pos::at(0), "Hello World")

// Safely construct a range:
let range = @text.Range::from_ints(0, 5) catch {
  @text.TextError::InvalidRange(start~, end~) => {
    println("Failed: start \{start} > end \{end}")
    return
  }
  error => raise error
}

// Safely delete a range with bounds checking:
doc.delete_range(range) catch {
  @text.TextError::InvalidPosition(pos~, len~) =>
    println("Failed: endpoint \{pos} exceeds document length \{len}")
  error => raise error
}

println(doc.text()) // " World"
```

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

## Accepted text history persistence

Full-history replay is the supported storage-independent restore path for text
schema 2. It preserves accepted operations, including deleted text and operation
identities needed by future synchronization. It is not a snapshot of the whole
runtime: pending messages, UndoManager stacks, peer acknowledgments, and UI state
are not exported. A state with pending messages can still save its accepted
history.

Capture history and Version synchronously, without interleaving edits:

```moonbit
let history_json = original.sync().export_all().to_json_string()
let saved_version_json = original.version().to_json_string()
// Persist both strings in one application-owned atomic record.
```

Both capture and Version encoding can fail. On failure, keep the previous saved
record; do not store partial output or substitute an empty document. The Version
is a consistency check, not a second source of state or a content integrity proof.

Restore into a private candidate and publish it only after all checks succeed.
This application-owned function is compiled and exercised in
`examples/examples_test.mbt`; it needs only the public `text` and `sync` packages.

```moonbit
fn restore_text_history(
  history_json : String,
  saved_version_json : String,
  fresh_replica_id : String,
) -> @text.TextState raise {
  let restore_limits = @sync.Limits(
    max_encoded_bytes=4 * 1024 * 1024,
    max_decoded_operations=20_000,
    max_pending_operations=0,
  )
  // Bound code units without encoding potentially malformed UTF-16.
  // apply_with_limits enforces the exact UTF-8 byte budget after decoding.
  guard history_json.length() <= restore_limits.max_encoded_bytes() else {
    fail("history exceeds pre-decode code-unit budget")
  }
  let expected = @text.Version::from_json_string(saved_version_json)
  // Normal network admission retains its usual pending budget.
  let candidate = @text.TextState::new(fresh_replica_id)
  let message = candidate.sync().decode_json(history_json)
  let report = candidate.sync().apply_with_limits(message, restore_limits)
  guard report.pending_operations() == 0 && candidate.version() == expected else {
    fail("incomplete or mismatched saved history")
  }
  candidate
}
```

The pre-check bounds UTF-16 code units before JSON parsing without allocating
an encoded copy. It is not an exact UTF-8 byte check: a well-formed string that
passes can encode to up to three times the byte budget. `decode_json` validates
UTF-16 before encoding, but does not enforce the budget; `apply_with_limits`
enforces the exact encoded byte limit after decoding. Do not call `@utf8.encode`
on unvalidated input: unpaired surrogates can abort on non-JS targets instead of
raising a catchable error. The per-call pending limit rejects archives with unresolved
dependencies without disabling pending for subsequent network synchronization.
Version comparison also rejects a complete but truncated prefix, which can have
zero pending operations. On any failure, discard the candidate, retain the saved
record, and report the error rather than opening an empty writable document.

After restoring, continue editing normally and use the receiver's actual Version:

```moonbit
let restored = restore_text_history(history_json, saved_version_json, fresh_id)
restored.insert(@text.Pos::at(restored.len()), "!")
let delta = restored.sync().export_since(peer.version())
peer.sync().apply(delta)
```

### Identity, bounds, and application storage requirements

- Supply a new, globally unique replica-instance ID for each new writable
  `TextState`. Constructors reject empty IDs but do not generate or verify global
  uniqueness. Never reuse an old `(replica_id, sequence)`. Reconnecting a UI to
  the same living state does not create a new writer. The fixed IDs in examples
  are test fixtures, not a production ID allocation scheme.
- Keep the application document ID separate from the replica ID. Put document
  ID and storage-format version in an application envelope and validate them
  before restore. Text sync messages do not authenticate or identify a document.
- The example's 4 MiB / 20,000-operation limits are illustrative restore budgets,
  not automatic cumulative history limits or measured production thresholds.
  Configure saving and restore consistently, including parent-count limits, and
  ensure saved Versions fit the [schema-2 Version limits](../migration/text-schema-2.md).
  The adapter must bound cumulative history and define what happens when local
  edits or remote merging would exceed it; never truncate history to fit.
- Bound incoming storage/network data before materializing unbounded strings.
  The code-unit pre-check bounds parsing input, not total replay memory or latency.
  If a strict byte limit before parsing is required, enforce it at the byte-oriented
  storage/network boundary before converting the input to a String.
- Save the two strings atomically, exclude competing stale writers, and advertise
  local save completion only after the storage transaction commits. No IndexedDB
  adapter, multi-tab exclusion, quota policy, or process/power-loss durability
  guarantee is supplied by this recipe.
- ACK only the **captured Version belonging to the committed record**, not the
  live state's Version sampled after an asynchronous write. Edits may have
  advanced while saving. Pending identities must not be acknowledged as durable.
  Senders must retain unacknowledged operations durably and retransmit from the
  receiver's restored Version; this is how discarded pending data recovers.
- Only schema 2 is supported here. Reject incompatible formats while retaining
  their original data for explicit migration. This recipe does not provide
  corruption authentication, checkpoint acceleration, or history compaction.

Contract tests in `text/history_restore_test.mbt` cover continued delta sync,
fresh writers, delayed references to deleted text, identity conflicts,
pending retransmission, resource boundaries, and generated restart cuts. They
exercise serialized replay, not an actual browser process crash.

## Tree synchronization

```moonbit
let alice = @tree.TreeState::new("alice-tree")
let project = alice.create_node(parent=@tree.root_id)
alice.set_property(project, "name", "project")

let bob = @tree.TreeState::new("bob-tree")
let report = bob.sync().apply(alice.sync().export_all())
println(report.applied_operations())
println(bob.get_property(project, "name"))
println(bob.properties(project)) // [("name", "project")]
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
