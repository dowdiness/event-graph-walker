///| Generated model traces for the private remote-change application pending-changes owner lifecycle.

///|
enum PendingChangesLifecycleEvent {
  MalformedBegin
  StaleBegin
  PrepareUnresolved
  BeginUnresolved
  BeginConsumed
  RejectAttempt
  RetrySameIdentity
  AdmitBlocker
  PartialAcknowledge
  Compact
  AcknowledgeRest
} derive(Debug)

///|
struct PendingChangesLifecycleTrace {
  depth : Int
  arrival_mode : Int
  acknowledgement_prefix : Int
} derive(Debug)

///|
struct PendingChangesLifecycleFixture {
  malformed_probe : @core.Op
  stale_probe : @core.Op
  external_apply_changes : @core.Op
  blocker : @core.Op
  unrelated_blocker : @core.Op
  unrelated_waiter : @core.Op
  component : Array[@core.Op]
  delivered_component : Array[@core.Op]
}

///|
struct PendingChangesLifecyclePending {
  op : @core.Op
  arrival : Int
}

///|
struct PendingChangesLifecycleModel {
  mut pending : Array[PendingChangesLifecyclePending]
  applied : @hashset.HashSet[@core.RawVersion]
  applied_order : Array[@core.RawVersion]
  mut next_arrival : Int
  mut generation : Int
}

///|
struct PendingChangesLifecycleModelPlan {
  staged : Array[@core.Op]
  planned : Array[@core.Op]
  remaining : Array[@core.Op]
  next_arrival : Int
  generation : Int
  mut consumed : Bool
}

///|
struct PendingChangesLifecycleNodeSnapshot {
  raw : @core.RawVersion
  op : @core.Op
  arrival : Int
  dependencies : Array[@core.RawVersion]
  waiting_dependencies : Array[@core.RawVersion]
  unresolved_count : Int
  ready_refs : Int
}

///|
struct PendingChangesLifecycleOrderSnapshot {
  raw : @core.RawVersion
  arrival : Int
}

///|
struct PendingChangesLifecycleWaiterSnapshot {
  dependency : @core.RawVersion
  raws : Array[@core.RawVersion]
  arrivals : Array[Int]
}

///|
struct PendingChangesLifecycleSnapshot {
  nodes : Array[PendingChangesLifecycleNodeSnapshot]
  order : Array[PendingChangesLifecycleOrderSnapshot]
  waiters : Array[PendingChangesLifecycleWaiterSnapshot]
  ready : Array[ReadyChange]
  next_arrival : Int
  generation : Int
  stale_order_tombstones : Int
  stale_waiter_refs : Int
  stale_ready_refs : Int
  plan_consumed : Bool
}

///|
fn pending_changes_lifecycle_rand_bounded(
  random_state : @splitmix.RandomState,
  bound : Int,
) -> Int {
  random_state.next_positive_int() % bound
}

///|
impl @quickcheck.Arbitrary for PendingChangesLifecycleTrace with fn arbitrary(
  size,
  random_state,
) {
  let size_cap = size.max(0)
  let depth_bound = 1 + (size_cap / 4).min(4)
  let depth = 2 +
    pending_changes_lifecycle_rand_bounded(random_state.split(), depth_bound)
  {
    depth,
    arrival_mode: pending_changes_lifecycle_rand_bounded(
      random_state.split(),
      3,
    ),
    acknowledgement_prefix: 1 +
    pending_changes_lifecycle_rand_bounded(random_state.split(), depth),
  }
}

///|
impl @qc.Shrink for PendingChangesLifecycleTrace with fn shrink(self) {
  let results : Array[PendingChangesLifecycleTrace] = []
  if self.depth > 2 {
    let half = self.depth / 2
    let depth = if half < 2 { 2 } else { half }
    results.push({
      depth,
      arrival_mode: self.arrival_mode,
      acknowledgement_prefix: self.acknowledgement_prefix.min(depth),
    })
  }
  if self.arrival_mode != 0 {
    results.push({
      depth: self.depth,
      arrival_mode: 0,
      acknowledgement_prefix: self.acknowledgement_prefix,
    })
  }
  if self.acknowledgement_prefix != 1 {
    results.push({
      depth: self.depth,
      arrival_mode: self.arrival_mode,
      acknowledgement_prefix: 1,
    })
  }
  results.iter()
}

///|
fn PendingChangesLifecycleTrace::events(
  _self : PendingChangesLifecycleTrace,
) -> Array[PendingChangesLifecycleEvent] {
  [
    MalformedBegin,
    StaleBegin,
    PrepareUnresolved,
    BeginUnresolved,
    BeginConsumed,
    RejectAttempt,
    RetrySameIdentity,
    AdmitBlocker,
    PartialAcknowledge,
    Compact,
    AcknowledgeRest,
  ]
}

///|
fn pending_changes_lifecycle_has_required_events(
  trace : PendingChangesLifecycleTrace,
) -> Bool {
  let mut malformed = false
  let mut stale = false
  let mut prepare = false
  let mut success = false
  let mut consumed = false
  let mut rejection = false
  let mut retry = false
  let mut acknowledgement = false
  let mut partial = false
  let mut compaction = false
  for event in trace.events() {
    match event {
      MalformedBegin => malformed = true
      StaleBegin => stale = true
      PrepareUnresolved => prepare = true
      BeginUnresolved => success = true
      BeginConsumed => consumed = true
      RejectAttempt => rejection = true
      RetrySameIdentity => retry = true
      AdmitBlocker => acknowledgement = true
      PartialAcknowledge => partial = true
      Compact => compaction = true
      AcknowledgeRest => acknowledgement = true
    }
  }
  malformed &&
  stale &&
  prepare &&
  success &&
  consumed &&
  rejection &&
  retry &&
  acknowledgement &&
  partial &&
  compaction &&
  trace.acknowledgement_prefix > 0 &&
  trace.acknowledgement_prefix < trace.depth + 1
}

///|
fn pending_changes_lifecycle_same_op(left : @core.Op, right : @core.Op) -> Bool {
  left.lv() == right.lv() &&
  left.agent() == right.agent() &&
  left.seq() == right.seq() &&
  left.content() == right.content() &&
  left.parents() == right.parents() &&
  left.origin_left() == right.origin_left() &&
  left.origin_right() == right.origin_right() &&
  left.is_insert() == right.is_insert() &&
  left.is_delete() == right.is_delete() &&
  left.is_undelete() == right.is_undelete()
}

///|
fn pending_changes_lifecycle_same_ops(
  left : ArrayView[@core.Op],
  right : ArrayView[@core.Op],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for i in 0..<left.length() {
    if !pending_changes_lifecycle_same_op(left[i], right[i]) {
      return false
    }
  }
  true
}

///|
fn pending_changes_lifecycle_same_raws(
  left : ArrayView[@core.RawVersion],
  right : ArrayView[@core.RawVersion],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for i in 0..<left.length() {
    if left[i] != right[i] {
      return false
    }
  }
  true
}

///|
fn pending_changes_lifecycle_same_raw_membership(
  left : ArrayView[@core.RawVersion],
  right : ArrayView[@core.RawVersion],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  let left_set : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet(left)
  for raw in right {
    if !left_set.contains(raw) {
      return false
    }
  }
  true
}

///|
fn pending_changes_lifecycle_fixture(
  trace : PendingChangesLifecycleTrace,
) -> PendingChangesLifecycleFixture {
  let malformed_probe = @core.Op::insert(
    -1,
    [],
    "generated-malformed-probe",
    0,
    "m",
    None,
    None,
  )
  let stale_probe = @core.Op::insert(
    -1,
    [],
    "generated-stale-probe",
    0,
    "s",
    None,
    None,
  )
  let external_apply_changes = @core.Op::insert(
    -1,
    [],
    "generated-external-admission",
    0,
    "e",
    None,
    None,
  )
  let blocker = @core.Op::insert(
    -1,
    [],
    "generated-lifecycle-blocker",
    0,
    "b",
    None,
    None,
  )
  let unrelated_blocker = @core.Op::insert(
    -1,
    [],
    "generated-unrelated-blocker",
    0,
    "u",
    None,
    None,
  )
  let unrelated_waiter = @core.Op::insert(
    -1,
    [oracle_raw(unrelated_blocker)],
    "generated-unrelated-waiter",
    0,
    "w",
    None,
    None,
  )
  let component : Array[@core.Op] = []
  for i in 0..<trace.depth {
    let dependency = if i == 0 {
      oracle_raw(blocker)
    } else {
      oracle_raw(component[i - 1])
    }
    component.push(
      @core.Op::insert(
        -1,
        [dependency],
        "generated-lifecycle-chain",
        i,
        "x",
        None,
        None,
      ),
    )
  }
  let delivered_component = match trace.arrival_mode {
    0 => component.copy()
    1 => oracle_reverse(component)
    _ => oracle_zigzag(component)
  }
  {
    malformed_probe,
    stale_probe,
    external_apply_changes,
    blocker,
    unrelated_blocker,
    unrelated_waiter,
    component,
    delivered_component,
  }
}

///|
fn PendingChangesLifecycleModel::PendingChangesLifecycleModel() -> PendingChangesLifecycleModel {
  {
    pending: [],
    applied: @hashset.HashSet([]),
    applied_order: [],
    next_arrival: 0,
    generation: 0,
  }
}

///|
fn PendingChangesLifecycleModel::is_applied(
  self : PendingChangesLifecycleModel,
  raw : @core.RawVersion,
) -> Bool {
  self.applied.contains(raw)
}

///|
fn PendingChangesLifecycleModel::has_pending_raw(
  self : PendingChangesLifecycleModel,
  raw : @core.RawVersion,
) -> Bool {
  self.pending.any(entry => oracle_raw(entry.op) == raw)
}

///|
fn PendingChangesLifecycleModel::pending_ops(
  self : PendingChangesLifecycleModel,
) -> Array[@core.Op] {
  self.pending.map(entry => entry.op)
}

///|
fn PendingChangesLifecycleModel::pending_raws(
  self : PendingChangesLifecycleModel,
) -> Array[@core.RawVersion] {
  self.pending.map(entry => oracle_raw(entry.op))
}

///|
fn PendingChangesLifecycleModel::prepare(
  self : PendingChangesLifecycleModel,
  incoming : Array[@core.Op],
) -> PendingChangesLifecycleModelPlan raise OpLogError {
  let staged : Array[@core.Op] = []
  let seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for op in incoming {
    let raw = oracle_raw(op)
    if self.is_applied(raw) || self.has_pending_raw(raw) || seen.contains(raw) {
      continue
    }
    seen.add(raw)
    staged.push(op)
  }
  let candidates = self.pending_ops()
  for op in staged {
    candidates.push(op)
  }
  let (planned, remaining) = oracle_plan_remote_candidates(
    candidates,
    self.applied_order,
  )
  {
    staged,
    planned,
    remaining,
    next_arrival: self.next_arrival + staged.length(),
    generation: self.generation,
    consumed: false,
  }
}

///|
fn PendingChangesLifecycleModel::begin(
  self : PendingChangesLifecycleModel,
  plan : PendingChangesLifecycleModelPlan,
) -> Bool {
  if plan.consumed || plan.generation != self.generation {
    return false
  }
  for index, op in plan.staged {
    self.pending.push({ op, arrival: self.next_arrival + index, })
  }
  self.next_arrival = plan.next_arrival
  plan.consumed = true
  self.generation += 1
  true
}

///|
fn PendingChangesLifecycleModel::acknowledge(
  self : PendingChangesLifecycleModel,
  raw : @core.RawVersion,
) -> Unit {
  if self.applied.add_and_check(raw) {
    self.applied_order.push(raw)
  }
  self.pending = self.pending.filter(entry => oracle_raw(entry.op) != raw)
  self.generation += 1
}

///|
fn pending_changes_lifecycle_depends_on_any(
  op : @core.Op,
  rejected : @hashset.HashSet[@core.RawVersion],
) -> Bool {
  for parent in op.parents_iter() {
    if rejected.contains(parent) {
      return true
    }
  }
  match op.origin_left() {
    Some(origin) => if rejected.contains(origin) { return true }
    None => ()
  }
  match op.origin_right() {
    Some(origin) => if rejected.contains(origin) { return true }
    None => ()
  }
  false
}

///|
fn PendingChangesLifecycleModel::reject(
  self : PendingChangesLifecycleModel,
  roots : Array[@core.RawVersion],
) -> Unit {
  let rejected : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet(roots)
  let mut changed = true
  while changed {
    changed = false
    for entry in self.pending {
      let raw = oracle_raw(entry.op)
      if !rejected.contains(raw) &&
        pending_changes_lifecycle_depends_on_any(entry.op, rejected) {
        rejected.add(raw)
        changed = true
      }
    }
  }
  let before = self.pending.length()
  self.pending = self.pending.filter(entry => {
    !rejected.contains(oracle_raw(entry.op))
  })
  if self.pending.length() != before {
    self.generation += 1
  }
}

///|
fn PendingChangesLifecycleModel::compact(
  self : PendingChangesLifecycleModel,
) -> Unit {
  self.pending = self.pending.filter(entry => {
    !self.is_applied(oracle_raw(entry.op))
  })
  self.generation += 1
}

///|
fn pending_changes_lifecycle_snapshot(
  pending_changes : PendingChanges,
  plan_consumed : Bool,
) -> PendingChangesLifecycleSnapshot {
  let nodes : Array[PendingChangesLifecycleNodeSnapshot] = []
  for raw, node in pending_changes.pending {
    nodes.push({
      raw,
      op: node.op,
      arrival: node.arrival,
      dependencies: node.dependencies.copy(),
      waiting_dependencies: node.waiting_dependencies.copy(),
      unresolved_count: node.unresolved_count,
      ready_refs: node.ready_refs,
    })
  }
  let order = pending_changes.pending_order.map(entry => PendingChangesLifecycleOrderSnapshot::{
    raw: entry.raw,
    arrival: entry.arrival,
  })
  let waiters : Array[PendingChangesLifecycleWaiterSnapshot] = []
  for dependency, bucket in pending_changes.waiters {
    waiters.push({
      dependency,
      raws: bucket.map(waiter => waiter.raw),
      arrivals: bucket.map(waiter => waiter.arrival),
    })
  }
  let ready : Array[ReadyChange] = []
  let ready_copy = pending_changes.ready.copy()
  while ready_copy.pop() is Some(entry) {
    ready.push(entry)
  }
  {
    nodes,
    order,
    waiters,
    ready,
    next_arrival: pending_changes.next_arrival,
    generation: pending_changes.generation,
    stale_order_tombstones: pending_changes.stale_order_tombstones,
    stale_waiter_refs: pending_changes.stale_waiter_refs,
    stale_ready_refs: pending_changes.stale_ready_refs,
    plan_consumed,
  }
}

///|
fn pending_changes_lifecycle_same_snapshot_node(
  left : PendingChangesLifecycleNodeSnapshot,
  right : PendingChangesLifecycleNodeSnapshot,
) -> Bool {
  left.raw == right.raw &&
  pending_changes_lifecycle_same_op(left.op, right.op) &&
  left.arrival == right.arrival &&
  left.dependencies == right.dependencies &&
  left.waiting_dependencies == right.waiting_dependencies &&
  left.unresolved_count == right.unresolved_count &&
  left.ready_refs == right.ready_refs
}

///|
fn pending_changes_lifecycle_same_snapshot(
  left : PendingChangesLifecycleSnapshot,
  right : PendingChangesLifecycleSnapshot,
) -> Bool {
  if left.nodes.length() != right.nodes.length() ||
    left.order.length() != right.order.length() ||
    left.waiters.length() != right.waiters.length() ||
    left.ready.length() != right.ready.length() {
    return false
  }
  for i in 0..<left.nodes.length() {
    if !pending_changes_lifecycle_same_snapshot_node(
        left.nodes[i],
        right.nodes[i],
      ) {
      return false
    }
  }
  for i in 0..<left.order.length() {
    if left.order[i].raw != right.order[i].raw ||
      left.order[i].arrival != right.order[i].arrival {
      return false
    }
  }
  for i in 0..<left.waiters.length() {
    if left.waiters[i].dependency != right.waiters[i].dependency ||
      left.waiters[i].raws != right.waiters[i].raws ||
      left.waiters[i].arrivals != right.waiters[i].arrivals {
      return false
    }
  }
  for i in 0..<left.ready.length() {
    if left.ready[i] != right.ready[i] {
      return false
    }
  }
  left.next_arrival == right.next_arrival &&
  left.generation == right.generation &&
  left.stale_order_tombstones == right.stale_order_tombstones &&
  left.stale_waiter_refs == right.stale_waiter_refs &&
  left.stale_ready_refs == right.stale_ready_refs &&
  left.plan_consumed == right.plan_consumed
}

///|
fn pending_changes_lifecycle_matches_model(
  pending_changes : PendingChanges,
  model : PendingChangesLifecycleModel,
) -> Bool {
  let actual = pending_changes.pending_operations()
  if !pending_changes_lifecycle_same_ops(actual, model.pending_ops()) ||
    !pending_changes_lifecycle_same_raws(
      pending_changes.pending_raws(),
      model.pending_raws(),
    ) ||
    pending_changes.generation != model.generation ||
    pending_changes.next_arrival != model.next_arrival {
    return false
  }
  for entry in model.pending {
    if pending_changes.arrival_of(oracle_raw(entry.op)) != Some(entry.arrival) {
      return false
    }
  }
  true
}

///|
fn pending_changes_lifecycle_plan_matches_model(
  pending_changes : PendingChanges,
  actual : ApplyChanges,
  expected : PendingChangesLifecycleModelPlan,
) -> Bool {
  pending_changes_lifecycle_same_ops(actual.operations(), expected.planned) &&
  pending_changes_lifecycle_same_raws(
    actual.remaining_raws(pending_changes),
    oracle_raws(expected.remaining),
  ) &&
  actual.generation() == expected.generation
}

///|
fn pending_changes_lifecycle_prepare_checked(
  pending_changes : PendingChanges,
  model : PendingChangesLifecycleModel,
  incoming : Array[@core.Op],
) -> (ApplyChanges, PendingChangesLifecycleModelPlan)? raise OpLogError {
  let before = pending_changes_lifecycle_snapshot(pending_changes, false)
  let expected = model.prepare(incoming)
  let actual = pending_changes.prepare(incoming, raw => model.is_applied(raw))
  let after = pending_changes_lifecycle_snapshot(pending_changes, false)
  if pending_changes_lifecycle_same_snapshot(before, after) &&
    pending_changes_lifecycle_plan_matches_model(
      pending_changes, actual, expected,
    ) {
    Some((actual, expected))
  } else {
    None
  }
}

///|
fn pending_changes_lifecycle_current_plan_matches_model(
  pending_changes : PendingChanges,
  model : PendingChangesLifecycleModel,
) -> Bool raise OpLogError {
  match pending_changes_lifecycle_prepare_checked(pending_changes, model, []) {
    Some(_) => true
    None => false
  }
}

///|
fn pending_changes_lifecycle_waiter_state_matches_suffix(
  pending_changes : PendingChanges,
  planned : Array[@core.Op],
  acknowledged : Int,
) -> Bool {
  for i in acknowledged..<planned.length() {
    let raw = oracle_raw(planned[i])
    guard pending_changes.pending.get(raw) is Some(node) else { return false }
    let expected_unresolved = if i == acknowledged { 0 } else { 1 }
    if node.unresolved_count != expected_unresolved {
      return false
    }
  }
  true
}

///|
fn pending_changes_lifecycle_ready_retry_is_safe(
  trace : PendingChangesLifecycleTrace,
) -> Bool {
  let root = @core.Op::insert(
    -1,
    [],
    "generated-ready-retry-root",
    0,
    "r",
    None,
    None,
  )
  let child = @core.Op::insert(
    -1,
    [oracle_raw(root)],
    "generated-ready-retry-child",
    0,
    "c",
    None,
    None,
  )
  let natural = [root, child]
  let incoming = if trace.arrival_mode == 0 {
    natural.copy()
  } else if trace.arrival_mode == 1 {
    oracle_reverse(natural)
  } else {
    oracle_zigzag(natural)
  }
  let pending_changes = PendingChanges()
  let model = PendingChangesLifecycleModel()
  guard (try! pending_changes_lifecycle_prepare_checked(
      pending_changes, model, incoming,
    ))
    is Some((initial, initial_expected)) else {
    return false
  }
  if !model.begin(initial_expected) {
    return false
  }
  match pending_changes.begin(initial, raw => model.is_applied(raw)) {
    BeginApplyResult::Started => ()
    _ => return false
  }
  let root_raw = oracle_raw(root)
  model.reject([root_raw])
  pending_changes.reject_pending_dependents([root_raw])
  if !pending_changes_lifecycle_matches_model(pending_changes, model) ||
    pending_changes.stale_count() == 0 {
    return false
  }
  guard (try! pending_changes_lifecycle_prepare_checked(
      pending_changes,
      model,
      [],
    ))
    is Some((stale_only, stale_only_expected)) else {
    return false
  }
  if !stale_only.operations().is_empty() ||
    !stale_only_expected.remaining.is_empty() {
    return false
  }
  guard (try! pending_changes_lifecycle_prepare_checked(
      pending_changes, model, incoming,
    ))
    is Some((retry, retry_expected)) else {
    return false
  }
  if !pending_changes_lifecycle_same_ops(retry_expected.planned, natural) ||
    !model.begin(retry_expected) {
    return false
  }
  match pending_changes.begin(retry, raw => model.is_applied(raw)) {
    BeginApplyResult::Started => ()
    _ => return false
  }
  if !pending_changes_lifecycle_matches_model(pending_changes, model) ||
    !(try! pending_changes_lifecycle_current_plan_matches_model(
      pending_changes, model,
    )) {
    return false
  }
  model.acknowledge(root_raw)
  pending_changes.acknowledge_applied(root_raw)
  guard pending_changes.pending.get(oracle_raw(child)) is Some(child_node) else {
    return false
  }
  if child_node.unresolved_count != 0 ||
    !pending_changes_lifecycle_matches_model(pending_changes, model) ||
    !(try! pending_changes_lifecycle_current_plan_matches_model(
      pending_changes, model,
    )) {
    return false
  }
  let child_raw = oracle_raw(child)
  model.acknowledge(child_raw)
  pending_changes.acknowledge_applied(child_raw)
  pending_changes_lifecycle_matches_model(pending_changes, model) &&
  model.pending.is_empty() &&
  (try! pending_changes_lifecycle_current_plan_matches_model(
    pending_changes, model,
  ))
}

///|
fn prop_apply_changes_pending_changes_lifecycle(
  trace : PendingChangesLifecycleTrace,
) -> Bool {
  if !pending_changes_lifecycle_has_required_events(trace) {
    return false
  }
  let fixture = pending_changes_lifecycle_fixture(trace)
  let pending_changes = PendingChanges()
  let model = PendingChangesLifecycleModel()
  let original_arrivals : Map[@core.RawVersion, Int] = Default::default()
  let mut active_plan : ApplyChanges? = None
  let mut active_model_plan : PendingChangesLifecycleModelPlan? = None
  let mut drain_operations : Array[@core.Op] = []

  for event in trace.events() {
    match event {
      MalformedBegin => {
        guard (try! pending_changes_lifecycle_prepare_checked(
            pending_changes,
            model,
            [fixture.malformed_probe],
          ))
          is Some((plan, expected)) else {
          return false
        }
        plan.planned.push(fixture.malformed_probe)
        let before = pending_changes_lifecycle_snapshot(
          pending_changes,
          plan.consumed,
        )
        match pending_changes.begin(plan, raw => model.is_applied(raw)) {
          BeginApplyResult::Conflict => ()
          _ => return false
        }
        let after = pending_changes_lifecycle_snapshot(
          pending_changes,
          plan.consumed,
        )
        if !pending_changes_lifecycle_same_snapshot(before, after) ||
          expected.consumed {
          return false
        }

        // Exercise the general capability's all-validation-before-registration
        // boundary with a real unresolved dependency from the generated pool.
        guard (try! pending_changes_lifecycle_prepare_checked(
            pending_changes,
            model,
            [fixture.unrelated_waiter],
          ))
          is Some((general_plan, general_expected)) else {
          return false
        }
        match general_plan.storage {
          DeferredFast => return false
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
        let general_before = pending_changes_lifecycle_snapshot(
          pending_changes,
          general_plan.consumed,
        )
        match
          pending_changes.begin(general_plan, raw => model.is_applied(raw)) {
          BeginApplyResult::Conflict => ()
          _ => return false
        }
        let general_after = pending_changes_lifecycle_snapshot(
          pending_changes,
          general_plan.consumed,
        )
        if !pending_changes_lifecycle_same_snapshot(
            general_before, general_after,
          ) ||
          general_expected.consumed {
          return false
        }
      }
      StaleBegin => {
        guard (try! pending_changes_lifecycle_prepare_checked(
            pending_changes,
            model,
            [fixture.stale_probe],
          ))
          is Some((plan, expected)) else {
          return false
        }
        let applied_raw = oracle_raw(fixture.external_apply_changes)
        model.acknowledge(applied_raw)
        pending_changes.acknowledge_applied(applied_raw)
        if !pending_changes_lifecycle_matches_model(pending_changes, model) {
          return false
        }
        let before = pending_changes_lifecycle_snapshot(
          pending_changes,
          plan.consumed,
        )
        match pending_changes.begin(plan, raw => model.is_applied(raw)) {
          BeginApplyResult::Stale => ()
          _ => return false
        }
        let after = pending_changes_lifecycle_snapshot(
          pending_changes,
          plan.consumed,
        )
        if !pending_changes_lifecycle_same_snapshot(before, after) ||
          expected.consumed {
          return false
        }
      }
      PrepareUnresolved => {
        let unresolved = fixture.delivered_component.copy()
        unresolved.push(fixture.unrelated_waiter)
        guard (try! pending_changes_lifecycle_prepare_checked(
            pending_changes, model, unresolved,
          ))
          is Some((plan, expected)) else {
          return false
        }
        if !expected.planned.is_empty() {
          return false
        }
        active_plan = Some(plan)
        active_model_plan = Some(expected)
      }
      BeginUnresolved => {
        guard active_plan is Some(plan) && active_model_plan is Some(expected) else {
          return false
        }
        let generation_before = pending_changes.generation
        if !model.begin(expected) {
          return false
        }
        match pending_changes.begin(plan, raw => model.is_applied(raw)) {
          BeginApplyResult::Started => ()
          _ => return false
        }
        if !plan.consumed ||
          !expected.consumed ||
          pending_changes.generation != generation_before + 1 ||
          !pending_changes_lifecycle_matches_model(pending_changes, model) {
          return false
        }
        for op in fixture.component {
          guard pending_changes.arrival_of(oracle_raw(op)) is Some(arrival) else {
            return false
          }
          original_arrivals.set(oracle_raw(op), arrival)
        }
      }
      BeginConsumed => {
        guard active_plan is Some(plan) && active_model_plan is Some(expected) else {
          return false
        }
        let before = pending_changes_lifecycle_snapshot(
          pending_changes,
          plan.consumed,
        )
        if model.begin(expected) {
          return false
        }
        match pending_changes.begin(plan, raw => model.is_applied(raw)) {
          BeginApplyResult::Consumed => ()
          _ => return false
        }
        let after = pending_changes_lifecycle_snapshot(
          pending_changes,
          plan.consumed,
        )
        if !pending_changes_lifecycle_same_snapshot(before, after) {
          return false
        }
      }
      RejectAttempt => {
        if !pending_changes_lifecycle_ready_retry_is_safe(trace) {
          return false
        }
        let root = oracle_raw(fixture.component[0])
        model.reject([root])
        pending_changes.reject_pending_dependents([root])
        if !pending_changes_lifecycle_matches_model(pending_changes, model) ||
          !pending_changes_lifecycle_same_ops(model.pending_ops(), [
            fixture.unrelated_waiter,
          ]) {
          return false
        }
        guard (try! pending_changes_lifecycle_prepare_checked(
            pending_changes,
            model,
            [],
          ))
          is Some((stale_only, stale_only_expected)) else {
          return false
        }
        if !stale_only.operations().is_empty() ||
          !pending_changes_lifecycle_same_ops(stale_only_expected.remaining, [
            fixture.unrelated_waiter,
          ]) {
          return false
        }
      }
      RetrySameIdentity => {
        guard (try! pending_changes_lifecycle_prepare_checked(
            pending_changes,
            model,
            fixture.delivered_component,
          ))
          is Some((plan, expected)) else {
          return false
        }
        if !model.begin(expected) {
          return false
        }
        match pending_changes.begin(plan, raw => model.is_applied(raw)) {
          BeginApplyResult::Started => ()
          _ => return false
        }
        if !pending_changes_lifecycle_matches_model(pending_changes, model) {
          return false
        }
        for op in fixture.component {
          let raw = oracle_raw(op)
          guard pending_changes.pending.get(raw) is Some(node) &&
            original_arrivals.get(raw) is Some(original_arrival) else {
            return false
          }
          if node.arrival <= original_arrival ||
            !pending_changes_lifecycle_same_op(node.op, op) {
            return false
          }
        }
      }
      AdmitBlocker => {
        guard (try! pending_changes_lifecycle_prepare_checked(
            pending_changes,
            model,
            [fixture.blocker],
          ))
          is Some((plan, expected)) else {
          return false
        }
        drain_operations = plan.operations().to_owned()
        let expected_drain = [fixture.blocker]
        for op in fixture.component {
          expected_drain.push(op)
        }
        if !pending_changes_lifecycle_same_ops(drain_operations, expected_drain) ||
          !model.begin(expected) {
          return false
        }
        match pending_changes.begin(plan, raw => model.is_applied(raw)) {
          BeginApplyResult::Started => ()
          _ => return false
        }
        if !pending_changes_lifecycle_matches_model(pending_changes, model) {
          return false
        }
        active_plan = Some(plan)
        active_model_plan = Some(expected)
      }
      PartialAcknowledge => {
        guard active_plan is Some(plan) &&
          active_model_plan is Some(expected) &&
          plan.consumed &&
          expected.consumed else {
          return false
        }
        for i in 0..<trace.acknowledgement_prefix {
          let raw = oracle_raw(drain_operations[i])
          model.acknowledge(raw)
          pending_changes.acknowledge_applied(raw)
          if !pending_changes_lifecycle_matches_model(pending_changes, model) ||
            !pending_changes_lifecycle_waiter_state_matches_suffix(
              pending_changes,
              drain_operations,
              i + 1,
            ) ||
            !(try! pending_changes_lifecycle_current_plan_matches_model(
              pending_changes, model,
            )) {
            return false
          }
          let expected_suffix = drain_operations[i + 1:].to_owned()
          let next_plan = try! model.prepare([])
          if !pending_changes_lifecycle_same_ops(
              next_plan.planned,
              expected_suffix,
            ) ||
            !pending_changes_lifecycle_same_ops(next_plan.remaining, [
              fixture.unrelated_waiter,
            ]) {
            return false
          }
        }
        let expected_suffix_raws = oracle_raws(
          drain_operations[trace.acknowledgement_prefix:].to_owned(),
        )
        expected_suffix_raws.push(oracle_raw(fixture.unrelated_waiter))
        if !pending_changes_lifecycle_same_raw_membership(
            pending_changes.pending_raws(),
            expected_suffix_raws,
          ) {
          return false
        }
      }
      Compact => {
        guard (try! pending_changes_lifecycle_prepare_checked(
            pending_changes,
            model,
            [],
          ))
          is Some((before_plan, before_expected)) else {
          return false
        }
        let pending_before = pending_changes.pending_raws()
        let planned_before = before_plan.operations().to_owned()
        let remaining_before = before_plan.remaining_raws(pending_changes)
        model.compact()
        pending_changes.compact(raw => model.is_applied(raw))
        if !pending_changes_lifecycle_matches_model(pending_changes, model) ||
          pending_changes.stale_count() != 0 {
          return false
        }
        guard (try! pending_changes_lifecycle_prepare_checked(
            pending_changes,
            model,
            [],
          ))
          is Some((after_plan, after_expected)) else {
          return false
        }
        if !pending_changes_lifecycle_same_ops(
            planned_before,
            after_plan.operations(),
          ) ||
          !pending_changes_lifecycle_same_raws(
            oracle_raws(before_expected.remaining),
            oracle_raws(after_expected.remaining),
          ) ||
          !pending_changes_lifecycle_same_raws(
            remaining_before,
            after_plan.remaining_raws(pending_changes),
          ) ||
          !pending_changes_lifecycle_same_raws(
            pending_before,
            pending_changes.pending_raws(),
          ) {
          return false
        }
      }
      AcknowledgeRest => {
        for i in trace.acknowledgement_prefix..<drain_operations.length() {
          let raw = oracle_raw(drain_operations[i])
          model.acknowledge(raw)
          pending_changes.acknowledge_applied(raw)
          if !pending_changes_lifecycle_matches_model(pending_changes, model) ||
            !(try! pending_changes_lifecycle_current_plan_matches_model(
              pending_changes, model,
            )) {
            return false
          }
        }
        let final_plan = try! model.prepare([])
        if !pending_changes_lifecycle_same_ops(model.pending_ops(), [
            fixture.unrelated_waiter,
          ]) ||
          !pending_changes_lifecycle_same_raws(pending_changes.pending_raws(), [
            oracle_raw(fixture.unrelated_waiter),
          ]) ||
          !final_plan.planned.is_empty() ||
          !pending_changes_lifecycle_same_ops(final_plan.remaining, [
            fixture.unrelated_waiter,
          ]) ||
          fixture.unrelated_waiter.parents() !=
          [oracle_raw(fixture.unrelated_blocker)] {
          return false
        }
      }
    }
  }
  true
}

///|
test "property generator: pending-changes owner lifecycle traces are complete and strict" {
  let traces : Array[PendingChangesLifecycleTrace] = @quickcheck.samples(32)
  assert_true(!traces.is_empty())
  for trace in traces {
    assert_true(pending_changes_lifecycle_has_required_events(trace))
    assert_true(trace.depth >= 2)
    assert_true(trace.acknowledgement_prefix > 0)
    assert_true(trace.acknowledgement_prefix < trace.depth + 1)
  }
}

///|
test "property: generated pending-changes owner lifecycle traces match the model" {
  @qc.quick_check_fn(
    prop_apply_changes_pending_changes_lifecycle,
    max_success=100,
    max_size=24,
  )
}

// --- Explicit trait-method promotions (E0079) ---

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend PendingChangesLifecycleEvent with @debug.Debug::{to_repr}

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend PendingChangesLifecycleTrace with @debug.Debug::{to_repr}
