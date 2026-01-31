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
test "undo returns empty ops in phase 1" {
  let doc = @text.TextDoc::new("alice")
  let mgr = @undo.UndoManager::new("alice")
  doc.insert_and_record(@text.Pos::at(0), "H", mgr, timestamp_ms=1000)
  let ops = mgr.undo(doc)
  inspect(ops.length(), content="0")
}
