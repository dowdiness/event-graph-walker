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

  let recovery = try! receiver.prepare_remote([root, target])
  let committed = try! receiver.commit_remote(recovery)
  inspect(committed.length(), content="2")
  inspect(receiver.op_count(), content="2")
  inspect(receiver.has_pending(), content="false")
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
  ignore(try! receiver.commit_remote(allowed))
  inspect(receiver.op_count(), content="0")
  inspect(receiver.has_pending(), content="true")
}
