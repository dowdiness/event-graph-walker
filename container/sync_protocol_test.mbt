///|
test "container v1 message and version round trips preserve results" {
  let alice = try! @container.Document::new("alice")
  let block = try! alice.create_node(parent=@container.root_id)
  alice.set_property(block, "title", "Greeting")
  try! alice.insert_text(block, 0, "hi")
  let message = try! alice.sync().export_all()
  let decoded = try! @container.SyncMessage::from_json_string(
    message.to_json_string(),
  )
  inspect(decoded.op_count(), content="4")
  inspect(
    decoded.to_canonical_bytes() == message.to_canonical_bytes(),
    content="true",
  )
  let bob = try! @container.Document::new("bob")
  let report = try! bob.sync().apply(decoded)
  inspect(report.applied_tree_operations(), content="2")
  inspect(report.applied_text_operations(), content="2")
  inspect(bob.get_property(block, "title") == Some("Greeting"), content="true")
  inspect(bob.get_text(block), content="hi")
  let version = try! @container.Version::from_json_string(
    alice.version().to_json_string(),
  )
  let delta = try! alice.sync().export_since(version)
  inspect(delta.is_empty(), content="true")
}

///|
test "container canonical empty-message golden vector" {
  let document = try! @container.Document::new("golden")
  let message = try! document.sync().export_all()
  @debug.assert_eq(
    message.to_canonical_bytes(),
    b"event-graph-walker:container-sync:v1\x00",
  )
}

///|
test "container strict decoder rejects legacy and unknown fields" {
  try @container.SyncMessage::from_json_string("[]") catch {
    _ => ()
  } noraise {
    _ => fail("legacy array must be rejected")
  }
  try
    @container.SyncMessage::from_json_string(
      "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[],\"extra\":true}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("unknown sync field must be rejected")
  }
  try
    @container.Version::from_json_string(
      "{\"schema\":2,\"format\":\"event-graph-walker/container-version\",\"entries\":[]}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("unknown version schema must be rejected")
  }
}

///|
test "container pending delivery resolves without adding pending to version" {
  let alice = try! @container.Document::new("alice")
  let _ = try! alice.create_node(parent=@container.root_id)
  let after_first = alice.version()
  let _ = try! alice.create_node(parent=@container.root_id)
  let second_only = try! alice.sync().export_since(after_first)
  let bob = try! @container.Document::new("bob")
  let pending_report = try! bob.sync().apply(second_only)
  inspect(pending_report.applied_tree_operations(), content="0")
  inspect(pending_report.pending_operations(), content="1")
  inspect(bob.version() == @container.Version::empty(), content="true")
  let complete = try! bob.sync().apply(try! alice.sync().export_all())
  inspect(complete.applied_tree_operations(), content="2")
  inspect(complete.duplicate_operations(), content="1")
  inspect(complete.pending_operations(), content="0")
  inspect(bob.version() == alice.version(), content="true")
}

///|
test "container conflicting identity is failure atomic" {
  let bob = try! @container.Document::new("bob")
  let first = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}}]}",
  )
  let _ = try! bob.sync().apply(first)
  let before_version = bob.version().to_json_string()
  let before_children = bob.children(@container.root_id)
  let conflict = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"property\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"key\":\"title\",\"value\":\"fork\"}}]}",
  )
  try bob.sync().apply(conflict) catch {
    _ => ()
  } noraise {
    _ => fail("conflicting identity must be rejected")
  }
  inspect(bob.version().to_json_string(), content=before_version)
  inspect(bob.children(@container.root_id) == before_children, content="true")
  let carol = try! @container.Document::new("carol")
  let _ = try! carol.create_node(parent=@container.root_id)
  let valid_report = try! bob.sync().apply(try! carol.sync().export_all())
  inspect(valid_report.applied_tree_operations(), content="1")
}

///|
test "container cyclic message is rejected during pure preparation" {
  try
    @container.SyncMessage::from_json_string(
      "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":1}],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":1,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":1},\"parent\":{\"kind\":\"root\"},\"position\":[49152]}}]}",
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("cyclic message must be rejected")
  }
}
