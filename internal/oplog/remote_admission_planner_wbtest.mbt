///| Differential white-box coverage for the isolated planner.

///|
fn planner_raws(ops : Array[@core.Op]) -> Array[@core.RawVersion] {
  [
    for op in ops => remote_admission_raw(op)
  ]
}

///|
fn planner_assert_raws(
  actual : Array[@core.RawVersion],
  expected : Array[@core.RawVersion],
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    assert_eq(actual[i], expected[i])
  }
}

///|
fn planner_compare(
  candidates : Array[@core.Op],
  pending_count : Int,
  known : Array[@core.RawVersion],
) -> Unit raise {
  let known_set : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet(known)
  let planner = RemoteAdmissionPlanner()
  for i in 0..<pending_count {
    planner.register_pending(candidates[i], raw => known_set.contains(raw))
  }
  let incoming : Array[@core.Op] = []
  for i in pending_count..<candidates.length() {
    incoming.push(candidates[i])
  }
  let (expected_planned, expected_remaining) = oracle_plan_remote_candidates(
    candidates.copy(),
    known,
  )
  let before_pending = planner.pending_raws()
  let before_generation = planner.generation()
  let plan = planner.prepare(incoming, raw => known_set.contains(raw))
  let actual_planned = plan.planned_operations()
  planner_assert_raws(
    planner_raws(actual_planned),
    planner_raws(expected_planned),
  )
  planner_assert_raws(
    plan.remaining_raws(planner),
    planner_raws(expected_remaining),
  )
  planner_assert_raws(planner.pending_raws(), before_pending)
  assert_eq(planner.generation(), before_generation)
}

///|
fn planner_chain(size : Int) -> Array[@core.Op] {
  oracle_chain(size)
}

///|
test "remote admission planner matches adversarial and reverse order" {
  let parent = @core.RawVersion::new("parent", 0)
  let candidates = [
    @core.Op::new_insert(-1, [parent], "child-before", 0, "x", None, None),
    @core.Op::new_insert(-1, [], "independent", 0, "x", None, None),
    @core.Op::new_insert(-1, [], "parent", 0, "x", None, None),
    @core.Op::new_insert(-1, [parent], "child-after", 0, "x", None, None),
  ]
  planner_compare(candidates, 0, [])
  for size in [1, 2, 3, 5, 8, 13, 32] {
    let chain = planner_chain(size)
    planner_compare(oracle_reverse(chain), 0, [])
  }
}

///|
test "remote admission planner matches joins and repeated origin edges" {
  let left = @core.RawVersion::new("left", 0)
  let right = @core.RawVersion::new("right", 0)
  let join = @core.Op::new_insert(
    -1,
    [left, right, left, right],
    "join",
    0,
    "j",
    Some(right),
    Some(left),
  )
  let candidates = [
    join,
    @core.Op::new_insert(-1, [], "left", 0, "l", None, None),
    @core.Op::new_insert(-1, [], "right", 0, "r", None, None),
  ]
  planner_compare(candidates, 0, [])
  let target = @core.RawVersion::new("target", 0)
  let delete = @core.Op::new_delete(-1, [], "delete", 0, Some(target))
  let target_op = @core.Op::new_insert(-1, [], "target", 0, "t", None, None)
  planner_compare([delete, target_op], 0, [])
}

///|
test "remote admission planner suppresses identical pending and admitted duplicates" {
  let duplicate = @core.Op::new_insert(-1, [], "duplicate", 0, "x", None, None)
  planner_compare([duplicate, duplicate], 0, [])
  planner_compare([duplicate, duplicate], 1, [])
  planner_compare([duplicate], 0, [remote_admission_raw(duplicate)])
}

///|
test "remote admission planner preserves unknown pending dependencies" {
  let unknown = @core.RawVersion::new("unknown", 0)
  let waiting = @core.Op::new_insert(
    -1,
    [unknown],
    "waiting",
    0,
    "w",
    None,
    None,
  )
  let independent = @core.Op::new_insert(
    -1,
    [],
    "independent",
    0,
    "i",
    None,
    None,
  )
  planner_compare([waiting, independent], 1, [])
  let parent = @core.Op::new_insert(-1, [], "unknown", 0, "u", None, None)
  planner_compare([waiting, parent], 1, [])
}

///|
test "remote admission planner handles graph-known dependencies" {
  let known = @core.RawVersion::new("known", 0)
  let known_child = @core.Op::new_insert(
    -1,
    [known],
    "known-child",
    0,
    "c",
    Some(known),
    Some(known),
  )
  planner_compare([known_child], 0, [known])
  let admitted = @core.Op::new_insert(-1, [], "known", 0, "s", None, None)
  planner_compare([admitted], 0, [known])
}

///|
test "remote admission planner rejection closure is attempt scoped" {
  let root = @core.RawVersion::new("root", 0)
  let child = @core.RawVersion::new("child", 0)
  let root_op = @core.Op::new_insert(-1, [], "root", 0, "r", None, None)
  let child_op = @core.Op::new_insert(-1, [root], "child", 0, "c", None, None)
  let grandchild_op = @core.Op::new_insert(
    -1,
    [child],
    "grandchild",
    0,
    "g",
    None,
    None,
  )
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(grandchild_op, raw => {
    ignore(raw)
    false
  })
  planner.register_pending(child_op, raw => {
    ignore(raw)
    false
  })
  planner.register_pending(root_op, raw => {
    ignore(raw)
    false
  })
  planner.reject_pending_dependents([root])
  assert_eq(planner.pending_raws().length(), 0)
  let retry_root = @core.Op::new_insert(-1, [], "root", 0, "retry", None, None)
  planner.register_pending(retry_root, raw => {
    ignore(raw)
    false
  })
  assert_eq(planner.pending_raws(), [root])
  assert_eq(planner.arrival_of(root), Some(3))
}

///|
test "remote admission planner prepare is non-mutating" {
  let chain = oracle_reverse(planner_chain(16))
  let known_set : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let planner = RemoteAdmissionPlanner()
  for i in 0..<4 {
    planner.register_pending(chain[i], raw => known_set.contains(raw))
  }
  let incoming : Array[@core.Op] = []
  for i in 4..<chain.length() {
    incoming.push(chain[i])
  }
  let pending_before = planner.pending_raws()
  let generation_before = planner.generation()
  let arrival_before = planner.next_arrival
  let plan = planner.prepare(incoming, raw => known_set.contains(raw))
  ignore(plan.planned_operations())
  planner_assert_raws(planner.pending_raws(), pending_before)
  assert_eq(planner.generation(), generation_before)
  assert_eq(planner.next_arrival, arrival_before)
}

///|
test "remote admission planner does not depend on map insertion order" {
  let parent = @core.RawVersion::new("map-parent", 0)
  let child = @core.Op::new_insert(
    -1,
    [parent],
    "map-child",
    0,
    "c",
    None,
    None,
  )
  let independent = @core.Op::new_insert(
    -1,
    [],
    "map-independent",
    0,
    "i",
    None,
    None,
  )
  let parent_op = @core.Op::new_insert(-1, [], "map-parent", 0, "p", None, None)
  let candidates = [child, independent, parent_op]
  let planner_a = RemoteAdmissionPlanner()
  for op in candidates {
    planner_a.register_pending(op, _ => false)
  }
  let planner_b = RemoteAdmissionPlanner()
  let scratch = @core.Op::new_insert(-1, [], "scratch", 0, "s", None, None)
  planner_b.register_pending(scratch, _ => false)
  planner_b.reject_pending_dependents([remote_admission_raw(scratch)])
  for op in candidates {
    planner_b.register_pending(op, _ => false)
  }
  let known : Array[@core.RawVersion] = []
  let (expected, _) = oracle_plan_remote_candidates(candidates.copy(), known)
  let plan_a = planner_a.prepare([], _ => false)
  let plan_b = planner_b.prepare([], _ => false)
  planner_assert_raws(
    planner_raws(plan_a.planned_operations()),
    planner_raws(expected),
  )
  planner_assert_raws(
    planner_raws(plan_b.planned_operations()),
    planner_raws(expected),
  )
}

///|
test "remote admission planner matches multiple branching sizes" {
  for depth in [1, 2, 3, 5, 8] {
    let branches = oracle_reverse(oracle_four_branches(depth))
    planner_compare(branches, 0, [])
  }
}

///|
test "remote admission planner accumulates multi-dependency rounds" {
  let left_raw = @core.RawVersion::new("round-left", 0)
  let right_raw = @core.RawVersion::new("round-right", 0)
  let seed_raw = @core.RawVersion::new("round-seed", 0)
  let join = @core.Op::new_insert(
    -1,
    [left_raw, right_raw],
    "round-join",
    0,
    "j",
    None,
    None,
  )
  let left = @core.Op::new_insert(
    -1,
    [seed_raw],
    "round-left",
    0,
    "l",
    None,
    None,
  )
  let right = @core.Op::new_insert(-1, [], "round-right", 0, "r", None, None)
  let seed = @core.Op::new_insert(-1, [], "round-seed", 0, "s", None, None)
  let candidates = [join, left, right, seed]
  let (expected, expected_remaining) = oracle_plan_remote_candidates(
    candidates.copy(),
    [],
  )
  planner_compare(candidates, 0, [])
  planner_assert_raws(planner_raws(expected), [
    @core.RawVersion::new("round-right", 0),
    @core.RawVersion::new("round-seed", 0),
    @core.RawVersion::new("round-left", 0),
    @core.RawVersion::new("round-join", 0),
  ])
  assert_eq(expected_remaining.length(), 0)
}

///|
test "remote admission planner rejects and retries with fresh waiter identities" {
  let root_raw = @core.RawVersion::new("retry-root", 0)
  let child_raw = @core.RawVersion::new("retry-child", 0)
  let grandchild_raw = @core.RawVersion::new("retry-grandchild", 0)
  let root = @core.Op::new_insert(-1, [], "retry-root", 0, "r", None, None)
  let child = @core.Op::new_insert(
    -1,
    [root_raw],
    "retry-child",
    0,
    "c",
    None,
    None,
  )
  let grandchild = @core.Op::new_insert(
    -1,
    [child_raw],
    "retry-grandchild",
    0,
    "g",
    None,
    None,
  )
  let unrelated = @core.Op::new_insert(
    -1,
    [],
    "retry-unrelated",
    0,
    "u",
    None,
    None,
  )
  let planner = RemoteAdmissionPlanner()
  // Descendants arrive before the root, leaving a ready root entry that will
  // become stale when the closure is rejected.
  planner.register_pending(grandchild, _ => false)
  planner.register_pending(child, _ => false)
  planner.register_pending(root, _ => false)
  planner.reject_pending_dependents([root_raw])
  planner.register_pending(unrelated, _ => false)
  let retry_root = @core.Op::new_insert(
    -1,
    [],
    "retry-root",
    0,
    "retry",
    None,
    None,
  )
  planner.register_pending(retry_root, _ => false)
  planner.register_pending(child, _ => false)
  planner.register_pending(grandchild, _ => false)

  let candidates = [unrelated, retry_root, child, grandchild]
  let (expected, expected_remaining) = oracle_plan_remote_candidates(
    candidates.copy(),
    [],
  )
  let plan = planner.prepare([], _ => false)
  planner_assert_raws(
    planner_raws(plan.planned_operations()),
    planner_raws(expected),
  )
  planner_assert_raws(
    plan.remaining_raws(planner),
    planner_raws(expected_remaining),
  )
  assert_eq(expected_remaining.length(), 0)
  // The unrelated ready node proves the retried root uses its new arrival;
  // the retry closure still follows it without count or remaining drift.
  let actual_raws = planner_raws(plan.planned_operations())
  assert_eq(actual_raws[1], root_raw)
  assert_eq(actual_raws[2], child_raw)
  assert_eq(actual_raws[3], grandchild_raw)
}

///|
test "remote admission planner ignores reversed dependency insertion order" {
  let left = @core.RawVersion::new("order-left", 0)
  let right = @core.RawVersion::new("order-right", 0)
  let forward = @core.Op::new_insert(
    -1,
    [left, right, left, right],
    "order-join",
    0,
    "j",
    Some(right),
    Some(left),
  )
  let reverse = @core.Op::new_insert(
    -1,
    [right, left, right, left],
    "order-join",
    0,
    "j",
    Some(left),
    Some(right),
  )
  let left_op = @core.Op::new_insert(-1, [], "order-left", 0, "l", None, None)
  let right_op = @core.Op::new_insert(-1, [], "order-right", 0, "r", None, None)
  let forward_candidates = [forward, left_op, right_op]
  let reverse_candidates = [reverse, left_op, right_op]
  let (expected, expected_remaining) = oracle_plan_remote_candidates(
    forward_candidates.copy(),
    [],
  )
  planner_compare(forward_candidates, 0, [])
  planner_compare(reverse_candidates, 0, [])
  assert_eq(expected_remaining.length(), 0)
  planner_assert_raws(planner_raws(expected), [
    @core.RawVersion::new("order-left", 0),
    @core.RawVersion::new("order-right", 0),
    @core.RawVersion::new("order-join", 0),
  ])
}

///|
test "remote admission acknowledgement wakes a child after external parent admission" {
  let parent = @core.RawVersion::new("ack-parent", 0)
  let child = @core.Op::new_insert(
    -1,
    [parent],
    "ack-child",
    0,
    "c",
    None,
    None,
  )
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(child, raw => known.contains(raw))
  known.add(parent)
  planner.acknowledge_admitted(parent)
  let plan = planner.prepare([], raw => known.contains(raw))
  let (expected_planned, expected_remaining) = oracle_plan_remote_candidates(
    [child],
    [parent],
  )
  planner_assert_raws(
    planner_raws(plan.planned_operations()),
    planner_raws(expected_planned),
  )
  planner_assert_raws(
    plan.remaining_raws(planner),
    planner_raws(expected_remaining),
  )
}

///|
test "remote admission acknowledgement removes an admitted pending duplicate" {
  let parent = @core.Op::new_insert(
    -1,
    [],
    "ack-duplicate-parent",
    0,
    "p",
    None,
    None,
  )
  let parent_raw = remote_admission_raw(parent)
  let child = @core.Op::new_insert(
    -1,
    [parent_raw],
    "ack-duplicate-child",
    0,
    "c",
    None,
    None,
  )
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(parent, raw => known.contains(raw))
  planner.register_pending(child, raw => known.contains(raw))
  known.add(parent_raw)
  planner.acknowledge_admitted(parent_raw)
  planner_assert_raws(planner.pending_raws(), [remote_admission_raw(child)])
  let plan = planner.prepare([], raw => known.contains(raw))
  let (expected_planned, expected_remaining) = oracle_plan_remote_candidates(
    [parent, child],
    [parent_raw],
  )
  planner_assert_raws(
    planner_raws(plan.planned_operations()),
    planner_raws(expected_planned),
  )
  planner_assert_raws(
    plan.remaining_raws(planner),
    planner_raws(expected_remaining),
  )
}

///|
test "remote admission acknowledgement invalidates an earlier plan generation" {
  let parent = @core.RawVersion::new("ack-stale-parent", 0)
  let child = @core.Op::new_insert(
    -1,
    [parent],
    "ack-stale-child",
    0,
    "c",
    None,
    None,
  )
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(child, raw => known.contains(raw))
  let old_plan = planner.prepare([], raw => known.contains(raw))
  let old_generation = old_plan.generation()
  assert_eq(old_generation, planner.generation())
  known.add(parent)
  planner.acknowledge_admitted(parent)
  assert_true(old_generation != planner.generation())
  assert_true(old_plan.generation() != planner.generation())
  let plan = planner.prepare([], raw => known.contains(raw))
  let (expected_planned, expected_remaining) = oracle_plan_remote_candidates(
    [child],
    [parent],
  )
  planner_assert_raws(
    planner_raws(plan.planned_operations()),
    planner_raws(expected_planned),
  )
  planner_assert_raws(
    plan.remaining_raws(planner),
    planner_raws(expected_remaining),
  )
}
