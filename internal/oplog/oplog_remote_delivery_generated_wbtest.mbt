///| Generated properties for general remote operation delivery.

///|
struct RemoteDeliveryTrace {
  suffix_count : Int
  source_seed : Int
  schedule_seed : Int
} derive(Debug)

///|
struct RemoteDeliverySnapshot {
  raw : @core.RawVersion
  parents : Array[@core.RawVersion]
  content : @core.OpContent
  origin_left : @core.RawVersion?
  origin_right : @core.RawVersion?
} derive(Debug, Eq)

///|
struct RemoteDeliveryScenario {
  ops : Array[@core.Op]
  expected : Map[@core.RawVersion, RemoteDeliverySnapshot]
  roots : Array[@core.Op]
  merge : @core.Op
  delete : @core.Op
  undelete : @core.Op
  expected_frontier : Array[@core.RawVersion]
}

///|
struct RemoteDeliveryModel {
  mut pending : Array[@core.Op]
  known : Array[@core.RawVersion]
  admitted : @hashset.HashSet[@core.RawVersion]
}

///|
struct RemoteDeliveryEvidence {
  valid : Bool
  out_of_order : Bool
  pending : Bool
  wakeup_drain : Bool
  parent_blocked : Bool
  insert_origin_blocked : Bool
  delete_origin_blocked : Bool
  duplicate_before_admission : Bool
  duplicate_while_pending : Bool
  duplicate_after_admission : Bool
  final_count : Int
} derive(Debug)

///|
impl @quickcheck.Arbitrary for RemoteDeliveryTrace with fn arbitrary(
  size,
  random_state,
) {
  let suffix_bound = size.max(0).min(4) + 1
  {
    suffix_count: random_state.split().next_positive_int() % suffix_bound,
    source_seed: random_state.split().next_positive_int(),
    schedule_seed: random_state.split().next_positive_int(),
  }
}

///|
impl @qc.Shrink for RemoteDeliveryTrace with fn shrink(self) {
  let results : Array[RemoteDeliveryTrace] = []
  if self.suffix_count > 0 {
    results.push({ ..self, suffix_count: 0 })
    let half = self.suffix_count / 2
    if half > 0 {
      results.push({ ..self, suffix_count: half })
    }
  }
  if self.source_seed != 0 {
    results.push({ ..self, source_seed: 0 })
  }
  if self.schedule_seed != 0 {
    results.push({ ..self, schedule_seed: 0 })
  }
  results.iter()
}

///|
fn remote_delivery_snapshot(op : @core.Op) -> RemoteDeliverySnapshot {
  {
    raw: oracle_raw(op),
    parents: op.parents(),
    content: op.content(),
    origin_left: op.origin_left(),
    origin_right: op.origin_right(),
  }
}

///|
fn remote_delivery_same_raw_sequence(
  left : ArrayView[@core.RawVersion],
  right : ArrayView[@core.RawVersion],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for index in 0..<left.length() {
    if left[index] != right[index] {
      return false
    }
  }
  true
}

///|
fn remote_delivery_same_raw_membership(
  left : ArrayView[@core.RawVersion],
  right : ArrayView[@core.RawVersion],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  let right_set : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet(right)
  right_set.length() == right.length() &&
  left.iter().all(raw => right_set.contains(raw))
}

///|
fn remote_delivery_matches_expected(
  op : @core.Op,
  expected : Map[@core.RawVersion, RemoteDeliverySnapshot],
) -> Bool {
  match expected.get(oracle_raw(op)) {
    Some(snapshot) => remote_delivery_snapshot(op) == snapshot
    None => false
  }
}

///|
fn remote_delivery_sequence_matches(
  actual : ArrayView[@core.Op],
  planned : ArrayView[@core.Op],
  expected : Map[@core.RawVersion, RemoteDeliverySnapshot],
) -> Bool {
  if actual.length() != planned.length() {
    return false
  }
  for index in 0..<actual.length() {
    if oracle_raw(actual[index]) != oracle_raw(planned[index]) ||
      !remote_delivery_matches_expected(actual[index], expected) {
      return false
    }
  }
  true
}

///|
fn remote_delivery_seed_source(
  agent : String,
  known : ArrayView[@core.Op],
) -> OpLog {
  let source = OpLog::new(agent)
  for op in known {
    let admitted = try! source.apply_remote(op)
    guard admitted.length() == 1 &&
      oracle_raw(admitted[0]) == oracle_raw(op) &&
      remote_delivery_snapshot(admitted[0]) == remote_delivery_snapshot(op) else {
      abort("closed source prefix did not replay exactly once")
    }
  }
  guard !source.has_pending() && source.op_count() == known.length() else {
    abort("closed source prefix left unresolved operations")
  }
  source
}

///|
fn remote_delivery_lv(source : OpLog, raw : @core.RawVersion) -> Int {
  match source.get_all_ops().iter().find_first(op => oracle_raw(op) == raw) {
    Some(op) => op.lv()
    None => abort("source operation identity has no local LV")
  }
}

///|
fn remote_delivery_insert_ops(source : OpLog) -> Array[@core.Op] {
  source.get_all_ops().filter(op => op.is_insert())
}

///|
fn remote_delivery_text(seed : Int, offset : Int) -> String {
  let alphabet = ["a", "b", "c", "d", "e"]
  alphabet[(seed % alphabet.length() + offset % alphabet.length()) %
  alphabet.length()]
}

///|
fn remote_delivery_extra_agent(seed : Int, offset : Int) -> String {
  let agents = ["generated-extra-a", "generated-extra-b", "generated-extra-c"]
  agents[(seed % agents.length() + offset % agents.length()) % agents.length()]
}

///|
fn remote_delivery_build_scenario(
  trace : RemoteDeliveryTrace,
) -> RemoteDeliveryScenario {
  guard trace.suffix_count >= 0 && trace.suffix_count <= 4 else {
    abort("remote delivery trace exceeded its bounded grammar")
  }
  let left_source = OpLog::new("generated-source-left")
  let left = try! left_source.insert(
    remote_delivery_text(trace.source_seed, 0),
    -1,
    -1,
  )
  let right_source = OpLog::new("generated-source-right")
  let right = try! right_source.insert(
    remote_delivery_text(trace.source_seed, 1),
    -1,
    -1,
  )
  let ops : Array[@core.Op] = [left, right]

  let merge_source = remote_delivery_seed_source("generated-source-merge", ops)
  let left_lv = remote_delivery_lv(merge_source, oracle_raw(left))
  let right_lv = remote_delivery_lv(merge_source, oracle_raw(right))
  let merge = try! merge_source.insert(
    remote_delivery_text(trace.source_seed, 2),
    left_lv,
    right_lv,
  )
  ops.push(merge)

  // A real local operation's origins are necessarily in the causal history of
  // its frontier parents, so an origin-only blocker cannot be generated without
  // fabricating an invalid source graph. Choose the second-delivered root as
  // the delete target so both insertion and delete origins remain absent until
  // the final dependency wake-up.
  let late_origin = if trace.schedule_seed % 2 == 0 { right } else { left }
  let delete_source = remote_delivery_seed_source(
    "generated-source-delete", ops,
  )
  let delete_target = remote_delivery_lv(delete_source, oracle_raw(late_origin))
  let delete = try! delete_source.delete(delete_target)
  ops.push(delete)

  let undelete_source = remote_delivery_seed_source(
    "generated-source-undelete", ops,
  )
  let undelete_target = remote_delivery_lv(
    undelete_source,
    oracle_raw(late_origin),
  )
  let undelete = try! undelete_source.undelete(undelete_target)
  ops.push(undelete)

  for offset in 0..<trace.suffix_count {
    let source = remote_delivery_seed_source(
      remote_delivery_extra_agent(trace.source_seed, offset),
      ops,
    )
    let inserts = remote_delivery_insert_ops(source)
    guard !inserts.is_empty() else {
      abort("generated source prefix lost every insertion target")
    }
    let target_index = (
        trace.source_seed % inserts.length() + offset % inserts.length()
      ) %
      inserts.length()
    let target_lv = inserts[target_index].lv()
    let choice = (trace.source_seed % 3 + offset % 3) % 3
    let op = if choice == 0 {
      let right_origin = if inserts.length() > 1 && offset % 2 == 0 {
        inserts[(target_index + 1) % inserts.length()].lv()
      } else {
        -1
      }
      try! source.insert(
        remote_delivery_text(trace.source_seed, offset + 3),
        target_lv,
        right_origin,
      )
    } else if choice == 1 {
      try! source.delete(target_lv)
    } else {
      try! source.undelete(target_lv)
    }
    ops.push(op)
  }

  let expected : Map[@core.RawVersion, RemoteDeliverySnapshot] = Map([])
  for op in ops {
    let raw = oracle_raw(op)
    guard !expected.contains(raw) else {
      abort("real source OpLogs generated a duplicate operation identity")
    }
    expected[raw] = remote_delivery_snapshot(op)
  }
  let parented : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for op in ops {
    for parent in op.parents_iter() {
      parented.add(parent)
    }
  }
  let expected_frontier = [
    for op in ops if !parented.contains(oracle_raw(op)) => oracle_raw(op)
  ]
  let (source_plan, source_remaining) = try! oracle_plan_remote_candidates(
    ops.copy(),
    [],
  )
  guard source_remaining.is_empty() && source_plan.length() == ops.length() else {
    abort("generated source DAG was not closed")
  }
  {
    ops,
    expected,
    roots: [left, right],
    merge,
    delete,
    undelete,
    expected_frontier,
  }
}

///|
fn RemoteDeliveryModel::RemoteDeliveryModel() -> RemoteDeliveryModel {
  { pending: [], known: [], admitted: @hashset.HashSet([]) }
}

///|
fn RemoteDeliveryModel::oracle_step(
  self : RemoteDeliveryModel,
  incoming : @core.Op,
) -> Array[@core.Op] {
  let incoming_raw = oracle_raw(incoming)
  guard !self.admitted.contains(incoming_raw) &&
    !self.pending.iter().any(op => oracle_raw(op) == incoming_raw) else {
    abort("oracle step received a duplicate instead of a new identity")
  }
  let candidates = self.pending.copy()
  candidates.push(incoming)
  let (planned, remaining) = try! oracle_plan_remote_candidates(
    candidates,
    self.known,
  )
  self.pending = remaining
  for op in planned {
    let raw = oracle_raw(op)
    guard !self.admitted.contains(raw) else {
      abort("fixed-point oracle admitted one identity twice")
    }
    self.admitted.add(raw)
    self.known.push(raw)
  }
  planned
}

///|
fn remote_delivery_pending_matches(
  target : OpLog,
  model : RemoteDeliveryModel,
) -> Bool {
  remote_delivery_same_raw_sequence(
    oracle_raws(target.planner.pending_operations()),
    oracle_raws(model.pending),
  ) &&
  target.has_pending() == !model.pending.is_empty()
}

///|
fn remote_delivery_apply_step(
  target : OpLog,
  model : RemoteDeliveryModel,
  incoming : @core.Op,
  expected : Map[@core.RawVersion, RemoteDeliverySnapshot],
) -> (Bool, Int) {
  let planned = model.oracle_step(incoming)
  let actual = try! target.apply_remote(incoming)
  (
    remote_delivery_sequence_matches(actual, planned, expected) &&
    remote_delivery_pending_matches(target, model),
    actual.length(),
  )
}

///|
fn remote_delivery_has_missing_parent(
  op : @core.Op,
  known : ArrayView[@core.RawVersion],
) -> Bool {
  op.parents_iter().any(parent => !known.contains(parent))
}

///|
fn remote_delivery_has_missing_origin(
  op : @core.Op,
  known : ArrayView[@core.RawVersion],
) -> Bool {
  match op.origin_left() {
    Some(origin) if !known.contains(origin) => true
    _ =>
      match op.origin_right() {
        Some(origin) => !known.contains(origin)
        None => false
      }
  }
}

///|
fn remote_delivery_suffix_schedule(
  scenario : RemoteDeliveryScenario,
  seed : Int,
) -> Array[@core.Op] {
  let result : Array[@core.Op] = []
  let suffix_count = scenario.ops.length() - 5
  if suffix_count > 0 {
    let rotation = seed % suffix_count
    for offset in 0..<suffix_count {
      let forward = (rotation + offset) % suffix_count
      let index = if seed % 2 == 0 {
        5 + forward
      } else {
        5 + suffix_count - forward - 1
      }
      result.push(scenario.ops[index])
    }
  }
  result
}

///|
fn remote_delivery_duplicate_before_admission(
  scenario : RemoteDeliveryScenario,
) -> Bool {
  let root = scenario.roots[0]
  let duplicate_target = OpLog::new("generated-duplicate-batch")
  let plan = try! duplicate_target.prepare_remote([root, root])
  let duplicate_admitted = try! duplicate_target.commit_remote(plan)
  let single_target = OpLog::new("generated-duplicate-single")
  let single_admitted = try! single_target.apply_remote(root)
  duplicate_admitted.length() == 1 &&
  single_admitted.length() == 1 &&
  remote_delivery_matches_expected(duplicate_admitted[0], scenario.expected) &&
  duplicate_target.op_count() == 1 &&
  !duplicate_target.has_pending() &&
  remote_delivery_same_raw_sequence(
    oracle_raws(duplicate_target.get_all_ops()),
    oracle_raws(single_target.get_all_ops()),
  ) &&
  remote_delivery_same_raw_sequence(
    try! duplicate_target.get_frontier_raw(),
    try! single_target.get_frontier_raw(),
  )
}

///|
fn remote_delivery_final_state_matches(
  target : OpLog,
  scenario : RemoteDeliveryScenario,
  model : RemoteDeliveryModel,
) -> Bool {
  let actual = target.get_all_ops()
  if target.op_count() != scenario.ops.length() ||
    actual.length() != scenario.ops.length() ||
    target.has_pending() ||
    !model.pending.is_empty() ||
    model.known.length() != scenario.ops.length() ||
    model.admitted.length() != scenario.ops.length() {
    return false
  }
  let actual_raws = oracle_raws(actual)
  let source_raws = oracle_raws(scenario.ops)
  if !remote_delivery_same_raw_membership(actual_raws, source_raws) {
    return false
  }
  for op in actual {
    if !remote_delivery_matches_expected(op, scenario.expected) {
      return false
    }
  }
  remote_delivery_same_raw_membership(
    try! target.get_frontier_raw(),
    scenario.expected_frontier,
  )
}

///|
fn remote_delivery_replay(
  trace : RemoteDeliveryTrace,
) -> RemoteDeliveryEvidence {
  let scenario = remote_delivery_build_scenario(trace)
  let target = OpLog::new("generated-delivery-target")
  let model = RemoteDeliveryModel::RemoteDeliveryModel()
  let mut valid = true

  let parent_blocked = remote_delivery_has_missing_parent(scenario.merge, []) &&
    remote_delivery_has_missing_parent(scenario.delete, [])
  let insert_origin_blocked = scenario.merge.is_insert() &&
    remote_delivery_has_missing_origin(scenario.merge, [])
  let delete_origin_blocked = scenario.delete.is_delete() &&
    remote_delivery_has_missing_origin(scenario.delete, [])

  let (delete_ok, delete_admitted) = remote_delivery_apply_step(
    target,
    model,
    scenario.delete,
    scenario.expected,
  )
  valid = valid && delete_ok && delete_admitted == 0
  let pending = target.has_pending() &&
    target.planner.pending_operations().length() == 1
  let count_before_pending_duplicate = target.op_count()
  let frontier_before_pending_duplicate = try! target.get_frontier_raw()
  let pending_before_duplicate = oracle_raws(
    target.planner.pending_operations(),
  )
  let pending_duplicate = try! target.apply_remote(scenario.delete)
  let duplicate_while_pending = pending_duplicate.is_empty() &&
    target.op_count() == count_before_pending_duplicate &&
    remote_delivery_same_raw_sequence(
      try! target.get_frontier_raw(),
      frontier_before_pending_duplicate,
    ) &&
    remote_delivery_same_raw_sequence(
      oracle_raws(target.planner.pending_operations()),
      pending_before_duplicate,
    )
  valid = valid &&
    duplicate_while_pending &&
    remote_delivery_pending_matches(target, model)

  let (merge_ok, merge_admitted) = remote_delivery_apply_step(
    target,
    model,
    scenario.merge,
    scenario.expected,
  )
  let (undelete_ok, undelete_admitted) = remote_delivery_apply_step(
    target,
    model,
    scenario.undelete,
    scenario.expected,
  )
  valid = valid &&
    merge_ok &&
    undelete_ok &&
    merge_admitted == 0 &&
    undelete_admitted == 0

  for op in remote_delivery_suffix_schedule(scenario, trace.schedule_seed) {
    let (step_ok, admitted) = remote_delivery_apply_step(
      target,
      model,
      op,
      scenario.expected,
    )
    valid = valid && step_ok && admitted == 0
  }

  let root_order = if trace.schedule_seed % 2 == 0 {
    scenario.roots
  } else {
    [scenario.roots[1], scenario.roots[0]]
  }
  let (first_root_ok, first_root_admitted) = remote_delivery_apply_step(
    target,
    model,
    root_order[0],
    scenario.expected,
  )
  let parent_blocked_until_final = parent_blocked &&
    remote_delivery_has_missing_parent(scenario.merge, model.known) &&
    remote_delivery_has_missing_parent(scenario.delete, model.known)
  let insert_origin_blocked_until_final = insert_origin_blocked &&
    remote_delivery_has_missing_origin(scenario.merge, model.known)
  let delete_origin_blocked_until_final = delete_origin_blocked &&
    remote_delivery_has_missing_origin(scenario.delete, model.known)
  let pending_until_final_dependency = target.has_pending() &&
    model.pending.iter().any(op => oracle_raw(op) == oracle_raw(scenario.merge)) &&
    model.pending
    .iter()
    .any(op => oracle_raw(op) == oracle_raw(scenario.delete)) &&
    parent_blocked_until_final &&
    insert_origin_blocked_until_final &&
    delete_origin_blocked_until_final
  let pending_before_wakeup = model.pending.length()
  let (second_root_ok, wakeup_count) = remote_delivery_apply_step(
    target,
    model,
    root_order[1],
    scenario.expected,
  )
  let wakeup_drain = first_root_admitted == 1 &&
    pending_before_wakeup >= 3 &&
    wakeup_count == pending_before_wakeup + 1 &&
    !target.has_pending()
  valid = valid &&
    first_root_ok &&
    second_root_ok &&
    pending_until_final_dependency &&
    wakeup_drain &&
    remote_delivery_final_state_matches(target, scenario, model)

  let count_before_admitted_duplicates = target.op_count()
  let ops_before_admitted_duplicates = oracle_raws(target.get_all_ops())
  let frontier_before_admitted_duplicates = try! target.get_frontier_raw()
  let duplicate_delete = try! target.apply_remote(scenario.delete)
  let duplicate_merge = try! target.apply_remote(scenario.merge)
  let duplicate_after_admission = duplicate_delete.is_empty() &&
    duplicate_merge.is_empty() &&
    target.op_count() == count_before_admitted_duplicates &&
    remote_delivery_same_raw_sequence(
      oracle_raws(target.get_all_ops()),
      ops_before_admitted_duplicates,
    ) &&
    remote_delivery_same_raw_sequence(
      try! target.get_frontier_raw(),
      frontier_before_admitted_duplicates,
    ) &&
    !target.has_pending()
  valid = valid &&
    duplicate_after_admission &&
    remote_delivery_final_state_matches(target, scenario, model)

  {
    valid,
    out_of_order: pending && scenario.delete.parents().length() > 0,
    pending,
    wakeup_drain,
    parent_blocked: parent_blocked_until_final,
    insert_origin_blocked: insert_origin_blocked_until_final,
    delete_origin_blocked: delete_origin_blocked_until_final,
    duplicate_before_admission: remote_delivery_duplicate_before_admission(
      scenario,
    ),
    duplicate_while_pending,
    duplicate_after_admission,
    final_count: target.op_count(),
  }
}

///|
fn prop_generated_remote_delivery_complete(trace : RemoteDeliveryTrace) -> Bool {
  let evidence = remote_delivery_replay(trace)
  let scenario = remote_delivery_build_scenario(trace)
  evidence.valid &&
  evidence.final_count == scenario.ops.length() &&
  evidence.out_of_order &&
  evidence.pending &&
  evidence.wakeup_drain
}

///|
/// PR #92 delivery seam: identity repeats are equal only when their payload is.
test "generated delivery distinguishes identical and conflicting payloads" {
  let root = @core.Op::new_insert(
    -1,
    [],
    "generated-identity",
    0,
    "a",
    None,
    None,
  )
  let identical_target = OpLog::new("generated-identical")
  let identical_plan = try! identical_target.prepare_remote([root, root])
  let identical = try! identical_target.commit_remote(identical_plan)
  assert_eq(identical.length(), 1)
  assert_eq(identical_target.op_count(), 1)

  let conflicting = @core.Op::new_insert(
    73,
    [],
    "generated-identity",
    0,
    "b",
    None,
    None,
  )
  let conflict_target = OpLog::new("generated-conflicting")
  let result : Result[RemoteAdmissionPlan, OpLogError] = Ok(
    conflict_target.prepare_remote([root, conflicting]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::ConflictingIdentity(raw~)) =>
      assert_eq(raw, @core.RawVersion::new("generated-identity", 0))
    _ => fail("expected generated identity conflict")
  }
  assert_eq(conflict_target.op_count(), 0)
  assert_eq(conflict_target.has_pending(), false)

  let missing_parent = @core.RawVersion::new("generated-parent", 0)
  let pending = @core.Op::new_insert(
    11,
    [missing_parent],
    "generated-pending",
    1,
    "authoritative",
    None,
    None,
  )
  let pending_target = OpLog::new("generated-pending-target")
  assert_eq(try! pending_target.apply_remote(pending).length(), 0)
  assert_true(pending_target.has_pending())
  assert_eq(pending_target.op_count(), 0)
  let pending_frontier = try! pending_target.get_frontier_raw()
  let pending_duplicate = @core.Op::new_insert(
    12,
    [missing_parent],
    "generated-pending",
    1,
    "authoritative",
    None,
    None,
  )
  assert_eq(try! pending_target.apply_remote(pending_duplicate).length(), 0)
  assert_true(pending_target.has_pending())
  let retained = pending_target.planner.pending_operations()
  assert_eq(retained.length(), 1)
  assert_eq(retained[0].lv(), 11)
  match retained[0].content() {
    Insert(text) => assert_eq(text, "authoritative")
    Delete | Undelete => fail("pending payload changed kind")
  }

  let pending_conflict = @core.Op::new_insert(
    13,
    [missing_parent],
    "generated-pending",
    1,
    "conflict",
    None,
    None,
  )
  let pending_result : Result[RemoteAdmissionPlan, OpLogError] = Ok(
    pending_target.prepare_remote([pending_conflict]),
  ) catch {
    error => Err(error)
  }
  match pending_result {
    Err(OpLogError::ConflictingIdentity(raw~)) =>
      assert_eq(raw, @core.RawVersion::new("generated-pending", 1))
    _ => fail("expected pending identity conflict")
  }
  assert_eq(pending_target.op_count(), 0)
  assert_eq(try! pending_target.get_frontier_raw(), pending_frontier)
  assert_true(pending_target.has_pending())
  let retained_after = pending_target.planner.pending_operations()
  match retained_after[0].content() {
    Insert(text) => assert_eq(text, "authoritative")
    Delete | Undelete => fail("pending payload changed kind")
  }

  let parent = @core.Op::new_insert(
    -1,
    [],
    missing_parent.agent,
    missing_parent.seq,
    "p",
    None,
    None,
  )
  let admitted = try! pending_target.apply_remote(parent)
  assert_eq(admitted.length(), 2)
  assert_eq(pending_target.op_count(), 2)
  assert_true(!pending_target.has_pending())
  let admitted_frontier = try! pending_target.get_frontier_raw()

  let admitted_source = pending_target
    .get_all_ops()
    .iter()
    .find_first(op => op.agent() == "generated-pending")
    .unwrap()
  let admitted_text = match admitted_source.content() {
    Insert(text) => text
    Delete | Undelete => fail("admitted pending operation changed kind")
  }
  let admitted_duplicate = @core.Op::new_insert(
    99,
    admitted_source.parents(),
    admitted_source.agent(),
    admitted_source.seq(),
    admitted_text,
    admitted_source.origin_left(),
    admitted_source.origin_right(),
  )
  assert_eq(try! pending_target.apply_remote(admitted_duplicate).length(), 0)
  assert_eq(pending_target.op_count(), 2)
  assert_eq(try! pending_target.get_frontier_raw(), admitted_frontier)
  let admitted_conflict = @core.Op::new_insert(
    100,
    [missing_parent],
    "generated-pending",
    1,
    "conflict",
    None,
    None,
  )
  let admitted_result : Result[RemoteAdmissionPlan, OpLogError] = Ok(
    pending_target.prepare_remote([admitted_conflict]),
  ) catch {
    error => Err(error)
  }
  match admitted_result {
    Err(OpLogError::ConflictingIdentity(raw~)) =>
      assert_eq(raw, @core.RawVersion::new("generated-pending", 1))
    _ => fail("expected admitted identity conflict")
  }
  assert_eq(pending_target.op_count(), 2)
  assert_eq(try! pending_target.get_frontier_raw(), admitted_frontier)
  assert_true(!pending_target.has_pending())
}

///|
fn prop_generated_remote_delivery_duplicates(
  trace : RemoteDeliveryTrace,
) -> Bool {
  let evidence = remote_delivery_replay(trace)
  evidence.valid &&
  evidence.duplicate_before_admission &&
  evidence.duplicate_while_pending &&
  evidence.duplicate_after_admission
}

///|
fn prop_generated_remote_delivery_dependencies(
  trace : RemoteDeliveryTrace,
) -> Bool {
  let evidence = remote_delivery_replay(trace)
  evidence.valid &&
  evidence.parent_blocked &&
  evidence.insert_origin_blocked &&
  evidence.delete_origin_blocked &&
  evidence.pending &&
  evidence.wakeup_drain
}

///|
test "property generator: remote delivery scenarios are closed and non-vacuous" {
  let traces : Array[RemoteDeliveryTrace] = @quickcheck.samples(32)
  assert_true(!traces.is_empty())
  let mut saw_suffix = false
  for trace in traces {
    let scenario = remote_delivery_build_scenario(trace)
    assert_eq(scenario.ops.length(), 5 + trace.suffix_count)
    assert_eq(scenario.expected.length(), scenario.ops.length())
    let (planned, remaining) = try! oracle_plan_remote_candidates(
      scenario.ops.copy(),
      [],
    )
    assert_eq(planned.length(), scenario.ops.length())
    assert_true(remaining.is_empty())
    let evidence = remote_delivery_replay(trace)
    assert_true(evidence.valid)
    assert_true(evidence.out_of_order)
    assert_true(evidence.pending)
    assert_true(evidence.wakeup_drain)
    assert_true(evidence.parent_blocked)
    assert_true(evidence.insert_origin_blocked)
    assert_true(evidence.delete_origin_blocked)
    assert_true(evidence.duplicate_before_admission)
    assert_true(evidence.duplicate_while_pending)
    assert_true(evidence.duplicate_after_admission)
    if trace.suffix_count > 0 {
      saw_suffix = true
    }
    for shrunk in @qc.Shrink::shrink(trace) {
      let shrunk_scenario = remote_delivery_build_scenario(shrunk)
      let (_, shrunk_remaining) = try! oracle_plan_remote_candidates(
        shrunk_scenario.ops.copy(),
        [],
      )
      assert_true(shrunk_remaining.is_empty())
    }
  }
  assert_true(saw_suffix)
}

///|
test "property: shuffled remote delivery admits every source operation once" {
  @qc.quick_check_fn(
    prop_generated_remote_delivery_complete,
    max_success=100,
    max_size=16,
  )
}

///|
test "property: identical remote duplicates are lifecycle-idempotent" {
  @qc.quick_check_fn(
    prop_generated_remote_delivery_duplicates,
    max_success=100,
    max_size=16,
  )
}

///|
test "property: missing parent and origin dependencies drain exactly once" {
  @qc.quick_check_fn(
    prop_generated_remote_delivery_dependencies,
    max_success=100,
    max_size=16,
  )
}
