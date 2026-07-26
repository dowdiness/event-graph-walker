///| Test-only fixed-point oracle and characterization tests for remote admission.

///|
/// This is intentionally the historical fixed-point algorithm rather than a
/// production helper. `known` is the test's explicit view of the causal-graph
/// identities already admitted by the OpLog.
fn oracle_plan_remote_candidates(
  candidates : Array[@core.Op],
  known : Array[@core.RawVersion],
) -> (Array[@core.Op], Array[@core.Op]) raise OpLogError {
  let mut candidates = candidates
  let planned : Array[@core.Op] = []
  let planned_raws : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let known_raws : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet(known)
  let mut progress = true
  while progress {
    progress = false
    let remaining : Array[@core.Op] = []
    for op in candidates {
      let raw = @core.RawVersion::new(op.agent(), op.seq())
      if known_raws.contains(raw) || planned_raws.contains(raw) {
        progress = true
        continue
      }
      if (op.is_delete() || op.is_undelete()) && op.origin_left() is None {
        raise OpLogError::MissingOrigin
      }
      let mut ready = true
      for parent in op.parents_iter() {
        if !known_raws.contains(parent) && !planned_raws.contains(parent) {
          ready = false
          break
        }
      }
      if ready {
        match op.origin_left() {
          None => ()
          Some(origin) =>
            if !known_raws.contains(origin) && !planned_raws.contains(origin) {
              ready = false
            }
        }
      }
      if ready {
        match op.origin_right() {
          None => ()
          Some(origin) =>
            if !known_raws.contains(origin) && !planned_raws.contains(origin) {
              ready = false
            }
        }
      }
      if ready {
        planned.push(op)
        planned_raws.add(raw)
        progress = true
      } else {
        remaining.push(op)
      }
    }
    candidates = remaining
  }
  (planned, candidates)
}

///|
fn oracle_raw(op : @core.Op) -> @core.RawVersion {
  @core.RawVersion::new(op.agent(), op.seq())
}

///|
fn oracle_raws(ops : Array[@core.Op]) -> Array[@core.RawVersion] {
  [
    for op in ops => oracle_raw(op)
  ]
}

///|
fn oracle_assert_raw_sequence(
  actual : Array[@core.RawVersion],
  expected : Array[@core.RawVersion],
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    assert_eq(actual[i], expected[i])
  }
}

///|
fn oracle_assert_op_sequence(
  actual : Array[@core.Op],
  expected : Array[@core.Op],
) -> Unit raise {
  oracle_assert_raw_sequence(oracle_raws(actual), oracle_raws(expected))
}

///|
fn oracle_assert_agents(
  ops : Array[@core.Op],
  expected : Array[String],
) -> Unit raise {
  assert_eq(ops.length(), expected.length())
  for i in 0..<ops.length() {
    assert_eq(ops[i].agent(), expected[i])
  }
}

///|
fn oracle_compare_plan(
  oplog : OpLog,
  incoming : Array[@core.Op],
  known : Array[@core.RawVersion],
) -> Unit raise {
  let pending_before = oracle_raws(oplog.planner.pending_operations())
  let op_count_before = oplog.op_count()
  let frontier_before = oplog.get_frontier_raw()
  let candidates = oplog.planner.pending_operations()
  for op in incoming {
    candidates.push(op)
  }
  let (oracle_planned, oracle_remaining) = oracle_plan_remote_candidates(
    candidates.copy(),
    known,
  )
  let prepared = oplog.prepare_remote(incoming)
  let current_planned = prepared.operations().to_owned()
  let current_remaining = prepared.remaining_raws(oplog.planner)
  oracle_assert_op_sequence(current_planned, oracle_planned)
  oracle_assert_raw_sequence(current_remaining, oracle_raws(oracle_remaining))

  // Private planning must not mutate the causal graph, oplog, or pending queue.
  assert_eq(oplog.op_count(), op_count_before)
  oracle_assert_raw_sequence(oplog.get_frontier_raw(), frontier_before)
  oracle_assert_raw_sequence(
    oracle_raws(oplog.planner.pending_operations()),
    pending_before,
  )

  // The public wrapper must expose the same compatibility order.
  let public_planned = oplog.plan_remote(incoming)
  oracle_assert_op_sequence(public_planned, oracle_planned)

  // Public planning is non-mutating as well; pending membership and its
  // observable flag stay unchanged while the private result reports the
  // hypothetical remainder.
  assert_eq(oplog.op_count(), op_count_before)
  oracle_assert_raw_sequence(oplog.get_frontier_raw(), frontier_before)
  oracle_assert_raw_sequence(
    oracle_raws(oplog.planner.pending_operations()),
    pending_before,
  )
  assert_eq(oplog.has_pending(), !pending_before.is_empty())
}

///|
fn oracle_chain(size : Int) -> Array[@core.Op] {
  let ops : Array[@core.Op] = []
  for i in 0..<size {
    let parents = if i == 0 {
      []
    } else {
      [@core.RawVersion::new("chain", i - 1)]
    }
    ops.push(@core.Op::new_insert(-1, parents, "chain", i, "x", None, None))
  }
  ops
}

///|
fn oracle_reverse(ops : Array[@core.Op]) -> Array[@core.Op] {
  [
    for i in 0..<ops.length() => ops[ops.length() - i - 1]
  ]
}

///|
fn oracle_four_branches(depth : Int) -> Array[@core.Op] {
  let agents = ["branch-a", "branch-b", "branch-c", "branch-d"]
  let ops : Array[@core.Op] = []
  for level in 0..<depth {
    for branch in 0..<agents.length() {
      let parents = if level == 0 {
        []
      } else {
        [@core.RawVersion::new(agents[branch], level - 1)]
      }
      ops.push(
        @core.Op::new_insert(
          -1,
          parents,
          agents[branch],
          level,
          "x",
          None,
          None,
        ),
      )
    }
  }
  ops
}

///|
/// Deterministic adversarial arrival order for generated fixtures.
fn oracle_zigzag(ops : Array[@core.Op]) -> Array[@core.Op] {
  let ordered : Array[@core.Op] = []
  let mut low = 0
  let mut high = ops.length() - 1
  while low <= high {
    ordered.push(ops[high])
    high = high - 1
    if low <= high {
      ordered.push(ops[low])
      low = low + 1
    }
  }
  ordered
}

///|
/// Generate two parent-linked insert chains, an origin-only node, and a join.
fn oracle_generated_insert_dag(size : Int, prefix : String) -> Array[@core.Op] {
  let left_agent = "\{prefix}-left"
  let right_agent = "\{prefix}-right"
  let ops : Array[@core.Op] = []
  for i in 0..<size {
    let left_parents = if i == 0 {
      []
    } else {
      [@core.RawVersion::new(left_agent, i - 1)]
    }
    let right_parents = if i == 0 {
      []
    } else {
      [@core.RawVersion::new(right_agent, i - 1)]
    }
    let left_origin_left = if i == 0 {
      None
    } else {
      Some(@core.RawVersion::new(left_agent, i - 1))
    }
    let left_origin_right = if i < 2 {
      None
    } else {
      Some(@core.RawVersion::new(right_agent, i - 2))
    }
    let right_origin_left = if i == 0 {
      None
    } else {
      Some(@core.RawVersion::new(left_agent, i - 1))
    }
    let right_origin_right = if i < 2 {
      None
    } else {
      Some(@core.RawVersion::new(left_agent, i - 2))
    }
    ops.push(
      @core.Op::new_insert(
        -1, left_parents, left_agent, i, "l", left_origin_left, left_origin_right,
      ),
    )
    ops.push(
      @core.Op::new_insert(
        -1, right_parents, right_agent, i, "r", right_origin_left, right_origin_right,
      ),
    )
  }
  let left_last = @core.RawVersion::new(left_agent, size - 1)
  let right_last = @core.RawVersion::new(right_agent, size - 1)
  let origin_agent = "\{prefix}-origin"
  let origin = @core.Op::new_insert(
    -1,
    [],
    origin_agent,
    0,
    "o",
    Some(left_last),
    Some(right_last),
  )
  ops.push(origin)
  ops.push(
    @core.Op::new_insert(
      -1,
      [left_last, right_last],
      "\{prefix}-join",
      0,
      "j",
      Some(@core.RawVersion::new(origin_agent, 0)),
      Some(left_last),
    ),
  )
  ops
}

///|
test "oracle matches current adversarial before and after parent order" {
  let parent = @core.RawVersion::new("parent", 0)
  let child_before = @core.Op::new_insert(
    -1,
    [parent],
    "child-before",
    0,
    "x",
    None,
    None,
  )
  let independent = @core.Op::new_insert(
    -1,
    [],
    "independent",
    0,
    "x",
    None,
    None,
  )
  let parent_op = @core.Op::new_insert(-1, [], "parent", 0, "x", None, None)
  let child_after = @core.Op::new_insert(
    -1,
    [parent],
    "child-after",
    0,
    "x",
    None,
    None,
  )
  let incoming = [child_before, independent, parent_op, child_after]
  let oplog = OpLog::new("local")
  try! oracle_compare_plan(oplog, incoming, [])
  let planned = try! oplog.plan_remote(incoming)
  oracle_assert_agents(planned, [
    "independent", "parent", "child-after", "child-before",
  ])
}

///|
test "oracle matches current reverse chains across deterministic sizes" {
  for size in [1, 2, 3, 5, 8, 13] {
    let incoming = oracle_reverse(oracle_chain(size))
    let oplog = OpLog::new("local")
    try! oracle_compare_plan(oplog, incoming, [])
    let planned = try! oplog.plan_remote(incoming)
    assert_eq(planned.length(), size)
    for i in 0..<size {
      assert_eq(planned[i].agent(), "chain")
      assert_eq(planned[i].seq(), i)
    }
  }
}

///|
test "oracle matches current four-branch reverse order" {
  let incoming = oracle_reverse(oracle_four_branches(3))
  let oplog = OpLog::new("local")
  try! oracle_compare_plan(oplog, incoming, [])
  let planned = try! oplog.plan_remote(incoming)
  let agents_by_round = ["branch-d", "branch-c", "branch-b", "branch-a"]
  assert_eq(planned.length(), 12)
  for level in 0..<3 {
    for branch in 0..<agents_by_round.length() {
      let index = level * agents_by_round.length() + branch
      assert_eq(planned[index].agent(), agents_by_round[branch])
      assert_eq(planned[index].seq(), level)
    }
  }
}

///|
test "oracle matches current joins" {
  let left = @core.RawVersion::new("left", 0)
  let right = @core.RawVersion::new("right", 0)
  let join = @core.Op::new_insert(-1, [left, right], "join", 0, "j", None, None)
  let left_op = @core.Op::new_insert(-1, [], "left", 0, "l", None, None)
  let right_op = @core.Op::new_insert(-1, [], "right", 0, "r", None, None)
  let incoming = [join, left_op, right_op]
  let oplog = OpLog::new("local")
  try! oracle_compare_plan(oplog, incoming, [])
  let planned = try! oplog.plan_remote(incoming)
  oracle_assert_agents(planned, ["left", "right", "join"])
}

///|
test "oracle matches repeated dependencies across parents and origins" {
  let left = @core.RawVersion::new("repeat-left", 0)
  let right = @core.RawVersion::new("repeat-right", 0)
  let repeated = @core.Op::new_insert(
    -1,
    [left, right, left, right],
    "repeated",
    0,
    "x",
    Some(right),
    Some(left),
  )
  let left_op = @core.Op::new_insert(-1, [], "repeat-left", 0, "l", None, None)
  let right_op = @core.Op::new_insert(
    -1,
    [],
    "repeat-right",
    0,
    "r",
    None,
    None,
  )
  let incoming = [repeated, right_op, left_op]
  let oplog = OpLog::new("local")
  try! oracle_compare_plan(oplog, incoming, [])
  let planned = try! oplog.plan_remote(incoming)
  oracle_assert_agents(planned, ["repeat-right", "repeat-left", "repeated"])
}

///|
test "oracle matches graph-known dependencies and admitted duplicates" {
  let oplog = OpLog::new("local")
  let seed = @core.Op::new_insert(-1, [], "known", 0, "s", None, None)
  ignore(try! oplog.apply_remote(seed))
  let seed_raw = @core.RawVersion::new("known", 0)
  let child = @core.Op::new_insert(
    -1,
    [seed_raw],
    "known-child",
    0,
    "c",
    Some(seed_raw),
    Some(seed_raw),
  )
  try! oracle_compare_plan(oplog, [child], [seed_raw])
  let child_plan = try! oplog.plan_remote([child])
  oracle_assert_agents(child_plan, ["known-child"])

  // An identity already admitted in the graph is a no-op.
  try! oracle_compare_plan(oplog, [seed], [seed_raw])
  let duplicate_plan = try! oplog.plan_remote([seed])
  assert_eq(duplicate_plan.length(), 0)
}

///|
test "oracle matches identical duplicates in an incoming batch" {
  let duplicate = @core.Op::new_insert(-1, [], "duplicate", 0, "x", None, None)
  let oplog = OpLog::new("local")
  try! oracle_compare_plan(oplog, [duplicate, duplicate], [])
  let planned = try! oplog.plan_remote([duplicate, duplicate])
  oracle_assert_op_sequence(planned, [duplicate])
}

///|
test "oracle preserves unknown pending dependencies and pending duplicates" {
  let unknown = @core.RawVersion::new("unknown", 0)
  let pending_op = @core.Op::new_insert(
    -1,
    [unknown],
    "pending",
    0,
    "p",
    None,
    None,
  )
  let oplog = OpLog::new("local")
  ignore(try! oplog.apply_remote(pending_op))
  assert_eq(oplog.has_pending(), true)

  let independent = @core.Op::new_insert(
    -1,
    [],
    "independent-pending-test",
    0,
    "i",
    None,
    None,
  )
  try! oracle_compare_plan(oplog, [independent], [])
  let planned = try! oplog.plan_remote([independent])
  oracle_assert_agents(planned, ["independent-pending-test"])
  oracle_assert_raw_sequence(oracle_raws(oplog.planner.pending_operations()), [
    oracle_raw(pending_op),
  ])

  // The unresolved duplicate remains pending until its dependency arrives;
  // once the dependency is supplied, fixed-point planning admits one identity.
  let unknown_op = @core.Op::new_insert(-1, [], "unknown", 0, "u", None, None)
  try! oracle_compare_plan(oplog, [pending_op, unknown_op], [])
  let resolved_plan = try! oplog.plan_remote([pending_op, unknown_op])
  oracle_assert_agents(resolved_plan, ["unknown", "pending"])
}

///|
test "oracle characterizes malformed delete and undelete admission" {
  let oplog = OpLog::new("local")
  let delete_raw = @core.RawVersion::new("malformed-delete", 0)
  let delete_seed = @core.Op::new_insert(
    -1,
    [],
    "malformed-delete",
    0,
    "d",
    None,
    None,
  )
  let undelete_seed = @core.Op::new_insert(
    -1,
    [],
    "malformed-undelete",
    0,
    "u",
    None,
    None,
  )
  ignore(try! oplog.apply_remote(delete_seed))
  ignore(try! oplog.apply_remote(undelete_seed))

  // Planning compares every retained logical field, while public application
  // preserves its malformed-origin validation boundary before preparation.
  let malformed_delete = @core.Op::new_delete(
    -1,
    [],
    "malformed-delete",
    0,
    None,
  )
  let malformed_undelete = @core.Op::new_undelete(
    -1,
    [],
    "malformed-undelete",
    0,
    None,
  )
  let plan_result : Result[Array[@core.Op], OpLogError] = Ok(
    oplog.plan_remote([malformed_delete, malformed_undelete]),
  ) catch {
    error => Err(error)
  }
  match plan_result {
    Err(OpLogError::ConflictingIdentity(raw~)) => assert_eq(raw, delete_raw)
    _ => fail("expected malformed identity conflict during planning")
  }

  let delete_result : Result[Array[@core.Op], OpLogError] = Ok(
    oplog.apply_remote(malformed_delete),
  ) catch {
    error => Err(error)
  }
  match delete_result {
    Err(OpLogError::MissingOrigin) => ()
    _ => fail("expected MissingOrigin for malformed delete")
  }
  let undelete_result : Result[Array[@core.Op], OpLogError] = Ok(
    oplog.apply_remote(malformed_undelete),
  ) catch {
    error => Err(error)
  }
  match undelete_result {
    Err(OpLogError::MissingOrigin) => ()
    _ => fail("expected MissingOrigin for malformed undelete")
  }
  assert_eq(oplog.op_count(), 2)
  assert_eq(oplog.has_pending(), false)
}

///|
test "oracle orders valid delete and undelete after sole origin dependency" {
  let target_raw = @core.RawVersion::new("target", 0)
  let target = @core.Op::new_insert(-1, [], "target", 0, "t", None, None)
  let delete = @core.Op::new_delete(-1, [], "delete", 0, Some(target_raw))
  let delete_log = OpLog::new("local")
  try! oracle_compare_plan(delete_log, [delete, target], [])
  let delete_plan = try! delete_log.plan_remote([delete, target])
  oracle_assert_op_sequence(delete_plan, [target, delete])

  let undelete = @core.Op::new_undelete(-1, [], "undelete", 0, Some(target_raw))
  let undelete_log = OpLog::new("local")
  try! oracle_compare_plan(undelete_log, [undelete, target], [])
  let undelete_plan = try! undelete_log.plan_remote([undelete, target])
  oracle_assert_op_sequence(undelete_plan, [target, undelete])
}

///|
test "oracle matches apply order while preserving unrelated pending" {
  let parent_raw = @core.RawVersion::new("arriving-parent", 0)
  let parent = @core.Op::new_insert(
    -1,
    [],
    "arriving-parent",
    0,
    "p",
    None,
    None,
  )
  let child = @core.Op::new_insert(
    -1,
    [parent_raw],
    "waiting-child",
    0,
    "c",
    None,
    None,
  )
  let unrelated = @core.Op::new_insert(
    -1,
    [@core.RawVersion::new("still-missing", 0)],
    "unrelated-pending",
    0,
    "u",
    None,
    None,
  )
  let oplog = OpLog::new("local")
  assert_eq((try! oplog.apply_remote(child)).length(), 0)
  assert_eq((try! oplog.apply_remote(unrelated)).length(), 0)

  let candidates = oplog.planner.pending_operations()
  candidates.push(parent)
  let (oracle_planned, oracle_remaining) = try! oracle_plan_remote_candidates(
    candidates.copy(),
    [],
  )
  let public_planned = try! oplog.plan_remote([parent])
  oracle_assert_op_sequence(public_planned, oracle_planned)
  oracle_assert_op_sequence(oracle_remaining, [unrelated])

  let applied = try! oplog.apply_remote(parent)
  oracle_assert_op_sequence(applied, public_planned)
  oracle_assert_op_sequence(
    oplog.planner.pending_operations(),
    oracle_remaining,
  )
  assert_eq(oplog.has_pending(), true)
}

///|
test "oracle differentially covers the public remote admission lifecycle" {
  for size in [1, 2, 4, 5] {
    let prefix = "lifecycle-\{size}"
    let generated = oracle_generated_insert_dag(size, prefix)
    let incoming_base = if size % 2 == 0 {
      oracle_zigzag(generated)
    } else {
      oracle_reverse(generated)
    }
    let incoming = incoming_base.copy()
    // The batch includes a repeated delivery; the oracle must collapse it.
    incoming.push(incoming_base[0])

    let missing_raw = @core.RawVersion::new("\{prefix}-missing", 0)
    let pending_root = @core.Op::new_insert(
      -1,
      [missing_raw],
      "\{prefix}-pending-root",
      0,
      "p",
      None,
      None,
    )
    let pending_child = @core.Op::new_insert(
      -1,
      [oracle_raw(pending_root)],
      "\{prefix}-pending-child",
      0,
      "c",
      None,
      None,
    )
    let oplog = OpLog::new("local")
    // Repeated delivery while unresolved remains one pending identity.
    assert_eq((try! oplog.apply_remote(pending_child)).length(), 0)
    assert_eq((try! oplog.apply_remote(pending_child)).length(), 0)
    assert_eq((try! oplog.apply_remote(pending_root)).length(), 0)
    oracle_assert_raw_sequence(
      oracle_raws(oplog.planner.pending_operations()),
      [oracle_raw(pending_child), oracle_raw(pending_root)],
    )

    let candidates = oplog.planner.pending_operations()
    for op in incoming {
      candidates.push(op)
    }
    let known = oracle_raws(oplog.get_all_ops())
    let (oracle_planned, oracle_remaining) = try! oracle_plan_remote_candidates(
      candidates.copy(),
      known,
    )
    let plan = try! oplog.prepare_remote(incoming)
    oracle_assert_op_sequence(plan.operations().to_owned(), oracle_planned)
    oracle_assert_raw_sequence(
      plan.remaining_raws(oplog.planner),
      oracle_raws(oracle_remaining),
    )
    let committed = try! oplog.commit_remote(plan)
    oracle_assert_op_sequence(committed, oracle_planned)
    oracle_assert_op_sequence(oplog.get_all_ops(), committed)
    assert_eq(oplog.op_count(), oracle_planned.length())
    oracle_assert_raw_sequence(
      oracle_raws(oplog.planner.pending_operations()),
      oracle_raws(oracle_remaining),
    )
    assert_eq(oplog.has_pending(), true)

    // The same admitted identity is a no-op on retransmission.
    let count_before_duplicate = oplog.op_count()
    let duplicate = try! oplog.apply_remote(incoming_base[0])
    assert_eq(duplicate.length(), 0)
    assert_eq(oplog.op_count(), count_before_duplicate)
    oracle_assert_raw_sequence(
      oracle_raws(oplog.planner.pending_operations()),
      oracle_raws(oracle_remaining),
    )

    // A later prepared plan supplies the missing root and drains the retained
    // component in the same fixed-point order.
    let missing_root = @core.Op::new_insert(
      -1,
      [],
      "\{prefix}-missing",
      0,
      "m",
      None,
      None,
    )
    let later_candidates = oplog.planner.pending_operations()
    later_candidates.push(missing_root)
    let later_known = oracle_raws(oplog.get_all_ops())
    let (later_planned, later_remaining) = try! oracle_plan_remote_candidates(
      later_candidates.copy(),
      later_known,
    )
    let later_plan = try! oplog.prepare_remote([missing_root])
    oracle_assert_op_sequence(later_plan.operations().to_owned(), later_planned)
    oracle_assert_raw_sequence(
      later_plan.remaining_raws(oplog.planner),
      oracle_raws(later_remaining),
    )
    let later_committed = try! oplog.commit_remote(later_plan)
    oracle_assert_op_sequence(later_committed, later_planned)
    assert_eq(later_remaining.length(), 0)
    assert_eq(oplog.has_pending(), false)
    assert_eq(
      oplog.op_count(),
      oracle_planned.length() + later_planned.length(),
    )
    let all_after = oplog.get_all_ops()
    assert_eq(
      all_after.length(),
      oracle_planned.length() + later_committed.length(),
    )
    for i in 0..<later_committed.length() {
      assert_eq(
        oracle_raw(all_after[oracle_planned.length() + i]),
        oracle_raw(later_committed[i]),
      )
    }
  }
}

///|
test "oracle matches transitive discard and retry behavior" {
  let root_raw = @core.RawVersion::new("reject-root", 0)
  let child_raw = @core.RawVersion::new("reject-child", 0)
  let ghost_raw = @core.RawVersion::new("reject-ghost", 0)
  let unrelated_ghost = @core.RawVersion::new("unrelated-ghost", 0)
  let root = @core.Op::new_insert(
    -1,
    [ghost_raw],
    "reject-root",
    0,
    "r",
    None,
    None,
  )
  let child = @core.Op::new_insert(
    -1,
    [root_raw],
    "reject-child",
    0,
    "c",
    None,
    None,
  )
  let grandchild = @core.Op::new_insert(
    -1,
    [],
    "reject-grandchild",
    0,
    "g",
    None,
    Some(child_raw),
  )
  let unrelated = @core.Op::new_insert(
    -1,
    [unrelated_ghost],
    "unrelated",
    0,
    "u",
    None,
    None,
  )
  let oplog = OpLog::new("local")
  // Enqueue descendants before the child and rejected root so cleanup needs
  // more than one fixed-point pass.
  ignore(try! oplog.apply_remote(grandchild))
  ignore(try! oplog.apply_remote(child))
  ignore(try! oplog.apply_remote(root))
  ignore(try! oplog.apply_remote(unrelated))
  try! oracle_compare_plan(oplog, [], [])
  oracle_assert_raw_sequence(oracle_raws(oplog.planner.pending_operations()), [
    oracle_raw(grandchild),
    child_raw,
    root_raw,
    oracle_raw(unrelated),
  ])

  oplog.discard_pending_dependents([root_raw])
  oracle_assert_raw_sequence(oracle_raws(oplog.planner.pending_operations()), [
    oracle_raw(unrelated),
  ])
  assert_eq(oplog.has_pending(), true)

  // Re-admit the rejected identity, then retry its dependent identities.
  let retry_root = @core.Op::new_insert(
    -1,
    [],
    "reject-root",
    0,
    "retry-root",
    None,
    None,
  )
  try! oracle_compare_plan(oplog, [retry_root], [])
  ignore(try! oplog.apply_remote(retry_root))
  assert_eq(oplog.has_pending(), true)

  try! oracle_compare_plan(oplog, [child], [root_raw])
  ignore(try! oplog.apply_remote(child))
  try! oracle_compare_plan(oplog, [grandchild], [root_raw, child_raw])
  ignore(try! oplog.apply_remote(grandchild))
  assert_eq(oplog.has_pending(), true)
  oracle_assert_raw_sequence(oracle_raws(oplog.planner.pending_operations()), [
    oracle_raw(unrelated),
  ])
}
