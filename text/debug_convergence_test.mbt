///| Minimal reproduction of undo+sync convergence bug.
///  Now verified as FIXED by LWW Delete/Undelete conflict resolution.

///|
test "debug: minimal undo+sync divergence (fixed)" {
  let doc0 = @text.TextDoc::new("agent_0")
  let doc1 = @text.TextDoc::new("agent_1")
  let mgr0 = @undo.UndoManager::new("agent_0")
  let mgr1 = @undo.UndoManager::new("agent_1")

  // Agent 1 inserts "f"
  doc1.insert_and_record(@text.Pos::at(0), "f", mgr1, timestamp_ms=0) catch { _ => () }

  // Sync 1->0: both have "f"
  doc0.sync().apply(doc1.sync().export_all() catch { _ => panic() }) catch { _ => () }

  // Agent 0 deletes "f"
  doc0.delete_and_record(@text.Pos::at(0), mgr0, timestamp_ms=0) catch { _ => () }
  inspect(doc0.text(), content="")

  // Agent 1 also deletes "f" (concurrently -- no sync between them)
  doc1.delete_and_record(@text.Pos::at(0), mgr1, timestamp_ms=0) catch { _ => () }
  inspect(doc1.text(), content="")

  // Agent 1 undoes -> undeletes "f"
  if mgr1.can_undo() {
    mgr1.undo(doc1) catch { _ => () }
  }

  // Agent 1 redoes -> deletes "f" again
  if mgr1.can_redo() {
    mgr1.redo(doc1) catch { _ => () }
  }

  // Now full sync
  for round = 0; round < 3; round = round + 1 {
    let m0 = doc0.sync().export_all() catch { _ => panic() }
    let m1 = doc1.sync().export_all() catch { _ => panic() }
    doc0.sync().apply(m1) catch { _ => () }
    doc1.sync().apply(m0) catch { _ => () }
  }
  assert_true!(doc0.text() == doc1.text())
}

///|
test "debug: delete/undelete conflict - simplest case (fixed)" {
  // Both agents share item "x". Both delete it. One undoes (undeletes).
  // After sync, should they agree?
  let doc_a = @text.TextDoc::new("alice")
  let doc_b = @text.TextDoc::new("bob")
  let mgr_a = @undo.UndoManager::new("alice")

  // Alice inserts "x"
  doc_a.insert_and_record(@text.Pos::at(0), "x", mgr_a, timestamp_ms=0) catch { _ => () }

  // Sync to Bob
  doc_b.sync().apply(doc_a.sync().export_all() catch { _ => panic() }) catch { _ => () }
  inspect(doc_a.text(), content="x")
  inspect(doc_b.text(), content="x")

  // Alice deletes "x"
  doc_a.delete_and_record(@text.Pos::at(0), mgr_a, timestamp_ms=1000) catch { _ => () }

  // Bob also deletes "x" (concurrent)
  doc_b.delete(@text.Pos::at(0)) catch { _ => () }

  // Alice undoes her delete -> undeletes "x"
  if mgr_a.can_undo() {
    mgr_a.undo(doc_a) catch { _ => () }
  }

  // Full sync
  for round = 0; round < 3; round = round + 1 {
    let ma = doc_a.sync().export_all() catch { _ => panic() }
    let mb = doc_b.sync().export_all() catch { _ => panic() }
    doc_a.sync().apply(mb) catch { _ => () }
    doc_b.sync().apply(ma) catch { _ => () }
  }
  assert_true!(doc_a.text() == doc_b.text())
}
