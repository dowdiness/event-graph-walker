///| Generated model traces for the private remote-admission planner lifecycle.

///|
enum PlannerLifecycleEvent {
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
struct PlannerLifecycleTrace {
  depth : Int
  arrival_mode : Int
  acknowledgement_prefix : Int
} derive(Debug)

///|
struct PlannerLifecycleFixture {
  malformed_probe : @core.Op
  stale_probe : @core.Op
  external_admission : @core.Op
  blocker : @core.Op
  unrelated_blocker : @core.Op
  unrelated_waiter : @core.Op
  component : Array[@core.Op]
  delivered_component : Array[@core.Op]
}

///|
struct PlannerLifecyclePending {
  op : @core.Op
  arrival : Int
}

///|
struct PlannerLifecycleModel {
  mut pending : Array[PlannerLifecyclePending]
  admitted : @hashset.HashSet[@core.RawVersion]
  admitted_order : Array[@core.RawVersion]
  mut next_arrival : Int
  mut generation : Int
}

///|
struct PlannerLifecycleModelPlan {
  staged : Array[@core.Op]
  planned : Array[@core.Op]
  remaining : Array[@core.Op]
  next_arrival : Int
  generation : Int
  mut consumed : Bool
}

///|
struct PlannerLifecycleNodeSnapshot {
  raw : @core.RawVersion
  op : @core.Op
  arrival : Int
  dependencies : Array[@core.RawVersion]
  waiting_dependencies : Array[@core.RawVersion]
  unresolved_count : Int
  ready_refs : Int
}

///|
struct PlannerLifecycleOrderSnapshot {
  raw : @core.RawVersion
  arrival : Int
}

///|
struct PlannerLifecycleWaiterSnapshot {
  dependency : @core.RawVersion
  raws : Array[@core.RawVersion]
  arrivals : Array[Int]
}

///|
struct PlannerLifecycleSnapshot {
  nodes : Array[PlannerLifecycleNodeSnapshot]
  order : Array[PlannerLifecycleOrderSnapshot]
  waiters : Array[PlannerLifecycleWaiterSnapshot]
  ready : Array[RemoteAdmissionReady]
  next_arrival : Int
  generation : Int
  stale_order_tombstones : Int
  stale_waiter_refs : Int
  stale_ready_refs : Int
  plan_consumed : Bool
}

///|
fn planner_lifecycle_rand_bounded(
  random_state : @splitmix.RandomState,
  bound : Int,
) -> Int {
  random_state.next_positive_int() % bound
}

///|
impl @quickcheck.Arbitrary for PlannerLifecycleTrace with fn arbitrary(
  size,
  random_state,
) {
  let size_cap = size.max(0)
  let depth_bound = 1 + (size_cap / 4).min(4)
  let depth = 2 +
    planner_lifecycle_rand_bounded(random_state.split(), depth_bound)
  {
    depth,
    arrival_mode: planner_lifecycle_rand_bounded(random_state.split(), 3),
    acknowledgement_prefix: 1 +
    planner_lifecycle_rand_bounded(random_state.split(), depth),
  }
}

///|
impl @qc.Shrink for PlannerLifecycleTrace with fn shrink(self) {
  let results : Array[PlannerLifecycleTrace] = []
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
fn PlannerLifecycleTrace::events(
  _self : PlannerLifecycleTrace,
) -> Array[PlannerLifecycleEvent] {
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
fn planner_lifecycle_has_required_events(trace : PlannerLifecycleTrace) -> Bool {
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
fn planner_lifecycle_same_op(left : @core.Op, right : @core.Op) -> Bool {
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
fn planner_lifecycle_same_ops(
  left : ArrayView[@core.Op],
  right : ArrayView[@core.Op],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for i in 0..<left.length() {
    if !planner_lifecycle_same_op(left[i], right[i]) {
      return false
    }
  }
  true
}

///|
fn planner_lifecycle_same_raws(
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
fn planner_lifecycle_same_raw_membership(
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
fn planner_lifecycle_fixture(
  trace : PlannerLifecycleTrace,
) -> PlannerLifecycleFixture {
  let malformed_probe = @core.Op::new_insert(
    -1,
    [],
    "generated-malformed-probe",
    0,
    "m",
    None,
    None,
  )
  let stale_probe = @core.Op::new_insert(
    -1,
    [],
    "generated-stale-probe",
    0,
    "s",
    None,
    None,
  )
  let external_admission = @core.Op::new_insert(
    -1,
    [],
    "generated-external-admission",
    0,
    "e",
    None,
    None,
  )
  let blocker = @core.Op::new_insert(
    -1,
    [],
    "generated-lifecycle-blocker",
    0,
    "b",
    None,
    None,
  )
  let unrelated_blocker = @core.Op::new_insert(
    -1,
    [],
    "generated-unrelated-blocker",
    0,
    "u",
    None,
    None,
  )
  let unrelated_waiter = @core.Op::new_insert(
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
      @core.Op::new_insert(
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
    external_admission,
    blocker,
    unrelated_blocker,
    unrelated_waiter,
    component,
    delivered_component,
  }
}

///|
fn PlannerLifecycleModel::PlannerLifecycleModel() -> PlannerLifecycleModel {
  {
    pending: [],
    admitted: @hashset.HashSet([]),
    admitted_order: [],
    next_arrival: 0,
    generation: 0,
  }
}

///|
fn PlannerLifecycleModel::is_admitted(
  self : PlannerLifecycleModel,
  raw : @core.RawVersion,
) -> Bool {
  self.admitted.contains(raw)
}

///|
fn PlannerLifecycleModel::has_pending_raw(
  self : PlannerLifecycleModel,
  raw : @core.RawVersion,
) -> Bool {
  self.pending.any(entry => oracle_raw(entry.op) == raw)
}

///|
fn PlannerLifecycleModel::pending_ops(
  self : PlannerLifecycleModel,
) -> Array[@core.Op] {
  self.pending.map(entry => entry.op)
}

///|
fn PlannerLifecycleModel::pending_raws(
  self : PlannerLifecycleModel,
) -> Array[@core.RawVersion] {
  self.pending.map(entry => oracle_raw(entry.op))
}

///|
fn PlannerLifecycleModel::prepare(
  self : PlannerLifecycleModel,
  incoming : Array[@core.Op],
) -> PlannerLifecycleModelPlan raise OpLogError {
  let staged : Array[@core.Op] = []
  let seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for op in incoming {
    let raw = oracle_raw(op)
    if self.is_admitted(raw) || self.has_pending_raw(raw) || seen.contains(raw) {
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
    self.admitted_order,
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
fn PlannerLifecycleModel::begin(
  self : PlannerLifecycleModel,
  plan : PlannerLifecycleModelPlan,
) -> Bool {
  if plan.consumed || plan.generation != self.generation {
    return false
  }
  for index, op in plan.staged {
    self.pending.push({ op, arrival: self.next_arrival + index })
  }
  self.next_arrival = plan.next_arrival
  plan.consumed = true
  self.generation += 1
  true
}

///|
fn PlannerLifecycleModel::acknowledge(
  self : PlannerLifecycleModel,
  raw : @core.RawVersion,
) -> Unit {
  if self.admitted.add_and_check(raw) {
    self.admitted_order.push(raw)
  }
  self.pending = self.pending.filter(entry => oracle_raw(entry.op) != raw)
  self.generation += 1
}

///|
fn planner_lifecycle_depends_on_any(
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
fn PlannerLifecycleModel::reject(
  self : PlannerLifecycleModel,
  roots : Array[@core.RawVersion],
) -> Unit {
  let rejected : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet(roots)
  let mut changed = true
  while changed {
    changed = false
    for entry in self.pending {
      let raw = oracle_raw(entry.op)
      if !rejected.contains(raw) &&
        planner_lifecycle_depends_on_any(entry.op, rejected) {
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
fn PlannerLifecycleModel::compact(self : PlannerLifecycleModel) -> Unit {
  self.pending = self.pending.filter(entry => {
    !self.is_admitted(oracle_raw(entry.op))
  })
  self.generation += 1
}

///|
fn planner_lifecycle_snapshot(
  planner : RemoteAdmissionPlanner,
  plan_consumed : Bool,
) -> PlannerLifecycleSnapshot {
  let nodes : Array[PlannerLifecycleNodeSnapshot] = []
  for raw, node in planner.pending {
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
  let order = planner.pending_order.map(entry => PlannerLifecycleOrderSnapshot::{
    raw: entry.raw,
    arrival: entry.arrival,
  })
  let waiters : Array[PlannerLifecycleWaiterSnapshot] = []
  for dependency, bucket in planner.waiters {
    waiters.push({
      dependency,
      raws: bucket.map(waiter => waiter.raw),
      arrivals: bucket.map(waiter => waiter.arrival),
    })
  }
  let ready : Array[RemoteAdmissionReady] = []
  let ready_copy = planner.ready.copy()
  while ready_copy.pop() is Some(entry) {
    ready.push(entry)
  }
  {
    nodes,
    order,
    waiters,
    ready,
    next_arrival: planner.next_arrival,
    generation: planner.generation,
    stale_order_tombstones: planner.stale_order_tombstones,
    stale_waiter_refs: planner.stale_waiter_refs,
    stale_ready_refs: planner.stale_ready_refs,
    plan_consumed,
  }
}

///|
fn planner_lifecycle_same_snapshot_node(
  left : PlannerLifecycleNodeSnapshot,
  right : PlannerLifecycleNodeSnapshot,
) -> Bool {
  left.raw == right.raw &&
  planner_lifecycle_same_op(left.op, right.op) &&
  left.arrival == right.arrival &&
  left.dependencies == right.dependencies &&
  left.waiting_dependencies == right.waiting_dependencies &&
  left.unresolved_count == right.unresolved_count &&
  left.ready_refs == right.ready_refs
}

///|
fn planner_lifecycle_same_snapshot(
  left : PlannerLifecycleSnapshot,
  right : PlannerLifecycleSnapshot,
) -> Bool {
  if left.nodes.length() != right.nodes.length() ||
    left.order.length() != right.order.length() ||
    left.waiters.length() != right.waiters.length() ||
    left.ready.length() != right.ready.length() {
    return false
  }
  for i in 0..<left.nodes.length() {
    if !planner_lifecycle_same_snapshot_node(left.nodes[i], right.nodes[i]) {
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
fn planner_lifecycle_matches_model(
  planner : RemoteAdmissionPlanner,
  model : PlannerLifecycleModel,
) -> Bool {
  let actual = planner.pending_operations()
  if !planner_lifecycle_same_ops(actual, model.pending_ops()) ||
    !planner_lifecycle_same_raws(planner.pending_raws(), model.pending_raws()) ||
    planner.generation != model.generation ||
    planner.next_arrival != model.next_arrival {
    return false
  }
  for entry in model.pending {
    if planner.arrival_of(oracle_raw(entry.op)) != Some(entry.arrival) {
      return false
    }
  }
  true
}

///|
fn planner_lifecycle_plan_matches_model(
  planner : RemoteAdmissionPlanner,
  actual : RemoteAdmissionPlan,
  expected : PlannerLifecycleModelPlan,
) -> Bool {
  planner_lifecycle_same_ops(actual.operations(), expected.planned) &&
  planner_lifecycle_same_raws(
    actual.remaining_raws(planner),
    oracle_raws(expected.remaining),
  ) &&
  actual.generation() == expected.generation
}

///|
fn planner_lifecycle_prepare_checked(
  planner : RemoteAdmissionPlanner,
  model : PlannerLifecycleModel,
  incoming : Array[@core.Op],
) -> (RemoteAdmissionPlan, PlannerLifecycleModelPlan)? raise OpLogError {
  let before = planner_lifecycle_snapshot(planner, false)
  let expected = model.prepare(incoming)
  let actual = planner.prepare(incoming, raw => model.is_admitted(raw))
  let after = planner_lifecycle_snapshot(planner, false)
  if planner_lifecycle_same_snapshot(before, after) &&
    planner_lifecycle_plan_matches_model(planner, actual, expected) {
    Some((actual, expected))
  } else {
    None
  }
}

///|
fn planner_lifecycle_current_plan_matches_model(
  planner : RemoteAdmissionPlanner,
  model : PlannerLifecycleModel,
) -> Bool raise OpLogError {
  match planner_lifecycle_prepare_checked(planner, model, []) {
    Some(_) => true
    None => false
  }
}

///|
fn planner_lifecycle_waiter_state_matches_suffix(
  planner : RemoteAdmissionPlanner,
  planned : Array[@core.Op],
  acknowledged : Int,
) -> Bool {
  for i in acknowledged..<planned.length() {
    let raw = oracle_raw(planned[i])
    guard planner.pending.get(raw) is Some(node) else { return false }
    let expected_unresolved = if i == acknowledged { 0 } else { 1 }
    if node.unresolved_count != expected_unresolved {
      return false
    }
  }
  true
}

///|
fn planner_lifecycle_ready_retry_is_safe(trace : PlannerLifecycleTrace) -> Bool {
  let root = @core.Op::new_insert(
    -1,
    [],
    "generated-ready-retry-root",
    0,
    "r",
    None,
    None,
  )
  let child = @core.Op::new_insert(
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
  let planner = RemoteAdmissionPlanner()
  let model = PlannerLifecycleModel()
  guard (try! planner_lifecycle_prepare_checked(planner, model, incoming))
    is Some((initial, initial_expected)) else {
    return false
  }
  if !model.begin(initial_expected) {
    return false
  }
  match planner.begin(initial, raw => model.is_admitted(raw)) {
    RemoteAdmissionBeginResult::Applied => ()
    _ => return false
  }
  let root_raw = oracle_raw(root)
  model.reject([root_raw])
  planner.reject_pending_dependents([root_raw])
  if !planner_lifecycle_matches_model(planner, model) ||
    planner.stale_count() == 0 {
    return false
  }
  guard (try! planner_lifecycle_prepare_checked(planner, model, []))
    is Some((stale_only, stale_only_expected)) else {
    return false
  }
  if !stale_only.operations().is_empty() ||
    !stale_only_expected.remaining.is_empty() {
    return false
  }
  guard (try! planner_lifecycle_prepare_checked(planner, model, incoming))
    is Some((retry, retry_expected)) else {
    return false
  }
  if !planner_lifecycle_same_ops(retry_expected.planned, natural) ||
    !model.begin(retry_expected) {
    return false
  }
  match planner.begin(retry, raw => model.is_admitted(raw)) {
    RemoteAdmissionBeginResult::Applied => ()
    _ => return false
  }
  if !planner_lifecycle_matches_model(planner, model) ||
    !(try! planner_lifecycle_current_plan_matches_model(planner, model)) {
    return false
  }
  model.acknowledge(root_raw)
  planner.acknowledge_admitted(root_raw)
  guard planner.pending.get(oracle_raw(child)) is Some(child_node) else {
    return false
  }
  if child_node.unresolved_count != 0 ||
    !planner_lifecycle_matches_model(planner, model) ||
    !(try! planner_lifecycle_current_plan_matches_model(planner, model)) {
    return false
  }
  let child_raw = oracle_raw(child)
  model.acknowledge(child_raw)
  planner.acknowledge_admitted(child_raw)
  planner_lifecycle_matches_model(planner, model) &&
  model.pending.is_empty() &&
  (try! planner_lifecycle_current_plan_matches_model(planner, model))
}

///|
fn prop_remote_admission_planner_lifecycle(
  trace : PlannerLifecycleTrace,
) -> Bool {
  if !planner_lifecycle_has_required_events(trace) {
    return false
  }
  let fixture = planner_lifecycle_fixture(trace)
  let planner = RemoteAdmissionPlanner()
  let model = PlannerLifecycleModel()
  let original_arrivals : Map[@core.RawVersion, Int] = Map::default()
  let mut active_plan : RemoteAdmissionPlan? = None
  let mut active_model_plan : PlannerLifecycleModelPlan? = None
  let mut drain_operations : Array[@core.Op] = []

  for event in trace.events() {
    match event {
      MalformedBegin => {
        guard (try! planner_lifecycle_prepare_checked(planner, model, [
            fixture.malformed_probe,
          ]))
          is Some((plan, expected)) else {
          return false
        }
        plan.planned.push(fixture.malformed_probe)
        let before = planner_lifecycle_snapshot(planner, plan.consumed)
        match planner.begin(plan, raw => model.is_admitted(raw)) {
          RemoteAdmissionBeginResult::Conflict => ()
          _ => return false
        }
        let after = planner_lifecycle_snapshot(planner, plan.consumed)
        if !planner_lifecycle_same_snapshot(before, after) || expected.consumed {
          return false
        }

        // Exercise the general capability's all-validation-before-registration
        // boundary with a real unresolved dependency from the generated pool.
        guard (try! planner_lifecycle_prepare_checked(planner, model, [
            fixture.unrelated_waiter,
          ]))
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
        let general_before = planner_lifecycle_snapshot(
          planner,
          general_plan.consumed,
        )
        match planner.begin(general_plan, raw => model.is_admitted(raw)) {
          RemoteAdmissionBeginResult::Conflict => ()
          _ => return false
        }
        let general_after = planner_lifecycle_snapshot(
          planner,
          general_plan.consumed,
        )
        if !planner_lifecycle_same_snapshot(general_before, general_after) ||
          general_expected.consumed {
          return false
        }
      }
      StaleBegin => {
        guard (try! planner_lifecycle_prepare_checked(planner, model, [
            fixture.stale_probe,
          ]))
          is Some((plan, expected)) else {
          return false
        }
        let admitted_raw = oracle_raw(fixture.external_admission)
        model.acknowledge(admitted_raw)
        planner.acknowledge_admitted(admitted_raw)
        if !planner_lifecycle_matches_model(planner, model) {
          return false
        }
        let before = planner_lifecycle_snapshot(planner, plan.consumed)
        match planner.begin(plan, raw => model.is_admitted(raw)) {
          RemoteAdmissionBeginResult::Stale => ()
          _ => return false
        }
        let after = planner_lifecycle_snapshot(planner, plan.consumed)
        if !planner_lifecycle_same_snapshot(before, after) || expected.consumed {
          return false
        }
      }
      PrepareUnresolved => {
        let unresolved = fixture.delivered_component.copy()
        unresolved.push(fixture.unrelated_waiter)
        guard (try! planner_lifecycle_prepare_checked(
            planner, model, unresolved,
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
        let generation_before = planner.generation
        if !model.begin(expected) {
          return false
        }
        match planner.begin(plan, raw => model.is_admitted(raw)) {
          RemoteAdmissionBeginResult::Applied => ()
          _ => return false
        }
        if !plan.consumed ||
          !expected.consumed ||
          planner.generation != generation_before + 1 ||
          !planner_lifecycle_matches_model(planner, model) {
          return false
        }
        for op in fixture.component {
          guard planner.arrival_of(oracle_raw(op)) is Some(arrival) else {
            return false
          }
          original_arrivals.set(oracle_raw(op), arrival)
        }
      }
      BeginConsumed => {
        guard active_plan is Some(plan) && active_model_plan is Some(expected) else {
          return false
        }
        let before = planner_lifecycle_snapshot(planner, plan.consumed)
        if model.begin(expected) {
          return false
        }
        match planner.begin(plan, raw => model.is_admitted(raw)) {
          RemoteAdmissionBeginResult::Consumed => ()
          _ => return false
        }
        let after = planner_lifecycle_snapshot(planner, plan.consumed)
        if !planner_lifecycle_same_snapshot(before, after) {
          return false
        }
      }
      RejectAttempt => {
        if !planner_lifecycle_ready_retry_is_safe(trace) {
          return false
        }
        let root = oracle_raw(fixture.component[0])
        model.reject([root])
        planner.reject_pending_dependents([root])
        if !planner_lifecycle_matches_model(planner, model) ||
          !planner_lifecycle_same_ops(model.pending_ops(), [
            fixture.unrelated_waiter,
          ]) {
          return false
        }
        guard (try! planner_lifecycle_prepare_checked(planner, model, []))
          is Some((stale_only, stale_only_expected)) else {
          return false
        }
        if !stale_only.operations().is_empty() ||
          !planner_lifecycle_same_ops(stale_only_expected.remaining, [
            fixture.unrelated_waiter,
          ]) {
          return false
        }
      }
      RetrySameIdentity => {
        guard (try! planner_lifecycle_prepare_checked(
            planner,
            model,
            fixture.delivered_component,
          ))
          is Some((plan, expected)) else {
          return false
        }
        if !model.begin(expected) {
          return false
        }
        match planner.begin(plan, raw => model.is_admitted(raw)) {
          RemoteAdmissionBeginResult::Applied => ()
          _ => return false
        }
        if !planner_lifecycle_matches_model(planner, model) {
          return false
        }
        for op in fixture.component {
          let raw = oracle_raw(op)
          guard planner.pending.get(raw) is Some(node) &&
            original_arrivals.get(raw) is Some(original_arrival) else {
            return false
          }
          if node.arrival <= original_arrival ||
            !planner_lifecycle_same_op(node.op, op) {
            return false
          }
        }
      }
      AdmitBlocker => {
        guard (try! planner_lifecycle_prepare_checked(planner, model, [
            fixture.blocker,
          ]))
          is Some((plan, expected)) else {
          return false
        }
        drain_operations = plan.operations().to_owned()
        let expected_drain = [fixture.blocker]
        for op in fixture.component {
          expected_drain.push(op)
        }
        if !planner_lifecycle_same_ops(drain_operations, expected_drain) ||
          !model.begin(expected) {
          return false
        }
        match planner.begin(plan, raw => model.is_admitted(raw)) {
          RemoteAdmissionBeginResult::Applied => ()
          _ => return false
        }
        if !planner_lifecycle_matches_model(planner, model) {
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
          planner.acknowledge_admitted(raw)
          if !planner_lifecycle_matches_model(planner, model) ||
            !planner_lifecycle_waiter_state_matches_suffix(
              planner,
              drain_operations,
              i + 1,
            ) ||
            !(try! planner_lifecycle_current_plan_matches_model(planner, model)) {
            return false
          }
          let expected_suffix = drain_operations[i + 1:].to_owned()
          let next_plan = try! model.prepare([])
          if !planner_lifecycle_same_ops(next_plan.planned, expected_suffix) ||
            !planner_lifecycle_same_ops(next_plan.remaining, [
              fixture.unrelated_waiter,
            ]) {
            return false
          }
        }
        let expected_suffix_raws = oracle_raws(
          drain_operations[trace.acknowledgement_prefix:].to_owned(),
        )
        expected_suffix_raws.push(oracle_raw(fixture.unrelated_waiter))
        if !planner_lifecycle_same_raw_membership(
            planner.pending_raws(),
            expected_suffix_raws,
          ) {
          return false
        }
      }
      Compact => {
        guard (try! planner_lifecycle_prepare_checked(planner, model, []))
          is Some((before_plan, before_expected)) else {
          return false
        }
        let pending_before = planner.pending_raws()
        let planned_before = before_plan.operations().to_owned()
        let remaining_before = before_plan.remaining_raws(planner)
        model.compact()
        planner.compact(raw => model.is_admitted(raw))
        if !planner_lifecycle_matches_model(planner, model) ||
          planner.stale_count() != 0 {
          return false
        }
        guard (try! planner_lifecycle_prepare_checked(planner, model, []))
          is Some((after_plan, after_expected)) else {
          return false
        }
        if !planner_lifecycle_same_ops(planned_before, after_plan.operations()) ||
          !planner_lifecycle_same_raws(
            oracle_raws(before_expected.remaining),
            oracle_raws(after_expected.remaining),
          ) ||
          !planner_lifecycle_same_raws(
            remaining_before,
            after_plan.remaining_raws(planner),
          ) ||
          !planner_lifecycle_same_raws(pending_before, planner.pending_raws()) {
          return false
        }
      }
      AcknowledgeRest => {
        for i in trace.acknowledgement_prefix..<drain_operations.length() {
          let raw = oracle_raw(drain_operations[i])
          model.acknowledge(raw)
          planner.acknowledge_admitted(raw)
          if !planner_lifecycle_matches_model(planner, model) ||
            !(try! planner_lifecycle_current_plan_matches_model(planner, model)) {
            return false
          }
        }
        let final_plan = try! model.prepare([])
        if !planner_lifecycle_same_ops(model.pending_ops(), [
            fixture.unrelated_waiter,
          ]) ||
          !planner_lifecycle_same_raws(planner.pending_raws(), [
            oracle_raw(fixture.unrelated_waiter),
          ]) ||
          !final_plan.planned.is_empty() ||
          !planner_lifecycle_same_ops(final_plan.remaining, [
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
test "property generator: planner lifecycle traces are complete and strict" {
  let traces : Array[PlannerLifecycleTrace] = @quickcheck.samples(32)
  assert_true(!traces.is_empty())
  for trace in traces {
    assert_true(planner_lifecycle_has_required_events(trace))
    assert_true(trace.depth >= 2)
    assert_true(trace.acknowledgement_prefix > 0)
    assert_true(trace.acknowledgement_prefix < trace.depth + 1)
  }
}

///|
test "property: generated planner lifecycle traces match the model" {
  @qc.quick_check_fn(
    prop_remote_admission_planner_lifecycle,
    max_success=100,
    max_size=24,
  )
}
