# Examples

These examples demonstrate common tasks using only public façade APIs. Equivalent test suites are compiled in `examples/examples_test.mbt`.

---

## Contents

- [Editor change stream](#editor-change-stream)
- [Text operations and error handling](#text-operations-and-error-handling)
- [Text synchronization](#text-synchronization)
- [Accepted text history persistence](#accepted-text-history-persistence)
- [Tree synchronization](#tree-synchronization)
- [Text undo and redo](#text-undo-and-redo)
- [Container document and undo](#container-document-and-undo)
- [Historical checkout](#historical-checkout)

---

## Editor change stream

Use `@text.Editor` when the application needs text changes for a textarea,
parser, or another derived view. It owns the CRDT and local Undo history;
`edit`, `undo`, `redo`, and `receive` all return `Edit`.
The contract is exercised in `text/editor_test.mbt`.

```moonbit
let editor = @text.Editor::new("alice-laptop")
let initial = editor.snapshot()
let result = editor.edit(initial.version, {
  start: 0, end: 0, text: "日本語🙂",
})
match result {
  Applied(update) => {
    // Apply each edit to the view at update.before, in order.
    // start/end are half-open UTF-16 offsets in the progressively updated text.
    for edit in update.edits() {
      println("replace \{edit.start}..\{edit.end} with \{edit.text}")
    }
    // Only then advance the view's version to update.after.
  }
  Rejected(_) => () // The visible document and causal version are unchanged.
  Invalidated(_) => abort("Editor invalidated; reopen explicitly before rendering")
}
```

Unlike `TextState`'s scalar-coordinate primitives, `Editor` accepts UTF-16 ranges
directly. It rejects negative/out-of-bounds offsets, surrogate splits, malformed
text, and edits addressed to a stale version. It does not clamp positions or
silently rebase a stale request. Conversion uses the document's existing rank
tree with scalar and UTF-16 subtree totals, not an application-owned index.

By default each nonempty request is one Undo group. `edit_many` accepts a
normalized `ChangeSet` in the base document's UTF-16 coordinates. `Keep(n)`
retains `n` code units; `Replace(n, text)` replaces the next `n` code units.
The sections cover the entire base document, including the trailing keep.

```moonbit
let editor = @text.Editor::new("batch-writer")
let seed = editor.edit(editor.version(), {
  start: 0, end: 0, text: "hello world",
}, undo=NoHistory)
guard seed is Applied(_) else { abort("seed rejected") }
let bold = @text.ChangeSet::new([
  Replace(0, "**"), Keep(5), Replace(0, "**"), Keep(6),
])
let result = editor.edit_many(editor.version(), bold, label="mark.add")
// One undo removes both delimiters, restoring "hello world".
```

`ChangeSet::new` copies and normalizes its input: adjacent keeps and adjacent
replacements merge; zero-length keeps and empty replacements disappear. It
rejects negative/overflowing lengths and malformed inserted UTF-16 before a
request reaches the editor. `edit_many` checks the version first, then base
length, then all replacement boundaries against the document. Length mismatch
is `InvalidChange(LengthMismatch)`, not `StaleVersion`. All replacements are
validated before applying any, then applied right-to-left inside one publication
boundary. It never invokes the public single-edit method in a loop.

`undo=NewGroup` is the default. `JoinPrevious` joins only if the preceding local
history group is still eligible. Receive with nonempty `edits()`,
Undo/Redo, and nonempty `NoHistory` edits end that eligibility. With no eligible
group, joining creates a new one. Rejected and empty local requests leave it
unchanged, as do empty receives (including duplicates and pending-only packets).
Nonempty recorded requests clear redo; `NoHistory` and empty requests
preserve redo. `NoHistory` does not create undo items. The editor does not use
time-based UndoManager capture; lower-level `TextState::*_and_record` retains
that compatibility behavior.

The host decides when an IME composition becomes a request and when adjacent
typing should join a group. This API does not supply browser event handling or
time-based typing decisions. Remote changes never enter the local Undo history.
Version equality establishes the document state, not user identity; do not reuse
a version across unrelated documents.

Normal updates contain authority-produced edits, coalesced for adjacent changes.
They never request a full-text diff, including Undo/Redo. `snapshot()` is an
explicit initialization/read operation, not a fallback for missing effects.
No-op or dependency-blocked receives can return an empty update.

`TextUpdate.edits()` remains the sole applied-edit record, in sequential UTF-16
coordinates. `before_len` records the old UTF-16 length from the projection index
without materializing text. `change_set()` lazily derives and caches a normalized
base-coordinate change set; it does not retain the Editor or a text snapshot.
Nonoverlapping descending edits already use base coordinates: after checking
that each edit's end is at most the preceding edit's start, derivation constructs
sections in one reverse pass. This applies to actual edits from any origin,
including qualifying receives. Other sequences use the general composition fold.
The direct path visits O(k) sections; concatenating inserted strings still has
its backend-dependent cost. It never substitutes the original command input
for the applied-edit record.
`ChangeSet::compose(next)` composes A→B with B→C and rejects incompatible lengths.
It can check boundaries within inserted text; only the editor can validate
boundaries in an otherwise unknown base document. Composition scans sections,
not unchanged document text. Repeated folding can revisit earlier sections;
this API does not promise linear total cost for arbitrarily many sequential edits.

The isolated first-derivation benchmark is
`moon bench text/change_set_benchmark_wbtest.mbt --target js --release`.
In this orb, removing repeated validation of already-validated composition
output reduced a 1,048,576-unit ASCII insertion followed by 1,000 appends from
3.16s to 2.32ms (ten benchmark samples, mean). The 1,000-appends-only control
changed from 1.82ms to 0.307ms. These exclude CRDT setup, transport, parsing and
rendering, and are not cross-backend or end-to-end claims. JavaScript may retain
concatenated strings without eagerly flattening them.
The separate 1,000-disjoint-descending-replacements case took 63.23ms after that
fix (69.52ms in the later comparison), then 0.102ms with direct descending
derivation. Actual Editor outputs on a 2,000-unit document reproduce the cost:
1,000 replacements through edit_many took 117.30 → 0.101ms to derive;
the corresponding receive output took 107.57 → 0.118ms. One/four-replacement
edit_many outputs took 0.645 → 0.180µs / 3.34 → 0.496µs. All exclude edit/receive
execution and reset the derived cache on each sample. Each actual-output case
checks normalized equality with its independently constructed input ChangeSet.
Node CPU sampling of the synthetic descending case before specialization
attributed non-idle self time to compose (27%), change_set (16.2%), array push
(13.9%), normalization (13.8%), and GC (11.9%). This includes runtime/warmup
and is sampling attribution, not exclusive phase timing of a single 63ms call.
No balanced composition structure is implemented; arbitrary-order folds retain
their existing worst-case complexity.

Every update identifies its cause as `Local(label)`, `Remote`, `Undo`, or `Redo`.
`sync_report` is `Some(SyncReport)` for every successful receive and `None` for
local edits, Undo and Redo. Its applied, duplicate and pending operation counts
remain available even when `edits()` is empty.
The optional `label` is application metadata, not a grouping rule or a network
field. Consumers can suppress automatic correction for `Remote` without tracing
the call site. Transport and causal authority remain `SyncMessage`, not ChangeSet.

`Invalidated` ends the current editing session, not the Editor instance's
lifetime. A failure may follow committed operations or leave no exact change
sequence. Neither case promises rollback. Snapshot reads, edits, Undo/Redo,
`receive()` and `advance_view()` are refused until explicit reopening.
`history_version()` and `export_since()` remain available for inspecting and
exporting accepted history; `version()` identifies the displayed cut instead.
History-only `accept_remote()` also remains available after invalidation and
reports admission independently of the projection.

Call `reopen_view()` to rebuild the complete accepted cut on the same Editor.
Successful reopening clears EGW Undo history and returns a new snapshot; the
host must explicitly establish a new native input/Undo baseline. Failure leaves
the session unavailable. `receive()` failures invalidate even when the displayed
version is unchanged. Conflicting incoming operations do not replace previously
accepted pending operations, but admission failures can retain committed progress;
they are not a promise that the entire request left history unchanged.

`SnapshotRequired` at the lower-level transition is not itself an Editor result.
Editor warms projection indexes before collecting edits. Losing exact indexes
during projection or rebuilding the projection during collection invalidates
the collector, so Editor returns `Invalidated` rather than publishing incomplete
edits. An error obtaining `before_len` also returns `Invalidated` before invoking
the action. Fault-injection tests cover recovery paths; they do not prove that
every possible valid packet is incapable of exposing an indexing defect.

`TextState`, `SyncSession`, and generic `UndoManager` remain lower-level APIs for
callers that own their mutation/Undo policy. Do not combine them with an `Editor`
or maintain a second mutable authority behind its back: the editor deliberately
does not expose its mutable state or Undo manager.

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
  // Normal network apply retains its usual pending budget.
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
