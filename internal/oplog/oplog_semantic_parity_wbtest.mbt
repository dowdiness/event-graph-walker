///| Gate P0 semantic parity tests for core-owned legacy admission.

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
test "P0 core rejects sequence fork before mutation" {
  let receiver = OpLog("receiver")
  let root = p0_insert("alice", 0, [], "A", None)
  let fork = p0_insert("alice", 1, [], "B", Some(p0_raw("alice", 0)))
  let result : Result[PreparedAdmission, OpLogError] = Ok(
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
  let plan = try! receiver.prepare_remote([descendant, middle, root])
  let committed = try! receiver.commit_remote(plan)
  inspect(committed.length(), content="3")
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
  let result : Result[PreparedAdmission, OpLogError] = Ok(
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
  let result : Result[PreparedAdmission, OpLogError] = Ok(
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
  let receiver = OpLog("receiver")
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
  let result : Result[PreparedAdmission, OpLogError] = Ok(
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
  let receiver = OpLog("receiver")
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
test "P0 core pending limit rejects without state mutation" {
  let receiver = OpLog("receiver")
  let future = p0_insert(
    "alice",
    1,
    [p0_raw("alice", 0)],
    "B",
    Some(p0_raw("alice", 0)),
  )
  let result : Result[PreparedAdmission, OpLogError] = Ok(
    receiver.prepare_remote([future], max_pending_after_complete=0),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(PendingForecastExceeded(limit~, predicted~)) => {
      inspect(limit, content="0")
      inspect(predicted, content="1")
    }
    _ => fail("expected core pending budget rejection")
  }
  inspect(receiver.op_count(), content="0")
  inspect(receiver.has_pending(), content="false")

  let allowed = try! receiver.prepare_remote(
    [future],
    max_pending_after_complete=1,
  )
  inspect(allowed.operations().length(), content="0")
  ignore(try! receiver.commit_remote(allowed))
  inspect(receiver.op_count(), content="0")
  inspect(receiver.has_pending(), content="true")

  let duplicate = try! receiver.prepare_remote(
    [future],
    max_pending_after_complete=1,
  )
  inspect(duplicate.operations().length(), content="0")
  ignore(try! receiver.commit_remote(duplicate))
  inspect(receiver.has_pending(), content="true")

  let negative : Result[PreparedAdmission, OpLogError] = Ok(
    receiver.prepare_remote([], max_pending_after_complete=-1),
  ) catch {
    error => Err(error)
  }
  match negative {
    Err(PendingForecastExceeded(limit~, predicted~)) => {
      inspect(limit, content="-1")
      inspect(predicted, content="1")
    }
    _ => fail("negative pending limit must reject")
  }
  inspect(receiver.has_pending(), content="true")

  let ready_receiver = OpLog("ready-receiver")
  let ready = p0_insert("ready", 0, [], "R", None)
  let ready_plan = try! ready_receiver.prepare_remote(
    [ready],
    max_pending_after_complete=0,
  )
  inspect(ready_plan.operations().length(), content="1")
  ignore(try! ready_receiver.commit_remote(ready_plan))
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
  let discard_plan = try! discard_receiver.prepare_remote(
    [alice_root, alice_delete],
    max_pending_after_complete=0,
  )
  inspect(discard_plan.operations().length(), content="2")
  ignore(try! discard_receiver.commit_remote(discard_plan))
  inspect(discard_receiver.op_count(), content="2")
  inspect(discard_receiver.has_pending(), content="false")

  let large_receiver = OpLog("large-limit")
  let large_plan = try! large_receiver.prepare_remote(
    [p0_insert("large", 0, [], "L", None)],
    max_pending_after_complete=2147483647,
  )
  inspect(large_plan.operations().length(), content="1")
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
    try! receiver.commit_remote(try! receiver.prepare_remote([invalid_root])),
  )
  ignore(
    try! receiver.commit_remote(
      try! receiver.prepare_remote([retained_dependent]),
    ),
  )
  inspect(receiver.has_pending(), content="true")

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
  let before = planner_lifecycle_snapshot(receiver.planner, false)
  let plan = try! receiver.prepare_remote([
    root, target, invalid_root, staged_dependent,
  ])
  let after = planner_lifecycle_snapshot(receiver.planner, false)
  inspect(planner_lifecycle_same_snapshot(before, after), content="true")
  inspect(plan.operations().length(), content="2")
  inspect(plan.remaining_raws(receiver.planner).is_empty(), content="true")

  let committed = try! receiver.commit_remote(plan)
  inspect(committed.length(), content="2")
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
    try! receiver.commit_remote(try! receiver.prepare_remote([invalid_root])),
  )
  ignore(
    try! receiver.commit_remote(try! receiver.prepare_remote([retained_middle])),
  )

  let root = p0_insert("alternating-target", 0, [], "A", None)
  let target = p0_delete(
    "alternating-target",
    1,
    [p0_raw("alternating-target", 0)],
    p0_raw("alternating-target", 0),
  )
  let before = planner_lifecycle_snapshot(receiver.planner, false)
  let plan = try! receiver.prepare_remote([
    root, target, invalid_root, staged_middle, staged_leaf,
  ])
  let after = planner_lifecycle_snapshot(receiver.planner, false)
  inspect(planner_lifecycle_same_snapshot(before, after), content="true")
  inspect(plan.operations().length(), content="2")
  inspect(plan.remaining_raws(receiver.planner).is_empty(), content="true")

  let committed = try! receiver.commit_remote(plan)
  inspect(committed.length(), content="2")
  inspect(receiver.op_count(), content="2")
  inspect(receiver.has_pending(), content="false")
}

///|
test "P0 pending limit is a complete-transition forecast across partial admission" {
  let receiver = OpLog("partial-limit")
  let first = p0_insert("partial-limit-first", 0, [], "A", None)
  let failed = p0_insert("partial-limit-failed", 0, [], "B", None)
  let plan = try! receiver.prepare_remote(
    [first, failed],
    max_pending_after_complete=0,
  )
  inspect(plan.operations().length(), content="2")

  let failed_raw = remote_admission_raw(failed)
  let result : Result[Array[@core.Op], OpLogError] = Ok(
    receiver.commit_remote_with(plan, op => {
      if remote_admission_raw(op) == failed_raw {
        raise OpLogError::CausalGraphError(
          error=@causal_graph.CausalGraphError::MissingParent(lv=-97),
        )
      }
      receiver.commit_one_remote(op)
    }),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::PartialRemoteAdmission(committed~, error~)) => {
      assert_eq(committed.length(), 1)
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) => assert_eq(lv, -97)
        _ => fail("expected injected causal graph failure")
      }
    }
    _ => fail("expected partial remote admission")
  }
  // The limit predicts the pending membership after a complete transition.
  // A partial prefix leaves its uncommitted suffix pending until retry.
  assert_eq(receiver.planner.pending_raws(), [failed_raw])
  assert_eq(receiver.planner.pending_raws().length(), 1)

  let retried = try! receiver.commit_remote(
    try! receiver.prepare_remote([failed], max_pending_after_complete=0),
  )
  assert_eq(retried.length(), 1)
  assert_eq(receiver.has_pending(), false)
}

///|
test "P0 prepared admission owns operation parent payload" {
  let receiver = OpLog("prepared-parent-alias")
  let alice = p0_insert("prepared-alice", 0, [], "A", None)
  let bob = p0_insert("prepared-bob", 0, [], "B", None)
  ignore(
    try! receiver.commit_remote(try! receiver.prepare_remote([alice, bob])),
  )

  let alice_raw = p0_raw("prepared-alice", 0)
  let bob_raw = p0_raw("prepared-bob", 0)
  let parents = [alice_raw]
  let next = p0_insert("prepared-alice", 1, parents, "C", None)
  let plan = try! receiver.prepare_remote([next])
  parents[0] = bob_raw

  let committed = try! receiver.commit_remote(plan)
  assert_eq(committed.length(), 1)
  assert_eq(committed[0].parents(), [alice_raw])
}

///|
test "P0 retained pending owns operation parent payload" {
  let receiver = OpLog("retained-parent-alias")
  let missing = p0_raw("retained-parent", 0)
  let alternate = p0_raw("retained-alternate", 0)
  let parents = [missing]
  let pending = p0_insert("retained-child", 0, parents, "P", None)
  ignore(try! receiver.commit_remote(try! receiver.prepare_remote([pending])))
  inspect(receiver.has_pending(), content="true")
  parents[0] = alternate

  let parent = p0_insert("retained-parent", 0, [], "R", None)
  let committed = try! receiver.commit_remote(
    try! receiver.prepare_remote([parent]),
  )
  assert_eq(committed.length(), 2)
  assert_eq(receiver.has_pending(), false)
  let pending_raw = remote_admission_raw(pending)
  match
    receiver
    .get_all_ops()
    .iter()
    .find_first(op => remote_admission_raw(op) == pending_raw) {
    Some(admitted) => assert_eq(admitted.parents(), [missing])
    None => fail("expected retained pending operation to be admitted")
  }
}
