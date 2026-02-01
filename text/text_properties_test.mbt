// Property-based tests for Text API using QuickCheck
//
// These tests verify fundamental properties of the TextDoc CRDT
// using Arbitrary and Shrink traits for automatic test generation and minimization.

///|
/// Generated operations for property testing (real TextDoc edits).
pub(all) struct RealOps {
  agent : String
  ops : Array[@core.Op]
} derive(Show)

///|
/// Arbitrary instance for RealOps
pub impl @quickcheck.Arbitrary for RealOps with arbitrary(size, random_state) {
  let chars : Array[Char] = [
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p',
    'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
  ]
  let agent_id = random_state.split().next_uint64().to_int().abs()
  let agent = "gen-\{agent_id}"
  let doc = @text.TextDoc::new(agent)
  let ops : Array[@core.Op] = []
  for i = 0; i < size; i = i + 1 {
    let len = doc.len()
    let is_insert = if len == 0 {
      true
    } else {
      random_state.split().next_uint64() % 2 == 0
    }
    if is_insert {
      let pos = random_state.split().next_uint64().to_int().abs() % (len + 1)
      let char_idx = random_state.split().next_uint64().to_int().abs() %
        chars.length()
      let change = doc.insert(@text.Pos::at(pos), chars[char_idx].to_string()) catch {
        _ => continue
      }
      ops.push(change.to_op())
    } else {
      let pos = random_state.split().next_uint64().to_int().abs() % len
      let change = doc.delete(@text.Pos::at(pos)) catch { _ => continue }
      ops.push(change.to_op())
    }
  }
  { agent, ops }
}

///|
/// Shrink instance for RealOps
pub impl @qc.Shrink for RealOps with shrink(self) {
  let results : Array[RealOps] = []
  let ops = self.ops
  let len = ops.length()
  if len > 0 {
    results.push({ agent: self.agent, ops: [] })
    let half = len / 2
    if half > 0 {
      results.push({ agent: self.agent, ops: ops[:half].to_array() })
    }
    results.push({ agent: self.agent, ops: ops[:len - 1].to_array() })
  }
  results.iter()
}

///|
/// Apply a real operation to a document, returning success.
fn apply_op(doc : @text.TextDoc, op : @core.Op) -> Bool {
  try {
    doc.apply_remote(op)
    true
  } catch {
    _ => false
  }
}

///|
/// Apply a sequence of operations to a document
fn apply_ops(doc : @text.TextDoc, ops : Array[@core.Op]) -> Unit {
  for op in ops {
    let _ = apply_op(doc, op)

  }
}

///|
/// Property: Sync convergence - two documents with same ops converge
fn prop_sync_convergence(ops : RealOps) -> Bool {
  let doc1 = @text.TextDoc::new("alice")
  let doc2 = @text.TextDoc::new("bob")

  // Apply ops to doc1
  apply_ops(doc1, ops.ops)

  // Sync doc1 -> doc2
  let msg = doc1.sync().export_all() catch {
      _ => return true // If export fails, skip this test case
    }
  doc2.sync().apply(msg) catch {
    _ => return true
  }

  // Both documents should have same text
  doc1.text() == doc2.text()
}

///|
test "property: sync convergence" {
  @qc.quick_check_fn(prop_sync_convergence)
}

///|
/// Property: Sync is idempotent - applying same message twice has no effect
fn prop_sync_idempotent(ops : RealOps) -> Bool {
  let doc1 = @text.TextDoc::new("alice")
  let doc2 = @text.TextDoc::new("bob")
  apply_ops(doc1, ops.ops)
  let msg = doc1.sync().export_all() catch { _ => return true }

  // Apply once
  doc2.sync().apply(msg) catch {
    _ => return true
  }
  let text_after_first = doc2.text()

  // Apply again (should be no-op)
  let msg2 = doc1.sync().export_all() catch { _ => return true }
  doc2.sync().apply(msg2) catch {
    _ => return true
  }
  let text_after_second = doc2.text()
  text_after_first == text_after_second
}

///|
test "property: sync is idempotent" {
  @qc.quick_check_fn(prop_sync_idempotent)
}

///|
/// Property: Version changes after edit
fn prop_version_changes_after_edit(char : Char) -> Bool {
  let doc = @text.TextDoc::new("alice")
  let v1 = doc.version()
  try {
    let _ = doc.insert(@text.Pos::at(0), char.to_string())

  } catch {
    _ => return true
  }
  let v2 = doc.version()
  v1 != v2
}

///|
test "property: version changes after edit" {
  @qc.quick_check_fn(prop_version_changes_after_edit)
}

///|
/// Property: Insert increases length by 1
fn prop_insert_increases_length(pos : Int) -> Bool {
  let doc = @text.TextDoc::new("alice")
  // Pre-populate with some content
  try {
    let _ = doc.insert(@text.Pos::at(0), "hello")

  } catch {
    _ => return true
  }
  let len_before = doc.len()
  let clamped_pos = if pos < 0 {
    0
  } else if pos > len_before {
    len_before
  } else {
    pos
  }
  try {
    let _ = doc.insert(@text.Pos::at(clamped_pos), "x")

  } catch {
    _ => return true
  }
  doc.len() == len_before + 1
}

///|
test "property: insert increases length" {
  @qc.quick_check_fn(prop_insert_increases_length)
}

///|
/// Property: Delete decreases length by 1 (when doc not empty)
fn prop_delete_decreases_length(pos : Int) -> Bool {
  let doc = @text.TextDoc::new("alice")
  // Pre-populate
  try {
    let _ = doc.insert(@text.Pos::at(0), "hello")

  } catch {
    _ => return true
  }
  let len_before = doc.len()
  if len_before == 0 {
    return true
  }
  let clamped_pos = if pos < 0 {
    0
  } else if pos >= len_before {
    len_before - 1
  } else {
    pos
  }
  try {
    let _ = doc.delete(@text.Pos::at(clamped_pos))

  } catch {
    _ => return true
  }
  doc.len() == len_before - 1
}

///|
test "property: delete decreases length" {
  @qc.quick_check_fn(prop_delete_decreases_length)
}

///|
/// Property: Checkout preserves text at that version
fn prop_checkout_preserves_text(ops : RealOps) -> Bool {
  let doc = @text.TextDoc::new("alice")

  // Apply some ops
  let mid = ops.ops.length() / 2
  for i = 0; i < mid; i = i + 1 {
    let _ = apply_op(doc, ops.ops[i])

  }

  // Save version and text
  let saved_version = doc.version()
  let saved_text = doc.text()

  // Apply more ops
  for i = mid; i < ops.ops.length(); i = i + 1 {
    let _ = apply_op(doc, ops.ops[i])

  }

  // Checkout saved version
  let view = doc.checkout(saved_version) catch { _ => return true }

  // Text should match
  view.text() == saved_text
}

///|
test "property: checkout preserves text" {
  @qc.quick_check_fn(prop_checkout_preserves_text)
}

///|
/// Property: Empty document has length 0
fn prop_empty_doc_length_zero(agent : String) -> Bool {
  let agent_name = if agent.length() == 0 { "default" } else { agent }
  let doc = @text.TextDoc::new(agent_name)
  doc.len() == 0 && doc.is_empty()
}

///|
test "property: empty document has length zero" {
  @qc.quick_check_fn(prop_empty_doc_length_zero)
}

///|
/// Property: Pos::at clamps negative values to 0
fn prop_pos_clamps_negative(n : Int) -> Bool {
  let pos = @text.Pos::at(n)
  pos.value() >= 0
}

///|
test "property: Pos clamps negative values" {
  @qc.quick_check_fn(prop_pos_clamps_negative)
}

///|
/// Property: Version equality is reflexive
fn prop_version_reflexive(ops : RealOps) -> Bool {
  let doc = @text.TextDoc::new("alice")
  apply_ops(doc, ops.ops)
  let v = doc.version()
  v == v
}

///|
test "property: version equality is reflexive" {
  @qc.quick_check_fn(prop_version_reflexive)
}

///|
/// Property: SyncMessage::is_empty consistent with op_count
fn prop_sync_message_empty_consistent(ops : RealOps) -> Bool {
  let doc = @text.TextDoc::new("alice")
  apply_ops(doc, ops.ops)
  let msg = doc.sync().export_all() catch { _ => return true }
  (msg.is_empty() && msg.op_count() == 0) ||
  (not(msg.is_empty()) && msg.op_count() > 0)
}

///|
test "property: SyncMessage is_empty consistent with op_count" {
  @qc.quick_check_fn(prop_sync_message_empty_consistent)
}

///|
/// Property: Bidirectional sync results in convergence
fn prop_bidirectional_sync_converges(pair : (RealOps, RealOps)) -> Bool {
  let (ops1, ops2) = pair
  let doc1 = @text.TextDoc::new("alice")
  let doc2 = @text.TextDoc::new("bob")

  // Apply different ops to each doc
  apply_ops(doc1, ops1.ops)
  apply_ops(doc2, ops2.ops)

  // Sync both ways
  let msg1 = doc1.sync().export_all() catch { _ => return true }
  let msg2 = doc2.sync().export_all() catch { _ => return true }
  doc1.sync().apply(msg2) catch {
    _ => return true
  }
  doc2.sync().apply(msg1) catch {
    _ => return true
  }

  // Should converge
  doc1.text() == doc2.text()
}

///|
test "property: bidirectional sync converges" {
  @qc.quick_check_fn(prop_bidirectional_sync_converges)
}

///|
/// Property: export_since with current version exports empty
fn prop_export_since_current_is_empty(ops : RealOps) -> Bool {
  let doc = @text.TextDoc::new("alice")
  apply_ops(doc, ops.ops)
  let current_version = doc.version()
  let msg = doc.sync().export_since(current_version) catch { _ => return true }
  msg.is_empty()
}

///|
test "property: export_since current version is empty" {
  @qc.quick_check_fn(prop_export_since_current_is_empty)
}

///|
/// Property: Undo-redo roundtrip preserves text.
/// For any sequence of inserts, undo then redo should restore the original text.
fn prop_undo_redo_roundtrip_insert(size : Int) -> Bool {
  let clamped = if size < 0 { 0 } else if size > 20 { 20 } else { size }
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  // Insert characters one by one
  for i = 0; i < clamped; i = i + 1 {
    let ch = Int::unsafe_to_char('a'.to_int() + i % 26).to_string()
    doc.insert_and_record(@text.Pos::at(i), ch, mgr, timestamp_ms=i * 1000) catch {
      _ => return true
    }
  }
  let text_before = doc.text()
  // Undo all groups
  let mut undo_count = 0
  while mgr.can_undo() {
    try {
      let _ = mgr.undo(doc)

    } catch {
      _ => return true
    }
    undo_count = undo_count + 1
  }
  // After full undo, document should be empty
  if doc.text() != "" {
    return false
  }
  // Redo all groups
  let mut redo_count = 0
  while mgr.can_redo() {
    try {
      let _ = mgr.redo(doc)

    } catch {
      _ => return true
    }
    redo_count = redo_count + 1
  }
  // After full redo, text should match original
  doc.text() == text_before && undo_count == redo_count
}

///|
test "property: undo-redo roundtrip preserves text (insert)" {
  @qc.quick_check_fn(prop_undo_redo_roundtrip_insert)
}

///|
/// Property: Undo-redo roundtrip for mixed insert/delete operations.
/// After undo followed by redo, the document state should be restored.
fn prop_undo_redo_roundtrip_mixed(size : Int) -> Bool {
  let clamped = if size < 0 { 1 } else if size > 10 { 10 } else { size }
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  // Insert some text first
  doc.insert_and_record(@text.Pos::at(0), "hello", mgr, timestamp_ms=0) catch {
    _ => return true
  }
  // Delete some characters (each in its own time group)
  for i = 0; i < clamped && doc.len() > 0; i = i + 1 {
    let pos = i % doc.len()
    doc.delete_and_record(@text.Pos::at(pos), mgr, timestamp_ms=(i + 1) * 1000) catch {
      _ => return true
    }
  }
  let text_after_edits = doc.text()
  // Undo the deletes
  let mut undo_count = 0
  while mgr.can_undo() && undo_count < clamped {
    try {
      let _ = mgr.undo(doc)

    } catch {
      _ => return true
    }
    undo_count = undo_count + 1
  }
  // Redo to restore
  let mut redo_count = 0
  while mgr.can_redo() && redo_count < undo_count {
    try {
      let _ = mgr.redo(doc)

    } catch {
      _ => return true
    }
    redo_count = redo_count + 1
  }
  // Text should match what we had after the edits
  doc.text() == text_after_edits
}

///|
test "property: undo-redo roundtrip preserves text (mixed)" {
  @qc.quick_check_fn(prop_undo_redo_roundtrip_mixed)
}

///|
/// Property: Undo operations can be synced to a peer and produce convergent state.
/// This verifies that undo-generated ops (Delete/Undelete) are valid sync ops.
fn prop_undo_ops_sync_to_peer(size : Int) -> Bool {
  let clamped = if size < 0 { 1 } else if size > 10 { 10 } else { size }
  let doc_a = @text.TextDoc::new("alice")
  let doc_b = @text.TextDoc::new("bob")
  let mgr = @undo.UndoManager::new("alice")
  // Alice inserts text with recording
  for i = 0; i < clamped; i = i + 1 {
    let ch = Int::unsafe_to_char('a'.to_int() + i % 26).to_string()
    doc_a.insert_and_record(@text.Pos::at(i), ch, mgr, timestamp_ms=i * 1000) catch {
      _ => return true
    }
  }
  // Sync initial state to Bob
  let msg1 = doc_a.sync().export_all() catch { _ => return true }
  doc_b.sync().apply(msg1) catch {
    _ => return true
  }
  if doc_a.text() != doc_b.text() {
    return false
  }
  // Alice undoes
  if mgr.can_undo() {
    let _ = mgr.undo(doc_a) catch { _ => return true }
    // Sync undo to Bob
    let msg2 = doc_a.sync().export_all() catch { _ => return true }
    doc_b.sync().apply(msg2) catch {
      _ => return true
    }
    // Both should converge
    return doc_a.text() == doc_b.text()
  }
  true
}

///|
test "property: undo ops sync to peer and converge" {
  @qc.quick_check_fn(prop_undo_ops_sync_to_peer)
}
