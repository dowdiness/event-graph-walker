///|
test "prepared local mutation capability owns its source document" {
  let source = try! Document::new("prepared-owner")
  let unrelated = try! Document::new("prepared-unrelated")
  let capability = try! source.prepare_tree_property_append(root_id, [])

  match (try! capability.begin()) {
    BeginReady(bound) => {
      assert_eq(bound.agent_id, "prepared-owner")
      assert_eq(unrelated.agent_id, "prepared-unrelated")
    }
    BeginStale => fail("fresh capability must not be stale")
    BeginConsumed => fail("fresh capability must begin")
  }
}

///|
test "prepared local mutation capability is consumed across aliases" {
  let source = try! Document::new("prepared-single-use")
  let capability = try! source.prepare_tree_property_append(root_id, [])
  let second_handle = capability

  match (try! capability.begin()) {
    BeginReady(_) => ()
    BeginStale => fail("fresh capability must not be stale")
    BeginConsumed => fail("fresh capability must begin")
  }
  match (try! second_handle.begin()) {
    BeginConsumed => ()
    BeginReady(_) => fail("consumed capability must reject reuse")
    BeginStale => fail("consumed check must precede stale check")
  }
}

///|
test "prepared local mutation rejects an active transaction without mutation" {
  let source = try! Document::new("prepared-active-transaction")
  source.txn_open()
  let before = try! prepared_local_source_snapshot(source)

  match
    (try! source.try_prepare_tree_property_append(root_id, [
      ("body", "rejected"),
    ])) {
    PreparationRejected(SourceNotIdle) => ()
    _ => fail("active transaction must reject preparation")
  }
  assert_true(try! (prepared_local_source_snapshot(source) == before))
  source.txn_close()
}

///|
test "prepared local mutation rejects canonical sync pending state" {
  let sender = try! Document::new("prepared-pending-sender")
  let first = try! sender.create_node(parent=root_id)
  let second = try! sender.create_node_after(parent=root_id, after=first)
  try! sender.move_node_after(target=first, parent=root_id, after=second)
  let full = try! sender.sync().export_all()
  let source = try! Document::new("prepared-sync-pending")
  let early = try! SyncMessage::SyncMessage(
    [full.tree_ops[full.tree_ops.length() - 1]],
    [],
    None,
    1,
  )
  let report = try! source.sync().apply(early)
  assert_eq(report.pending_operations(), 1)
  let before = try! prepared_local_source_snapshot(source)

  match
    (try! source.try_prepare_tree_property_append(root_id, [
      ("body", "rejected"),
    ])) {
    PreparationRejected(SourceHasSyncPending) => ()
    _ => fail("canonical sync pending state must reject preparation")
  }
  assert_true(try! (prepared_local_source_snapshot(source) == before))
}

///|
test "prepared local mutation rejects internal text pending state" {
  let source = try! Document::new("prepared-text-pending")
  let version = @core.RawVersion::new("prepared-text-remote", 0)
  let pending : VersionedBlockTextOp = {
    version,
    parents: [],
    block: { agent: "missing-block", counter: 0 },
    op: Insert({
      id: version,
      content: "x",
      origin_left: None,
      origin_right: None,
      timestamp: 0,
      agent: "prepared-text-remote",
    }),
  }
  assert_true(source.try_apply_versioned_text_op(pending))
  assert_true(source.record_sync_text_op(pending))
  assert_eq(source.pending_text_ops.length(), 1)
  let before = try! prepared_local_source_snapshot(source)

  match
    (try! source.try_prepare_tree_property_append(root_id, [
      ("body", "rejected"),
    ])) {
    PreparationRejected(SourceHasTextPending) => ()
    _ => fail("internal text pending state must reject preparation")
  }
  assert_true(try! (prepared_local_source_snapshot(source) == before))
}

///|
test "prepared local mutation rejects unavailable parents" {
  let source = try! Document::new("prepared-parent-unavailable")
  let parent = try! source.create_node(parent=root_id)
  try! source.delete_node(parent)
  let before = try! prepared_local_source_snapshot(source)

  match
    (try! source.try_prepare_tree_property_append(parent, [("body", "rejected")])) {
    PreparationRejected(ParentUnavailable) => ()
    _ => fail("deleted parent must reject preparation")
  }
  assert_true(try! (prepared_local_source_snapshot(source) == before))
}

///|
test "prepared successor evidence is exact and replayable" {
  let source = try! Document::new("prepared-evidence")
  let properties = [
    ("record_type", "example/record/v1"),
    ("entity_id", "entity-2"),
    ("body", "quoted \\\"value\\\" 😀"),
  ]
  let before = try! prepared_local_source_snapshot(source)
  let capability = try! source.prepare_tree_property_append(root_id, properties)

  let evidence = capability.evidence()
  assert_eq(evidence.delta_operation_count, 4)
  assert_eq(
    evidence.successor_json_bytes,
    @utf8.encode(evidence.successor_json).length(),
  )
  let decoded = try! SyncMessage::from_json_string(evidence.successor_json)
  assert_eq(decoded.op_count(), 4)
  assert_eq(decoded.to_canonical_bytes(), evidence.successor_canonical_bytes)

  let receiver = try! Document::new("prepared-evidence-receiver")
  let report = try! receiver.sync().apply(decoded)
  assert_eq(report.applied_tree_operations(), 4)
  let children = receiver.children(root_id)
  assert_eq(children.length(), 1)
  assert_eq(
    receiver.get_property(children[0], "record_type"),
    Some("example/record/v1"),
  )
  assert_eq(receiver.get_property(children[0], "entity_id"), Some("entity-2"))
  assert_eq(
    receiver.get_property(children[0], "body"),
    Some("quoted \\\"value\\\" 😀"),
  )
  assert_true(try! (prepared_local_source_snapshot(source) == before))
}

///|
test "prepared successor evidence preserves existing mixed tree and text history" {
  let sender = try! Document::new("prepared-mixed-remote")
  let remote_node = try! sender.create_node(parent=root_id)
  try! sender.insert_text(remote_node, 0, "AB")
  let source = try! Document::new("prepared-mixed-local")
  ignore(try! source.sync().apply(try! sender.sync().export_all()))
  let before = try! prepared_local_source_snapshot(source)

  let capability = try! source.prepare_tree_property_append(root_id, [
    ("body", "local"),
  ])
  let evidence = capability.evidence()
  let candidate = try! SyncMessage::from_json_string(evidence.successor_json)
  assert_eq(candidate.op_count(), 5)
  assert_eq(candidate.tree_ops.length(), 3)
  assert_eq(candidate.text_ops.length(), 2)
  let receiver = try! Document::new("prepared-mixed-receiver")
  let candidate_report = try! receiver.sync().apply(candidate)
  assert_eq(candidate_report.applied_tree_operations(), 3)
  assert_eq(candidate_report.applied_text_operations(), 2)
  assert_eq(receiver.get_text(receiver.children(root_id)[0]), "AB")
  assert_true(try! (prepared_local_source_snapshot(source) == before))

  match (try! capability.commit()) {
    CommitAll(2) => ()
    _ => fail("mixed-history preparation must commit exactly")
  }
  let full = try! source.sync().export_all()
  assert_eq(full.to_json_string(), evidence.successor_json)
  assert_eq(full.to_canonical_bytes(), evidence.successor_canonical_bytes)
}

///|
test "prepared tree property append commits exact records once with local history" {
  let source = try! Document::new("prepared-commit")
  let properties = [
    ("record_type", "example/record/v1"),
    ("entity_id", "entity-3"),
    ("body", "committed body"),
  ]
  let before = source.version()
  let capability = try! source.prepare_tree_property_append(root_id, properties)
  let evidence = capability.evidence()

  match (try! capability.commit()) {
    CommitAll(count) => assert_eq(count, 4)
    CommitStale => fail("fresh capability must not be stale")
    CommitConsumed => fail("fresh capability must not be consumed")
    CommitInterruptedBeforeMutation =>
      fail("validated commit must not be interrupted")
    CommitPartial(_) => fail("validated commit must be total")
  }
  let delta = try! source.sync().export_since(before)
  assert_eq(delta.op_count(), evidence.delta_operation_count)
  let full = try! source.sync().export_all()
  assert_eq(
    @utf8.encode(full.to_json_string()).length(),
    evidence.successor_json_bytes,
  )
  assert_eq(full.to_canonical_bytes(), evidence.successor_canonical_bytes)
  let children = source.children(root_id)
  assert_eq(children.length(), 1)
  assert_eq(source.get_property(children[0], "body"), Some("committed body"))
  assert_true(source.can_undo())
  assert_true(try! source.undo())
  assert_true(!source.is_alive(children[0]))
  assert_true(try! source.redo())
  assert_true(source.is_alive(children[0]))
  assert_eq(source.get_property(children[0], "entity_id"), Some("entity-3"))

  let after_first_commit = try! prepared_local_source_snapshot(source)
  match (try! capability.commit()) {
    CommitConsumed => ()
    _ => fail("second commit must reject consumed capability")
  }
  assert_true(
    try! (prepared_local_source_snapshot(source) == after_first_commit),
  )
}

///|
test "prepared local writer continues an existing remote frontier exactly" {
  let sender = try! Document::new("prepared-frontier-remote")
  let remote_node = try! sender.create_node(parent=root_id)
  sender.set_property(remote_node, "remote", "state")
  let source = try! Document::new("prepared-frontier-local")
  ignore(try! source.sync().apply(try! sender.sync().export_all()))
  let before = try! prepared_local_source_snapshot(source)

  let capability = try! source.prepare_tree_property_append(root_id, [
    ("local", "prepared"),
  ])
  assert_eq(capability.records.length(), 2)
  let create = capability.records[0]
  assert_eq(create.lv, 2)
  assert_eq(
    create.sync.version,
    @core.RawVersion::new("prepared-frontier-local", 0),
  )
  assert_eq(create.sync.parents, [
    @core.RawVersion::new("prepared-frontier-remote", 1),
  ])
  match create.sync.op {
    @mt.Move(op) => {
      assert_eq(op.timestamp, 2)
      assert_eq(op.target.counter, 0)
    }
    _ => fail("first prepared record must create the local node")
  }
  assert_true(try! (prepared_local_source_snapshot(source) == before))

  let evidence = capability.evidence()
  match (try! capability.commit()) {
    CommitAll(2) => ()
    _ => fail("remote-frontier preparation must commit exactly")
  }
  let full = try! source.sync().export_all()
  assert_eq(
    @utf8.encode(full.to_json_string()).length(),
    evidence.successor_json_bytes,
  )
  assert_eq(full.to_canonical_bytes(), evidence.successor_canonical_bytes)
}

///|
test "prepared local writer stamps every head of a concurrent frontier" {
  let left = try! Document::new("prepared-frontier-left")
  ignore(try! left.create_node(parent=root_id))
  let right = try! Document::new("prepared-frontier-right")
  ignore(try! right.create_node(parent=root_id))
  let source = try! Document::new("prepared-frontier-join")
  ignore(try! source.sync().apply(try! left.sync().export_all()))
  ignore(try! source.sync().apply(try! right.sync().export_all()))
  let before = try! prepared_local_source_snapshot(source)

  let capability = try! source.prepare_tree_property_append(root_id, [
    ("joined", "frontier"),
  ])
  let create = capability.records[0]
  assert_eq(create.lv, 2)
  assert_eq(
    create.sync.version,
    @core.RawVersion::new("prepared-frontier-join", 0),
  )
  assert_eq(create.sync.parents, [
    @core.RawVersion::new("prepared-frontier-left", 0),
    @core.RawVersion::new("prepared-frontier-right", 0),
  ])
  match create.sync.op {
    @mt.Move(op) => assert_eq(op.timestamp, 1)
    _ => fail("joined frontier must start with the prepared create")
  }
  let property = capability.records[1]
  assert_eq(property.sync.parents, [
    @core.RawVersion::new("prepared-frontier-join", 0),
  ])
  match property.sync.op {
    @mt.SetProperty(op) => assert_eq(op.timestamp, 2)
    _ => fail("joined frontier must chain the prepared property")
  }
  assert_true(try! (prepared_local_source_snapshot(source) == before))

  let evidence = capability.evidence()
  match (try! capability.commit()) {
    CommitAll(2) => ()
    _ => fail("joined frontier must commit the prepared records")
  }
  let full = try! source.sync().export_all()
  assert_eq(full.to_canonical_bytes(), evidence.successor_canonical_bytes)
}

///|
test "prepared tree property append rejects a stale source before mutation" {
  let source = try! Document::new("prepared-stale")
  let capability = try! source.prepare_tree_property_append(root_id, [
    ("body", "prepared"),
  ])
  ignore(try! source.create_node(parent=root_id))
  let before_rejection = try! prepared_local_source_snapshot(source)

  match (try! capability.commit()) {
    CommitStale => ()
    _ => fail("advanced source must reject stale capability")
  }
  assert_true(try! (prepared_local_source_snapshot(source) == before_rejection))
}

///|
test "prepared writer fence detects local history changes without a new version" {
  let source = try! Document::new("prepared-history-fence")
  ignore(try! source.create_node(parent=root_id))
  let capability = try! source.prepare_tree_property_append(root_id, [
    ("body", "prepared"),
  ])
  let prepared_version = source.version()
  source.clear_undo()
  assert_eq(source.version(), prepared_version)
  let before_rejection = try! prepared_local_source_snapshot(source)

  match (try! capability.commit()) {
    CommitStale => ()
    _ => fail("local history change must stale the prepared writer fence")
  }
  assert_true(try! (prepared_local_source_snapshot(source) == before_rejection))
}

///|
test "prepared writer fence detects tracking changes without a new version" {
  let source = try! Document::new("prepared-tracking-fence")
  let capability = try! source.prepare_tree_property_append(root_id, [
    ("body", "prepared"),
  ])
  let prepared_version = source.version()
  source.set_tracking(false)
  assert_eq(source.version(), prepared_version)
  let before_rejection = try! prepared_local_source_snapshot(source)

  match (try! capability.commit()) {
    CommitStale => ()
    _ => fail("tracking change must stale the prepared writer fence")
  }
  assert_true(try! (prepared_local_source_snapshot(source) == before_rejection))
}

///|
test "prepared writer fence detects undo execution mode changes" {
  let source = try! Document::new("prepared-undo-mode-fence")
  let capability = try! source.prepare_tree_property_append(root_id, [
    ("body", "prepared"),
  ])
  let prepared_version = source.version()
  source.undo_execution_mode = true
  assert_eq(source.version(), prepared_version)
  let before_rejection = try! prepared_local_source_snapshot(source)

  match (try! capability.commit()) {
    CommitStale => ()
    _ => fail("undo execution mode must stale the prepared writer fence")
  }
  assert_true(try! (prepared_local_source_snapshot(source) == before_rejection))
  source.undo_execution_mode = false
}

///|
test "prepared failure injection rejects out-of-range boundaries" {
  let source = try! Document::new("prepared-failure-range")
  let capability = try! source.prepare_tree_property_append(root_id, [
    ("body", "prepared"),
  ])
  assert_true(!capability.inject_failure_before(-1))
  assert_true(!capability.inject_failure_before(3))
  match (try! capability.commit()) {
    CommitAll(2) => ()
    _ => fail("invalid injection boundary must not alter commit")
  }
}

///|
test "prepared commit reports every injected operation boundary" {
  for fail_before in 0..<=4 {
    let source = try! Document::new(
      "prepared-failure-" + fail_before.to_string(),
    )
    ignore(try! source.create_node(parent=root_id))
    assert_true(source.can_undo())
    let capability = try! source.prepare_tree_property_append(root_id, [
      ("one", "1"),
      ("two", "2"),
      ("three", "3"),
    ])
    assert_true(capability.inject_failure_before(fail_before))
    let before = try! prepared_local_source_snapshot(source)

    match (try! capability.commit()) {
      CommitInterruptedBeforeMutation => assert_eq(fail_before, 0)
      CommitPartial(committed) => {
        assert_true(fail_before > 0)
        assert_eq(committed, fail_before)
      }
      _ => fail("injected commit must report its exact boundary")
    }

    if fail_before == 0 {
      assert_true(try! (prepared_local_source_snapshot(source) == before))
      assert_true(source.can_undo())
    } else {
      let delta = try! source.sync().export_since(before.version)
      assert_eq(delta.op_count(), fail_before)
      assert_true(!source.can_undo())
      assert_true(!source.can_redo())
      let full = try! source.sync().export_all()
      let receiver = try! Document::new(
        "prepared-failure-receiver-" + fail_before.to_string(),
      )
      let report = try! receiver.sync().apply(full)
      assert_eq(report.applied_tree_operations(), source.graph.op_count())
    }
    match (try! capability.commit()) {
      CommitConsumed => ()
      _ => fail("interrupted capability must remain consumed")
    }
  }
}

///|
test "preparing one create and three properties is detached and exact" {
  let source = try! Document::new("prepared-overlay")
  let expected_properties = [
    ("record_type", "example/record/v1"),
    ("entity_id", "entity-1"),
    ("body", "  鐘😀𠮷  \n"),
  ]
  let properties = expected_properties.copy()
  let before = try! prepared_local_source_snapshot(source)

  let capability = try! source.prepare_tree_property_append(root_id, properties)
  properties[0] = ("mutated", "outside")

  let after = try! prepared_local_source_snapshot(source)
  assert_true(before == after)
  assert_eq(source.children(root_id).length(), 0)
  assert_true(!source.can_undo())
  assert_eq(capability.records.length(), 4)
  for index, record in capability.records {
    assert_eq(record.lv, index)
    assert_eq(
      record.sync.version,
      @core.RawVersion::new("prepared-overlay", index),
    )
    let expected_parents = if index == 0 {
      []
    } else {
      [@core.RawVersion::new("prepared-overlay", index - 1)]
    }
    assert_eq(record.sync.parents, expected_parents)
  }
  match capability.records[0].sync.op {
    @mt.Move(op) => {
      assert_eq(op.timestamp, 0)
      assert_eq(op.target.agent, "prepared-overlay")
      assert_eq(op.target.counter, 0)
      assert_eq(op.new_parent, @mt.root_id)
    }
    @mt.SetProperty(_) => fail("first prepared operation must create the node")
  }
  for index in 1..<4 {
    match capability.records[index].sync.op {
      @mt.SetProperty(op) => {
        assert_eq(op.timestamp, index)
        assert_eq(op.target.agent, "prepared-overlay")
        assert_eq(op.target.counter, 0)
        assert_eq(op.key, expected_properties[index - 1].0)
        assert_eq(op.value, expected_properties[index - 1].1)
      }
      @mt.Move(_) => fail("prepared property operation must remain a property")
    }
  }
}
