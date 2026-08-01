///|
test "documented text incremental sync sequence compiles" {
  let alice = try! @text.TextState::new("alice-laptop")
  let bob = try! @text.TextState::new("bob-laptop")
  try! alice.insert(@text.Pos::at(0), "Hello")
  let _ = try! bob.sync().apply(try! alice.sync().export_all())
  let bob_version = bob.version()
  try! alice.insert(@text.Pos::at(5), "!")
  let _ = try! bob.sync().apply(try! alice.sync().export_since(bob_version))
  inspect(bob.text(), content="Hello!")
}

///|
test "documented tree sync sequence compiles" {
  let alice = try! @tree.TreeState::new("alice-tree")
  let node = try! alice.create_node(parent=@tree.root_id)
  alice.set_property(node, "name", "project")
  let bob = try! @tree.TreeState::new("bob-tree")
  let _ = try! bob.sync().apply(try! alice.sync().export_all())
  inspect(bob.get_property(node, "name") == Some("project"), content="true")
  assert_eq(bob.properties(node), [("name", "project")])
}

///|
test "documented undo return values compile" {
  let document = try! @text.TextState::new("alice-undo")
  let manager = @undo.UndoManager::new("alice-undo")
  try! document.insert_and_record(
    @text.Pos::at(0),
    "x",
    manager,
    timestamp_ms=0,
  )
  inspect(try! manager.undo(document), content="true")
  let container = try! @container.Document::new("container-undo")
  let node = try! container.create_node(parent=@container.root_id)
  try! container.insert_text(node, 0, "x")
  inspect(try! container.undo(), content="true")
}

///|
test "documented custom limits constructor compiles" {
  let limits = try! @sync.Limits(
    max_encoded_bytes=4 * 1024 * 1024,
    max_decoded_operations=20_000,
    max_pending_operations=2_000,
    max_parents_per_operation=128,
  )
  let document = try! @text.TextState::new_with_sync_limits(
    "limited-replica", limits,
  )
  inspect(document.is_empty(), content="true")
}
