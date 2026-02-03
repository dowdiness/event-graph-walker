///| UndoManager blackbox tests

///|
test "basic undo insert" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="H")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
}

///|
test "basic undo delete" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="H")
  doc.delete_and_record(@text.Pos::at(0), mgr, timestamp_ms=2000)
  inspect(doc.text(), content="")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="H")
}

///|
test "undo-redo roundtrip" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="H")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
  let _ = mgr.redo(doc)
  inspect(doc.text(), content="H")
}

///|
test "redo cleared on new edit" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  let _ = mgr.undo(doc)
  inspect(mgr.can_redo(), content="true")
  doc.insert_and_record(@text.Pos::at(0), "X", mgr, timestamp_ms=3000)
  inspect(mgr.can_redo(), content="false")
}

///|
test "time grouping within timeout" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice", capture_timeout_ms=500)
  doc.insert_and_record(@text.Pos::at(0), "a", mgr, timestamp_ms=100)
  doc.insert_and_record(@text.Pos::at(1), "b", mgr, timestamp_ms=200)
  doc.insert_and_record(@text.Pos::at(2), "c", mgr, timestamp_ms=300)
  inspect(doc.text(), content="abc")
  // All within 500ms of last, should be one group
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
}

///|
test "time grouping continuous typing uses last change" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice", capture_timeout_ms=500)
  doc.insert_and_record(@text.Pos::at(0), "a", mgr, timestamp_ms=0)
  doc.insert_and_record(@text.Pos::at(1), "b", mgr, timestamp_ms=400)
  doc.insert_and_record(@text.Pos::at(2), "c", mgr, timestamp_ms=800)
  doc.insert_and_record(@text.Pos::at(3), "d", mgr, timestamp_ms=1200)
  inspect(doc.text(), content="abcd")
  // Each edit is within 500ms of the previous edit, so one group.
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
}

///|
test "time grouping split across timeout" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice", capture_timeout_ms=500)
  doc.insert_and_record(@text.Pos::at(0), "a", mgr, timestamp_ms=0)
  doc.insert_and_record(@text.Pos::at(1), "b", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="ab")
  // "b" is in separate group (1000 - 0 >= 500)
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="a")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
}

///|
test "per-agent filtering" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "A", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="A")
  // Simulate remote agent insert — record_insert with different agent is ignored
  mgr.record_insert(99, "bob", 2000, content=Some("B"))
  // Only alice's insert should be tracked
  inspect(mgr.can_undo(), content="true")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
  inspect(mgr.can_undo(), content="false")
}

///|
test "suppress tracking" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  mgr.set_tracking(false)
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="H")
  inspect(mgr.can_undo(), content="false")
  mgr.set_tracking(true)
  doc.insert_and_record(@text.Pos::at(1), "i", mgr, timestamp_ms=2000)
  inspect(mgr.can_undo(), content="true")
}

///|
test "double undo-redo" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "a", mgr, timestamp_ms=0)
  doc.insert_and_record(@text.Pos::at(1), "b", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="ab")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="a")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
  let _ = mgr.redo(doc)
  inspect(doc.text(), content="a")
  let _ = mgr.redo(doc)
  inspect(doc.text(), content="ab")
}

///|
test "clear stacks" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(mgr.can_undo(), content="true")
  mgr.clear()
  inspect(mgr.can_undo(), content="false")
  inspect(mgr.can_redo(), content="false")
}

///|
test "multi-char insert undo" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "Hello", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="Hello")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
}

///|
test "undo delete then redo delete" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "ab", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="ab")
  doc.delete_and_record(@text.Pos::at(0), mgr, timestamp_ms=2000)
  inspect(doc.text(), content="b")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="ab")
  let _ = mgr.redo(doc)
  inspect(doc.text(), content="b")
}

///|
test "undo-insert generates Delete op" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  let ops = mgr.undo(doc)
  inspect(ops.length(), content="1")
  inspect(ops[0].is_delete(), content="true")
  inspect(doc.text(), content="")
}

///|
test "undo-delete generates Undelete op" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  doc.delete_and_record(@text.Pos::at(0), mgr, timestamp_ms=2000)
  inspect(doc.text(), content="")
  let ops = mgr.undo(doc)
  inspect(ops.length(), content="1")
  inspect(ops[0].is_undelete(), content="true")
  inspect(doc.text(), content="H")
}

///|
test "redo generates ops" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
  let ops = mgr.redo(doc)
  inspect(ops.length(), content="1")
  inspect(ops[0].is_undelete(), content="true")
  inspect(doc.text(), content="H")
}

///|
test "undo ops can be applied to peer" {
  let doc_a = @text.TextDoc::new("alice")
  let doc_b = @text.TextDoc::new("bob")
  let mgr = @undo.UndoManager::new("alice")
  // Alice inserts "H", sync to Bob
  let insert_change = doc_a.insert(@text.Pos::at(0), "H")
  let insert_msg = @text.SyncMessage::new(
    [insert_change.to_op()],
    doc_a.sync().export_all().get_heads(),
  )
  doc_b.sync().apply(insert_msg)
  inspect(doc_b.text(), content="H")
  // Record the insert for undo tracking
  mgr.record_insert(0, "alice", 1000, content=Some("H"))
  // Alice undoes, gets Delete op
  let undo_ops = mgr.undo(doc_a)
  inspect(doc_a.text(), content="")
  // Send undo ops to Bob via sync
  let undo_msg = @text.SyncMessage::new(
    undo_ops,
    doc_a.sync().export_all().get_heads(),
  )
  doc_b.sync().apply(undo_msg)
  inspect(doc_b.text(), content="")
}

// =============================================================================
// Gap 1: Concurrent Undo/Redo with Network Sync Tests
// =============================================================================

///|
/// Test: Alice undoes her insert while Bob inserts concurrently
/// Both documents should converge to the same state after full sync
test "concurrent undo while peer inserts" {
  let doc_a = @text.TextDoc::new("alice")
  let doc_b = @text.TextDoc::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Alice inserts "A" and syncs to Bob
  doc_a.insert_and_record(@text.Pos::at(0), "A", mgr_a, timestamp_ms=1000)
  inspect(doc_a.text(), content="A")

  // Sync Alice's insert to Bob
  let msg1 = doc_a.sync().export_all()
  doc_b.sync().apply(msg1)
  inspect(doc_b.text(), content="A")

  // Concurrent operations: Alice undoes while Bob inserts "B"
  // Alice's undo (generates Delete op)
  let undo_ops = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="")
  inspect(undo_ops.length() > 0, content="true")

  // Bob inserts "B" after "A" concurrently (doesn't know about undo yet)
  let _ = doc_b.insert(@text.Pos::at(1), "B")
  inspect(doc_b.text(), content="AB")

  // Full bidirectional sync using export_all for complete convergence
  let full_a = doc_a.sync().export_all()
  let full_b = doc_b.sync().export_all()

  doc_a.sync().apply(full_b)
  doc_b.sync().apply(full_a)

  // Both should converge to the same state
  inspect(doc_a.text() == doc_b.text(), content="true")
}

///|
/// Test: Alice undoes delete (Undelete) while Bob has concurrent ops
/// Verifies convergence with concurrent undelete and insert operations
test "concurrent undelete while peer operations (add-wins)" {
  let doc_a = @text.TextDoc::new("alice")
  let doc_b = @text.TextDoc::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Alice inserts "X" and deletes it
  doc_a.insert_and_record(@text.Pos::at(0), "X", mgr_a, timestamp_ms=1000)
  doc_a.delete_and_record(@text.Pos::at(0), mgr_a, timestamp_ms=2000)
  inspect(doc_a.text(), content="")

  // Sync state to Bob
  let msg1 = doc_a.sync().export_all()
  doc_b.sync().apply(msg1)
  inspect(doc_b.text(), content="")

  // Concurrent operations: Alice undoes delete (undelete), Bob inserts "Y"
  let undelete_ops = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="X")
  inspect(undelete_ops.length() > 0, content="true")

  // Bob inserts "Y" concurrently
  let _ = doc_b.insert(@text.Pos::at(0), "Y")
  inspect(doc_b.text(), content="Y")

  // Full bidirectional sync for complete convergence
  let full_a = doc_a.sync().export_all()
  let full_b = doc_b.sync().export_all()

  doc_a.sync().apply(full_b)
  doc_b.sync().apply(full_a)

  // Both should converge to the same state
  let text_a = doc_a.text()
  let text_b = doc_b.text()
  inspect(text_a == text_b, content="true")
  // At minimum, Bob's "Y" should be present since it's a new insert
  inspect(text_a.contains("Y"), content="true")
}

///|
/// Test: Three agents each undo their own insert, all converge to empty
test "three-agent concurrent undos converge" {
  let doc_a = @text.TextDoc::new("alice")
  let doc_b = @text.TextDoc::new("bob")
  let doc_c = @text.TextDoc::new("carol")
  let mgr_a = @undo.UndoManager::new("alice")
  let mgr_b = @undo.UndoManager::new("bob")
  let mgr_c = @undo.UndoManager::new("carol")

  // Each agent inserts a character
  doc_a.insert_and_record(@text.Pos::at(0), "A", mgr_a, timestamp_ms=1000)
  doc_b.insert_and_record(@text.Pos::at(0), "B", mgr_b, timestamp_ms=1000)
  doc_c.insert_and_record(@text.Pos::at(0), "C", mgr_c, timestamp_ms=1000)

  // Sync all to each other
  let msg_a = doc_a.sync().export_all()
  let msg_b = doc_b.sync().export_all()
  let msg_c = doc_c.sync().export_all()

  doc_a.sync().apply(msg_b)
  doc_a.sync().apply(msg_c)
  doc_b.sync().apply(msg_a)
  doc_b.sync().apply(msg_c)
  doc_c.sync().apply(msg_a)
  doc_c.sync().apply(msg_b)

  // Verify all have "ABC" (order depends on agent ordering)
  let initial_len = doc_a.len()
  inspect(initial_len, content="3")
  inspect(doc_a.text() == doc_b.text(), content="true")
  inspect(doc_b.text() == doc_c.text(), content="true")

  // Each agent undoes their own insert concurrently
  let undo_a = mgr_a.undo(doc_a)
  let undo_b = mgr_b.undo(doc_b)
  let undo_c = mgr_c.undo(doc_c)

  // Sync all undo ops
  let undo_msg_a = @text.SyncMessage::new(undo_a, doc_a.sync().export_all().get_heads())
  let undo_msg_b = @text.SyncMessage::new(undo_b, doc_b.sync().export_all().get_heads())
  let undo_msg_c = @text.SyncMessage::new(undo_c, doc_c.sync().export_all().get_heads())

  doc_a.sync().apply(undo_msg_b)
  doc_a.sync().apply(undo_msg_c)
  doc_b.sync().apply(undo_msg_a)
  doc_b.sync().apply(undo_msg_c)
  doc_c.sync().apply(undo_msg_a)
  doc_c.sync().apply(undo_msg_b)

  // All should converge to empty document
  inspect(doc_a.text(), content="")
  inspect(doc_b.text(), content="")
  inspect(doc_c.text(), content="")
}

///|
/// Test: Full round-trip - A inserts, syncs, undoes, syncs undo, B converges
test "undo ops arrive at peer after sync" {
  let doc_a = @text.TextDoc::new("alice")
  let doc_b = @text.TextDoc::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Step 1: Alice inserts "Hello"
  doc_a.insert_and_record(@text.Pos::at(0), "Hello", mgr_a, timestamp_ms=1000)
  inspect(doc_a.text(), content="Hello")

  // Step 2: Sync insert to Bob
  let msg1 = doc_a.sync().export_all()
  doc_b.sync().apply(msg1)
  inspect(doc_b.text(), content="Hello")

  // Step 3: Alice undoes the insert
  let undo_ops = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="")
  inspect(undo_ops.length() > 0, content="true")

  // Step 4: Sync undo ops to Bob
  let undo_msg = @text.SyncMessage::new(undo_ops, doc_a.sync().export_all().get_heads())
  doc_b.sync().apply(undo_msg)

  // Step 5: Bob converges to same state
  inspect(doc_b.text(), content="")
}

///|
/// Test: Undo then redo with sync in between preserves state
test "redo after peer sync preserves state" {
  let doc_a = @text.TextDoc::new("alice")
  let doc_b = @text.TextDoc::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Alice inserts and syncs
  doc_a.insert_and_record(@text.Pos::at(0), "Test", mgr_a, timestamp_ms=1000)
  let msg1 = doc_a.sync().export_all()
  doc_b.sync().apply(msg1)
  inspect(doc_a.text(), content="Test")
  inspect(doc_b.text(), content="Test")

  // Alice undoes
  let undo_ops = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="")

  // Sync undo to Bob
  let undo_msg = @text.SyncMessage::new(undo_ops, doc_a.sync().export_all().get_heads())
  doc_b.sync().apply(undo_msg)
  inspect(doc_b.text(), content="")

  // Alice redoes
  let redo_ops = mgr_a.redo(doc_a)
  inspect(doc_a.text(), content="Test")

  // Sync redo to Bob
  let redo_msg = @text.SyncMessage::new(redo_ops, doc_a.sync().export_all().get_heads())
  doc_b.sync().apply(redo_msg)

  // Both should have "Test" again
  inspect(doc_a.text(), content="Test")
  inspect(doc_b.text(), content="Test")
}
