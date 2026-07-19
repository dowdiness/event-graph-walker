///|
test "tree v1 codecs are façade-specific and deterministic" {
  let alice = try! @tree.TreeState::new("alice")
  let node = try! alice.create_node(parent=@tree.root_id)
  alice.set_property(node, "title", "hello")
  let message = try! alice.sync().export_all()
  let json = message.to_json_string()
  inspect(json.contains("event-graph-walker/tree-sync"), content="true")
  let decoded = try! @tree.SyncMessage::from_json_string(json)
  inspect(decoded.op_count(), content="2")
  inspect(
    decoded.to_canonical_bytes() == message.to_canonical_bytes(),
    content="true",
  )
  let bob = try! @tree.TreeState::new("bob")
  let report = try! bob.sync().apply(decoded)
  inspect(report.applied_operations(), content="2")
  inspect(bob.get_property(node, "title") == Some("hello"), content="true")
  let version = try! @tree.Version::from_json_string(
    alice.version().to_json_string(),
  )
  inspect((try! alice.sync().export_since(version)).is_empty(), content="true")
}

///|
test "tree decoder rejects container and legacy envelopes" {
  let container = try! @container.Document::new("container")
  let _ = try! container.create_node(parent=@container.root_id)
  let container_json = (try! container.sync().export_all()).to_json_string()
  try @tree.SyncMessage::from_json_string(container_json) catch {
    _ => ()
  } noraise {
    _ => fail("container envelope must be rejected")
  }
  try @tree.SyncMessage::from_json_string("[]") catch {
    _ => ()
  } noraise {
    _ => fail("legacy array must be rejected")
  }
}

///|
test "tree canonical empty-message golden vector" {
  let tree = try! @tree.TreeState::new("golden")
  let message = try! tree.sync().export_all()
  @debug.assert_eq(
    message.to_canonical_bytes(),
    b"event-graph-walker:tree-sync:v1\x25event-graph-walker:container-sync:v1\x00",
  )
}
