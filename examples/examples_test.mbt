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
/// Application-owned recipe, not a new storage API in the text package.
fn restore_text_history(
  history_json : String,
  saved_version_json : String,
  fresh_replica_id : String,
) -> @text.TextState raise {
  let restore_limits = @sync.Limits(
    max_encoded_bytes=4 * 1024 * 1024,
    max_decoded_operations=20_000,
    max_pending_operations=0,
  )
  // Bound code units without encoding potentially malformed UTF-16.
  // apply_with_limits enforces the exact UTF-8 byte budget after decoding.
  guard history_json.length() <= restore_limits.max_encoded_bytes() else {
    fail("history exceeds pre-decode code-unit budget")
  }
  let expected = @text.Version::from_json_string(saved_version_json)
  // Normal network admission retains its usual pending budget.
  let candidate = @text.TextState::new(fresh_replica_id)
  let message = candidate.sync().decode_json(history_json)
  let report = candidate.sync().apply_with_limits(message, restore_limits)
  guard report.pending_operations() == 0 && candidate.version() == expected else {
    fail("incomplete or mismatched saved history")
  }
  candidate
}

///|
test "documented accepted-history restore continues editing and delta sync" {
  let original = try! @text.TextState::new("writer-before")
  let peer = try! @text.TextState::new("peer")
  try! original.insert(@text.Pos::at(0), "Hello")
  let _ = try! peer.sync().apply(try! original.sync().export_all())
  try! original.insert(@text.Pos::at(original.len()), " 日本")
  // Capture without interleaving edits. Store these strings together atomically.
  let history_json = try! original.sync().export_all().to_json_string()
  let saved_version_json = try! original.version().to_json_string()
  let restored = try! restore_text_history(
    history_json, saved_version_json, "writer-after",
  )
  assert_eq(restored.text(), "Hello 日本")
  assert_eq(restored.version(), original.version())
  try! restored.insert(@text.Pos::at(restored.len()), "!")
  let delta = try! restored.sync().export_since(peer.version())
  let _ = try! peer.sync().apply(delta)
  assert_eq(peer.text(), "Hello 日本!")
  assert_eq(peer.version(), restored.version())
  assert_eq((try! peer.sync().apply(delta)).applied_operations(), 0)
  // The recipe must not publish a valid prefix paired with a later Version.
  try
    restore_text_history(
      history_json,
      try! restored.version().to_json_string(),
      "failed-candidate",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("mismatched archive must not be published")
  }
}

///|
test "documented restore reports malformed UTF-16 instead of aborting" {
  let source = try! @text.TextState::new("source")
  let history = try! source.sync().export_all().to_json_string()
  let version = try! source.version().to_json_string()
  for bytes in [b"\x00\xD8", b"\x00\xDC"] {
    try
      restore_text_history(
        history + bytes.to_unchecked_string(),
        version,
        "fresh",
      )
    catch {
      @text.TextError::SyncFailed(@sync.Failure::MalformedMessage(detail=_)) =>
        ()
      _ => fail("expected malformed UTF-16 error")
    } noraise {
      _ => fail("unpaired surrogate must not be accepted")
    }
  }
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
