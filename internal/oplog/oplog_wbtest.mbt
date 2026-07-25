///| Whitebox tests for OpLog internal functions

///|
test "add_op auto-merges contiguous insert ops" {
  let oplog = OpLog::new("test")
  let _ = try! oplog.insert("a", -1, -1)
  let _ = try! oplog.insert("b", 0, -1)

  // Two contiguous inserts from same agent should merge into 1 run
  inspect(oplog.op_count(), content="2")
  inspect(oplog.operations.length(), content="1")
}

///|
test "op_count returns total ops across all runs" {
  let oplog = OpLog::new("test")
  let _ = try! oplog.insert("a", -1, -1)
  inspect(oplog.op_count(), content="1")
}

///|
test "get_all_ops expands runs back to individual ops" {
  let oplog = OpLog::new("test")
  let _ = try! oplog.insert("h", -1, -1)
  let _ = try! oplog.insert("i", 0, -1)
  let all = oplog.get_all_ops()
  inspect(all.length(), content="2")
}

///|
test "get_ops_rle expands a middle slice from a compressed run" {
  let oplog = OpLog::new("test")
  let mut prev = -1
  for ch in ["a", "b", "c", "d"] {
    let op = try! oplog.insert(ch, prev, -1)
    prev = op.lv()
  }
  inspect(oplog.operations.length(), content="1")

  let ranges : @rle.Rle[@core.LvRange] = @rle.Rle::from_array([
    @core.LvRange::{ start: 1, count: 2 },
  ])
  let ops = oplog.get_ops_rle(ranges)
  inspect(ops.length(), content="2")
  inspect(ops[0].lv(), content="1")
  inspect(ops[0].content(), content="Insert(\"b\")")
  inspect(ops[1].lv(), content="2")
  inspect(ops[1].content(), content="Insert(\"c\")")
}

///|
test "remote admission plan is opaque, read-only, and single use" {
  let oplog = OpLog::new("local")
  let first = @core.Op::new_insert(-1, [], "opaque-first", 0, "a", None, None)
  let second = @core.Op::new_insert(-1, [], "opaque-second", 0, "b", None, None)
  let plan = try! oplog.prepare_remote([first, second])
  let view = plan.operations()
  assert_eq(view.length(), 2)
  let copy = view.to_owned()
  copy[0] = second
  assert_eq(plan.operations()[0].agent(), "opaque-first")
  let applied = try! oplog.commit_remote(plan)
  assert_eq(applied.length(), 2)
  let reused : Result[Array[@core.Op], OpLogError] = Ok(
    oplog.commit_remote(plan),
  ) catch {
    error => Err(error)
  }
  match reused {
    Err(OpLogError::ConsumedRemoteAdmissionPlan) => ()
    _ => fail("expected consumed remote admission plan")
  }
}

///|
test "remote admission rejects stale plans before local mutation" {
  let oplog = OpLog::new("local")
  let incoming = @core.Op::new_insert(
    -1,
    [],
    "stale-incoming",
    0,
    "r",
    None,
    None,
  )
  let plan = try! oplog.prepare_remote([incoming])
  ignore(try! oplog.insert("local", -1, -1))
  let count_before = oplog.op_count()
  let result : Result[Array[@core.Op], OpLogError] = Ok(
    oplog.commit_remote(plan),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::StaleRemoteAdmissionPlan) => ()
    _ => fail("expected stale remote admission plan")
  }
  assert_eq(oplog.op_count(), count_before)
  assert_eq(oplog.has_pending(), false)
}

///|
test "remote admission begin rejects internal conflicts atomically" {
  let oplog = OpLog::new("local")
  let first = @core.Op::new_insert(-1, [], "conflict-first", 0, "a", None, None)
  let second = @core.Op::new_insert(
    -1,
    [],
    "conflict-second",
    0,
    "b",
    None,
    None,
  )
  let plan = try! oplog.prepare_remote([first, second])
  plan.staged_order[1] = plan.staged_order[0]
  let result : Result[Array[@core.Op], OpLogError] = Ok(
    oplog.commit_remote(plan),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::InvalidRemoteAdmissionPlan) => ()
    _ => fail("expected invalid remote admission plan")
  }
  assert_eq(oplog.op_count(), 0)
  assert_eq(oplog.has_pending(), false)
}

///|
test "remote admission duplicate pending identities remain one node" {
  let oplog = OpLog::new("local")
  let parent_raw = @core.RawVersion::new("duplicate-parent", 0)
  let child = @core.Op::new_insert(
    -1,
    [parent_raw],
    "duplicate-child",
    0,
    "c",
    None,
    None,
  )
  let parent = @core.Op::new_insert(
    -1,
    [],
    "duplicate-parent",
    0,
    "p",
    None,
    None,
  )
  assert_eq((try! oplog.apply_remote(child)).length(), 0)
  assert_eq((try! oplog.apply_remote(child)).length(), 0)
  assert_eq(oplog.planner.pending_operations().length(), 1)
  let applied = try! oplog.apply_remote(parent)
  assert_eq(applied.length(), 2)
  assert_eq(oplog.has_pending(), false)
}

///|
test "remote admission discard removes dependents and permits retry" {
  let oplog = OpLog::new("local")
  let root_raw = @core.RawVersion::new("discard-root", 0)
  let root = @core.Op::new_insert(
    -1,
    [@core.RawVersion::new("missing-root", 0)],
    "discard-root",
    0,
    "r",
    None,
    None,
  )
  let child = @core.Op::new_insert(
    -1,
    [root_raw],
    "discard-child",
    0,
    "c",
    None,
    None,
  )
  ignore(try! oplog.apply_remote(child))
  ignore(try! oplog.apply_remote(root))
  oplog.discard_pending_dependents([root_raw])
  assert_eq(oplog.has_pending(), false)
  let retry = @core.Op::new_insert(
    -1,
    [],
    "discard-root",
    0,
    "retry",
    None,
    None,
  )
  assert_eq((try! oplog.apply_remote(retry)).length(), 1)
  assert_eq(oplog.has_pending(), false)
}

///|
test "remote admission preserves committed prefix on injected graph failure" {
  let oplog = OpLog::new("local")
  let first = @core.Op::new_insert(-1, [], "partial-first", 0, "a", None, None)
  let failed = @core.Op::new_insert(
    -1,
    [],
    "partial-failed",
    0,
    "b",
    None,
    None,
  )
  let suffix = @core.Op::new_insert(
    -1,
    [],
    "partial-suffix",
    0,
    "c",
    None,
    None,
  )
  let missing = @core.RawVersion::new("partial-compaction-missing", 0)
  for i in 0..<512 {
    let stale = @core.Op::new_insert(
      -1,
      [missing],
      "partial-compaction-stale",
      i,
      "s",
      None,
      None,
    )
    oplog.planner.register_pending(stale, _ => false)
    oplog.planner.acknowledge_admitted(remote_admission_raw(stale))
  }
  assert_eq(oplog.planner.stale_count(), 1024)
  let plan = try! oplog.prepare_remote([first, failed, suffix])
  let failed_raw = remote_admission_raw(failed)
  let result : Result[Array[@core.Op], OpLogError] = Ok(
    oplog.commit_remote_with(plan, op => {
      if remote_admission_raw(op) == failed_raw {
        raise OpLogError::CausalGraphError(
          error=@causal_graph.CausalGraphError::MissingParent(lv=-99),
        )
      }
      oplog.commit_one_remote(op)
    }),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::PartialRemoteAdmission(committed~, error~)) => {
      assert_eq(committed.length(), 1)
      assert_eq(committed[0].agent(), "partial-first")
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) => assert_eq(lv, -99)
        _ => fail("expected injected causal graph failure")
      }
    }
    _ => fail("expected partial remote admission")
  }
  assert_eq(oplog.planner.stale_count(), 0)
  let pending = oplog.planner.pending_operations()
  assert_eq(pending.length(), 2)
  assert_eq(pending[0].agent(), "partial-failed")
  assert_eq(pending[1].agent(), "partial-suffix")
  let retried = try! oplog.commit_remote(
    try! oplog.prepare_remote([failed, suffix]),
  )
  assert_eq(retried.length(), 2)
  assert_eq(oplog.has_pending(), false)
}

///|
test "get_ops_rle preserves range order for retreat-style ranges" {
  let oplog = OpLog::new("test")
  let mut prev = -1
  for ch in ["a", "b", "c"] {
    let op = try! oplog.insert(ch, prev, -1)
    prev = op.lv()
  }
  let ranges : @rle.Rle[@core.LvRange] = @rle.Rle::from_array([
    @core.LvRange::{ start: 2, count: 1 },
    @core.LvRange::{ start: 0, count: 1 },
  ])
  let ops = oplog.get_ops_rle(ranges)
  inspect(ops.length(), content="2")
  inspect(ops[0].lv(), content="2")
  inspect(ops[1].lv(), content="0")
}

///|
test "get_ops_rle keeps clamped invalid-LV behavior" {
  let oplog = OpLog::new("test")
  let _ = try! oplog.insert("a", -1, -1)
  let _ = try! oplog.insert("b", 0, -1)
  let ranges : @rle.Rle[@core.LvRange] = @rle.Rle::from_array([
    @core.LvRange::{ start: -1, count: 4 },
  ])
  let ops = oplog.get_ops_rle(ranges)
  inspect(ops.length(), content="2")
  inspect(ops[0].lv(), content="0")
  inspect(ops[1].lv(), content="1")
}
