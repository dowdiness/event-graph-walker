# Examples

Worked examples for common use cases. These build on the Quick Start in the [README](../README.md) — read that first.

---

## Example 1: Sync with Error Handling

Real networks fail. This example shows how to handle each `TextError` variant from the sync API and decide whether to retry, reconnect, or discard.

```moonbit
import "dowdiness/event-graph-walker/text"

fn sync_to_peer(
  doc : @text.TextDoc,
  peer : @text.TextDoc,
) -> Unit {
  let peer_version = peer.version()

  try {
    // Export only what the peer hasn't seen yet
    let message = doc.sync().export_since(peer_version)
    if not(message.is_empty()) {
      peer.sync().apply(message)
    }
  } catch {
    @text.TextError::SyncFailed(@text.MissingDependency(hint~)) => {
      // Peer is missing an operation we depend on — fall back to full sync
      println("Dependency gap detected: \{hint}. Sending full history.")
      try {
        let full = doc.sync().export_all()
        peer.sync().apply(full)
      } catch {
        err => println("Full sync failed: " + err.message())
      }
    }
    @text.TextError::SyncFailed(@text.MalformedMessage(detail~)) => {
      // Message is corrupt or from an incompatible version — discard silently
      println("Discarding malformed message: \{detail}")
    }
    @text.TextError::SyncFailed(@text.Timeout(detail~)) => {
      // Network timeout — safe to retry
      println("Sync timed out: \{detail}. Will retry.")
    }
    @text.TextError::SyncFailed(@text.Cancelled(detail~)) => {
      // User cancelled — do nothing
      println("Sync cancelled: \{detail}")
    }
    @text.TextError::VersionNotFound => {
      // Peer's version is no longer in our history — full sync needed
      println("Peer version unknown. Sending full history.")
      try {
        let full = doc.sync().export_all()
        peer.sync().apply(full)
      } catch {
        err => println("Full sync failed: " + err.message())
      }
    }
    err => {
      // Other errors: log and decide based on is_retryable()
      if err.is_retryable() {
        println("Transient error: " + err.message() + ". Will retry.")
      } else {
        println("Fatal sync error: " + err.message())
        println("Hint: " + err.help())
      }
    }
  }
}

// Usage
let alice = @text.TextDoc::new("alice")
alice.insert(@text.Pos::at(0), "Hello")
alice.insert(@text.Pos::at(5), " World")

let bob = @text.TextDoc::new("bob")
sync_to_peer(alice, bob)
println(bob.text())  // "Hello World"

// Concurrent edits converge after sync in both directions
bob.insert(@text.Pos::at(11), "!")
sync_to_peer(bob, alice)
println(alice.text())  // "Hello World!"
```

---

## Example 2: Undo/Redo with Collaborative Sync

The `UndoManager` tracks which operations belong to the local user, so undo only reverts *your own* edits even when remote edits are interleaved. Use `insert_and_record` / `delete_and_record` for local edits; use `apply_remote` / `merge_remote` for remote edits (those are never recorded).

```moonbit
import "dowdiness/event-graph-walker/text"
import "dowdiness/event-graph-walker/undo"

// Create document and undo manager for alice
let alice_doc = @text.TextDoc::new("alice")
let alice_mgr = @undo.UndoManager::new("alice")

// Helpers track local operations in the undo manager
let now = 1000  // milliseconds timestamp

alice_doc.insert_and_record(@text.Pos::at(0), "Hello", alice_mgr, timestamp_ms=now)
alice_doc.insert_and_record(@text.Pos::at(5), " World", alice_mgr, timestamp_ms=now)
println(alice_doc.text())  // "Hello World"

// Remote op from bob arrives — apply directly, do NOT record
let bob_doc = @text.TextDoc::new("bob")
bob_doc.insert(@text.Pos::at(0), "Hi ")
let bob_msg = bob_doc.sync().export_all()
alice_doc.sync().apply(bob_msg)

// Undo only reverts alice's last edit, leaving bob's "Hi " intact
if alice_mgr.can_undo() {
  try {
    let undo_ops = alice_mgr.undo(alice_doc)
    println(alice_doc.text())  // "Hi Hello" (bob's "Hi " is still there)

    // Propagate the undo to peers by wrapping returned ops in a SyncMessage
    if not(undo_ops.is_empty()) {
      let heads = alice_doc.get_frontier_raw()
      let undo_msg = @text.SyncMessage::new(undo_ops, heads)
      // send undo_msg to peers...
      let _ = undo_msg  // (in real code: send over network)
    }
  } catch {
    err => println("Undo failed: \{err}")
  }
}

// Redo restores alice's text
if alice_mgr.can_redo() {
  try {
    let redo_ops = alice_mgr.redo(alice_doc)
    println(alice_doc.text())  // "Hi Hello World"
    let _ = redo_ops  // propagate to peers the same way
  } catch {
    err => println("Redo failed: \{err}")
  }
}
```

**Key points:**
- `insert_and_record` / `delete_and_record` both edit the document *and* record to the undo stack in one call.
- `undo` / `redo` return `Array[@core.Op]` — the inverse operations applied. Wrap them in `SyncMessage::new(ops, heads)` and send to peers so they see the undo too.
- `can_undo()` / `can_redo()` let you enable/disable buttons in the UI without triggering errors.

---

## Example 3: Historical Checkout and Incremental Catch-Up

`TextDoc::checkout` returns a read-only `TextView` frozen at a past version. The live document is unaffected. This is useful for diffing, read-only preview, and letting a late-joining peer catch up incrementally.

```moonbit
import "dowdiness/event-graph-walker/text"

let doc = @text.TextDoc::new("alice")

doc.insert(@text.Pos::at(0), "Hello")
let v1 = doc.version()  // Snapshot version after "Hello"

doc.insert(@text.Pos::at(5), " World")
let v2 = doc.version()  // Snapshot version after " World"

doc.insert(@text.Pos::at(11), "!")
println(doc.text())  // "Hello World!"

// Inspect an earlier version without changing the live document
try {
  let snapshot_v1 = doc.checkout(v1)
  println(snapshot_v1.text())  // "Hello"
  println(doc.text())           // "Hello World!" (unchanged)

  let snapshot_v2 = doc.checkout(v2)
  println(snapshot_v2.text())  // "Hello World"
} catch {
  @text.TextError::VersionNotFound =>
    println("Version no longer available")
  err => println("Checkout failed: " + err.message())
}

// Late-joining peer: catch up incrementally from a known version
let carol = @text.TextDoc::new("carol")

// Carol received the first batch up to v1 previously
let batch1 = doc.sync().export_since(carol.version())
carol.sync().apply(batch1)
println(carol.text())  // "Hello World!"

// Or, if carol has v1 already, sync only the delta
let carol_v1 = v1
try {
  let delta = doc.sync().export_since(carol_v1)
  // carol.sync().apply(delta)  -- only needed if carol already has v1
  println("Delta has \{delta.op_count()} operation(s)")
} catch {
  @text.TextError::VersionNotFound => {
    // carol's version is older than what we track — full sync fallback
    let full = doc.sync().export_all()
    carol.sync().apply(full)
  }
  err => println("Sync error: " + err.message())
}
```

**Key points:**
- `doc.version()` returns a `Version` value that can be stored and passed to `checkout` or `export_since` later.
- `checkout` returns a `TextView` (read-only view) — it has `text()` but no mutation methods.
- `export_since(version)` efficiently sends only the operations the peer hasn't seen. Fall back to `export_all()` when `VersionNotFound` is raised.
