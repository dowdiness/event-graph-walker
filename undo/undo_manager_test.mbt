///| UndoManager blackbox tests

///|
/// Test document for characterizing unrecoverable internal failures.
struct FailureProbeDoc {
  mut applied : Array[String]
  mut fail_target : Int
  stale_target : Int?
}

///|
pub impl @undo.Undoable for FailureProbeDoc with fn delete_lv(self, lv) -> @undo.CompensatingEditResult raise @undo.UndoError {
  if lv == self.fail_target {
    raise @undo.UndoError::Internal(detail="injected delete failure")
  }
  match self.stale_target {
    Some(target) if target == lv => return @undo.CompensatingEditResult::stale()
    _ => ()
  }
  self.applied.push("delete:" + lv.to_string())
  @undo.CompensatingEditResult::applied()
}

///|
pub impl @undo.Undoable for FailureProbeDoc with fn undelete_lv(self, lv) -> @undo.CompensatingEditResult raise @undo.UndoError {
  if lv == self.fail_target {
    raise @undo.UndoError::Internal(detail="injected undelete failure")
  }
  match self.stale_target {
    Some(target) if target == lv => return @undo.CompensatingEditResult::stale()
    _ => ()
  }
  self.applied.push("undelete:" + lv.to_string())
  @undo.CompensatingEditResult::applied()
}

///|
test "internal undo failure clears history and restores tracking" {
  let manager = @undo.UndoManager::new("alice")
  manager.record_insert(1, "alice", 1000)
  manager.record_insert(2, "alice", 1000)
  let doc : FailureProbeDoc = {
    applied: [],
    fail_target: 1,
    stale_target: None,
  }
  let result : Result[Bool, @undo.UndoError] = Ok(manager.undo(doc)) catch {
    error => Err(error)
  }
  match result {
    Err(@undo.UndoError::Internal(detail~)) =>
      inspect(detail, content="injected delete failure")
    _ => fail("Expected internal undo error")
  }
  inspect(doc.applied.join(","), content="delete:2")
  inspect(manager.can_undo(), content="false")
  inspect(manager.can_redo(), content="false")
  inspect(manager.is_tracking(), content="true")
  manager.record_insert(3, "alice", 2000)
  inspect(manager.can_undo(), content="true")
}

///|
test "internal redo failure clears history and restores tracking" {
  let manager = @undo.UndoManager::new("alice")
  manager.record_insert(1, "alice", 1000)
  manager.record_insert(2, "alice", 1000)
  let doc : FailureProbeDoc = {
    applied: [],
    fail_target: 99,
    stale_target: None,
  }
  inspect(manager.undo(doc), content="true")
  doc.applied = []
  doc.fail_target = 1
  let result : Result[Bool, @undo.UndoError] = Ok(manager.redo(doc)) catch {
    error => Err(error)
  }
  match result {
    Err(@undo.UndoError::Internal(detail~)) =>
      inspect(detail, content="injected undelete failure")
    _ => fail("Expected internal redo error")
  }
  inspect(doc.applied.join(","), content="undelete:2")
  inspect(manager.can_undo(), content="false")
  inspect(manager.can_redo(), content="false")
  inspect(manager.is_tracking(), content="true")
}

///|
test "stale result consumes group without opposite history" {
  let manager = @undo.UndoManager::new("alice")
  manager.record_insert(1, "alice", 1000)
  let doc : FailureProbeDoc = {
    applied: [],
    fail_target: 99,
    stale_target: Some(1),
  }
  inspect(manager.undo(doc), content="false")
  inspect(doc.applied.join(","), content="")
  inspect(manager.can_undo(), content="false")
  inspect(manager.can_redo(), content="false")
}

///|
test "basic undo insert" {
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="H")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
}

///|
test "basic undo delete" {
  let doc = try! @text.TextState::new("alice")
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
  let doc = try! @text.TextState::new("alice")
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
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  let _ = mgr.undo(doc)
  inspect(mgr.can_redo(), content="true")
  doc.insert_and_record(@text.Pos::at(0), "X", mgr, timestamp_ms=3000)
  inspect(mgr.can_redo(), content="false")
}

///|
test "time grouping within timeout" {
  let doc = try! @text.TextState::new("alice")
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
  let doc = try! @text.TextState::new("alice")
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
  let doc = try! @text.TextState::new("alice")
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
  let doc = try! @text.TextState::new("alice")
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
  let doc = try! @text.TextState::new("alice")
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
  let doc = try! @text.TextState::new("alice")
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
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(mgr.can_undo(), content="true")
  mgr.clear()
  inspect(mgr.can_undo(), content="false")
  inspect(mgr.can_redo(), content="false")
}

///|
test "multi-char insert undo" {
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "Hello", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="Hello")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
}

///|
test "undo delete then redo delete" {
  let doc = try! @text.TextState::new("alice")
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
test "undo-insert reflects in doc text" {
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
}

///|
test "undo-delete reflects in doc text" {
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  doc.delete_and_record(@text.Pos::at(0), mgr, timestamp_ms=2000)
  inspect(doc.text(), content="")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="H")
}

///|
test "redo reflects in doc text" {
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
  let _ = mgr.redo(doc)
  inspect(doc.text(), content="H")
}

///|
test "undo syncs to peer via export_all" {
  let doc_a = try! @text.TextState::new("alice")
  let doc_b = try! @text.TextState::new("bob")
  let mgr = @undo.UndoManager::new("alice")
  // Alice inserts "H" and records for undo
  doc_a.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  // Sync to Bob
  let _ = doc_b.sync().apply(doc_a.sync().export_all())
  inspect(doc_b.text(), content="H")
  // Alice undoes
  let _ = mgr.undo(doc_a)
  inspect(doc_a.text(), content="")
  // Sync undo to Bob (export_all includes the delete op from undo)
  let _ = doc_b.sync().apply(doc_a.sync().export_all())
  inspect(doc_b.text(), content="")
}

// =============================================================================
// Gap 1: Concurrent Undo/Redo with Network Sync Tests
// =============================================================================

///|
/// Test: Alice undoes her insert while Bob inserts concurrently
/// Both documents should converge to the same state after full sync
test "concurrent undo while peer inserts" {
  let doc_a = try! @text.TextState::new("alice")
  let doc_b = try! @text.TextState::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Alice inserts "A" and syncs to Bob
  doc_a.insert_and_record(@text.Pos::at(0), "A", mgr_a, timestamp_ms=1000)
  inspect(doc_a.text(), content="A")

  // Sync Alice's insert to Bob
  let msg1 = doc_a.sync().export_all()
  let _ = doc_b.sync().apply(msg1)
  inspect(doc_b.text(), content="A")

  // Concurrent operations: Alice undoes while Bob inserts "B"
  // Alice's undo (generates Delete op)
  let _ = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="")

  // Bob inserts "B" after "A" concurrently (doesn't know about undo yet)
  let _ = doc_b.insert(@text.Pos::at(1), "B")
  inspect(doc_b.text(), content="AB")

  // Full bidirectional sync using export_all for complete convergence
  let full_a = doc_a.sync().export_all()
  let full_b = doc_b.sync().export_all()
  let _ = doc_a.sync().apply(full_b)
  let _ = doc_b.sync().apply(full_a)

  // Both should converge to the same state
  inspect(doc_a.text() == doc_b.text(), content="true")
  // Alice's "A" was undone, only Bob's "B" remains
  inspect(doc_a.text(), content="B")
}

///|
/// Test: Alice undoes delete (Undelete) while Bob has concurrent ops
/// Verifies convergence with concurrent undelete and insert operations
test "concurrent undelete while peer operations (add-wins)" {
  let doc_a = try! @text.TextState::new("alice")
  let doc_b = try! @text.TextState::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Alice inserts "X" and deletes it
  doc_a.insert_and_record(@text.Pos::at(0), "X", mgr_a, timestamp_ms=1000)
  doc_a.delete_and_record(@text.Pos::at(0), mgr_a, timestamp_ms=2000)
  inspect(doc_a.text(), content="")

  // Sync state to Bob
  let msg1 = doc_a.sync().export_all()
  let _ = doc_b.sync().apply(msg1)
  inspect(doc_b.text(), content="")

  // Concurrent operations: Alice undoes delete (undelete), Bob inserts "Y"
  let _ = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="X")

  // Bob inserts "Y" concurrently
  let _ = doc_b.insert(@text.Pos::at(0), "Y")
  inspect(doc_b.text(), content="Y")

  // Full bidirectional sync for complete convergence
  let full_a = doc_a.sync().export_all()
  let full_b = doc_b.sync().export_all()
  let _ = doc_a.sync().apply(full_b)
  let _ = doc_b.sync().apply(full_a)

  // Both should converge to the same state
  let text_a = doc_a.text()
  let text_b = doc_b.text()
  inspect(text_a == text_b, content="true")
  // At minimum, Bob's "Y" should be present since it's a new insert
  inspect(text_a.contains("Y"), content="true")
  // Alice's undelete should also restore "X" (add-wins)
  inspect(text_a.contains("X"), content="true")
}

///|
/// Test: Three agents each undo their own insert, all converge to empty
test "three-agent concurrent undos converge" {
  let doc_a = try! @text.TextState::new("alice")
  let doc_b = try! @text.TextState::new("bob")
  let doc_c = try! @text.TextState::new("carol")
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
  let _ = doc_a.sync().apply(msg_b)
  let _ = doc_a.sync().apply(msg_c)
  let _ = doc_b.sync().apply(msg_a)
  let _ = doc_b.sync().apply(msg_c)
  let _ = doc_c.sync().apply(msg_a)
  let _ = doc_c.sync().apply(msg_b)

  // Verify all have "ABC" (order depends on agent ordering)
  let initial_len = doc_a.len()
  inspect(initial_len, content="3")
  inspect(doc_a.text() == doc_b.text(), content="true")
  inspect(doc_b.text() == doc_c.text(), content="true")

  // Each agent undoes their own insert concurrently
  let _ = mgr_a.undo(doc_a)
  let _ = mgr_b.undo(doc_b)
  let _ = mgr_c.undo(doc_c)

  // Sync all undo ops using export_all (includes the undo delete ops)
  let undo_msg_a = doc_a.sync().export_all()
  let undo_msg_b = doc_b.sync().export_all()
  let undo_msg_c = doc_c.sync().export_all()
  let _ = doc_a.sync().apply(undo_msg_b)
  let _ = doc_a.sync().apply(undo_msg_c)
  let _ = doc_b.sync().apply(undo_msg_a)
  let _ = doc_b.sync().apply(undo_msg_c)
  let _ = doc_c.sync().apply(undo_msg_a)
  let _ = doc_c.sync().apply(undo_msg_b)

  // All should converge to empty document
  inspect(doc_a.text(), content="")
  inspect(doc_b.text(), content="")
  inspect(doc_c.text(), content="")
}

///|
/// Test: Full round-trip - A inserts, syncs, undoes, syncs undo, B converges
test "undo ops arrive at peer after sync" {
  let doc_a = try! @text.TextState::new("alice")
  let doc_b = try! @text.TextState::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Step 1: Alice inserts "Hello"
  doc_a.insert_and_record(@text.Pos::at(0), "Hello", mgr_a, timestamp_ms=1000)
  inspect(doc_a.text(), content="Hello")

  // Step 2: Sync insert to Bob
  let msg1 = doc_a.sync().export_all()
  let _ = doc_b.sync().apply(msg1)
  inspect(doc_b.text(), content="Hello")

  // Step 3: Alice undoes the insert (saves version before undo to export delta)
  let pre_undo_version = doc_a.version()
  let _ = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="")

  // Step 4: Sync undo ops to Bob (export delta since pre-undo state)
  let undo_msg = doc_a.sync().export_since(pre_undo_version)
  let _ = doc_b.sync().apply(undo_msg)

  // Step 5: Bob converges to same state
  inspect(doc_b.text(), content="")
}

///|
/// Test: Undo then redo with sync in between preserves state
test "redo after peer sync preserves state" {
  let doc_a = try! @text.TextState::new("alice")
  let doc_b = try! @text.TextState::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Alice inserts and syncs
  doc_a.insert_and_record(@text.Pos::at(0), "Test", mgr_a, timestamp_ms=1000)
  let msg1 = doc_a.sync().export_all()
  let _ = doc_b.sync().apply(msg1)
  inspect(doc_a.text(), content="Test")
  inspect(doc_b.text(), content="Test")

  // Alice undoes (save version before to export delta)
  let pre_undo_version = doc_a.version()
  let _ = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="")

  // Sync undo to Bob via delta export
  let undo_msg = doc_a.sync().export_since(pre_undo_version)
  let _ = doc_b.sync().apply(undo_msg)
  inspect(doc_b.text(), content="")

  // Alice redoes (save version before to export delta)
  let pre_redo_version = doc_a.version()
  let _ = mgr_a.redo(doc_a)
  inspect(doc_a.text(), content="Test")

  // Sync redo to Bob via delta export
  let redo_msg = doc_a.sync().export_since(pre_redo_version)
  let _ = doc_b.sync().apply(redo_msg)

  // Both should have "Test" again
  inspect(doc_a.text(), content="Test")
  inspect(doc_b.text(), content="Test")
}

///|
/// Calling `undo` on an empty stack must return `false` (not panic). Without
/// this contract, a toolbar Undo button pressed at session start aborts the
/// host — `try { mgr.undo(doc) } catch { _ => false }` cannot recover from a
/// bare `guard` panic.
test "undo on empty stack returns false" {
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  inspect(mgr.can_undo(), content="false")
  inspect(mgr.undo(doc), content="false")
  inspect(doc.text(), content="")
  inspect(mgr.can_undo(), content="false")
  inspect(mgr.can_redo(), content="false")
}

///|
/// Symmetric: empty redo stack returns `false`.
test "redo on empty stack returns false" {
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  inspect(mgr.can_redo(), content="false")
  inspect(mgr.redo(doc), content="false")
  inspect(doc.text(), content="")
  inspect(mgr.can_redo(), content="false")
}

///|
/// `undo` returns `true` when it actually pops a group, `false` once the
/// stack is drained. Mirrors the toolbar use-case where a user hammers
/// Undo past the first recorded edit — the second call must not panic.
test "undo past start drains and signals via return" {
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(mgr.undo(doc), content="true")
  inspect(doc.text(), content="")
  // One more undo with nothing left — must return false, not panic.
  inspect(mgr.undo(doc), content="false")
  inspect(doc.text(), content="")
  inspect(mgr.can_undo(), content="false")
}

///|
/// `redo` past the most-recent redo group must also drain to `false`, not
/// abort. Covers the realistic "undid once, redid once, hit Redo again" flow
/// that the symmetric no-op-on-fresh-manager test doesn't exercise.
test "redo past last drains and signals via return" {
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(mgr.undo(doc), content="true")
  inspect(mgr.redo(doc), content="true")
  inspect(doc.text(), content="H")
  // Redo stack is now empty.
  inspect(mgr.can_redo(), content="false")
  inspect(mgr.redo(doc), content="false")
  inspect(doc.text(), content="H")
}

///|
/// Oscillating undo↔redo across the start boundary — the canonical "mash both
/// buttons" stress shape — must not panic and must converge in both
/// directions. Catches any subtle state corruption introduced by the no-op
/// branch (e.g. leaving `tracking_enabled` flipped, or pushing a phantom
/// empty group onto the opposite stack).
test "oscillating undo/redo across boundary stays consistent" {
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(mgr.undo(doc), content="true")
  inspect(mgr.redo(doc), content="true")
  inspect(mgr.undo(doc), content="true")
  inspect(mgr.redo(doc), content="true")
  inspect(mgr.undo(doc), content="true")
  inspect(doc.text(), content="")
  // Past the boundary on both sides.
  inspect(mgr.undo(doc), content="false")
  inspect(mgr.redo(doc), content="true")
  inspect(doc.text(), content="H")
  inspect(mgr.redo(doc), content="false")
  inspect(doc.text(), content="H")
}

///|
/// The no-op path must leave `tracking_enabled` in its original state. The
/// real branch toggles tracking off-and-on around the inverse-application
/// loop; if the no-op branch accidentally took the same path it would leave
/// tracking permanently disabled, and the next user edit would be silently
/// untracked.
test "no-op undo preserves tracking state and recordability" {
  let doc = try! @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  inspect(mgr.is_tracking(), content="true")
  // Empty-stack call — exercises the early-return branch.
  inspect(mgr.undo(doc), content="false")
  inspect(mgr.is_tracking(), content="true")
  // A subsequent real edit must still be recorded.
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(mgr.can_undo(), content="true")
  inspect(mgr.undo(doc), content="true")
  inspect(doc.text(), content="")
}
