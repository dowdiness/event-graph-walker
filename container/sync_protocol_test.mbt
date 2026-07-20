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
test "container sync preserves empty property keys accepted by public API" {
  let source = try! @container.Document::new("source")
  let node = try! source.create_node(parent=@container.root_id)
  source.set_property(node, "", "empty-key")
  let json = (try! source.sync().export_all()).to_json_string()
  let receiver = try! @container.Document::new("receiver")
  let message = try! receiver.sync().decode_json(json)
  let report = try! receiver.sync().apply(message)
  inspect(report.applied_tree_operations(), content="2")
  inspect(receiver.get_property(node, "") == Some("empty-key"), content="true")
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

///|
test "container rejects replica sequence that does not descend from predecessor" {
  let receiver = try! @container.Document::new("receiver")
  let before = receiver.version()
  let message = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}},{\"id\":{\"replica_id\":\"bob\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"bob\",\"target\":{\"kind\":\"node\",\"replica_id\":\"bob\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[49152]}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"bob\",\"sequence\":0}],\"domain\":\"tree\",\"payload\":{\"kind\":\"property\",\"timestamp\":1,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"key\":\"title\",\"value\":\"fork\"}}]}",
  )
  try receiver.sync().apply(message) catch {
    @container.DocumentError::SyncFailed(
      @sync.Failure::MalformedMessage(detail=_)
    ) => ()
    _ => fail("expected causal sequence-descent failure")
  } noraise {
    _ => fail("sequence fork must be rejected")
  }
  inspect(receiver.version() == before, content="true")
  inspect(receiver.children(@container.root_id).is_empty(), content="true")
  inspect(receiver.sync().pending_sync_count(), content="0")
}

///|
test "resent malformed pending sequence is discarded after predecessors arrive" {
  let receiver = try! @container.Document::new("receiver")
  let malformed_future = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":2},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"property\",\"timestamp\":2,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"key\":\"title\",\"value\":\"poison\"}}]}",
  )
  let deferred = try! receiver.sync().apply(malformed_future)
  inspect(deferred.applied_tree_operations(), content="0")
  inspect(receiver.sync().pending_sync_count(), content="1")
  let predecessors_and_resend = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":1,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":1},\"parent\":{\"kind\":\"root\"},\"position\":[49152]}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":2},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"property\",\"timestamp\":2,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"key\":\"title\",\"value\":\"poison\"}}]}",
  )
  let applied = try! receiver.sync().apply(predecessors_and_resend)
  inspect(applied.applied_tree_operations(), content="2")
  inspect(applied.duplicate_operations(), content="1")
  inspect(receiver.children(@container.root_id).length(), content="2")
  inspect(
    receiver.get_property(
      try! @container.TreeNodeId::TreeNodeId("alice", 0),
      "title",
    )
    is None,
    content="true",
  )
  inspect(receiver.sync().pending_sync_count(), content="0")
}

///|
test "container rejects tree operation identity used as text origin" {
  let receiver = try! @container.Document::new("receiver")
  let message = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"domain\":\"text\",\"payload\":{\"kind\":\"insert\",\"timestamp\":1,\"agent\":\"alice\",\"block\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"item\":{\"replica_id\":\"alice\",\"sequence\":1},\"content\":\"A\",\"origin_left\":{\"replica_id\":\"alice\",\"sequence\":0},\"origin_right\":null}}]}",
  )
  try receiver.sync().apply(message) catch {
    @container.DocumentError::SyncFailed(
      @sync.Failure::InvalidContent(detail=_)
    ) => ()
    _ => fail("expected invalid text origin")
  } noraise {
    _ => fail("tree identity must not be accepted as a text origin")
  }
  inspect(receiver.version() == @container.Version::empty(), content="true")
  inspect(receiver.children(@container.root_id).is_empty(), content="true")
}

///|
test "container rejects insert origin from a different block" {
  let receiver = try! @container.Document::new("receiver")
  let message = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"domain\":\"text\",\"payload\":{\"kind\":\"insert\",\"timestamp\":1,\"agent\":\"alice\",\"block\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"item\":{\"replica_id\":\"alice\",\"sequence\":1},\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":2},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":1}],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":2,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":2},\"parent\":{\"kind\":\"root\"},\"position\":[49152]}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":3},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":2}],\"domain\":\"text\",\"payload\":{\"kind\":\"insert\",\"timestamp\":3,\"agent\":\"alice\",\"block\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":2},\"item\":{\"replica_id\":\"alice\",\"sequence\":3},\"content\":\"B\",\"origin_left\":{\"replica_id\":\"alice\",\"sequence\":1},\"origin_right\":null}}]}",
  )
  try receiver.sync().apply(message) catch {
    @container.DocumentError::SyncFailed(
      @sync.Failure::InvalidContent(detail=_)
    ) => ()
    _ => fail("expected cross-block origin failure")
  } noraise {
    _ => fail("insert origin from another block must be rejected")
  }
  inspect(receiver.version() == @container.Version::empty(), content="true")
  inspect(receiver.children(@container.root_id).is_empty(), content="true")
}

///|
test "container rejects delete and undelete targets from a different block" {
  for kind in ["delete", "undelete"] {
    let receiver = try! @container.Document::new("receiver-" + kind)
    let message = try! @container.SyncMessage::from_json_string(
      "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"domain\":\"text\",\"payload\":{\"kind\":\"insert\",\"timestamp\":1,\"agent\":\"alice\",\"block\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"item\":{\"replica_id\":\"alice\",\"sequence\":1},\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":2},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":1}],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":2,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":2},\"parent\":{\"kind\":\"root\"},\"position\":[49152]}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":3},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":2}],\"domain\":\"text\",\"payload\":{\"kind\":\"\{kind}\",\"timestamp\":3,\"agent\":\"alice\",\"block\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":2},\"target\":{\"replica_id\":\"alice\",\"sequence\":1}}}]}",
    )
    try receiver.sync().apply(message) catch {
      @container.DocumentError::SyncFailed(
        @sync.Failure::InvalidContent(detail=_)
      ) => ()
      _ => fail("expected cross-block " + kind + " failure")
    } noraise {
      _ => fail(kind + " target from another block must be rejected")
    }
    inspect(receiver.version() == @container.Version::empty(), content="true")
    inspect(receiver.children(@container.root_id).is_empty(), content="true")
  }
}

///|
test "container rejects text targeting a nonexistent block atomically" {
  let receiver = try! @container.Document::new("receiver")
  let message = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"text\",\"payload\":{\"kind\":\"insert\",\"timestamp\":0,\"agent\":\"alice\",\"block\":{\"kind\":\"node\",\"replica_id\":\"ghost\",\"sequence\":0},\"item\":{\"replica_id\":\"alice\",\"sequence\":0},\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}}]}",
  )
  try receiver.sync().apply(message) catch {
    @container.DocumentError::SyncFailed(
      @sync.Failure::InvalidContent(detail=_)
    ) => ()
    _ => fail("expected nonexistent text block failure")
  } noraise {
    _ => fail("text targeting a nonexistent block must be rejected")
  }
  inspect(receiver.version() == @container.Version::empty(), content="true")
  inspect(receiver.sync().pending_sync_count(), content="0")
  inspect((try! receiver.sync().export_all()).is_empty(), content="true")
}

///|
test "container tree preflight snapshot cannot mutate receiver on text failure" {
  let receiver = try! @container.Document::new("receiver")
  let message = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"domain\":\"text\",\"payload\":{\"kind\":\"insert\",\"timestamp\":1,\"agent\":\"alice\",\"block\":{\"kind\":\"node\",\"replica_id\":\"ghost\",\"sequence\":0},\"item\":{\"replica_id\":\"alice\",\"sequence\":1},\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}}]}",
  )
  try receiver.sync().apply(message) catch {
    @container.DocumentError::SyncFailed(
      @sync.Failure::InvalidContent(detail=_)
    ) => ()
    _ => fail("expected nonexistent text block failure")
  } noraise {
    _ => fail("message with a nonexistent text block must be failure atomic")
  }
  inspect(receiver.version() == @container.Version::empty(), content="true")
  inspect(receiver.children(@container.root_id).is_empty(), content="true")
  inspect(receiver.sync().pending_sync_count(), content="0")
}

///|
test "container receiver limits govern decode and later apply" {
  let source = try! @container.Document::new("source")
  let _ = try! source.create_node(parent=@container.root_id)
  let json = (try! source.sync().export_all()).to_json_string()
  let limits = try! @sync.Limits(max_encoded_bytes=json.length() - 1)
  let receiver = try! @container.Document::new_with_sync_limits(
    "receiver", limits,
  )
  try receiver.sync().decode_json(json) catch {
    @container.DocumentError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=_,
        actual=_
      )
    ) => ()
    _ => fail("expected receiver encoded-byte limit")
  } noraise {
    _ => fail("receiver decoder must reject oversized JSON")
  }
  let decoded = try! @container.SyncMessage::from_json_string(json)
  try receiver.sync().apply(decoded) catch {
    @container.DocumentError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=_,
        actual=_
      )
    ) => ()
    _ => fail("expected encoded-byte limit during apply")
  } noraise {
    _ => fail("apply must preserve receiver encoded-byte enforcement")
  }
  inspect(receiver.version() == @container.Version::empty(), content="true")
}

///|
test "container receiver decoder honors raised parent limit" {
  let parents : Array[String] = []
  for sequence in 0..<257 {
    parents.push("{\"replica_id\":\"parent-\{sequence}\",\"sequence\":0}")
  }
  let json = "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[" +
    parents.join(",") +
    "],\"domain\":\"tree\",\"payload\":{\"kind\":\"property\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"key\":\"title\",\"value\":\"ok\"}}]}"
  try @container.SyncMessage::from_json_string(json) catch {
    @container.DocumentError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::ParentsPerOperation,
        limit=256,
        actual=257
      )
    ) => ()
    _ => fail("expected default parent limit")
  } noraise {
    _ => fail("default decoder must reject 257 parents")
  }
  let limits = try! @sync.Limits(
    max_encoded_bytes=json.length(),
    max_parents_per_operation=257,
  )
  let receiver = try! @container.Document::new_with_sync_limits(
    "receiver", limits,
  )
  let message = try! receiver.sync().decode_json(json)
  inspect(message.op_count(), content="1")
}
