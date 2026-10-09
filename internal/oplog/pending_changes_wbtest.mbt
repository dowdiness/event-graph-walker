///| Differential white-box coverage for the isolated pending-changes owner.

///|
fn pending_changes_raws(ops : Array[@core.Op]) -> Array[@core.RawVersion] {
  [
    for op in ops => apply_changes_raw(op)
  ]
}

///|
fn pending_changes_assert_raws(
  actual : Array[@core.RawVersion],
  expected : Array[@core.RawVersion],
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    assert_eq(actual[i], expected[i])
  }
}

///|
fn pending_changes_compare(
  candidates : Array[@core.Op],
  pending_count : Int,
  known : Array[@core.RawVersion],
) -> Unit raise {
  let known_set : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet(known)
  let pending_changes = PendingChanges()
  for i in 0..<pending_count {
    pending_changes.register_pending(candidates[i], raw => {
      known_set.contains(raw)
    })
  }
  let incoming : Array[@core.Op] = []
  for i in pending_count..<candidates.length() {
    incoming.push(candidates[i])
  }
  let (expected_planned, expected_remaining) = oracle_plan_remote_candidates(
    candidates.copy(),
    known,
  )
  let before_pending = pending_changes.pending_raws()
  let before_generation = pending_changes.generation()
  let plan = pending_changes.prepare(incoming, raw => known_set.contains(raw))
  let actual_planned = plan.planned_operations()
  pending_changes_assert_raws(
    pending_changes_raws(actual_planned),
    pending_changes_raws(expected_planned),
  )
  pending_changes_assert_raws(
    plan.remaining_raws(pending_changes),
    pending_changes_raws(expected_remaining),
  )
  pending_changes_assert_raws(pending_changes.pending_raws(), before_pending)
  assert_eq(pending_changes.generation(), before_generation)
}

///|
fn pending_changes_chain(size : Int) -> Array[@core.Op] {
  oracle_chain(size)
}

///|
test "remote change application pending-changes owner matches adversarial and reverse order" {
  let parent = @core.RawVersion("parent", 0)
  let candidates = [
    @core.Op::insert(-1, [parent], "child-before", 0, "x", None, None),
    @core.Op::insert(-1, [], "independent", 0, "x", None, None),
    @core.Op::insert(-1, [], "parent", 0, "x", None, None),
    @core.Op::insert(-1, [parent], "child-after", 0, "x", None, None),
  ]
  pending_changes_compare(candidates, 0, [])
  for size in [1, 2, 3, 5, 8, 13, 32] {
    let chain = pending_changes_chain(size)
    pending_changes_compare(oracle_reverse(chain), 0, [])
  }
}

///|
test "remote change application dependencies preserve first occurrence order" {
  let first = @core.RawVersion("dependency-first", 0)
  let second = @core.RawVersion("dependency-second", 0)
  let third = @core.RawVersion("dependency-third", 0)
  let parent_origin_overlap = @core.Op::insert(
    -1,
    [first, second, first],
    "parent-origin-overlap",
    0,
    "x",
    Some(second),
    Some(third),
  )
  pending_changes_assert_raws(
    apply_changes_dependencies(parent_origin_overlap),
    [first, second, third],
  )
  let repeated_origins = @core.Op::insert(
    -1,
    [first],
    "repeated-origins",
    0,
    "x",
    Some(third),
    Some(third),
  )
  pending_changes_assert_raws(apply_changes_dependencies(repeated_origins), [
    first, third,
  ])
}

///|
test "remote change application pending-changes owner matches joins and repeated origin edges" {
  let left = @core.RawVersion("left", 0)
  let right = @core.RawVersion("right", 0)
  let join = @core.Op::insert(
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
    @core.Op::insert(-1, [], "left", 0, "l", None, None),
    @core.Op::insert(-1, [], "right", 0, "r", None, None),
  ]
  pending_changes_compare(candidates, 0, [])
  let target = @core.RawVersion("target", 0)
  let delete = @core.Op::delete(-1, [], "delete", 0, Some(target))
  let target_op = @core.Op::insert(-1, [], "target", 0, "t", None, None)
  pending_changes_compare([delete, target_op], 0, [])
}

///|
test "remote change application pending-changes owner suppresses identical pending and recorded duplicates" {
  let duplicate = @core.Op::insert(-1, [], "duplicate", 0, "x", None, None)
  pending_changes_compare([duplicate, duplicate], 0, [])
  pending_changes_compare([duplicate, duplicate], 1, [])
  pending_changes_compare([duplicate], 0, [apply_changes_raw(duplicate)])
}

///|
/// PendingChanges preparation seam: fast staging rejects a conflicting repeat atomically.
test "remote change application fast staging raises conflicting identity" {
  let first = @core.Op::insert(-1, [], "fast-conflict", 0, "a", None, None)
  let second = @core.Op::insert(-1, [], "fast-conflict", 0, "b", None, None)
  let pending_changes = PendingChanges()
  let result : Result[ApplyChanges, OpLogError] = Ok(
    pending_changes.prepare([first, second], _ => false),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::ConflictingIdentity(raw~)) =>
      assert_eq(raw, apply_changes_raw(first))
    _ => fail("expected fast staging conflict")
  }
  assert_eq(pending_changes.pending_raws().length(), 0)
}

///|
/// PendingChanges preparation seam: incoming full operations remain comparable under change application hints.
test "remote change application fast staging compares recorded repeated payloads" {
  let first = @core.Op::insert(-1, [], "admitted-repeat", 0, "a", None, None)
  let second = @core.Op::insert(-1, [], "admitted-repeat", 0, "b", None, None)
  let expected_raw = apply_changes_raw(first)
  let pending_changes = PendingChanges()
  let result : Result[ApplyChanges, OpLogError] = Ok(
    pending_changes.prepare([first, second], candidate => {
      candidate == expected_raw
    }),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::ConflictingIdentity(raw~)) => assert_eq(raw, expected_raw)
    _ => fail("expected recorded repeated conflict")
  }
  assert_eq(pending_changes.pending_raws().length(), 0)
}

///|
/// PendingChanges preparation seam: canonical pending payload remains authoritative.
test "remote change application canonical pending raises conflicting identity" {
  let pending = @core.Op::insert(
    -1,
    [@core.RawVersion("pending-unknown", 0)],
    "canonical-conflict",
    0,
    "authoritative",
    None,
    None,
  )
  let incoming = @core.Op::insert(
    41,
    [@core.RawVersion("pending-unknown", 0)],
    "canonical-conflict",
    0,
    "different",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  pending_changes.register_pending(pending, _ => false)
  let before = pending_changes.pending_operations()
  let result : Result[ApplyChanges, OpLogError] = Ok(
    pending_changes.prepare([incoming], _ => false),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::ConflictingIdentity(raw~)) =>
      assert_eq(raw, apply_changes_raw(pending))
    _ => fail("expected canonical pending conflict")
  }
  let after = pending_changes.pending_operations()
  assert_eq(after.length(), before.length())
  assert_eq(after[0].content(), before[0].content())
  assert_eq(after[0].lv(), before[0].lv())
}

///|
/// PendingChanges preparation seam: an overlay repeat is checked before readiness.
test "remote change application overlay staging raises conflicting identity" {
  let missing = @core.RawVersion("overlay-missing", 0)
  let first = @core.Op::insert(
    -1,
    [missing],
    "overlay-conflict",
    0,
    "a",
    None,
    None,
  )
  let second = @core.Op::insert(
    -1,
    [missing],
    "overlay-conflict",
    0,
    "b",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  let result : Result[ApplyChanges, OpLogError] = Ok(
    pending_changes.prepare([first, second], _ => false),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::ConflictingIdentity(raw~)) =>
      assert_eq(raw, apply_changes_raw(first))
    _ => fail("expected overlay staging conflict")
  }
  assert_eq(pending_changes.pending_raws().length(), 0)
}

///|
test "remote change application pending-changes owner preserves unknown pending dependencies" {
  let unknown = @core.RawVersion("unknown", 0)
  let waiting = @core.Op::insert(-1, [unknown], "waiting", 0, "w", None, None)
  let independent = @core.Op::insert(-1, [], "independent", 0, "i", None, None)
  pending_changes_compare([waiting, independent], 1, [])
  let parent = @core.Op::insert(-1, [], "unknown", 0, "u", None, None)
  pending_changes_compare([waiting, parent], 1, [])
}

///|
test "remote change application pending-changes owner handles graph-known dependencies" {
  let known = @core.RawVersion("known", 0)
  let known_child = @core.Op::insert(
    -1,
    [known],
    "known-child",
    0,
    "c",
    Some(known),
    Some(known),
  )
  pending_changes_compare([known_child], 0, [known])
  let applied = @core.Op::insert(-1, [], "known", 0, "s", None, None)
  pending_changes_compare([applied], 0, [known])
}

///|
test "remote change application pending-changes owner rejection closure is attempt scoped" {
  let root = @core.RawVersion("root", 0)
  let child = @core.RawVersion("child", 0)
  let root_op = @core.Op::insert(-1, [], "root", 0, "r", None, None)
  let child_op = @core.Op::insert(-1, [root], "child", 0, "c", None, None)
  let grandchild_op = @core.Op::insert(
    -1,
    [child],
    "grandchild",
    0,
    "g",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  pending_changes.register_pending(grandchild_op, raw => {
    ignore(raw)
    false
  })
  pending_changes.register_pending(child_op, raw => {
    ignore(raw)
    false
  })
  pending_changes.register_pending(root_op, raw => {
    ignore(raw)
    false
  })
  pending_changes.reject_pending_dependents([root])
  assert_eq(pending_changes.pending_raws().length(), 0)
  let retry_root = @core.Op::insert(-1, [], "root", 0, "retry", None, None)
  pending_changes.register_pending(retry_root, raw => {
    ignore(raw)
    false
  })
  assert_eq(pending_changes.pending_raws(), [root])
  assert_eq(pending_changes.arrival_of(root), Some(3))
}

///|
test "remote change application pending-changes owner prepare is non-mutating" {
  let chain = oracle_reverse(pending_changes_chain(16))
  let known_set : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let pending_changes = PendingChanges()
  for i in 0..<4 {
    pending_changes.register_pending(chain[i], raw => known_set.contains(raw))
  }
  let incoming : Array[@core.Op] = []
  for i in 4..<chain.length() {
    incoming.push(chain[i])
  }
  let pending_before = pending_changes.pending_raws()
  let generation_before = pending_changes.generation()
  let arrival_before = pending_changes.next_arrival
  let plan = pending_changes.prepare(incoming, raw => known_set.contains(raw))
  ignore(plan.planned_operations())
  pending_changes_assert_raws(pending_changes.pending_raws(), pending_before)
  assert_eq(pending_changes.generation(), generation_before)
  assert_eq(pending_changes.next_arrival, arrival_before)
}

///|
test "remote change application pending-changes owner does not depend on map insertion order" {
  let parent = @core.RawVersion("map-parent", 0)
  let child = @core.Op::insert(-1, [parent], "map-child", 0, "c", None, None)
  let independent = @core.Op::insert(
    -1,
    [],
    "map-independent",
    0,
    "i",
    None,
    None,
  )
  let parent_op = @core.Op::insert(-1, [], "map-parent", 0, "p", None, None)
  let candidates = [child, independent, parent_op]
  let pending_changes_a = PendingChanges()
  for op in candidates {
    pending_changes_a.register_pending(op, _ => false)
  }
  let pending_changes_b = PendingChanges()
  let scratch = @core.Op::insert(-1, [], "scratch", 0, "s", None, None)
  pending_changes_b.register_pending(scratch, _ => false)
  pending_changes_b.reject_pending_dependents([apply_changes_raw(scratch)])
  for op in candidates {
    pending_changes_b.register_pending(op, _ => false)
  }
  let known : Array[@core.RawVersion] = []
  let (expected, _) = oracle_plan_remote_candidates(candidates.copy(), known)
  let plan_a = pending_changes_a.prepare([], _ => false)
  let plan_b = pending_changes_b.prepare([], _ => false)
  pending_changes_assert_raws(
    pending_changes_raws(plan_a.planned_operations()),
    pending_changes_raws(expected),
  )
  pending_changes_assert_raws(
    pending_changes_raws(plan_b.planned_operations()),
    pending_changes_raws(expected),
  )
}

///|
test "remote change application pending-changes owner matches multiple branching sizes" {
  for depth in [1, 2, 3, 5, 8] {
    let branches = oracle_reverse(oracle_four_branches(depth))
    pending_changes_compare(branches, 0, [])
  }
}

///|
test "remote change application pending-changes owner accumulates multi-dependency rounds" {
  let left_raw = @core.RawVersion("round-left", 0)
  let right_raw = @core.RawVersion("round-right", 0)
  let seed_raw = @core.RawVersion("round-seed", 0)
  let join = @core.Op::insert(
    -1,
    [left_raw, right_raw],
    "round-join",
    0,
    "j",
    None,
    None,
  )
  let left = @core.Op::insert(-1, [seed_raw], "round-left", 0, "l", None, None)
  let right = @core.Op::insert(-1, [], "round-right", 0, "r", None, None)
  let seed = @core.Op::insert(-1, [], "round-seed", 0, "s", None, None)
  let candidates = [join, left, right, seed]
  let (expected, expected_remaining) = oracle_plan_remote_candidates(
    candidates.copy(),
    [],
  )
  pending_changes_compare(candidates, 0, [])
  pending_changes_assert_raws(pending_changes_raws(expected), [
    @core.RawVersion("round-right", 0),
    @core.RawVersion("round-seed", 0),
    @core.RawVersion("round-left", 0),
    @core.RawVersion("round-join", 0),
  ])
  assert_eq(expected_remaining.length(), 0)
}

///|
test "remote change application pending-changes owner rejects and retries with fresh waiter identities" {
  let root_raw = @core.RawVersion("retry-root", 0)
  let child_raw = @core.RawVersion("retry-child", 0)
  let grandchild_raw = @core.RawVersion("retry-grandchild", 0)
  let root = @core.Op::insert(-1, [], "retry-root", 0, "r", None, None)
  let child = @core.Op::insert(
    -1,
    [root_raw],
    "retry-child",
    0,
    "c",
    None,
    None,
  )
  let grandchild = @core.Op::insert(
    -1,
    [child_raw],
    "retry-grandchild",
    0,
    "g",
    None,
    None,
  )
  let unrelated = @core.Op::insert(
    -1,
    [],
    "retry-unrelated",
    0,
    "u",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  // Descendants arrive before the root, leaving a ready root entry that will
  // become stale when the closure is rejected.
  pending_changes.register_pending(grandchild, _ => false)
  pending_changes.register_pending(child, _ => false)
  pending_changes.register_pending(root, _ => false)
  pending_changes.reject_pending_dependents([root_raw])
  pending_changes.register_pending(unrelated, _ => false)
  let retry_root = @core.Op::insert(
    -1,
    [],
    "retry-root",
    0,
    "retry",
    None,
    None,
  )
  pending_changes.register_pending(retry_root, _ => false)
  pending_changes.register_pending(child, _ => false)
  pending_changes.register_pending(grandchild, _ => false)

  let candidates = [unrelated, retry_root, child, grandchild]
  let (expected, expected_remaining) = oracle_plan_remote_candidates(
    candidates.copy(),
    [],
  )
  let plan = pending_changes.prepare([], _ => false)
  pending_changes_assert_raws(
    pending_changes_raws(plan.planned_operations()),
    pending_changes_raws(expected),
  )
  pending_changes_assert_raws(
    plan.remaining_raws(pending_changes),
    pending_changes_raws(expected_remaining),
  )
  assert_eq(expected_remaining.length(), 0)
  // The unrelated ready node proves the retried root uses its new arrival;
  // the retry closure still follows it without count or remaining drift.
  let actual_raws = pending_changes_raws(plan.planned_operations())
  assert_eq(actual_raws[1], root_raw)
  assert_eq(actual_raws[2], child_raw)
  assert_eq(actual_raws[3], grandchild_raw)
}

///|
test "remote change application pending-changes owner ignores reversed dependency insertion order" {
  let left = @core.RawVersion("order-left", 0)
  let right = @core.RawVersion("order-right", 0)
  let forward = @core.Op::insert(
    -1,
    [left, right, left, right],
    "order-join",
    0,
    "j",
    Some(right),
    Some(left),
  )
  let reverse = @core.Op::insert(
    -1,
    [right, left, right, left],
    "order-join",
    0,
    "j",
    Some(left),
    Some(right),
  )
  let left_op = @core.Op::insert(-1, [], "order-left", 0, "l", None, None)
  let right_op = @core.Op::insert(-1, [], "order-right", 0, "r", None, None)
  let forward_candidates = [forward, left_op, right_op]
  let reverse_candidates = [reverse, left_op, right_op]
  let (expected, expected_remaining) = oracle_plan_remote_candidates(
    forward_candidates.copy(),
    [],
  )
  pending_changes_compare(forward_candidates, 0, [])
  pending_changes_compare(reverse_candidates, 0, [])
  assert_eq(expected_remaining.length(), 0)
  pending_changes_assert_raws(pending_changes_raws(expected), [
    @core.RawVersion("order-left", 0),
    @core.RawVersion("order-right", 0),
    @core.RawVersion("order-join", 0),
  ])
}

///|
test "remote change application acknowledgement wakes a child after external parent change application" {
  let parent = @core.RawVersion("ack-parent", 0)
  let child = @core.Op::insert(-1, [parent], "ack-child", 0, "c", None, None)
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let pending_changes = PendingChanges()
  pending_changes.register_pending(child, raw => known.contains(raw))
  known.add(parent)
  pending_changes.acknowledge_applied(parent)
  let plan = pending_changes.prepare([], raw => known.contains(raw))
  let (expected_planned, expected_remaining) = oracle_plan_remote_candidates(
    [child],
    [parent],
  )
  pending_changes_assert_raws(
    pending_changes_raws(plan.planned_operations()),
    pending_changes_raws(expected_planned),
  )
  pending_changes_assert_raws(
    plan.remaining_raws(pending_changes),
    pending_changes_raws(expected_remaining),
  )
}

///|
test "remote change application acknowledgement removes an recorded pending duplicate" {
  let parent = @core.Op::insert(
    -1,
    [],
    "ack-duplicate-parent",
    0,
    "p",
    None,
    None,
  )
  let parent_raw = apply_changes_raw(parent)
  let child = @core.Op::insert(
    -1,
    [parent_raw],
    "ack-duplicate-child",
    0,
    "c",
    None,
    None,
  )
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let pending_changes = PendingChanges()
  pending_changes.register_pending(parent, raw => known.contains(raw))
  pending_changes.register_pending(child, raw => known.contains(raw))
  known.add(parent_raw)
  pending_changes.acknowledge_applied(parent_raw)
  pending_changes_assert_raws(pending_changes.pending_raws(), [
    apply_changes_raw(child),
  ])
  let plan = pending_changes.prepare([], raw => known.contains(raw))
  let (expected_planned, expected_remaining) = oracle_plan_remote_candidates(
    [parent, child],
    [parent_raw],
  )
  pending_changes_assert_raws(
    pending_changes_raws(plan.planned_operations()),
    pending_changes_raws(expected_planned),
  )
  pending_changes_assert_raws(
    plan.remaining_raws(pending_changes),
    pending_changes_raws(expected_remaining),
  )
}

///|
test "remote change application acknowledgement invalidates an earlier plan generation" {
  let parent = @core.RawVersion("ack-stale-parent", 0)
  let child = @core.Op::insert(
    -1,
    [parent],
    "ack-stale-child",
    0,
    "c",
    None,
    None,
  )
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let pending_changes = PendingChanges()
  pending_changes.register_pending(child, raw => known.contains(raw))
  let old_plan = pending_changes.prepare([], raw => known.contains(raw))
  let old_generation = old_plan.generation()
  assert_eq(old_generation, pending_changes.generation())
  known.add(parent)
  pending_changes.acknowledge_applied(parent)
  assert_true(old_generation != pending_changes.generation())
  assert_true(old_plan.generation() != pending_changes.generation())
  let plan = pending_changes.prepare([], raw => known.contains(raw))
  let (expected_planned, expected_remaining) = oracle_plan_remote_candidates(
    [child],
    [parent],
  )
  pending_changes_assert_raws(
    pending_changes_raws(plan.planned_operations()),
    pending_changes_raws(expected_planned),
  )
  pending_changes_assert_raws(
    plan.remaining_raws(pending_changes),
    pending_changes_raws(expected_remaining),
  )
}

///|
test "remote change application pending-changes owner retry acknowledgement tombstones stay nonnegative" {
  let root = @core.Op::insert(-1, [], "tombstone-root", 0, "r", None, None)
  let root_raw = apply_changes_raw(root)
  let child = @core.Op::insert(
    -1,
    [root_raw],
    "tombstone-child",
    0,
    "c",
    None,
    None,
  )
  let child_raw = apply_changes_raw(child)
  let grandchild = @core.Op::insert(
    -1,
    [child_raw],
    "tombstone-grandchild",
    0,
    "g",
    None,
    None,
  )
  let grandchild_raw = apply_changes_raw(grandchild)
  let pending_changes = PendingChanges()
  pending_changes.register_pending(grandchild, _ => false)
  pending_changes.register_pending(child, _ => false)
  pending_changes.register_pending(root, _ => false)
  pending_changes.reject_pending_dependents([root_raw])
  assert_true(pending_changes.stale_count() >= 0)
  assert_true(pending_changes.stale_count() > 0)

  let retry_root = @core.Op::insert(
    -1,
    [],
    "tombstone-root",
    0,
    "retry",
    None,
    None,
  )
  pending_changes.register_pending(retry_root, _ => false)
  assert_eq(pending_changes.arrival_of(root_raw), Some(3))
  assert_true(pending_changes.stale_count() >= 0)
  pending_changes.register_pending(child, _ => false)
  pending_changes.register_pending(grandchild, _ => false)
  assert_true(pending_changes.stale_count() >= 0)

  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  known.add(root_raw)
  pending_changes.acknowledge_applied(root_raw)
  assert_true(pending_changes.stale_count() >= 0)
  known.add(child_raw)
  pending_changes.acknowledge_applied(child_raw)
  assert_true(pending_changes.stale_count() >= 0)
  known.add(grandchild_raw)
  pending_changes.acknowledge_applied(grandchild_raw)
  assert_true(pending_changes.stale_count() >= 0)
  pending_changes.compact(raw => known.contains(raw))
  assert_eq(pending_changes.stale_count(), 0)
  assert_eq(pending_changes.pending_raws().length(), 0)
}

///|
test "remote change application pending-changes owner selects fast and general preparation exactly" {
  let applied_parent = @core.RawVersion("fast-admitted-parent", 0)
  let applied = @core.Op::insert(
    -1,
    [],
    "fast-admitted-parent",
    0,
    "known",
    None,
    None,
  )
  let parent = @core.Op::insert(-1, [], "fast-parent", 0, "p", None, None)
  let parent_raw = apply_changes_raw(parent)
  let child = @core.Op::insert(
    -1,
    [parent_raw, parent_raw],
    "fast-child",
    0,
    "c",
    Some(parent_raw),
    Some(applied_parent),
  )
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([
    applied_parent,
  ])
  let fast_pending_changes = PendingChanges()
  let fast_plan = fast_pending_changes.prepare(
    [applied, parent, parent, child],
    dependency => known.contains(dependency),
  )
  match fast_plan.storage {
    DeferredFast => ()
    ImmediateGeneral(_, planned_count=_) => fail("expected deferred fast plan")
  }
  pending_changes_assert_raws(
    pending_changes_raws(fast_plan.planned_operations()),
    [parent_raw, apply_changes_raw(child)],
  )

  let unready_pending_changes = PendingChanges()
  let unready_plan = unready_pending_changes.prepare([child, parent], dependency => {
    known.contains(dependency)
  })
  match unready_plan.storage {
    DeferredFast => fail("first unready operation must rerun general planning")
    ImmediateGeneral(_, planned_count=_) => ()
  }

  let missing = @core.RawVersion("fast-pending-missing", 0)
  let pending = @core.Op::insert(
    -1,
    [missing],
    "fast-pending",
    0,
    "x",
    None,
    None,
  )
  let pending_pending_changes = PendingChanges()
  pending_pending_changes.register_pending(pending, _ => false)
  let pending_plan = pending_pending_changes.prepare([parent], _ => false)
  match pending_plan.storage {
    DeferredFast => fail("canonical pending must force general planning")
    ImmediateGeneral(_, planned_count=_) => ()
  }
}

///|
test "remote change application general lifecycle preserves pending-first fixed-point order" {
  let parent = @core.Op::insert(
    -1,
    [],
    "pending-first-parent",
    0,
    "p",
    None,
    None,
  )
  let child = @core.Op::insert(
    -1,
    [apply_changes_raw(parent)],
    "pending-first-child",
    0,
    "c",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  pending_changes.register_pending(child, _ => false)
  let plan = pending_changes.prepare([parent], _ => false)
  match plan.storage {
    DeferredFast => fail("canonical pending must select general planning")
    ImmediateGeneral(_, planned_count=_) => ()
  }
  pending_changes_assert_raws(pending_changes_raws(plan.planned_operations()), [
    apply_changes_raw(parent),
    apply_changes_raw(child),
  ])
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Started => ()
    _ => fail("expected pending-first general begin")
  }
  for op in plan.operations() {
    pending_changes.acknowledge_applied(apply_changes_raw(op))
  }
  assert_eq(pending_changes.pending_raws().length(), 0)
}

///|
test "remote change application general begin registers unresolved nodes" {
  let unknown = @core.RawVersion("begin-unresolved-unknown", 0)
  let child = @core.Op::insert(
    -1,
    [unknown],
    "begin-unresolved-child",
    0,
    "c",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  let plan = pending_changes.prepare([child], _ => false)
  match plan.storage {
    DeferredFast => fail("unresolved operation must select general planning")
    ImmediateGeneral(_, planned_count=_) => ()
  }
  assert_eq(plan.planned_operations().length(), 0)
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Started => ()
    _ => fail("expected unresolved general begin")
  }
  pending_changes_assert_raws(pending_changes.pending_raws(), [
    apply_changes_raw(child),
  ])
}

///|
test "remote change application fast begin rejects reordered dependencies atomically" {
  let parent = @core.Op::insert(-1, [], "fast-begin-parent", 0, "p", None, None)
  let child = @core.Op::insert(
    -1,
    [apply_changes_raw(parent)],
    "fast-begin-child",
    0,
    "c",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  let plan = pending_changes.prepare([parent, child], _ => false)
  match plan.storage {
    DeferredFast => ()
    ImmediateGeneral(_, planned_count=_) => fail("expected fast capability")
  }
  let first = plan.planned[0]
  plan.planned[0] = plan.planned[1]
  plan.planned[1] = first
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Conflict => ()
    _ => fail("expected reordered fast dependency conflict")
  }
  assert_eq(pending_changes.pending_raws().length(), 0)
  assert_eq(pending_changes.generation(), 0)
  assert_eq(pending_changes.next_arrival, 0)
  assert_true(!plan.consumed)
}

///|
test "remote change application fast plan begins and is consumed exactly once" {
  let op = @core.Op::insert(-1, [], "fast-consumed", 0, "x", None, None)
  let pending_changes = PendingChanges()
  let plan = pending_changes.prepare([op], _ => false)
  match plan.storage {
    DeferredFast => ()
    ImmediateGeneral(_, planned_count=_) => fail("expected fast capability")
  }
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Started => ()
    _ => fail("expected fast begin")
  }
  let generation_after = pending_changes.generation()
  let pending_after = pending_changes.pending_raws()
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Consumed => ()
    _ => fail("expected consumed fast plan")
  }
  pending_changes_assert_raws(pending_changes.pending_raws(), pending_after)
  assert_eq(pending_changes.generation(), generation_after)
}

///|
test "remote change application acknowledgement always invalidates `ApplyChanges` actions" {
  let incoming = @core.Op::insert(
    -1,
    [],
    "ack-unrelated-incoming",
    0,
    "i",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  let plan = pending_changes.prepare([incoming], _ => false)
  let generation_before = pending_changes.generation()
  pending_changes.acknowledge_applied(
    @core.RawVersion("ack-unrelated-admitted", 0),
  )
  assert_eq(pending_changes.generation(), generation_before + 1)
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Stale => ()
    _ => fail("every graph change application must invalidate a ApplyChanges")
  }
}

///|
test "remote change application pending-changes owner begins staged nodes exactly once" {
  let parent = @core.Op::insert(-1, [], "begin-parent", 0, "p", None, None)
  let child = @core.Op::insert(
    -1,
    [apply_changes_raw(parent)],
    "begin-child",
    0,
    "c",
    None,
    None,
  )
  let independent = @core.Op::insert(
    -1,
    [],
    "begin-independent",
    0,
    "i",
    None,
    None,
  )
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let pending_changes = PendingChanges()
  let plan = pending_changes.prepare([child, parent, independent], raw => {
    known.contains(raw)
  })
  let generation_before = pending_changes.generation()
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Started => ()
    _ => fail("expected staged registration")
  }
  assert_true(plan.consumed)
  assert_eq(pending_changes.generation(), generation_before + 1)
  pending_changes_assert_raws(pending_changes.pending_raws(), [
    apply_changes_raw(child),
    apply_changes_raw(parent),
    apply_changes_raw(independent),
  ])
  let consumed_generation = pending_changes.generation()
  let consumed_order = pending_changes.pending_order.copy()
  let consumed_stale = pending_changes.stale_count()
  let consumed_next_arrival = pending_changes.next_arrival
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Consumed => ()
    _ => fail("expected consumed plan")
  }
  assert_eq(pending_changes.generation(), consumed_generation)
  assert_eq(pending_changes.pending_order.length(), consumed_order.length())
  for i in 0..<consumed_order.length() {
    assert_eq(pending_changes.pending_order[i].raw, consumed_order[i].raw)
    assert_eq(
      pending_changes.pending_order[i].arrival,
      consumed_order[i].arrival,
    )
  }
  assert_eq(pending_changes.stale_count(), consumed_stale)
  assert_eq(pending_changes.next_arrival, consumed_next_arrival)
  assert_eq(pending_changes.pending_raws().length(), 3)
  for op in plan.planned_operations() {
    let raw = apply_changes_raw(op)
    known.add(raw)
    pending_changes.acknowledge_applied(raw)
  }
  assert_eq(pending_changes.pending_raws().length(), 0)
}

///|
test "remote change application pending-changes owner assigns post-staging arrivals on begin" {
  let parent = @core.Op::insert(
    -1,
    [],
    "begin-order-parent",
    0,
    "p",
    None,
    None,
  )
  let child = @core.Op::insert(
    -1,
    [apply_changes_raw(parent)],
    "begin-order-child",
    0,
    "c",
    None,
    None,
  )
  let independent = @core.Op::insert(
    -1,
    [],
    "begin-order-independent",
    0,
    "i",
    None,
    None,
  )
  let direct = @core.Op::insert(
    -1,
    [],
    "begin-order-direct",
    0,
    "d",
    None,
    None,
  )
  let staged = [child, parent, independent]
  let pending_changes = PendingChanges()
  let old_next_arrival = pending_changes.next_arrival
  let plan = pending_changes.prepare(staged, _ => false)
  match plan.storage {
    DeferredFast => fail("expected general arrival capability")
    ImmediateGeneral(nodes, planned_count=_) =>
      for i, node in nodes {
        assert_eq(node.arrival, old_next_arrival + i)
      }
  }
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Started => ()
    _ => fail("expected staged registration")
  }
  assert_eq(pending_changes.next_arrival, plan.next_arrival)
  pending_changes.register_pending(direct, _ => false)
  let direct_raw = apply_changes_raw(direct)
  let direct_arrival = pending_changes.arrival_of(direct_raw)
  assert_eq(direct_arrival, Some(plan.next_arrival))
  let candidates = staged.add([direct])
  let (expected, expected_remaining) = oracle_plan_remote_candidates(
    candidates.copy(),
    [],
  )
  let future = pending_changes.prepare([], _ => false)
  pending_changes_assert_raws(
    pending_changes_raws(future.planned_operations()),
    pending_changes_raws(expected),
  )
  pending_changes_assert_raws(
    future.remaining_raws(pending_changes),
    pending_changes_raws(expected_remaining),
  )
}

///|
test "remote change application pending-changes owner preserves an unacknowledged successful prefix remainder" {
  let incoming = oracle_reverse(oracle_chain(7))
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let pending_changes = PendingChanges()
  let plan = pending_changes.prepare(incoming, raw => known.contains(raw))
  let planned = plan.planned_operations()
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Started => ()
    _ => fail("expected staged registration")
  }
  let prefix_length = 3
  for i in 0..<prefix_length {
    let raw = apply_changes_raw(planned[i])
    known.add(raw)
    pending_changes.acknowledge_applied(raw)
  }
  let expected_remaining : Array[@core.RawVersion] = [
    for op in incoming if !known.contains(apply_changes_raw(op)) => {
      apply_changes_raw(op)
    }
  ]
  pending_changes_assert_raws(
    pending_changes.pending_raws(),
    expected_remaining,
  )
}

///|
test "remote change application pending-changes owner rejects stale `ApplyChanges` actions before mutation" {
  let first = @core.Op::insert(-1, [], "stale-first", 0, "x", None, None)
  let second = @core.Op::insert(-1, [], "stale-second", 0, "x", None, None)
  let pending_changes = PendingChanges()
  let stale_plan = pending_changes.prepare([first], _ => false)
  pending_changes.register_pending(second, _ => false)
  let pending_before = pending_changes.pending_raws()
  let generation_before = pending_changes.generation()
  let order_before = pending_changes.pending_order.copy()
  let stale_before = pending_changes.stale_count()
  match pending_changes.begin(stale_plan, _ => false) {
    BeginApplyResult::Stale => ()
    _ => fail("expected stale plan")
  }
  pending_changes_assert_raws(pending_changes.pending_raws(), pending_before)
  assert_eq(pending_changes.generation(), generation_before)
  assert_eq(pending_changes.pending_order.length(), order_before.length())
  for i in 0..<order_before.length() {
    assert_eq(pending_changes.pending_order[i].raw, order_before[i].raw)
    assert_eq(pending_changes.pending_order[i].arrival, order_before[i].arrival)
  }
  assert_eq(pending_changes.stale_count(), stale_before)
  assert_true(!stale_plan.consumed)
}

///|
test "remote change application pending-changes owner rejects duplicate staged arrivals before mutation" {
  let live = @core.Op::insert(-1, [], "conflict-live", 0, "l", None, None)
  let staged = @core.Op::insert(-1, [], "conflict-staged", 0, "s", None, None)
  let staged_other = @core.Op::insert(
    -1,
    [],
    "conflict-staged-other",
    0,
    "o",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  pending_changes.register_pending(live, _ => false)
  let plan = pending_changes.prepare([staged, staged_other], _ => false)
  match plan.storage {
    DeferredFast => fail("expected general duplicate-arrival capability")
    ImmediateGeneral(nodes, planned_count=_) => {
      let first = nodes[0]
      let second = nodes[1]
      nodes[1] = {
        op: second.op,
        raw: second.raw,
        arrival: first.arrival,
        dependencies: second.dependencies,
        waiting_dependencies: second.waiting_dependencies,
        unresolved_count: second.unresolved_count,
      }
    }
  }
  let pending_before = pending_changes.pending_raws()
  let order_length_before = pending_changes.pending_order.length()
  let generation_before = pending_changes.generation()
  let stale_before = pending_changes.stale_count()
  let next_arrival_before = pending_changes.next_arrival
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Conflict => ()
    _ => fail("expected duplicate staged arrival conflict")
  }
  pending_changes_assert_raws(pending_changes.pending_raws(), pending_before)
  assert_eq(pending_changes.pending_order.length(), order_length_before)
  assert_eq(pending_changes.generation(), generation_before)
  assert_eq(pending_changes.stale_count(), stale_before)
  assert_eq(pending_changes.next_arrival, next_arrival_before)
  assert_true(!plan.consumed)
}

///|
test "remote change application pending-changes owner rejects gapped staged arrivals atomically" {
  let live = @core.Op::insert(-1, [], "gap-live", 0, "l", None, None)
  let first = @core.Op::insert(-1, [], "gap-first", 0, "f", None, None)
  let second = @core.Op::insert(-1, [], "gap-second", 0, "s", None, None)
  let pending_changes = PendingChanges()
  pending_changes.register_pending(live, _ => false)
  let plan = pending_changes.prepare([first, second], _ => false)
  match plan.storage {
    DeferredFast => fail("expected general gapped-arrival capability")
    ImmediateGeneral(nodes, planned_count=_) => {
      let second_node = nodes[1]
      nodes[1] = {
        op: second_node.op,
        raw: second_node.raw,
        arrival: second_node.arrival + 1,
        dependencies: second_node.dependencies,
        waiting_dependencies: second_node.waiting_dependencies,
        unresolved_count: second_node.unresolved_count,
      }
    }
  }
  let pending_before = pending_changes.pending_raws()
  let order_before = pending_changes.pending_order.copy()
  let generation_before = pending_changes.generation()
  let stale_before = pending_changes.stale_count()
  let next_arrival_before = pending_changes.next_arrival
  let consumed_before = plan.consumed
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Conflict => ()
    _ => fail("expected gapped arrival conflict")
  }
  pending_changes_assert_raws(pending_changes.pending_raws(), pending_before)
  assert_eq(pending_changes.pending_order.length(), order_before.length())
  for i in 0..<order_before.length() {
    assert_eq(pending_changes.pending_order[i].raw, order_before[i].raw)
    assert_eq(pending_changes.pending_order[i].arrival, order_before[i].arrival)
  }
  assert_eq(pending_changes.generation(), generation_before)
  assert_eq(pending_changes.stale_count(), stale_before)
  assert_eq(pending_changes.next_arrival, next_arrival_before)
  assert_eq(plan.consumed, consumed_before)
}

///|
test "remote change application pending-changes owner rejects staged payload mismatch atomically" {
  let live = @core.Op::insert(-1, [], "raw-live", 0, "l", None, None)
  let first = @core.Op::insert(-1, [], "raw-first", 0, "f", None, None)
  let second = @core.Op::insert(-1, [], "raw-second", 0, "s", None, None)
  let mismatch = @core.Op::insert(
    -1,
    [],
    "raw-second",
    0,
    "changed",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  pending_changes.register_pending(live, _ => false)
  let plan = pending_changes.prepare([first, second], _ => false)
  match plan.storage {
    DeferredFast => fail("expected general payload capability")
    ImmediateGeneral(nodes, planned_count=_) => {
      let second_node = nodes[1]
      nodes[1] = {
        op: mismatch,
        raw: second_node.raw,
        arrival: second_node.arrival,
        dependencies: second_node.dependencies,
        waiting_dependencies: second_node.waiting_dependencies,
        unresolved_count: second_node.unresolved_count,
      }
    }
  }
  let pending_before = pending_changes.pending_raws()
  let order_before = pending_changes.pending_order.copy()
  let generation_before = pending_changes.generation()
  let stale_before = pending_changes.stale_count()
  let next_arrival_before = pending_changes.next_arrival
  let consumed_before = plan.consumed
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Conflict => ()
    _ => fail("expected staged payload mismatch conflict")
  }
  pending_changes_assert_raws(pending_changes.pending_raws(), pending_before)
  assert_eq(pending_changes.pending_order.length(), order_before.length())
  for i in 0..<order_before.length() {
    assert_eq(pending_changes.pending_order[i].raw, order_before[i].raw)
    assert_eq(pending_changes.pending_order[i].arrival, order_before[i].arrival)
  }
  assert_eq(pending_changes.generation(), generation_before)
  assert_eq(pending_changes.stale_count(), stale_before)
  assert_eq(pending_changes.next_arrival, next_arrival_before)
  assert_eq(plan.consumed, consumed_before)
}

///|
test "remote change application pending-changes owner rejects pending planned payload mismatch atomically" {
  let pending = @core.Op::insert(
    -1,
    [],
    "planned-payload",
    0,
    "original",
    None,
    None,
  )
  let changed = @core.Op::insert(
    -1,
    [],
    "planned-payload",
    0,
    "changed",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  pending_changes.register_pending(pending, _ => false)
  let plan = pending_changes.prepare([], _ => false)
  assert_eq(plan.planned.length(), 1)
  plan.planned[0] = changed
  let pending_before = pending_changes.pending_raws()
  let generation_before = pending_changes.generation()
  let next_arrival_before = pending_changes.next_arrival
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Conflict => ()
    _ => fail("expected pending planned payload conflict")
  }
  pending_changes_assert_raws(pending_changes.pending_raws(), pending_before)
  assert_eq(pending_changes.generation(), generation_before)
  assert_eq(pending_changes.next_arrival, next_arrival_before)
  assert_true(!plan.consumed)
}

///|
test "remote change application pending-changes owner rejects reordered and injected planned entries" {
  let parent = @core.Op::insert(
    -1,
    [],
    "planned-order-parent",
    0,
    "p",
    None,
    None,
  )
  let child = @core.Op::insert(
    -1,
    [apply_changes_raw(parent)],
    "planned-order-child",
    0,
    "c",
    None,
    None,
  )
  let reordered_pending_changes = PendingChanges()
  let reordered_plan = reordered_pending_changes.prepare([child, parent], _ => {
    false
  })
  let first = reordered_plan.planned[0]
  reordered_plan.planned[0] = reordered_plan.planned[1]
  reordered_plan.planned[1] = first
  match reordered_pending_changes.begin(reordered_plan, _ => false) {
    BeginApplyResult::Conflict => ()
    _ => fail("expected reordered planned conflict")
  }
  assert_eq(reordered_pending_changes.pending_raws().length(), 0)
  assert_eq(reordered_pending_changes.generation(), 0)
  assert_eq(reordered_pending_changes.next_arrival, 0)
  assert_true(!reordered_plan.consumed)

  let first_ready = @core.Op::insert(
    -1,
    [],
    "planned-order-first-ready",
    0,
    "a",
    None,
    None,
  )
  let second_ready = @core.Op::insert(
    -1,
    [],
    "planned-order-second-ready",
    0,
    "b",
    None,
    None,
  )
  let arrival_blocker_dependency = @core.RawVersion(
    "planned-order-arrival-blocker", 0,
  )
  let arrival_blocker = @core.Op::insert(
    -1,
    [arrival_blocker_dependency],
    "planned-order-arrival-pending",
    0,
    "x",
    None,
    None,
  )
  let arrival_pending_changes = PendingChanges()
  arrival_pending_changes.register_pending(arrival_blocker, _ => false)
  let arrival_pending_before = arrival_pending_changes.pending_raws()
  let arrival_generation_before = arrival_pending_changes.generation()
  let arrival_next_before = arrival_pending_changes.next_arrival
  let arrival_plan = arrival_pending_changes.prepare(
    [first_ready, second_ready],
    _ => false,
  )
  let arrival_first = arrival_plan.planned[0]
  arrival_plan.planned[0] = arrival_plan.planned[1]
  arrival_plan.planned[1] = arrival_first
  match arrival_pending_changes.begin(arrival_plan, _ => false) {
    BeginApplyResult::Conflict => ()
    _ => fail("expected compatibility arrival-order conflict")
  }
  pending_changes_assert_raws(
    arrival_pending_changes.pending_raws(),
    arrival_pending_before,
  )
  assert_eq(arrival_pending_changes.generation(), arrival_generation_before)
  assert_eq(arrival_pending_changes.next_arrival, arrival_next_before)
  assert_true(!arrival_plan.consumed)

  let unknown = @core.RawVersion("planned-injected-unknown", 0)
  let ready = @core.Op::insert(
    -1,
    [],
    "planned-injected-ready",
    0,
    "r",
    None,
    None,
  )
  let blocked = @core.Op::insert(
    -1,
    [unknown],
    "planned-injected-blocked",
    0,
    "b",
    None,
    None,
  )
  let injected_pending_changes = PendingChanges()
  let injected_plan = injected_pending_changes.prepare([ready, blocked], _ => {
    false
  })
  assert_eq(injected_plan.planned.length(), 1)
  injected_plan.planned[0] = blocked
  match injected_pending_changes.begin(injected_plan, _ => false) {
    BeginApplyResult::Conflict => ()
    _ => fail("expected prematurely injected planned conflict")
  }
  assert_eq(injected_pending_changes.pending_raws().length(), 0)
  assert_eq(injected_pending_changes.generation(), 0)
  assert_eq(injected_pending_changes.next_arrival, 0)
  assert_true(!injected_plan.consumed)
}

///|
test "remote change application pending-changes owner rejects newly recorded staged raw atomically" {
  let staged = @core.Op::insert(
    -1,
    [],
    "newly-admitted-staged",
    0,
    "x",
    None,
    None,
  )
  let raw = apply_changes_raw(staged)
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let pending_changes = PendingChanges()
  let plan = pending_changes.prepare([staged], dependency => {
    known.contains(dependency)
  })
  known.add(raw)
  let generation_before = pending_changes.generation()
  let next_arrival_before = pending_changes.next_arrival
  match pending_changes.begin(plan, dependency => known.contains(dependency)) {
    BeginApplyResult::Conflict => ()
    _ => fail("expected newly recorded staged conflict")
  }
  assert_eq(pending_changes.pending_raws().length(), 0)
  assert_eq(pending_changes.generation(), generation_before)
  assert_eq(pending_changes.next_arrival, next_arrival_before)
  assert_true(!plan.consumed)
}

///|
test "remote change application pending-changes owner rejects inconsistent waiting metadata atomically" {
  let dependency = @core.RawVersion("waiting-metadata-dependency", 0)
  let staged = @core.Op::insert(
    -1,
    [dependency],
    "waiting-metadata-staged",
    0,
    "x",
    None,
    None,
  )
  let waiting_pending_changes = PendingChanges()
  let waiting_plan = waiting_pending_changes.prepare([staged], _ => false)
  match waiting_plan.storage {
    DeferredFast => fail("expected general waiting-metadata capability")
    ImmediateGeneral(nodes, planned_count=_) => {
      let node = nodes[0]
      nodes[0] = {
        op: node.op,
        raw: node.raw,
        arrival: node.arrival,
        dependencies: node.dependencies,
        waiting_dependencies: [],
        unresolved_count: node.unresolved_count,
      }
    }
  }
  match waiting_pending_changes.begin(waiting_plan, _ => false) {
    BeginApplyResult::Conflict => ()
    _ => fail("expected waiting dependency conflict")
  }
  assert_eq(waiting_pending_changes.pending_raws().length(), 0)
  assert_eq(waiting_pending_changes.generation(), 0)
  assert_eq(waiting_pending_changes.next_arrival, 0)
  assert_true(!waiting_plan.consumed)

  let count_pending_changes = PendingChanges()
  let count_plan = count_pending_changes.prepare([staged], _ => false)
  match count_plan.storage {
    DeferredFast => fail("expected general unresolved-count capability")
    ImmediateGeneral(nodes, planned_count=_) => {
      let node = nodes[0]
      nodes[0] = {
        op: node.op,
        raw: node.raw,
        arrival: node.arrival,
        dependencies: node.dependencies,
        waiting_dependencies: node.waiting_dependencies,
        unresolved_count: node.unresolved_count + 1,
      }
    }
  }
  match count_pending_changes.begin(count_plan, _ => false) {
    BeginApplyResult::Conflict => ()
    _ => fail("expected unresolved count conflict")
  }
  assert_eq(count_pending_changes.pending_raws().length(), 0)
  assert_eq(count_pending_changes.generation(), 0)
  assert_eq(count_pending_changes.next_arrival, 0)
  assert_true(!count_plan.consumed)
}

///|
test "remote change application operation copy cannot mutate prepared storage" {
  let original = @core.Op::insert(
    -1,
    [],
    "operation-copy",
    0,
    "original",
    None,
    None,
  )
  let replacement = @core.Op::insert(
    -1,
    [],
    "operation-copy",
    0,
    "replacement",
    None,
    None,
  )
  let pending_changes = PendingChanges()
  let blocker_dependency = @core.RawVersion("operation-copy-blocker", 0)
  let blocker = @core.Op::insert(
    -1,
    [blocker_dependency],
    "operation-copy-pending",
    0,
    "b",
    None,
    None,
  )
  pending_changes.register_pending(blocker, _ => false)
  let plan = pending_changes.prepare([original], _ => false)
  let owning_copy = plan.operations().to_owned()
  owning_copy[0] = replacement
  assert_true(apply_changes_same_operation(plan.planned[0], original))
  match plan.storage {
    DeferredFast => fail("expected general operation-copy capability")
    ImmediateGeneral(nodes, planned_count=_) =>
      assert_true(apply_changes_same_operation(nodes[0].op, original))
  }
  match pending_changes.begin(plan, _ => false) {
    BeginApplyResult::Started => ()
    _ => fail("owning operation copy changed the prepared capability")
  }
}

///|
test "remote change application pending-changes owner compacts stale indexes and preserves live arrivals" {
  let root = @core.Op::insert(-1, [], "compact-root", 0, "r", None, None)
  let child = @core.Op::insert(
    -1,
    [apply_changes_raw(root)],
    "compact-child",
    0,
    "c",
    None,
    None,
  )
  let unrelated_dependency = @core.RawVersion("compact-unrelated-dependency", 0)
  let unrelated = @core.Op::insert(
    -1,
    [unrelated_dependency],
    "compact-unrelated",
    0,
    "u",
    None,
    None,
  )
  let ready = @core.Op::insert(-1, [], "compact-ready", 0, "q", None, None)
  let pending_changes = PendingChanges()
  pending_changes.register_pending(child, _ => false)
  pending_changes.register_pending(root, _ => false)
  pending_changes.register_pending(unrelated, _ => false)
  pending_changes.register_pending(ready, _ => false)
  pending_changes.reject_pending_dependents([apply_changes_raw(root)])
  let live_arrival_before = pending_changes.arrival_of(
    apply_changes_raw(unrelated),
  )
  let generation_before = pending_changes.generation()
  assert_true(pending_changes.stale_count() > 0)
  pending_changes.compact(_ => false)
  assert_eq(pending_changes.stale_count(), 0)
  assert_eq(pending_changes.generation(), generation_before + 1)
  assert_eq(
    pending_changes.arrival_of(apply_changes_raw(unrelated)),
    live_arrival_before,
  )
  pending_changes_assert_raws(pending_changes.pending_raws(), [
    apply_changes_raw(unrelated),
    apply_changes_raw(ready),
  ])
  let before = pending_changes.prepare([], _ => false)
  pending_changes.compact(_ => false)
  let after = pending_changes.prepare([], _ => false)
  pending_changes_assert_raws(
    pending_changes_raws(before.planned_operations()),
    pending_changes_raws(after.planned_operations()),
  )
  pending_changes_assert_raws(
    before.remaining_raws(pending_changes),
    after.remaining_raws(pending_changes),
  )
  pending_changes_assert_raws(
    pending_changes_raws(before.planned_operations()),
    [apply_changes_raw(ready)],
  )
  pending_changes_assert_raws(before.remaining_raws(pending_changes), [
    apply_changes_raw(unrelated),
  ])
}

///|
test "remote change application pending-changes owner filters graph-known nodes during compaction" {
  let dependency = @core.RawVersion("compact-known-dependency", 0)
  let waiting = @core.Op::insert(
    -1,
    [dependency],
    "compact-known-waiter",
    0,
    "w",
    None,
    None,
  )
  let known_node = @core.Op::insert(
    -1,
    [],
    "compact-known-node",
    0,
    "k",
    None,
    None,
  )
  let known : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let pending_changes = PendingChanges()
  pending_changes.register_pending(waiting, _ => false)
  pending_changes.register_pending(known_node, _ => false)
  let waiting_arrival = pending_changes.arrival_of(apply_changes_raw(waiting))
  known.add(apply_changes_raw(known_node))
  known.add(dependency)
  pending_changes.compact(raw => known.contains(raw))
  assert_eq(pending_changes.arrival_of(apply_changes_raw(known_node)), None)
  assert_eq(
    pending_changes.arrival_of(apply_changes_raw(waiting)),
    waiting_arrival,
  )
  let plan = pending_changes.prepare([], raw => known.contains(raw))
  pending_changes_assert_raws(pending_changes_raws(plan.planned_operations()), [
    apply_changes_raw(waiting),
  ])
}

///|
test "remote change application pending-changes owner maybe_compact uses bounded stale policy" {
  let pending_changes = PendingChanges()
  for i in 0..<511 {
    let op = @core.Op::insert(-1, [], "maybe-compact", i, "x", None, None)
    pending_changes.register_pending(op, _ => false)
    pending_changes.acknowledge_applied(apply_changes_raw(op))
  }
  let generation_before = pending_changes.generation()
  assert_eq(pending_changes.stale_count(), 1022)
  assert_true(!pending_changes.maybe_compact(_ => false))
  assert_eq(pending_changes.generation(), generation_before)

  let threshold_op = @core.Op::insert(
    -1,
    [],
    "maybe-compact",
    511,
    "x",
    None,
    None,
  )
  pending_changes.register_pending(threshold_op, _ => false)
  pending_changes.acknowledge_applied(apply_changes_raw(threshold_op))
  assert_eq(pending_changes.stale_count(), 1024)
  assert_true(pending_changes.maybe_compact(_ => false))
  assert_eq(pending_changes.stale_count(), 0)
}

///|
test "remote change application pending-changes owner maybe_compact pins live ratio boundary" {
  let missing = @core.RawVersion("ratio-missing", 0)
  let pending_changes = PendingChanges()
  for i in 0..<513 {
    pending_changes.register_pending(
      @core.Op::insert(-1, [missing], "ratio-live", i, "x", None, None),
      _ => false,
    )
  }
  for i in 0..<512 {
    let churn = @core.Op::insert(-1, [], "ratio-stale", i, "x", None, None)
    pending_changes.register_pending(churn, _ => false)
    pending_changes.acknowledge_applied(apply_changes_raw(churn))
  }
  assert_eq(pending_changes.pending_raws().length(), 513)
  assert_eq(pending_changes.stale_count(), 1024)
  assert_true(!pending_changes.maybe_compact(_ => false))

  let trigger = @core.Op::insert(-1, [], "ratio-stale", 512, "x", None, None)
  pending_changes.register_pending(trigger, _ => false)
  pending_changes.acknowledge_applied(apply_changes_raw(trigger))
  assert_eq(pending_changes.stale_count(), 1026)
  assert_true(pending_changes.maybe_compact(_ => false))
  assert_eq(pending_changes.stale_count(), 0)
  assert_eq(pending_changes.pending_raws().length(), 513)
}
