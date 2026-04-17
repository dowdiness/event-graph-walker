///| Whitebox tests for undo internals (depth counter, buffer, gating flags).
///
/// These assertions cannot be written blackbox because the txn depth, buffer
/// state, and the two gating flags are private. Once the Phase 3 public API
/// lands, most behaviors will also be testable through public entry points.

///|
/// Synthesize a cheap TextInsert undo item for tests that don't care about
/// content — only the presence of a record in the buffer / stack.
fn dummy_undo_item() -> UndoItem {
  let id : @mt.TreeNodeId = { agent: "test", counter: 0 }
  TextInsert(block=id, lv=42, content="x")
}

///|
test "undo: depth counter starts at 0 and pairs correctly" {
  let doc = Document::new("alice")
  inspect(doc.txn_depth, content="0")
  doc.txn_open()
  inspect(doc.txn_depth, content="1")
  doc.txn_close()
  inspect(doc.txn_depth, content="0")
  inspect(doc.undo_stack.length(), content="0")
}

///|
test "undo: nested transactions flatten into a single outer group" {
  let doc = Document::new("alice")
  doc.txn_open()
  doc.txn_open()
  doc.record_undo_item(dummy_undo_item())
  doc.txn_close()
  inspect(doc.txn_depth, content="1")
  // No commit yet — still inside outer txn.
  inspect(doc.undo_stack.length(), content="0")
  doc.txn_close()
  inspect(doc.txn_depth, content="0")
  inspect(doc.undo_stack.length(), content="1")
  inspect(doc.undo_stack[0].items.length(), content="1")
}

///|
test "undo: commit clears redo stack" {
  let doc = Document::new("alice")
  // Pre-seed redo with a dummy group to prove a fresh commit wipes it.
  doc.redo_stack.push({ items: [dummy_undo_item()] })
  inspect(doc.redo_stack.length(), content="1")
  doc.txn_open()
  doc.record_undo_item(dummy_undo_item())
  doc.txn_close()
  inspect(doc.undo_stack.length(), content="1")
  inspect(doc.redo_stack.length(), content="0")
}

///|
test "undo: empty transaction commits no group" {
  let doc = Document::new("alice")
  doc.txn_open()
  doc.txn_close()
  inspect(doc.txn_depth, content="0")
  inspect(doc.undo_stack.length(), content="0")
}

///|
// `tracking_enabled=false` and `undo_execution_mode=true` suppression paths
// are exercised by Phase 3's public-API tests (set_tracking, undo/redo).
// Phase 2 only tests the depth/buffer/stack invariants.

///|
test "undo: record outside any txn is a no-op" {
  let doc = Document::new("alice")
  doc.record_undo_item(dummy_undo_item())
  inspect(doc.txn_depth, content="0")
  inspect(doc.txn_buffer.length(), content="0")
  inspect(doc.undo_stack.length(), content="0")
}
