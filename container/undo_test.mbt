///| Blackbox tests for Document::transaction/undo/redo and hooked mutations.
///
/// Together with undo_wbtest.mbt these exercise the Phase 3 surface. The focus
/// here is gesture-level guarantees (per-call grouping, explicit composition,
/// redo round-trip, tracking suppression); Phase 4 then exercises convergence
/// with concurrent peers.

// ---------------------------------------------------------------------------
// Task 3.9 — implicit per-call grouping (one gesture → one undo step)
// ---------------------------------------------------------------------------

///|
test "undo: multi-char insert_text undoes as one group" {
  let doc = @container.Document::new("alice")
  let block = doc.create_node(parent=@container.root_id)
  doc.insert_text(block, 0, "abc")
  inspect(doc.get_text(block), content="abc")
  inspect(doc.can_undo(), content="true")
  // After the multi-char insert, one undo removes the whole "abc".
  let undone = doc.undo()
  inspect(undone, content="true")
  inspect(doc.get_text(block), content="")
  inspect(doc.can_redo(), content="true")
}

///|
test "undo: replace_text undoes as one group" {
  let doc = @container.Document::new("alice")
  let block = doc.create_node(parent=@container.root_id)
  doc.insert_text(block, 0, "old text")
  // The block creation + initial insert are separate groups; the replace is
  // the third group and one undo reverts it entirely.
  doc.replace_text(block, "new text")
  inspect(doc.get_text(block), content="new text")
  let undone = doc.undo()
  inspect(undone, content="true")
  inspect(doc.get_text(block), content="old text")
}

///|
test "undo: move_node reverts in one step" {
  let doc = @container.Document::new("alice")
  let a = doc.create_node(parent=@container.root_id)
  let b = doc.create_node(parent=@container.root_id)
  let x = doc.create_node(parent=a)
  inspect(doc.children(a).length(), content="1")
  inspect(doc.children(b).length(), content="0")
  doc.move_node(target=x, new_parent=b)
  inspect(doc.children(a).length(), content="0")
  inspect(doc.children(b).length(), content="1")
  let _ = doc.undo()
  inspect(doc.children(a).length(), content="1")
  inspect(doc.children(b).length(), content="0")
}

///|
test "undo: delete_node restores the node with its text" {
  let doc = @container.Document::new("alice")
  let block = doc.create_node(parent=@container.root_id)
  doc.insert_text(block, 0, "hello")
  doc.delete_node(block)
  inspect(doc.is_alive(block), content="false")
  let _ = doc.undo()
  inspect(doc.is_alive(block), content="true")
  inspect(doc.get_text(block), content="hello")
}

// ---------------------------------------------------------------------------
// Task 3.10 — explicit composition and nested flattening
// ---------------------------------------------------------------------------

///|
test "undo: explicit transaction composes independent ops into one group" {
  let doc = @container.Document::new("alice")
  let block = doc.create_node(parent=@container.root_id)
  let n1 = doc.create_node(parent=block)
  doc.transaction(() => {
    doc.delete_node(n1)
    doc.insert_text(block, 0, "hi")
  })
  inspect(doc.is_alive(n1), content="false")
  inspect(doc.get_text(block), content="hi")
  let _ = doc.undo()
  inspect(doc.is_alive(n1), content="true")
  inspect(doc.get_text(block), content="")
}

///|
test "undo: nested transaction flattens into one group" {
  let doc = @container.Document::new("alice")
  let block = doc.create_node(parent=@container.root_id)
  doc.transaction((
  // insert_text opens its own implicit transaction; depth counter flattens.
  ) => doc.insert_text(block, 0, "a"))
  // One undo should empty the block, proving no double-group was pushed.
  let _ = doc.undo()
  inspect(doc.get_text(block), content="")
  inspect(doc.can_undo(), content="true") // the create_node group
  inspect(doc.can_redo(), content="true")
}

///|
test "undo: empty transaction pushes no group" {
  let doc = @container.Document::new("alice")
  doc.transaction(() => ())
  inspect(doc.can_undo(), content="false")
}

// ---------------------------------------------------------------------------
// Task 3.11 — redo round-trip and redo-cleared-on-new-edit
// ---------------------------------------------------------------------------

///|
test "undo: insert → undo → redo round-trip" {
  let doc = @container.Document::new("alice")
  let block = doc.create_node(parent=@container.root_id)
  doc.insert_text(block, 0, "h")
  inspect(doc.get_text(block), content="h")
  let _ = doc.undo()
  inspect(doc.get_text(block), content="")
  let _ = doc.redo()
  inspect(doc.get_text(block), content="h")
  inspect(doc.can_redo(), content="false")
  inspect(doc.can_undo(), content="true")
}

///|
test "undo: new edit after undo clears redo stack" {
  let doc = @container.Document::new("alice")
  let block = doc.create_node(parent=@container.root_id)
  doc.insert_text(block, 0, "h")
  let _ = doc.undo()
  inspect(doc.can_redo(), content="true")
  doc.insert_text(block, 0, "x")
  inspect(doc.can_redo(), content="false")
  inspect(doc.get_text(block), content="x")
}

// ---------------------------------------------------------------------------
// Task 3.12 — tracking suppression
// ---------------------------------------------------------------------------

///|
test "undo: set_tracking(false) suppresses recording but not sync" {
  let doc = @container.Document::new("alice")
  let block = doc.create_node(parent=@container.root_id)
  inspect(doc.is_tracking(), content="true")
  doc.set_tracking(false)
  doc.insert_text(block, 0, "h")
  // The op still applied...
  inspect(doc.get_text(block), content="h")
  // ...and sync still picked it up (exported text op exists).
  inspect(doc.export_text_ops().length(), content="1")
  // ...but it's not on the undo stack — only the earlier create_node is.
  let _ = doc.undo()
  // Undoing the create leaves the block trashed; text content doesn't round
  // back because the insert itself wasn't recorded.
  inspect(doc.is_alive(block), content="false")
}

///|
test "undo: toggling tracking affects only subsequent mutations" {
  let doc = @container.Document::new("alice")
  let block = doc.create_node(parent=@container.root_id)
  doc.set_tracking(false)
  doc.insert_text(block, 0, "untracked")
  doc.set_tracking(true)
  doc.insert_text(block, doc.text_len(block), "!")
  inspect(doc.get_text(block), content="untracked!")
  // Only the second insert is on the undo stack.
  let _ = doc.undo()
  inspect(doc.get_text(block), content="untracked")
}

///|
test "undo: clear_undo drops history but preserves state" {
  let doc = @container.Document::new("alice")
  let block = doc.create_node(parent=@container.root_id)
  doc.insert_text(block, 0, "hi")
  inspect(doc.can_undo(), content="true")
  doc.clear_undo()
  inspect(doc.can_undo(), content="false")
  inspect(doc.can_redo(), content="false")
  inspect(doc.get_text(block), content="hi")
}

///|
test "undo: undo on empty stack returns false, state unchanged" {
  let doc = @container.Document::new("alice")
  inspect(doc.undo(), content="false")
  inspect(doc.redo(), content="false")
}
