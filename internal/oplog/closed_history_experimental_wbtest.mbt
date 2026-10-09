///|
fn closed_log_chain(size : Int) -> Array[@core.Op] {
  let ops : Array[@core.Op] = []
  for i = 0; i < size; i = i + 1 {
    ops.push(
      @core.Op::insert(
        -10,
        if i == 0 {
          []
        } else {
          [@core.RawVersion("seed", i - 1)]
        },
        "seed",
        i,
        if i % 2 == 0 {
          "😀"
        } else {
          "x"
        },
        if i == 0 {
          None
        } else {
          Some(@core.RawVersion("seed", i - 1))
        },
        None,
      ),
    )
  }
  ops
}

///|
fn closed_log_compare(actual : OpLog, reference : OpLog) -> Unit raise {
  assert_true(
    pending_changes_lifecycle_same_ops(
      actual.get_all_ops(),
      reference.get_all_ops(),
    ),
  )
  assert_eq(actual.get_all_runs(), reference.get_all_runs())
  assert_eq(
    actual.graph.current_graph_version(),
    reference.graph.current_graph_version(),
  )
  assert_eq(
    actual.get_frontier().to_array(),
    reference.get_frontier().to_array(),
  )
}

///|
test "closed history run shapes match scalar change application at cap boundaries" {
  for count in [0, 1, 255, 256, 257, 513] {
    let ops = closed_log_chain(count)
    let proof = ClosedHistory::prepare_experimental(ops)
    let saved = proof.version_experimental()
    let (actual, projection) = proof.consume_experimental("fresh")
    let reference = OpLog("fresh")
    ignore(
      (try! p1_apply_success(reference, try! ApplyChanges(reference, ops))).committed(),
    )
    closed_log_compare(actual, reference)
    assert_eq(actual.graph.current_graph_version(), saved)
    assert_true(actual.pending_changes.pending.is_empty())
    assert_eq(actual.pending_changes.generation, 0)
    assert_true(
      try proof.consume_experimental("second") catch {
        OpLogError::ConsumedApplyChanges => true
        _ => false
      } noraise {
        _ => false
      },
    )
    assert_true(
      try proof.version_experimental() catch {
        OpLogError::ConsumedApplyChanges => true
        _ => false
      } noraise {
        _ => false
      },
    )
    let retained_runs = actual.get_all_runs()
    let retained_reference_runs = reference.get_all_runs()
    projection.clear()
    closed_log_compare(actual, reference)
    ignore(actual.insert("z", -1, -1))
    ignore(reference.insert("z", -1, -1))
    closed_log_compare(actual, reference)
    assert_eq(retained_runs, retained_reference_runs)
  }
}

///|
test "closed proof owns input and independent builds do not share graph" {
  let input = closed_log_chain(4)
  let first = ClosedHistory::prepare_experimental(input)
  let second = ClosedHistory::prepare_experimental(input)
  let saved = first.version_experimental()
  input.clear()
  let (a, _) = first.consume_experimental("fresh-a")
  let (b, _) = second.consume_experimental("fresh-b")
  ignore(a.insert("A", -1, -1))
  assert_eq(b.op_count(), 4)
  assert_eq(b.graph.current_graph_version(), saved)
}

///|
test "closed history future pending drain stale and consumed capabilities match replay" {
  let ops = closed_log_chain(12)
  let (a, _) = ClosedHistory::prepare_experimental(ops).consume_experimental(
    "fresh",
  )
  let b = OpLog("fresh")
  ignore((try! p1_apply_success(b, try! ApplyChanges(b, ops))).committed())
  let waiting = @core.Op::insert(
    -1,
    [@core.RawVersion("dep", 0)],
    "waiting",
    0,
    "w",
    Some(@core.RawVersion("dep", 0)),
    None,
  )
  ignore(
    (try! p1_apply_success(a, try! ApplyChanges(a, [waiting]))).committed(),
  )
  ignore(
    (try! p1_apply_success(b, try! ApplyChanges(b, [waiting]))).committed(),
  )
  assert_eq(a.pending_count(), 1)
  assert_eq(a.pending_changes.pending_raws(), b.pending_changes.pending_raws())
  let dep = @core.Op::insert(-1, [], "dep", 0, "d", None, None)
  ignore((try! p1_apply_success(a, try! ApplyChanges(a, [dep]))).committed())
  ignore((try! p1_apply_success(b, try! ApplyChanges(b, [dep]))).committed())
  closed_log_compare(a, b)
  let tail = @core.Op::insert(-1, [], "tail", 0, "t", None, None)
  let action_a = try! ApplyChanges(a, [tail])
  let action_b = try! ApplyChanges(b, [tail])
  ignore(a.insert("l", -1, -1))
  ignore(b.insert("l", -1, -1))
  assert_true(
    try a.apply_changes(action_a) catch {
      OpLogError::StaleApplyChanges => true
      _ => false
    } noraise {
      _ => false
    },
  )
  assert_true(
    try b.apply_changes(action_b) catch {
      OpLogError::StaleApplyChanges => true
      _ => false
    } noraise {
      _ => false
    },
  )
  let action_a2 = ApplyChanges(a, [tail])
  let action_b2 = ApplyChanges(b, [tail])
  ignore(try! a.apply_changes(action_a2))
  ignore(try! b.apply_changes(action_b2))
  assert_true(
    try a.apply_changes(action_a2) catch {
      OpLogError::ConsumedApplyChanges => true
      _ => false
    } noraise {
      _ => false
    },
  )
  assert_true(
    try b.apply_changes(action_b2) catch {
      OpLogError::ConsumedApplyChanges => true
      _ => false
    } noraise {
      _ => false
    },
  )
  closed_log_compare(a, b)
}

///|
test "closed proof rejects incomplete cyclic noninsert targets and raw empty text" {
  let root = @core.Op::insert(-1, [], "a", 0, "x", None, None)
  let deletion = @core.Op::delete(
    -1,
    [@core.RawVersion("a", 0)],
    "d",
    0,
    Some(@core.RawVersion("a", 0)),
  )
  for
    bad in [
      @core.Op::insert(-1, [], "bad", 0, "", None, None),
      @core.Op::insert(-1, [], "bad", 0, "xy", None, None),
      @core.Op::insert(
        -1,
        [],
        "bad",
        0,
        "x",
        Some(@core.RawVersion("missing", 0)),
        None,
      ),
      @core.Op::insert(
        -1,
        [],
        "bad",
        0,
        "x",
        Some(@core.RawVersion("bad", 0)),
        None,
      ),
      @core.Op::insert(
        -1,
        [],
        "bad",
        0,
        "x",
        Some(@core.RawVersion("d", 0)),
        None,
      ),
    ] {
    assert_true(
      try ClosedHistory::prepare_experimental([root, deletion, bad]) catch {
        _ => true
      } noraise {
        _ => false
      },
    )
  }
  let a = @core.Op::insert(
    -1,
    [],
    "cycle-a",
    0,
    "a",
    Some(@core.RawVersion("cycle-b", 0)),
    None,
  )
  let b = @core.Op::insert(
    -1,
    [],
    "cycle-b",
    0,
    "b",
    Some(@core.RawVersion("cycle-a", 0)),
    None,
  )
  assert_true(
    try ClosedHistory::prepare_experimental([a, b]) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}
