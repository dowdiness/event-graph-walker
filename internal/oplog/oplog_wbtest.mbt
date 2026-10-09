///| Whitebox tests for OpLog internal functions

///|
/// OpLog primary seam: logical identity comparison is structural and LV-free.
test "OpLog logical operation equality ignores destination LV and parent order" {
  let left = @core.RawVersion("left", 1)
  let right = @core.RawVersion("right", 2)
  let first = @core.Op::insert(
    7,
    [right, left, right],
    "agent",
    3,
    "x",
    Some(left),
    Some(right),
  )
  let reordered = @core.Op::insert(
    99,
    [left, right, right],
    "agent",
    3,
    "x",
    Some(left),
    Some(right),
  )
  assert_true(apply_changes_same_logical_operation(first, reordered))

  let parent_conflict = @core.Op::insert(
    99,
    [left, right, left],
    "agent",
    3,
    "x",
    Some(left),
    Some(right),
  )
  assert_true(!apply_changes_same_logical_operation(first, parent_conflict))
  let content_conflict = @core.Op::insert(
    99,
    [left, right, right],
    "agent",
    3,
    "y",
    Some(left),
    Some(right),
  )
  assert_true(!apply_changes_same_logical_operation(first, content_conflict))
  let left_origin_conflict = @core.Op::insert(
    99,
    [left, right, right],
    "agent",
    3,
    "x",
    Some(right),
    Some(right),
  )
  assert_true(
    !apply_changes_same_logical_operation(first, left_origin_conflict),
  )
  let right_origin_conflict = @core.Op::insert(
    99,
    [left, right, right],
    "agent",
    3,
    "x",
    Some(left),
    Some(left),
  )
  assert_true(
    !apply_changes_same_logical_operation(first, right_origin_conflict),
  )
  let delete_conflict = @core.Op::delete(
    99,
    [left, right, right],
    "agent",
    3,
    Some(left),
  )
  assert_true(!apply_changes_same_logical_operation(first, delete_conflict))
  let agent_conflict = @core.Op::insert(
    99,
    [left, right, right],
    "other",
    3,
    "x",
    Some(left),
    Some(right),
  )
  assert_true(!apply_changes_same_logical_operation(first, agent_conflict))
  let seq_conflict = @core.Op::insert(
    99,
    [left, right, right],
    "agent",
    4,
    "x",
    Some(left),
    Some(right),
  )
  assert_true(!apply_changes_same_logical_operation(first, seq_conflict))
}

///|
test "add_op auto-merges contiguous insert ops" {
  let oplog = OpLog("test")
  let _ = try! oplog.insert("a", -1, -1)
  let _ = try! oplog.insert("b", 0, -1)

  // Two contiguous inserts from same agent should merge into 1 run
  inspect(oplog.op_count(), content="2")
  inspect(oplog.operations.length(), content="1")
}

///|
test "op_count returns total ops across all runs" {
  let oplog = OpLog("test")
  let _ = try! oplog.insert("a", -1, -1)
  inspect(oplog.op_count(), content="1")
}

///|
test "get_all_ops expands runs back to individual ops" {
  let oplog = OpLog("test")
  let _ = try! oplog.insert("h", -1, -1)
  let _ = try! oplog.insert("i", 0, -1)
  let all = oplog.get_all_ops()
  inspect(all.length(), content="2")
}

///|
test "get_ops_rle expands a middle slice from a compressed run" {
  let oplog = OpLog("test")
  let mut prev = -1
  for ch in ["a", "b", "c", "d"] {
    let op = try! oplog.insert(ch, prev, -1)
    prev = op.lv()
  }
  inspect(oplog.operations.length(), content="1")

  let ranges : @rle.Rle[@core.LvRange] = @rle.Rle::from_array([
    @core.LvRange::{ start: 1, count: 2, },
  ])
  let ops = oplog.get_ops_rle(ranges)
  inspect(ops.length(), content="2")
  inspect(ops[0].lv(), content="1")
  inspect(ops[0].content(), content="Insert(\"b\")")
  inspect(ops[1].lv(), content="2")
  inspect(ops[1].content(), content="Insert(\"c\")")
}

///|
test "`ApplyChanges` action is opaque, read-only, and single use" {
  let oplog = OpLog("local")
  let first = @core.Op::insert(-1, [], "opaque-first", 0, "a", None, None)
  let second = @core.Op::insert(-1, [], "opaque-second", 0, "b", None, None)
  let action = try! ApplyChanges(oplog, [first, second])
  let view = action.operations()
  assert_eq(view.length(), 2)
  let copy = view.to_owned()
  copy[0] = second
  assert_eq(action.operations()[0].agent(), "opaque-first")
  let report = try! p1_apply_success(oplog, action)
  assert_eq(report.committed().length(), 2)
  let reused : Result[ApplyChangesOutcome, OpLogError] = Ok(
    oplog.apply_changes(action),
  ) catch {
    error => Err(error)
  }
  match reused {
    Err(OpLogError::ConsumedApplyChanges) => ()
    _ => fail("expected consumed ApplyChanges")
  }
}

///|
test "`ApplyChanges` action rejects stale values before local mutation" {
  let oplog = OpLog("local")
  let incoming = @core.Op::insert(-1, [], "stale-incoming", 0, "r", None, None)
  let action = try! ApplyChanges(oplog, [incoming])
  ignore(try! oplog.insert("local", -1, -1))
  let count_before = oplog.op_count()
  let result : Result[ApplyChangesOutcome, OpLogError] = Ok(
    oplog.apply_changes(action),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::StaleApplyChanges) => ()
    _ => fail("expected stale ApplyChanges")
  }
  assert_eq(oplog.op_count(), count_before)
  assert_eq(oplog.has_pending(), false)
}

///|
test "remote change application rejects generation mismatch after remote change application" {
  let oplog = OpLog("local")
  let stale = @core.Op::insert(-1, [], "stale-remote", 0, "s", None, None)
  let independent = @core.Op::insert(
    -1,
    [],
    "intervening-remote",
    0,
    "i",
    None,
    None,
  )
  let action = try! ApplyChanges(oplog, [stale])
  let applied = try! oplog.apply_remote(independent)
  assert_eq(applied.length(), 1)
  let ops_after = oplog.get_all_ops()
  let pending_after = oplog.pending_changes.pending_operations()
  let count_after = oplog.op_count()
  let runs_after = oplog.operations.length()
  let frontier_after = oplog.get_frontier_raw()

  let result : Result[ApplyChangesOutcome, OpLogError] = Ok(
    oplog.apply_changes(action),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::StaleApplyChanges) => ()
    _ => fail("expected stale ApplyChanges")
  }

  assert_eq(oplog.op_count(), count_after)
  assert_eq(oplog.operations.length(), runs_after)
  assert_eq(oplog.get_frontier_raw(), frontier_after)
  let ops_now = oplog.get_all_ops()
  assert_eq(ops_now.length(), ops_after.length())
  for i in 0..<ops_after.length() {
    assert_eq(ops_now[i].lv(), ops_after[i].lv())
    assert_eq(ops_now[i].agent(), ops_after[i].agent())
    assert_eq(ops_now[i].seq(), ops_after[i].seq())
    assert_eq(ops_now[i].content(), ops_after[i].content())
  }
  let pending_now = oplog.pending_changes.pending_operations()
  assert_eq(pending_now.length(), pending_after.length())
  for i in 0..<pending_after.length() {
    assert_eq(
      apply_changes_raw(pending_now[i]),
      apply_changes_raw(pending_after[i]),
    )
  }
  assert_eq(oplog.has_pending(), !pending_after.is_empty())
}

///|
test "remote change application begin rejects internal conflicts atomically" {
  let oplog = OpLog("local")
  let first = @core.Op::insert(-1, [], "conflict-first", 0, "a", None, None)
  let second = @core.Op::insert(-1, [], "conflict-second", 0, "b", None, None)
  let action = try! ApplyChanges(oplog, [first, second])
  action.planned[1] = action.planned[0]
  let result : Result[ApplyChangesOutcome, OpLogError] = Ok(
    oplog.apply_changes(action),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::InvalidApplyChanges) => ()
    _ => fail("expected invalid ApplyChanges")
  }
  assert_eq(oplog.op_count(), 0)
  assert_eq(oplog.has_pending(), false)
}

///|
test "remote change application duplicate pending identities remain one node" {
  let oplog = OpLog("local")
  let parent_raw = @core.RawVersion("duplicate-parent", 0)
  let child = @core.Op::insert(
    -1,
    [parent_raw],
    "duplicate-child",
    0,
    "c",
    None,
    None,
  )
  let parent = @core.Op::insert(-1, [], "duplicate-parent", 0, "p", None, None)
  assert_eq((try! oplog.apply_remote(child)).length(), 0)
  assert_eq((try! oplog.apply_remote(child)).length(), 0)
  assert_eq(oplog.pending_changes.pending_operations().length(), 1)
  let applied = try! oplog.apply_remote(parent)
  assert_eq(applied.length(), 2)
  assert_eq(oplog.has_pending(), false)
}

///|
test "remote change application discard removes dependents and permits retry" {
  let oplog = OpLog("local")
  let root_raw = @core.RawVersion("discard-root", 0)
  let root = @core.Op::insert(
    -1,
    [@core.RawVersion("missing-root", 0)],
    "discard-root",
    0,
    "r",
    None,
    None,
  )
  let child = @core.Op::insert(
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
  let retry = @core.Op::insert(-1, [], "discard-root", 0, "retry", None, None)
  assert_eq((try! oplog.apply_remote(retry)).length(), 1)
  assert_eq(oplog.has_pending(), false)
}

///|
test "remote change application preserves committed prefix on injected graph failure" {
  let oplog = OpLog("local")
  let first = @core.Op::insert(-1, [], "partial-first", 0, "a", None, None)
  let failed = @core.Op::insert(-1, [], "partial-failed", 0, "b", None, None)
  let suffix = @core.Op::insert(-1, [], "partial-suffix", 0, "c", None, None)
  let missing = @core.RawVersion("partial-compaction-missing", 0)
  for i in 0..<512 {
    let stale = @core.Op::insert(
      -1,
      [missing],
      "partial-compaction-stale",
      i,
      "s",
      None,
      None,
    )
    oplog.pending_changes.register_pending(stale, _ => false)
    oplog.pending_changes.acknowledge_applied(apply_changes_raw(stale))
  }
  assert_eq(oplog.pending_changes.stale_count(), 1024)
  let action = try! ApplyChanges(oplog, [first, failed, suffix])
  let failed_raw = apply_changes_raw(failed)
  match
    (try! oplog.apply_changes_with(action, op => {
      if apply_changes_raw(op) == failed_raw {
        raise @causal_graph.CausalGraphError::MissingParent(lv=-99)
      }
      oplog.commit_one_remote_for_apply_changes(op)
    })) {
    ApplyChangesOutcome::Failed(report~, error~) => {
      assert_eq(report.committed().length(), 1)
      assert_eq(report.committed()[0].agent(), "partial-first")
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) => assert_eq(lv, -99)
        _ => fail("expected injected causal graph failure")
      }
    }
    ApplyChangesOutcome::Succeeded(_) =>
      fail("expected partial remote change application")
  }
  assert_eq(oplog.pending_changes.stale_count(), 0)
  let pending = oplog.pending_changes.pending_operations()
  assert_eq(pending.length(), 2)
  assert_eq(pending[0].agent(), "partial-failed")
  assert_eq(pending[1].agent(), "partial-suffix")
  let retried = try! p1_apply_success(
    oplog,
    try! ApplyChanges(oplog, [failed, suffix]),
  )
  assert_eq(retried.committed().length(), 2)
  assert_eq(oplog.has_pending(), false)
}

///|
test "get_ops_rle preserves range order for retreat-style ranges" {
  let oplog = OpLog("test")
  let mut prev = -1
  for ch in ["a", "b", "c"] {
    let op = try! oplog.insert(ch, prev, -1)
    prev = op.lv()
  }
  let ranges : @rle.Rle[@core.LvRange] = @rle.Rle::from_array([
    @core.LvRange::{ start: 2, count: 1, },
    @core.LvRange::{ start: 0, count: 1, },
  ])
  let ops = oplog.get_ops_rle(ranges)
  inspect(ops.length(), content="2")
  inspect(ops[0].lv(), content="2")
  inspect(ops[1].lv(), content="0")
}

///|
test "get_ops_rle keeps clamped invalid-LV behavior" {
  let oplog = OpLog("test")
  let _ = try! oplog.insert("a", -1, -1)
  let _ = try! oplog.insert("b", 0, -1)
  let ranges : @rle.Rle[@core.LvRange] = @rle.Rle::from_array([
    @core.LvRange::{ start: -1, count: 4, },
  ])
  let ops = oplog.get_ops_rle(ranges)
  inspect(ops.length(), content="2")
  inspect(ops[0].lv(), content="0")
  inspect(ops[1].lv(), content="1")
}

///|
test "collect_missing_ops work follows delta rather than recorded history" {
  for history in [1000, 10000] {
    let oplog = OpLog("agent")
    let mut previous = -1
    for _ in 0..<history {
      let op = try! oplog.insert("x", previous, -1)
      previous = op.lv()
    }
    let peer = try! @causal_graph.GraphVersion::from_parts(
      [@core.RawVersion("agent", history - 2)],
      [("agent", [(0U, (history - 1).reinterpret_as_uint())])],
    )
    let (operations, ranges, identities, lookups, expanded) = try! oplog.collect_missing_ops_counted(
      peer,
    )
    assert_eq(operations.length(), 1)
    assert_eq(operations[0].seq(), history - 1)
    assert_eq(ranges, 1)
    assert_eq(identities, 1)
    assert_eq(lookups, 1)
    assert_eq(expanded, 1)

    let (_, empty_ranges, empty_identities, empty_lookups, empty_expanded) = try! oplog.collect_missing_ops_counted(
      oplog.causal_graph().current_graph_version(),
    )
    assert_eq(empty_ranges, 0)
    assert_eq(empty_identities, 0)
    assert_eq(empty_lookups, 0)
    assert_eq(empty_expanded, 0)
  }
}
