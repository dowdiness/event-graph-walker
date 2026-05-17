///| UndoManager blackbox tests

///|
test "basic undo insert" {
  let doc = @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="H")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
}

///|
test "basic undo delete" {
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  let _ = mgr.undo(doc)
  inspect(mgr.can_redo(), content="true")
  doc.insert_and_record(@text.Pos::at(0), "X", mgr, timestamp_ms=3000)
  inspect(mgr.can_redo(), content="false")
}

///|
test "time grouping within timeout" {
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  inspect(mgr.can_undo(), content="true")
  mgr.clear()
  inspect(mgr.can_undo(), content="false")
  inspect(mgr.can_redo(), content="false")
}

///|
test "multi-char insert undo" {
  let doc = @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "Hello", mgr, timestamp_ms=1000)
  inspect(doc.text(), content="Hello")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
}

///|
test "undo delete then redo delete" {
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
}

///|
test "undo-delete reflects in doc text" {
  let doc = @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  doc.delete_and_record(@text.Pos::at(0), mgr, timestamp_ms=2000)
  inspect(doc.text(), content="")
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="H")
}

///|
test "redo reflects in doc text" {
  let doc = @text.TextState::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  let _ = mgr.undo(doc)
  inspect(doc.text(), content="")
  let _ = mgr.redo(doc)
  inspect(doc.text(), content="H")
}

///|
test "undo syncs to peer via export_all" {
  let doc_a = @text.TextState::new("alice")
  let doc_b = @text.TextState::new("bob")
  let mgr = @undo.UndoManager::new("alice")
  // Alice inserts "H" and records for undo
  doc_a.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  // Sync to Bob
  doc_b.sync().apply(doc_a.sync().export_all())
  inspect(doc_b.text(), content="H")
  // Alice undoes
  let _ = mgr.undo(doc_a)
  inspect(doc_a.text(), content="")
  // Sync undo to Bob (export_all includes the delete op from undo)
  doc_b.sync().apply(doc_a.sync().export_all())
  inspect(doc_b.text(), content="")
}

// =============================================================================
// Gap 1: Concurrent Undo/Redo with Network Sync Tests
// =============================================================================

///|
/// Test: Alice undoes her insert while Bob inserts concurrently
/// Both documents should converge to the same state after full sync
test "concurrent undo while peer inserts" {
  let doc_a = @text.TextState::new("alice")
  let doc_b = @text.TextState::new("bob")
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
  let _ = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="")

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
  // Alice's "A" was undone, only Bob's "B" remains
  inspect(doc_a.text(), content="B")
}

///|
/// Test: Alice undoes delete (Undelete) while Bob has concurrent ops
/// Verifies convergence with concurrent undelete and insert operations
test "concurrent undelete while peer operations (add-wins)" {
  let doc_a = @text.TextState::new("alice")
  let doc_b = @text.TextState::new("bob")
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
  let _ = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="X")

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
  // Alice's undelete should also restore "X" (add-wins)
  inspect(text_a.contains("X"), content="true")
}

///|
/// Test: Three agents each undo their own insert, all converge to empty
test "three-agent concurrent undos converge" {
  let doc_a = @text.TextState::new("alice")
  let doc_b = @text.TextState::new("bob")
  let doc_c = @text.TextState::new("carol")
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
  let _ = mgr_a.undo(doc_a)
  let _ = mgr_b.undo(doc_b)
  let _ = mgr_c.undo(doc_c)

  // Sync all undo ops using export_all (includes the undo delete ops)
  let undo_msg_a = doc_a.sync().export_all()
  let undo_msg_b = doc_b.sync().export_all()
  let undo_msg_c = doc_c.sync().export_all()
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
  let doc_a = @text.TextState::new("alice")
  let doc_b = @text.TextState::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Step 1: Alice inserts "Hello"
  doc_a.insert_and_record(@text.Pos::at(0), "Hello", mgr_a, timestamp_ms=1000)
  inspect(doc_a.text(), content="Hello")

  // Step 2: Sync insert to Bob
  let msg1 = doc_a.sync().export_all()
  doc_b.sync().apply(msg1)
  inspect(doc_b.text(), content="Hello")

  // Step 3: Alice undoes the insert (saves version before undo to export delta)
  let pre_undo_version = doc_a.version()
  let _ = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="")

  // Step 4: Sync undo ops to Bob (export delta since pre-undo state)
  let undo_msg = doc_a.sync().export_since(pre_undo_version)
  doc_b.sync().apply(undo_msg)

  // Step 5: Bob converges to same state
  inspect(doc_b.text(), content="")
}

///|
/// Test: Undo then redo with sync in between preserves state
test "redo after peer sync preserves state" {
  let doc_a = @text.TextState::new("alice")
  let doc_b = @text.TextState::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Alice inserts and syncs
  doc_a.insert_and_record(@text.Pos::at(0), "Test", mgr_a, timestamp_ms=1000)
  let msg1 = doc_a.sync().export_all()
  doc_b.sync().apply(msg1)
  inspect(doc_a.text(), content="Test")
  inspect(doc_b.text(), content="Test")

  // Alice undoes (save version before to export delta)
  let pre_undo_version = doc_a.version()
  let _ = mgr_a.undo(doc_a)
  inspect(doc_a.text(), content="")

  // Sync undo to Bob via delta export
  let undo_msg = doc_a.sync().export_since(pre_undo_version)
  doc_b.sync().apply(undo_msg)
  inspect(doc_b.text(), content="")

  // Alice redoes (save version before to export delta)
  let pre_redo_version = doc_a.version()
  let _ = mgr_a.redo(doc_a)
  inspect(doc_a.text(), content="Test")

  // Sync redo to Bob via delta export
  let redo_msg = doc_a.sync().export_since(pre_redo_version)
  doc_b.sync().apply(redo_msg)

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
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
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
  let doc = @text.TextState::new("alice")
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
/// When a group is popped but every item is stale — peer deleted the
/// inserted LVs concurrently, so `lv_to_position` returns `None` for each
/// inverse — no inverse is actually applied and no redo group is pushed.
/// The Bool return must be `false` in that case, not `true`, so callers
/// using it as "did undo happen?" don't run post-undo machinery (cursor
/// adjust, broadcast, dirty flag) on a no-op. Caught by chatgpt-codex on
/// PR #42.
test "undo returns false when every item in the popped group is stale" {
  let doc_a = @text.TextState::new("alice")
  let doc_b = @text.TextState::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Alice inserts "X" and records it for undo.
  doc_a.insert_and_record(@text.Pos::at(0), "X", mgr_a, timestamp_ms=1000)
  inspect(doc_a.text(), content="X")

  // Sync to Bob, then Bob deletes Alice's "X". Sync back.
  doc_b.sync().apply(doc_a.sync().export_all())
  inspect(doc_b.text(), content="X")
  let _ = doc_b.delete(@text.Pos::at(0))
  doc_a.sync().apply(doc_b.sync().export_all())
  inspect(doc_a.text(), content="")

  // Alice's only undo item is an Insert whose LV is now deleted upstream.
  // Popping the group runs `lv_to_position(...) == None`, skips, and pushes
  // no redo item. Return must be `false`.
  inspect(mgr_a.can_undo(), content="true")
  inspect(mgr_a.undo(doc_a), content="false")
  inspect(doc_a.text(), content="")
  // The popped group is consumed even on no-op (the LVs are stale forever,
  // so retaining the group would be useless), and nothing makes it to redo.
  inspect(mgr_a.can_undo(), content="false")
  inspect(mgr_a.can_redo(), content="false")
}

///|
/// The no-op path must leave `tracking_enabled` in its original state. The
/// real branch toggles tracking off-and-on around the inverse-application
/// loop; if the no-op branch accidentally took the same path it would leave
/// tracking permanently disabled, and the next user edit would be silently
/// untracked.
test "no-op undo preserves tracking state and recordability" {
  let doc = @text.TextState::new("alice")
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
