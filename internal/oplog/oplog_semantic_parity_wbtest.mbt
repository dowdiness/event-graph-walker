///| Gate P0 semantic parity tests for core-owned legacy admission.

///|
fn p0_raw(agent : String, seq : Int) -> @core.RawVersion {
  @core.RawVersion::new(agent, seq)
}

///|
fn p0_insert(
  agent : String,
  seq : Int,
  parents : Array[@core.RawVersion],
  text : String,
  origin_left : @core.RawVersion?,
) -> @core.Op {
  @core.Op::new_insert(-1, parents, agent, seq, text, origin_left, None)
}

///|
fn p0_delete(
  agent : String,
  seq : Int,
  parents : Array[@core.RawVersion],
  target : @core.RawVersion,
) -> @core.Op {
  @core.Op::new_delete(-1, parents, agent, seq, Some(target))
}

///|
test "P0 core rejects sequence fork before mutation" {
  let receiver = OpLog::new("receiver")
  let root = p0_insert("alice", 0, [], "A", None)
  let fork = p0_insert("alice", 1, [], "B", Some(p0_raw("alice", 0)))
  let result : Result[RemoteAdmissionPlan, OpLogError] = Ok(
    receiver.prepare_remote([root, fork]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(SequenceAncestryViolation(raw~)) => {
      inspect(raw.agent, content="alice")
      inspect(raw.seq, content="1")
    }
    _ => fail("expected core sequence ancestry validation")
  }
  inspect(receiver.op_count(), content="0")
  inspect(receiver.has_pending(), content="false")
}

///|
test "P0 core accepts indirect predecessor ancestry" {
  let receiver = OpLog::new("receiver")
  let root = p0_insert("alice", 0, [], "A", None)
  let middle = p0_insert(
    "bob",
    0,
    [p0_raw("alice", 0)],
    "B",
    Some(p0_raw("alice", 0)),
  )
  let descendant = p0_insert(
    "alice",
    1,
    [p0_raw("bob", 0)],
    "C",
    Some(p0_raw("bob", 0)),
  )
  let plan = try! receiver.prepare_remote([descendant, middle, root])
  let committed = try! receiver.commit_remote(plan)
  inspect(committed.length(), content="3")
  inspect(receiver.op_count(), content="3")
  inspect(receiver.has_pending(), content="false")
}

///|
test "P0 core rejects non-insert origin before mutation" {
  let receiver = OpLog::new("receiver")
  let root = p0_insert("alice", 0, [], "A", None)
  let delete = p0_delete("alice", 1, [p0_raw("alice", 0)], p0_raw("alice", 0))
  let malformed = p0_insert(
    "bob",
    0,
    [p0_raw("alice", 1)],
    "B",
    Some(p0_raw("alice", 1)),
  )
  let result : Result[RemoteAdmissionPlan, OpLogError] = Ok(
    receiver.prepare_remote([root, delete, malformed]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OriginTargetNotInsert(operation~, target~)) => {
      inspect(operation.agent, content="bob")
      inspect(operation.seq, content="0")
      inspect(target.agent, content="alice")
      inspect(target.seq, content="1")
    }
    _ => fail("expected core origin target validation")
  }
  inspect(receiver.op_count(), content="0")
  inspect(receiver.has_pending(), content="false")
}

///|
test "P0 rejects delete right-origin shape before mutation" {
  let receiver = OpLog::new("receiver")
  let raw = p0_raw("target", 0)
  let normal_delete = @core.Op::new_delete(
    -1,
    [],
    "normal-delete",
    0,
    Some(raw),
  )
  let malformed = @core.Op::new_from_parts(
    lv=-1,
    parents=[],
    agent="remote",
    seq=0,
    content=normal_delete.content(),
    origin_left=Some(raw),
    origin_right=Some(raw),
  )
  let result : Result[RemoteAdmissionPlan, OpLogError] = Ok(
    receiver.prepare_remote([malformed]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(InvalidOriginShape(raw~)) => {
      inspect(raw.agent, content="remote")
      inspect(raw.seq, content="0")
    }
    _ => fail("expected invalid delete origin shape")
  }
  inspect(receiver.op_count(), content="0")
  inspect(receiver.has_pending(), content="false")
}

///|
test "P0 known invalid origin rejects despite unrelated missing parent" {
  let receiver = OpLog::new("receiver")
  let root = p0_insert("alice", 0, [], "A", None)
  let target = p0_delete("alice", 1, [p0_raw("alice", 0)], p0_raw("alice", 0))
  ignore(
    try! receiver.commit_remote(try! receiver.prepare_remote([root, target])),
  )
  let malformed = p0_insert(
    "bob",
    0,
    [p0_raw("missing", 0)],
    "B",
    Some(p0_raw("alice", 1)),
  )
  let result : Result[RemoteAdmissionPlan, OpLogError] = Ok(
    receiver.prepare_remote([malformed]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OriginTargetNotInsert(operation~, target~)) => {
      inspect(operation.agent, content="bob")
      inspect(target.agent, content="alice")
      inspect(target.seq, content="1")
    }
    _ => fail("known invalid origin must reject before pending")
  }
  inspect(receiver.op_count(), content="2")
  inspect(receiver.has_pending(), content="false")
}

///|
test "P0 retained invalid pending root and dependents are discarded" {
  let receiver = OpLog::new("receiver")
  let root = p0_insert("alice", 0, [], "A", None)
  let target = p0_delete("alice", 1, [p0_raw("alice", 0)], p0_raw("alice", 0))
  let invalid_root = p0_insert(
    "bob",
    0,
    [p0_raw("alice", 1)],
    "B",
    Some(p0_raw("alice", 1)),
  )
  let dependent = p0_insert(
    "carol",
    0,
    [p0_raw("bob", 0)],
    "C",
    Some(p0_raw("bob", 0)),
  )
  let staged = try! receiver.prepare_remote([invalid_root])
  let initially_committed = try! receiver.commit_remote(staged)
  inspect(initially_committed.length(), content="0")
  let dependent_plan = try! receiver.prepare_remote([dependent])
  ignore(try! receiver.commit_remote(dependent_plan))
  inspect(receiver.has_pending(), content="true")

  let recovery = try! receiver.prepare_remote([root, target, invalid_root])
  let committed = try! receiver.commit_remote(recovery)
  inspect(committed.length(), content="2")
  inspect(receiver.op_count(), content="2")
  inspect(receiver.has_pending(), content="false")
}

///|
test "P0 semantic prepare is fully nonmutating and repeatable" {
  let receiver = OpLog::new("receiver")
  let invalid_root = p0_insert(
    "bob",
    0,
    [p0_raw("alice", 1)],
    "B",
    Some(p0_raw("alice", 1)),
  )
  ignore(
    try! receiver.commit_remote(try! receiver.prepare_remote([invalid_root])),
  )
  let root = p0_insert("alice", 0, [], "A", None)
  let target = p0_delete("alice", 1, [p0_raw("alice", 0)], p0_raw("alice", 0))
  let before = planner_lifecycle_snapshot(receiver.planner, false)
  let before_count = receiver.op_count()
  let before_frontier = try! receiver.get_frontier_raw()
  let first = try! receiver.prepare_remote([root, target])
  let after_first = planner_lifecycle_snapshot(receiver.planner, false)
  inspect(planner_lifecycle_same_snapshot(before, after_first), content="true")
  inspect(receiver.op_count(), content="0")
  assert_eq(receiver.op_count(), before_count)
  assert_eq(try! receiver.get_frontier_raw(), before_frontier)

  let second = try! receiver.prepare_remote([root, target])
  let after_second = planner_lifecycle_snapshot(receiver.planner, false)
  inspect(planner_lifecycle_same_snapshot(before, after_second), content="true")
  inspect(
    planner_lifecycle_same_ops(first.operations(), second.operations()),
    content="true",
  )
  inspect(
    planner_lifecycle_same_raws(
      first.remaining_raws(receiver.planner),
      second.remaining_raws(receiver.planner),
    ),
    content="true",
  )
  assert_eq(first.discard_roots, second.discard_roots)
  let first_discarded = @hashset.HashSet(first.discarded_staged)
  let second_discarded = @hashset.HashSet(second.discarded_staged)
  assert_eq(first_discarded.length(), second_discarded.length())
  for raw in first_discarded {
    inspect(second_discarded.contains(raw), content="true")
  }
  assert_eq(first.next_arrival, second.next_arrival)
  assert_eq(first.generation, second.generation)
}

///|
test "P0 core pending limit rejects without state mutation" {
  let receiver = OpLog::new("receiver")
  let future = p0_insert(
    "alice",
    1,
    [p0_raw("alice", 0)],
    "B",
    Some(p0_raw("alice", 0)),
  )
  let result : Result[RemoteAdmissionPlan, OpLogError] = Ok(
    receiver.prepare_remote_with_limit([future], 0),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(PendingLimitExceeded(limit~, actual~)) => {
      inspect(limit, content="0")
      inspect(actual, content="1")
    }
    _ => fail("expected core pending budget rejection")
  }
  inspect(receiver.op_count(), content="0")
  inspect(receiver.has_pending(), content="false")

  let allowed = try! receiver.prepare_remote_with_limit([future], 1)
  inspect(allowed.operations().length(), content="0")
  ignore(try! receiver.commit_remote(allowed))
  inspect(receiver.op_count(), content="0")
  inspect(receiver.has_pending(), content="true")

  let duplicate = try! receiver.prepare_remote_with_limit([future], 1)
  inspect(duplicate.operations().length(), content="0")
  ignore(try! receiver.commit_remote(duplicate))
  inspect(receiver.has_pending(), content="true")

  let negative : Result[RemoteAdmissionPlan, OpLogError] = Ok(
    receiver.prepare_remote_with_limit([], -1),
  ) catch {
    error => Err(error)
  }
  match negative {
    Err(PendingLimitExceeded(limit~, actual~)) => {
      inspect(limit, content="-1")
      inspect(actual, content="1")
    }
    _ => fail("negative pending limit must reject")
  }
  inspect(receiver.has_pending(), content="true")

  let ready_receiver = OpLog::new("ready-receiver")
  let ready = p0_insert("ready", 0, [], "R", None)
  let ready_plan = try! ready_receiver.prepare_remote_with_limit([ready], 0)
  inspect(ready_plan.operations().length(), content="1")
  ignore(try! ready_receiver.commit_remote(ready_plan))
  inspect(ready_receiver.op_count(), content="1")
  inspect(ready_receiver.has_pending(), content="false")

  let discard_receiver = OpLog::new("discard-receiver")
  let invalid_root = p0_insert(
    "bob",
    0,
    [p0_raw("alice", 1)],
    "B",
    Some(p0_raw("alice", 1)),
  )
  ignore(
    try! discard_receiver.commit_remote(
      try! discard_receiver.prepare_remote([invalid_root]),
    ),
  )
  let alice_root = p0_insert("alice", 0, [], "A", None)
  let alice_delete = p0_delete(
    "alice",
    1,
    [p0_raw("alice", 0)],
    p0_raw("alice", 0),
  )
  let discard_plan = try! discard_receiver.prepare_remote_with_limit(
    [alice_root, alice_delete],
    0,
  )
  inspect(discard_plan.operations().length(), content="2")
  ignore(try! discard_receiver.commit_remote(discard_plan))
  inspect(discard_receiver.op_count(), content="2")
  inspect(discard_receiver.has_pending(), content="false")

  let large_receiver = OpLog::new("large-limit")
  let large_plan = try! large_receiver.prepare_remote_with_limit(
    [p0_insert("large", 0, [], "L", None)],
    2147483647,
  )
  inspect(large_plan.operations().length(), content="1")
}
