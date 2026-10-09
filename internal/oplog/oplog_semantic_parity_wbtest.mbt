///| Gate P0 semantic parity tests for core-owned legacy change application.

///|
fn p0_raw(agent : String, seq : Int) -> @core.RawVersion {
  @core.RawVersion(agent, seq)
}

///|
fn p0_insert(
  agent : String,
  seq : Int,
  parents : Array[@core.RawVersion],
  text : String,
  origin_left : @core.RawVersion?,
) -> @core.Op {
  @core.Op::insert(-1, parents, agent, seq, text, origin_left, None)
}

///|
fn p0_delete(
  agent : String,
  seq : Int,
  parents : Array[@core.RawVersion],
  target : @core.RawVersion,
) -> @core.Op {
  @core.Op::delete(-1, parents, agent, seq, Some(target))
}

///|
test "P0 core accepts a same-agent causal fork atomically" {
  let receiver = OpLog("receiver")
  let root = p0_insert("alice", 0, [], "A", None)
  let fork = p0_insert("alice", 1, [], "B", Some(p0_raw("alice", 0)))
  let action = try! ApplyChanges(receiver, [root, fork])
  inspect(action.operations().length(), content="2")
  inspect(receiver.op_count(), content="0")
  ignore(try! p1_apply_success(receiver, action))
  inspect(receiver.op_count(), content="2")
  inspect(receiver.has_pending(), content="false")
  let frontier = try! receiver.get_frontier_raw()
  inspect(frontier.contains(p0_raw("alice", 0)), content="true")
  inspect(frontier.contains(p0_raw("alice", 1)), content="true")
}

///|
test "P0 core accepts indirect predecessor ancestry" {
  let receiver = OpLog("receiver")
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
  let action = try! ApplyChanges(receiver, [descendant, middle, root])
  let report = try! p1_apply_success(receiver, action)
  inspect(report.committed().length(), content="3")
  inspect(receiver.op_count(), content="3")
  inspect(receiver.has_pending(), content="false")
}

///|
test "P0 core rejects non-insert origin before mutation" {
  let receiver = OpLog("receiver")
  let root = p0_insert("alice", 0, [], "A", None)
  let delete = p0_delete("alice", 1, [p0_raw("alice", 0)], p0_raw("alice", 0))
  let malformed = p0_insert(
    "bob",
    0,
    [p0_raw("alice", 1)],
    "B",
    Some(p0_raw("alice", 1)),
  )
  let result : Result[ApplyChanges, OpLogError] = Ok(
    ApplyChanges(receiver, [root, delete, malformed]),
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
  let receiver = OpLog("receiver")
  let malformed_run : @core.OpRun = @json.from_json(
    @json.parse(
      (
        #|{"start_lv":0,"agent":"remote","start_seq":0,"content":"Deletes","parents":[],"origin_left":[{"agent":"target","seq":0}],"origin_right":[{"agent":"target","seq":0}],"count":1}
      ),
    ),
  )
  let malformed = match malformed_run.decompress(0) {
    Some(op) => op
    None => fail("expected malformed operation from OpRun")
  }
  let result : Result[ApplyChanges, OpLogError] = Ok(
    ApplyChanges(receiver, [malformed]),
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
  let receiver = OpLog("receiver")
  let root = p0_insert("alice", 0, [], "A", None)
  let target = p0_delete("alice", 1, [p0_raw("alice", 0)], p0_raw("alice", 0))
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [root, target])),
  )
  let malformed = p0_insert(
    "bob",
    0,
    [p0_raw("missing", 0)],
    "B",
    Some(p0_raw("alice", 1)),
  )
  let result : Result[ApplyChanges, OpLogError] = Ok(
    ApplyChanges(receiver, [malformed]),
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
  let receiver = OpLog("receiver")
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
  let staged_action = try! ApplyChanges(receiver, [invalid_root])
  let staged_report = try! p1_apply_success(receiver, staged_action)
  inspect(staged_report.committed().length(), content="0")
  let dependent_action = try! ApplyChanges(receiver, [dependent])
  ignore(try! p1_apply_success(receiver, dependent_action))
  inspect(receiver.has_pending(), content="true")

  let recovery_action = try! ApplyChanges(receiver, [root, target, invalid_root])
  let recovery_report = try! p1_apply_success(receiver, recovery_action)
  inspect(recovery_report.committed().length(), content="2")
  inspect(receiver.op_count(), content="2")
  inspect(receiver.has_pending(), content="false")
}

///|
test "P0 semantic prepare is fully nonmutating and repeatable" {
  let receiver = OpLog("receiver")
  let invalid_root = p0_insert(
    "bob",
    0,
    [p0_raw("alice", 1)],
    "B",
    Some(p0_raw("alice", 1)),
  )
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [invalid_root])),
  )
  let root = p0_insert("alice", 0, [], "A", None)
  let target = p0_delete("alice", 1, [p0_raw("alice", 0)], p0_raw("alice", 0))
  let before = pending_changes_lifecycle_snapshot(
    receiver.pending_changes,
    false,
  )
  let before_count = receiver.op_count()
  let before_frontier = try! receiver.get_frontier_raw()
  let first = try! ApplyChanges(receiver, [root, target])
  let after_first = pending_changes_lifecycle_snapshot(
    receiver.pending_changes,
    false,
  )
  inspect(
    pending_changes_lifecycle_same_snapshot(before, after_first),
    content="true",
  )
  inspect(receiver.op_count(), content="0")
  assert_eq(receiver.op_count(), before_count)
  assert_eq(try! receiver.get_frontier_raw(), before_frontier)

  let second = try! ApplyChanges(receiver, [root, target])
  let after_second = pending_changes_lifecycle_snapshot(
    receiver.pending_changes,
    false,
  )
  inspect(
    pending_changes_lifecycle_same_snapshot(before, after_second),
    content="true",
  )
  inspect(
    pending_changes_lifecycle_same_ops(first.operations(), second.operations()),
    content="true",
  )
  inspect(
    pending_changes_lifecycle_same_raws(
      first.remaining_raws(receiver.pending_changes),
      second.remaining_raws(receiver.pending_changes),
    ),
    content="true",
  )
  assert_eq(first.discard_roots, second.discard_roots)
  assert_eq(first.discarded_pending.length(), second.discarded_pending.length())
  for raw in first.discarded_pending {
    inspect(second.discarded_pending.contains(raw), content="true")
  }
  assert_eq(first.discarded_staged.length(), second.discarded_staged.length())
  for raw in first.discarded_staged {
    inspect(second.discarded_staged.contains(raw), content="true")
  }
  assert_eq(first.next_arrival, second.next_arrival)
  assert_eq(first.generation, second.generation)
}

///|
test "P1 hard pending limit rejects without state mutation" {
  let receiver = OpLog("receiver")
  let future = p0_insert(
    "alice",
    1,
    [p0_raw("alice", 0)],
    "B",
    Some(p0_raw("alice", 0)),
  )
  let result : Result[ApplyChanges, OpLogError] = Ok(
    ApplyChanges(receiver, [future], max_pending=0),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(PendingLimitExceeded(limit~, required~)) => {
      inspect(limit, content="0")
      inspect(required, content="1")
    }
    _ => fail("expected hard pending-limit rejection")
  }
  inspect(receiver.op_count(), content="0")
  inspect(receiver.has_pending(), content="false")

  let allowed = try! ApplyChanges(receiver, [future], max_pending=1)
  inspect(allowed.operations().length(), content="0")
  ignore(try! p1_apply_success(receiver, allowed))
  inspect(receiver.op_count(), content="0")
  inspect(receiver.has_pending(), content="true")
  inspect(receiver.pending_changes.pending_operations().length(), content="1")

  let duplicate = try! ApplyChanges(receiver, [future], max_pending=1)
  inspect(duplicate.operations().length(), content="0")
  ignore(try! p1_apply_success(receiver, duplicate))
  inspect(receiver.has_pending(), content="true")

  let negative : Result[ApplyChanges, OpLogError] = Ok(
    ApplyChanges(receiver, [], max_pending=-1),
  ) catch {
    error => Err(error)
  }
  match negative {
    Err(PendingLimitExceeded(limit~, required~)) => {
      inspect(limit, content="-1")
      inspect(required, content="1")
    }
    _ => fail("negative pending limit must reject")
  }
  inspect(receiver.has_pending(), content="true")

  let ready_receiver = OpLog("ready-receiver")
  let ready = p0_insert("ready", 0, [], "R", None)
  let ready_rejected : Result[ApplyChanges, OpLogError] = Ok(
    ApplyChanges(ready_receiver, [ready], max_pending=0),
  ) catch {
    error => Err(error)
  }
  match ready_rejected {
    Err(PendingLimitExceeded(limit~, required~)) => {
      inspect(limit, content="0")
      inspect(required, content="1")
    }
    _ => fail("begin-after pending membership must be bounded")
  }
  let ready_action = try! ApplyChanges(ready_receiver, [ready], max_pending=1)
  inspect(ready_action.operations().length(), content="1")
  ignore(try! p1_apply_success(ready_receiver, ready_action))
  inspect(ready_receiver.op_count(), content="1")
  inspect(ready_receiver.has_pending(), content="false")

  let discard_receiver = OpLog("discard-receiver")
  let invalid_root = p0_insert(
    "bob",
    0,
    [p0_raw("alice", 1)],
    "B",
    Some(p0_raw("alice", 1)),
  )
  ignore(
    try! p1_apply_success(
      discard_receiver,
      try! ApplyChanges(discard_receiver, [invalid_root]),
    ),
  )
  let alice_root = p0_insert("alice", 0, [], "A", None)
  let alice_delete = p0_delete(
    "alice",
    1,
    [p0_raw("alice", 0)],
    p0_raw("alice", 0),
  )
  let discard_rejected : Result[ApplyChanges, OpLogError] = Ok(
    ApplyChanges(discard_receiver, [alice_root, alice_delete], max_pending=1),
  ) catch {
    error => Err(error)
  }
  match discard_rejected {
    Err(PendingLimitExceeded(limit~, required~)) => {
      inspect(limit, content="1")
      inspect(required, content="2")
    }
    _ => fail("discard closure must be included in the bound")
  }
  let discard_action = try! ApplyChanges(
    discard_receiver,
    [alice_root, alice_delete],
    max_pending=2,
  )
  inspect(discard_action.operations().length(), content="2")
  ignore(try! p1_apply_success(discard_receiver, discard_action))
  inspect(discard_receiver.op_count(), content="2")
  inspect(discard_receiver.has_pending(), content="false")

  let large_receiver = OpLog("large-limit")
  let large_action = try! ApplyChanges(
    large_receiver,
    [p0_insert("large", 0, [], "L", None)],
    max_pending=2147483647,
  )
  inspect(large_action.operations().length(), content="1")
}

///|
test "P0 rejection closure crosses retained pending into staged dependents" {
  let receiver = OpLog("closure-retained-staged")
  let missing_target = p0_raw("closure-target", 1)
  let invalid_root = p0_insert(
    "closure-root",
    0,
    [missing_target],
    "R",
    Some(missing_target),
  )
  let retained_dependent = p0_insert(
    "closure-retained",
    0,
    [p0_raw("closure-root", 0)],
    "P",
    Some(p0_raw("closure-root", 0)),
  )
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [invalid_root])),
  )
  ignore(
    try! p1_apply_success(
      receiver,
      try! ApplyChanges(receiver, [retained_dependent]),
    ),
  )

  let root = p0_insert("closure-target", 0, [], "A", None)
  let target = p0_delete(
    "closure-target",
    1,
    [p0_raw("closure-target", 0)],
    p0_raw("closure-target", 0),
  )
  let staged_dependent = p0_insert(
    "closure-staged",
    0,
    [p0_raw("closure-retained", 0)],
    "S",
    Some(p0_raw("closure-retained", 0)),
  )
  let before = pending_changes_lifecycle_snapshot(
    receiver.pending_changes,
    false,
  )
  let action = try! ApplyChanges(receiver, [
    root, target, invalid_root, staged_dependent,
  ])
  let after = pending_changes_lifecycle_snapshot(
    receiver.pending_changes,
    false,
  )
  inspect(
    pending_changes_lifecycle_same_snapshot(before, after),
    content="true",
  )
  inspect(action.operations().length(), content="2")
  inspect(
    action.remaining_raws(receiver.pending_changes).is_empty(),
    content="true",
  )

  let report = try! p1_apply_success(receiver, action)
  inspect(report.committed().length(), content="2")
  inspect(receiver.op_count(), content="2")
  inspect(receiver.has_pending(), content="false")
}

///|
test "P0 rejection closure crosses alternating retained and staged dependents" {
  let receiver = OpLog("closure-alternating")
  let missing_target = p0_raw("alternating-target", 1)
  let invalid_root = p0_insert(
    "alternating-root",
    0,
    [missing_target],
    "R",
    Some(missing_target),
  )
  let staged_middle = p0_insert(
    "alternating-staged-middle",
    0,
    [p0_raw("alternating-root", 0)],
    "S1",
    Some(p0_raw("alternating-root", 0)),
  )
  let retained_middle = p0_insert(
    "alternating-retained-middle",
    0,
    [p0_raw("alternating-staged-middle", 0)],
    "P2",
    Some(p0_raw("alternating-staged-middle", 0)),
  )
  let staged_leaf = p0_insert(
    "alternating-staged-leaf",
    0,
    [p0_raw("alternating-retained-middle", 0)],
    "S2",
    Some(p0_raw("alternating-retained-middle", 0)),
  )
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [invalid_root])),
  )
  ignore(
    try! p1_apply_success(
      receiver,
      try! ApplyChanges(receiver, [retained_middle]),
    ),
  )
  let root = p0_insert("alternating-target", 0, [], "A", None)
  let target = p0_delete(
    "alternating-target",
    1,
    [p0_raw("alternating-target", 0)],
    p0_raw("alternating-target", 0),
  )
  let before = pending_changes_lifecycle_snapshot(
    receiver.pending_changes,
    false,
  )
  let action = try! ApplyChanges(receiver, [
    root, target, invalid_root, staged_middle, staged_leaf,
  ])
  let after = pending_changes_lifecycle_snapshot(
    receiver.pending_changes,
    false,
  )
  inspect(
    pending_changes_lifecycle_same_snapshot(before, after),
    content="true",
  )
  inspect(action.operations().length(), content="2")
  inspect(
    action.remaining_raws(receiver.pending_changes).is_empty(),
    content="true",
  )

  let report = try! p1_apply_success(receiver, action)
  inspect(report.committed().length(), content="2")
  inspect(receiver.op_count(), content="2")
  inspect(receiver.has_pending(), content="false")
}

///|
test "P1 pending limit rejects before zero-prefix partial" {
  let receiver = OpLog("partial-limit")
  let first = p0_insert("partial-limit-first", 0, [], "A", None)
  let failed = p0_insert("partial-limit-failed", 0, [], "B", None)
  let rejected : Result[ApplyChanges, OpLogError] = Ok(
    ApplyChanges(receiver, [first, failed], max_pending=1),
  ) catch {
    error => Err(error)
  }
  match rejected {
    Err(PendingLimitExceeded(limit~, required~)) => {
      assert_eq(limit, 1)
      assert_eq(required, 2)
    }
    _ => fail("zero-prefix partial must satisfy begin-after pending bound")
  }
  assert_eq(receiver.op_count(), 0)
  assert_eq(receiver.pending_changes.pending_operations().length(), 0)

  let action = try! ApplyChanges(receiver, [first, failed], max_pending=2)
  inspect(action.operations().length(), content="2")
  let failed_raw = apply_changes_raw(failed)
  match
    (try! receiver.apply_changes_with_failure(action, op => {
      if apply_changes_raw(op) == failed_raw {
        Some(@causal_graph.CausalGraphError::MissingParent(lv=-97))
      } else {
        None
      }
    })) {
    ApplyChangesOutcome::Failed(report~, error~) => {
      assert_eq(report.committed().length(), 1)
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) => assert_eq(lv, -97)
        _ => fail("expected injected causal graph failure")
      }
    }
    ApplyChangesOutcome::Succeeded(_) =>
      fail("expected partial remote change application")
  }
  assert_eq(receiver.pending_changes.pending_raws(), [failed_raw])
  assert_eq(receiver.pending_changes.pending_raws().length(), 1)

  let retry_action = try! ApplyChanges(receiver, [failed], max_pending=1)
  let retry_report = try! p1_apply_success(receiver, retry_action)
  assert_eq(retry_report.committed().length(), 1)
  assert_eq(receiver.has_pending(), false)
}

///|
test "P0 `ApplyChanges` action owns operation parent payload" {
  let receiver = OpLog("prepared-parent-alias")
  let alice = p0_insert("prepared-alice", 0, [], "A", None)
  let bob = p0_insert("prepared-bob", 0, [], "B", None)
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [alice, bob])),
  )

  let alice_raw = p0_raw("prepared-alice", 0)
  let bob_raw = p0_raw("prepared-bob", 0)
  let parents = [alice_raw]
  let next = p0_insert("prepared-alice", 1, parents, "C", None)
  let action = try! ApplyChanges(receiver, [next])
  parents[0] = bob_raw

  let report = try! p1_apply_success(receiver, action)
  assert_eq(report.committed().length(), 1)
  assert_eq(report.committed()[0].parents(), [alice_raw])
}

///|
test "P0 retained pending owns operation parent payload" {
  let receiver = OpLog("retained-parent-alias")
  let missing = p0_raw("retained-parent", 0)
  let alternate = p0_raw("retained-alternate", 0)
  let parents = [missing]
  let pending = p0_insert("retained-child", 0, parents, "P", None)
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [pending])),
  )
  inspect(receiver.has_pending(), content="true")
  parents[0] = alternate

  let parent = p0_insert("retained-parent", 0, [], "R", None)
  let report = try! p1_apply_success(
    receiver,
    try! ApplyChanges(receiver, [parent]),
  )
  assert_eq(report.committed().length(), 2)
  assert_eq(receiver.has_pending(), false)
  let pending_raw = apply_changes_raw(pending)
  match
    receiver
    .get_all_ops()
    .iter()
    .find_first(op => apply_changes_raw(op) == pending_raw) {
    Some(applied) => assert_eq(applied.parents(), [missing])
    None => fail("expected retained pending operation to be recorded")
  }
}
