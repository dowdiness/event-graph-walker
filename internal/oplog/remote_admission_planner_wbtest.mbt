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

///|
test "remote admission planner retry acknowledgement tombstones stay nonnegative" {
  let root = @core.Op::new_insert(-1, [], "tombstone-root", 0, "r", None, None)
  let root_raw = remote_admission_raw(root)
  let child = @core.Op::new_insert(
    -1,
    [root_raw],
    "tombstone-child",
    0,
    "c",
    None,
    None,
  )
  let child_raw = remote_admission_raw(child)
  let grandchild = @core.Op::new_insert(
    -1,
    [child_raw],
    "tombstone-grandchild",
    0,
    "g",
    None,
    None,
  )
  let grandchild_raw = remote_admission_raw(grandchild)
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(grandchild, _ => false)
  planner.register_pending(child, _ => false)
  planner.register_pending(root, _ => false)
  planner.reject_pending_dependents([root_raw])
  assert_true(planner.stale_count() >= 0)
  assert_true(planner.stale_count() > 0)

  let retry_root = @core.Op::new_insert(
    -1,
    [],
    "tombstone-root",
    0,
    "retry",
    None,
    None,
  )
  planner.register_pending(retry_root, _ => false)
  assert_eq(planner.arrival_of(root_raw), Some(3))
  assert_true(planner.stale_count() >= 0)
  planner.register_pending(child, _ => false)
  planner.register_pending(grandchild, _ => false)
  assert_true(planner.stale_count() >= 0)

  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  known.add(root_raw)
  planner.acknowledge_admitted(root_raw)
  assert_true(planner.stale_count() >= 0)
  known.add(child_raw)
  planner.acknowledge_admitted(child_raw)
  assert_true(planner.stale_count() >= 0)
  known.add(grandchild_raw)
  planner.acknowledge_admitted(grandchild_raw)
  assert_true(planner.stale_count() >= 0)
  planner.compact(raw => known.contains(raw))
  assert_eq(planner.stale_count(), 0)
  assert_eq(planner.pending_raws().length(), 0)
}

///|
test "remote admission acknowledgement always invalidates prepared plans" {
  let incoming = @core.Op::new_insert(
    -1,
    [],
    "ack-unrelated-incoming",
    0,
    "i",
    None,
    None,
  )
  let planner = RemoteAdmissionPlanner()
  let plan = planner.prepare([incoming], _ => false)
  let generation_before = planner.generation()
  planner.acknowledge_admitted(
    @core.RawVersion::new("ack-unrelated-admitted", 0),
  )
  assert_eq(planner.generation(), generation_before + 1)
  match planner.begin(plan) {
    RemoteAdmissionBeginResult::Stale => ()
    _ => fail("every graph admission must invalidate a prepared plan")
  }
}

///|
test "remote admission planner begins staged nodes exactly once" {
  let parent = @core.Op::new_insert(-1, [], "begin-parent", 0, "p", None, None)
  let child = @core.Op::new_insert(
    -1,
    [remote_admission_raw(parent)],
    "begin-child",
    0,
    "c",
    None,
    None,
  )
  let independent = @core.Op::new_insert(
    -1,
    [],
    "begin-independent",
    0,
    "i",
    None,
    None,
  )
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let planner = RemoteAdmissionPlanner()
  let plan = planner.prepare([child, parent, independent], raw => {
    known.contains(raw)
  })
  let generation_before = planner.generation()
  match planner.begin_plan(plan) {
    RemoteAdmissionBeginResult::Applied => ()
    _ => fail("expected staged registration")
  }
  assert_true(plan.consumed)
  assert_eq(planner.generation(), generation_before + 1)
  planner_assert_raws(planner.pending_raws(), [
    remote_admission_raw(child),
    remote_admission_raw(parent),
    remote_admission_raw(independent),
  ])
  let consumed_generation = planner.generation()
  let consumed_order = planner.pending_order.copy()
  let consumed_stale = planner.stale_count()
  let consumed_next_arrival = planner.next_arrival
  match planner.begin(plan) {
    RemoteAdmissionBeginResult::Consumed => ()
    _ => fail("expected consumed plan")
  }
  assert_eq(planner.generation(), consumed_generation)
  assert_eq(planner.pending_order.length(), consumed_order.length())
  for i in 0..<consumed_order.length() {
    assert_eq(planner.pending_order[i].raw, consumed_order[i].raw)
    assert_eq(planner.pending_order[i].arrival, consumed_order[i].arrival)
  }
  assert_eq(planner.stale_count(), consumed_stale)
  assert_eq(planner.next_arrival, consumed_next_arrival)
  assert_eq(planner.pending_raws().length(), 3)
  for op in plan.planned_operations() {
    let raw = remote_admission_raw(op)
    known.add(raw)
    planner.acknowledge_admitted(raw)
  }
  assert_eq(planner.pending_raws().length(), 0)
}

///|
test "remote admission planner assigns post-staging arrivals on begin" {
  let parent = @core.Op::new_insert(
    -1,
    [],
    "begin-order-parent",
    0,
    "p",
    None,
    None,
  )
  let child = @core.Op::new_insert(
    -1,
    [remote_admission_raw(parent)],
    "begin-order-child",
    0,
    "c",
    None,
    None,
  )
  let independent = @core.Op::new_insert(
    -1,
    [],
    "begin-order-independent",
    0,
    "i",
    None,
    None,
  )
  let direct = @core.Op::new_insert(
    -1,
    [],
    "begin-order-direct",
    0,
    "d",
    None,
    None,
  )
  let staged = [child, parent, independent]
  let planner = RemoteAdmissionPlanner()
  let old_next_arrival = planner.next_arrival
  let plan = planner.prepare(staged, _ => false)
  for i, raw in plan.staged_order {
    let node = plan.staged[raw]
    assert_eq(node.arrival, old_next_arrival + i)
  }
  match planner.begin(plan) {
    RemoteAdmissionBeginResult::Applied => ()
    _ => fail("expected staged registration")
  }
  assert_eq(planner.next_arrival, plan.next_arrival)
  planner.register_pending(direct, _ => false)
  let direct_raw = remote_admission_raw(direct)
  let direct_arrival = planner.arrival_of(direct_raw)
  assert_eq(direct_arrival, Some(plan.next_arrival))
  let candidates = staged.add([direct])
  let (expected, expected_remaining) = oracle_plan_remote_candidates(
    candidates.copy(),
    [],
  )
  let future = planner.prepare([], _ => false)
  planner_assert_raws(
    planner_raws(future.planned_operations()),
    planner_raws(expected),
  )
  planner_assert_raws(
    future.remaining_raws(planner),
    planner_raws(expected_remaining),
  )
}

///|
test "remote admission planner preserves an unacknowledged successful prefix remainder" {
  let incoming = oracle_reverse(oracle_chain(7))
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let planner = RemoteAdmissionPlanner()
  let plan = planner.prepare(incoming, raw => known.contains(raw))
  let planned = plan.planned_operations()
  match planner.begin(plan) {
    RemoteAdmissionBeginResult::Applied => ()
    _ => fail("expected staged registration")
  }
  let prefix_length = 3
  for i in 0..<prefix_length {
    let raw = remote_admission_raw(planned[i])
    known.add(raw)
    planner.acknowledge_admitted(raw)
  }
  let expected_remaining : Array[@core.RawVersion] = [
    for op in incoming if !known.contains(remote_admission_raw(op)) => {
      remote_admission_raw(op)
    }
  ]
  planner_assert_raws(planner.pending_raws(), expected_remaining)
}

///|
test "remote admission planner rejects stale plans before mutation" {
  let first = @core.Op::new_insert(-1, [], "stale-first", 0, "x", None, None)
  let second = @core.Op::new_insert(-1, [], "stale-second", 0, "x", None, None)
  let planner = RemoteAdmissionPlanner()
  let stale_plan = planner.prepare([first], _ => false)
  planner.register_pending(second, _ => false)
  let pending_before = planner.pending_raws()
  let generation_before = planner.generation()
  let order_before = planner.pending_order.copy()
  let stale_before = planner.stale_count()
  match planner.begin(stale_plan) {
    RemoteAdmissionBeginResult::Stale => ()
    _ => fail("expected stale plan")
  }
  planner_assert_raws(planner.pending_raws(), pending_before)
  assert_eq(planner.generation(), generation_before)
  assert_eq(planner.pending_order.length(), order_before.length())
  for i in 0..<order_before.length() {
    assert_eq(planner.pending_order[i].raw, order_before[i].raw)
    assert_eq(planner.pending_order[i].arrival, order_before[i].arrival)
  }
  assert_eq(planner.stale_count(), stale_before)
  assert_true(!stale_plan.consumed)
}

///|
test "remote admission planner rejects malformed staged order before mutation" {
  let live = @core.Op::new_insert(-1, [], "conflict-live", 0, "l", None, None)
  let staged = @core.Op::new_insert(
    -1,
    [],
    "conflict-staged",
    0,
    "s",
    None,
    None,
  )
  let staged_other = @core.Op::new_insert(
    -1,
    [],
    "conflict-staged-other",
    0,
    "o",
    None,
    None,
  )
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(live, _ => false)
  let plan = planner.prepare([staged, staged_other], _ => false)
  plan.staged_order[1] = plan.staged_order[0]
  let pending_before = planner.pending_raws()
  let order_length_before = planner.pending_order.length()
  let generation_before = planner.generation()
  let stale_before = planner.stale_count()
  let next_arrival_before = planner.next_arrival
  match planner.begin(plan) {
    RemoteAdmissionBeginResult::Conflict => ()
    _ => fail("expected malformed staged order conflict")
  }
  planner_assert_raws(planner.pending_raws(), pending_before)
  assert_eq(planner.pending_order.length(), order_length_before)
  assert_eq(planner.generation(), generation_before)
  assert_eq(planner.stale_count(), stale_before)
  assert_eq(planner.next_arrival, next_arrival_before)
  assert_true(!plan.consumed)
}

///|
test "remote admission planner rejects gapped staged arrivals atomically" {
  let live = @core.Op::new_insert(-1, [], "gap-live", 0, "l", None, None)
  let first = @core.Op::new_insert(-1, [], "gap-first", 0, "f", None, None)
  let second = @core.Op::new_insert(-1, [], "gap-second", 0, "s", None, None)
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(live, _ => false)
  let plan = planner.prepare([first, second], _ => false)
  let second_raw = remote_admission_raw(second)
  let second_node = plan.staged[second_raw]
  plan.staged.set(second_raw, {
    ..second_node,
    arrival: second_node.arrival + 1,
  })
  let pending_before = planner.pending_raws()
  let order_before = planner.pending_order.copy()
  let generation_before = planner.generation()
  let stale_before = planner.stale_count()
  let next_arrival_before = planner.next_arrival
  let consumed_before = plan.consumed
  match planner.begin(plan) {
    RemoteAdmissionBeginResult::Conflict => ()
    _ => fail("expected gapped arrival conflict")
  }
  planner_assert_raws(planner.pending_raws(), pending_before)
  assert_eq(planner.pending_order.length(), order_before.length())
  for i in 0..<order_before.length() {
    assert_eq(planner.pending_order[i].raw, order_before[i].raw)
    assert_eq(planner.pending_order[i].arrival, order_before[i].arrival)
  }
  assert_eq(planner.generation(), generation_before)
  assert_eq(planner.stale_count(), stale_before)
  assert_eq(planner.next_arrival, next_arrival_before)
  assert_eq(plan.consumed, consumed_before)
}

///|
test "remote admission planner rejects staged raw/op mismatch atomically" {
  let live = @core.Op::new_insert(-1, [], "raw-live", 0, "l", None, None)
  let first = @core.Op::new_insert(-1, [], "raw-first", 0, "f", None, None)
  let second = @core.Op::new_insert(-1, [], "raw-second", 0, "s", None, None)
  let mismatch = @core.Op::new_insert(-1, [], "raw-other", 0, "x", None, None)
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(live, _ => false)
  let plan = planner.prepare([first, second], _ => false)
  let second_raw = remote_admission_raw(second)
  let second_node = plan.staged[second_raw]
  plan.staged.set(second_raw, { ..second_node, op: mismatch })
  let pending_before = planner.pending_raws()
  let order_before = planner.pending_order.copy()
  let generation_before = planner.generation()
  let stale_before = planner.stale_count()
  let next_arrival_before = planner.next_arrival
  let consumed_before = plan.consumed
  match planner.begin(plan) {
    RemoteAdmissionBeginResult::Conflict => ()
    _ => fail("expected raw/op mismatch conflict")
  }
  planner_assert_raws(planner.pending_raws(), pending_before)
  assert_eq(planner.pending_order.length(), order_before.length())
  for i in 0..<order_before.length() {
    assert_eq(planner.pending_order[i].raw, order_before[i].raw)
    assert_eq(planner.pending_order[i].arrival, order_before[i].arrival)
  }
  assert_eq(planner.generation(), generation_before)
  assert_eq(planner.stale_count(), stale_before)
  assert_eq(planner.next_arrival, next_arrival_before)
  assert_eq(plan.consumed, consumed_before)
}

///|
test "remote admission planner compacts stale indexes and preserves live arrivals" {
  let root = @core.Op::new_insert(-1, [], "compact-root", 0, "r", None, None)
  let child = @core.Op::new_insert(
    -1,
    [remote_admission_raw(root)],
    "compact-child",
    0,
    "c",
    None,
    None,
  )
  let unrelated_dependency = @core.RawVersion::new(
    "compact-unrelated-dependency", 0,
  )
  let unrelated = @core.Op::new_insert(
    -1,
    [unrelated_dependency],
    "compact-unrelated",
    0,
    "u",
    None,
    None,
  )
  let ready = @core.Op::new_insert(-1, [], "compact-ready", 0, "q", None, None)
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(child, _ => false)
  planner.register_pending(root, _ => false)
  planner.register_pending(unrelated, _ => false)
  planner.register_pending(ready, _ => false)
  planner.reject_pending_dependents([remote_admission_raw(root)])
  let live_arrival_before = planner.arrival_of(remote_admission_raw(unrelated))
  let generation_before = planner.generation()
  assert_true(planner.stale_count() > 0)
  planner.compact(_ => false)
  assert_eq(planner.stale_count(), 0)
  assert_eq(planner.generation(), generation_before + 1)
  assert_eq(
    planner.arrival_of(remote_admission_raw(unrelated)),
    live_arrival_before,
  )
  planner_assert_raws(planner.pending_raws(), [
    remote_admission_raw(unrelated),
    remote_admission_raw(ready),
  ])
  let before = planner.prepare([], _ => false)
  planner.compact(_ => false)
  let after = planner.prepare([], _ => false)
  planner_assert_raws(
    planner_raws(before.planned_operations()),
    planner_raws(after.planned_operations()),
  )
  planner_assert_raws(
    before.remaining_raws(planner),
    after.remaining_raws(planner),
  )
  planner_assert_raws(planner_raws(before.planned_operations()), [
    remote_admission_raw(ready),
  ])
  planner_assert_raws(before.remaining_raws(planner), [
    remote_admission_raw(unrelated),
  ])
}

///|
test "remote admission planner filters graph-known nodes during compaction" {
  let dependency = @core.RawVersion::new("compact-known-dependency", 0)
  let waiting = @core.Op::new_insert(
    -1,
    [dependency],
    "compact-known-waiter",
    0,
    "w",
    None,
    None,
  )
  let known_node = @core.Op::new_insert(
    -1,
    [],
    "compact-known-node",
    0,
    "k",
    None,
    None,
  )
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(waiting, _ => false)
  planner.register_pending(known_node, _ => false)
  let waiting_arrival = planner.arrival_of(remote_admission_raw(waiting))
  known.add(remote_admission_raw(known_node))
  known.add(dependency)
  planner.compact(raw => known.contains(raw))
  assert_eq(planner.arrival_of(remote_admission_raw(known_node)), None)
  assert_eq(planner.arrival_of(remote_admission_raw(waiting)), waiting_arrival)
  let plan = planner.prepare([], raw => known.contains(raw))
  planner_assert_raws(planner_raws(plan.planned_operations()), [
    remote_admission_raw(waiting),
  ])
}

///|
test "remote admission planner maybe_compact uses bounded stale policy" {
  let planner = RemoteAdmissionPlanner()
  for i in 0..<511 {
    let op = @core.Op::new_insert(-1, [], "maybe-compact", i, "x", None, None)
    planner.register_pending(op, _ => false)
    planner.acknowledge_admitted(remote_admission_raw(op))
  }
  let generation_before = planner.generation()
  assert_eq(planner.stale_count(), 1022)
  assert_true(!planner.maybe_compact(_ => false))
  assert_eq(planner.generation(), generation_before)

  let threshold_op = @core.Op::new_insert(
    -1,
    [],
    "maybe-compact",
    511,
    "x",
    None,
    None,
  )
  planner.register_pending(threshold_op, _ => false)
  planner.acknowledge_admitted(remote_admission_raw(threshold_op))
  assert_eq(planner.stale_count(), 1024)
  assert_true(planner.maybe_compact(_ => false))
  assert_eq(planner.stale_count(), 0)
}

///|
test "remote admission planner maybe_compact pins live ratio boundary" {
  let missing = @core.RawVersion::new("ratio-missing", 0)
  let planner = RemoteAdmissionPlanner()
  for i in 0..<513 {
    planner.register_pending(
      @core.Op::new_insert(-1, [missing], "ratio-live", i, "x", None, None),
      _ => false,
    )
  }
  for i in 0..<512 {
    let churn = @core.Op::new_insert(-1, [], "ratio-stale", i, "x", None, None)
    planner.register_pending(churn, _ => false)
    planner.acknowledge_admitted(remote_admission_raw(churn))
  }
  assert_eq(planner.pending_raws().length(), 513)
  assert_eq(planner.stale_count(), 1024)
  assert_true(!planner.maybe_compact(_ => false))

  let trigger = @core.Op::new_insert(
    -1,
    [],
    "ratio-stale",
    512,
    "x",
    None,
    None,
  )
  planner.register_pending(trigger, _ => false)
  planner.acknowledge_admitted(remote_admission_raw(trigger))
  assert_eq(planner.stale_count(), 1026)
  assert_true(planner.maybe_compact(_ => false))
  assert_eq(planner.stale_count(), 0)
  assert_eq(planner.pending_raws().length(), 513)
}
