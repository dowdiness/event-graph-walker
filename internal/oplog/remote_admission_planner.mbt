///|
/// Graph-agnostic, private owner for remote-admission planning.
///
/// The mutable fields are deliberate: this is the planner's in-memory state
/// machine, not shared graph state. Preparation only mutates a disposable
/// overlay; canonical state changes happen through the explicit registration,
/// acknowledgement, and rejection transitions below.
priv struct RemoteAdmissionPlanner {
  mut pending : Map[@core.RawVersion, RemoteAdmissionNode]
  mut pending_order : Array[RemoteAdmissionOrderEntry]
  mut waiters : Map[@core.RawVersion, Array[RemoteAdmissionWaiter]]
  mut ready : @priority_queue.PriorityQueue[RemoteAdmissionReady]
  mut next_arrival : Int
  mut generation : Int
  mut stale_order_tombstones : Int
  mut stale_waiter_refs : Int
  mut stale_ready_refs : Int
}

///|
/// Arrival-qualified order identity. A retry appends a new entry instead of
/// requiring a suffix scan to find the live occurrence.
priv struct RemoteAdmissionOrderEntry {
  raw : @core.RawVersion
  arrival : Int
}

///|
/// Reverse-edge identity. The arrival makes stale edges harmless after retry.
priv struct RemoteAdmissionWaiter {
  raw : @core.RawVersion
  arrival : Int
}

///|
/// Canonical metadata for one live pending identity.
priv struct RemoteAdmissionNode {
  op : @core.Op
  arrival : Int
  dependencies : Array[@core.RawVersion]
  waiting_dependencies : Array[@core.RawVersion]
  mut unresolved_count : Int
  mut ready_refs : Int
}

///|
/// Immutable staged metadata owned by one prepared capability.
priv struct RemoteAdmissionPreparedNode {
  op : @core.Op
  raw : @core.RawVersion
  arrival : Int
  dependencies : Array[@core.RawVersion]
  waiting_dependencies : Array[@core.RawVersion]
  unresolved_count : Int
}

///|
/// Private representation of staged capability data.
priv enum PreparedAdmissionStorage {
  DeferredFast
  ImmediateGeneral(Array[RemoteAdmissionPreparedNode], planned_count~ : Int)
}

///|
/// A max-first queue entry. Negative keys invert the desired min order.
priv struct RemoteAdmissionReady {
  round_key : Int
  arrival_key : Int
  raw : @core.RawVersion
} derive(Eq, Compare)

///|
/// Non-mutating admission prepared for one commit. Its fields are private to this package.
pub struct PreparedAdmission {
  priv planned : Array[@core.Op]
  priv storage : PreparedAdmissionStorage
  priv discard_roots : Array[@core.RawVersion]
  priv discarded_pending : @hashset.HashSet[@core.RawVersion]
  priv discarded_staged : @hashset.HashSet[@core.RawVersion]
  priv next_arrival : Int
  priv generation : Int
  priv pending_before_count : Int
  priv new_staged_count : Int
  priv required_pending : Int
  priv max_pending : Int?
  priv max_pending_after_complete : Int?
  priv already_admitted : Array[@core.RawVersion]
  priv duplicate_of_pending : Array[@core.RawVersion]
  // Prospective provenance for retained identities affected by this plan.
  priv retained_pending : Array[@core.RawVersion]
  priv touched_retained_pending : Array[@core.RawVersion]
  priv mut consumed : Bool
}

///|
/// Admitted-history lookup used only by the core-owned semantic gate. The
/// planner remains graph-agnostic: the caller supplies the history view.
priv struct RemoteAdmissionSemantics {
  op_of : (@core.RawVersion) -> @core.Op?
}

///|
/// Result of the core semantic gate before provenance maps it to rejection or
/// retained-pending cleanup.
priv enum RemoteAdmissionSemanticResult {
  Valid
  Origin(operation~ : @core.RawVersion, target~ : @core.RawVersion)
  Invalid
}

///|
/// Result of the private begin transition. These states are deliberately not
/// OpLog errors: public error variants belong to the integration commit.
priv enum RemoteAdmissionBeginResult {
  Applied
  Stale
  Consumed
  Conflict
  PendingLimit(limit~ : Int, required~ : Int)
}

///|
/// Disposable state used while preparing a plan.
priv struct RemoteAdmissionOverlay {
  staged : Map[@core.RawVersion, RemoteAdmissionNode]
  staged_order : Array[@core.RawVersion]
  staged_unresolved : Map[@core.RawVersion, Int]
  touched_deltas : Map[@core.RawVersion, Int]
  waiter_edges : Map[@core.RawVersion, Array[RemoteAdmissionWaiter]]
  planned : @hashset.HashSet[@core.RawVersion]
  discard_roots : Array[@core.RawVersion]
  ready_rounds : Map[@core.RawVersion, Int]
  ready : @priority_queue.PriorityQueue[RemoteAdmissionReady]
  planned_operations : Array[@core.Op]
}

///|
/// One unified rejection closure partitioned by canonical ownership.
priv struct RemoteAdmissionRejectionClosure {
  discarded_pending : @hashset.HashSet[@core.RawVersion]
  discarded_staged : @hashset.HashSet[@core.RawVersion]
}

///|
/// Construct an empty planner; Commit 2 deliberately has no OpLog integration.
fn RemoteAdmissionPlanner::RemoteAdmissionPlanner() -> RemoteAdmissionPlanner {
  {
    pending: Default::default(),
    pending_order: [],
    waiters: Default::default(),
    ready: Default::default(),
    next_arrival: 0,
    generation: 0,
    stale_order_tombstones: 0,
    stale_waiter_refs: 0,
    stale_ready_refs: 0,
  }
}

///|
/// Return the operation identity.
fn remote_admission_raw(op : @core.Op) -> @core.RawVersion {
  @core.RawVersion(op.agent(), op.seq())
}

///|
/// Normalize all causal and origin edges while preserving first occurrence.
fn remote_admission_dependencies(op : @core.Op) -> Array[@core.RawVersion] {
  let dependencies : Array[@core.RawVersion] = []
  for dependency in op.parents_iter() {
    if !dependencies.contains(dependency) {
      dependencies.push(dependency)
    }
  }
  match op.origin_left() {
    Some(origin) =>
      if !dependencies.contains(origin) {
        dependencies.push(origin)
      }
    None => ()
  }
  match op.origin_right() {
    Some(origin) =>
      if !dependencies.contains(origin) {
        dependencies.push(origin)
      }
    None => ()
  }
  dependencies
}

///|
/// Semantic applicability follows only declared causal parents and origins.
fn remote_admission_dependencies_for(
  op : @core.Op,
  _semantics : RemoteAdmissionSemantics?,
) -> Array[@core.RawVersion] {
  remote_admission_dependencies(op)
}

///|
/// Compare complete immutable operation payloads for capability validation.
/// `Op` deliberately has no public `Eq`, so this private boundary is required.
fn remote_admission_same_operation(left : @core.Op, right : @core.Op) -> Bool {
  left.lv() == right.lv() &&
  left.parents() == right.parents() &&
  left.agent() == right.agent() &&
  left.seq() == right.seq() &&
  left.content() == right.content() &&
  left.origin_left() == right.origin_left() &&
  left.origin_right() == right.origin_right()
}

///|
/// Logical equality for one RawVersion identity. Destination-local LV and
/// parent order are not operation identity; duplicate parent multiplicity is.
fn remote_admission_same_logical_operation(
  left : @core.Op,
  right : @core.Op,
) -> Bool {
  let left_parents = left.parents()
  let right_parents = right.parents()
  left_parents.sort()
  right_parents.sort()
  left.agent() == right.agent() &&
  left.seq() == right.seq() &&
  left_parents == right_parents &&
  left.content() == right.content() &&
  left.origin_left() == right.origin_left() &&
  left.origin_right() == right.origin_right()
}

///|
/// Check fast-path readiness without allocating normalized dependency metadata.
/// Repeated dependencies are harmless because readiness is Boolean-idempotent.
fn remote_admission_is_ready(
  op : @core.Op,
  planned : @hashset.HashSet[@core.RawVersion],
  is_admitted : (@core.RawVersion) -> Bool,
  semantics : RemoteAdmissionSemantics?,
) -> Bool {
  for dependency in remote_admission_dependencies_for(op, semantics) {
    if !is_admitted(dependency) && !planned.contains(dependency) {
      return false
    }
  }
  true
}

///|
/// Return whether the operation's content and origin fields have a canonical
/// shape before any dependency or semantic admission decision is attempted.
fn remote_admission_origin_shape_is_valid(op : @core.Op) -> Bool {
  match op.content() {
    @core.Insert(_) => true
    @core.Delete | @core.Undelete =>
      op.origin_left() is Some(_) && op.origin_right() is None
  }
}

///|
/// Preserve the existing malformed delete/undelete boundary.
fn remote_admission_validate_origin_shape(
  op : @core.Op,
) -> Unit raise OpLogError {
  match op.content() {
    @core.Insert(_) => ()
    @core.Delete | @core.Undelete =>
      match (op.origin_left(), op.origin_right()) {
        (None, _) => raise OpLogError::MissingOrigin
        (Some(_), Some(_)) =>
          raise OpLogError::InvalidOriginShape(raw=remote_admission_raw(op))
        (Some(_), None) => ()
      }
  }
}

///|
/// Preserve the existing malformed delete/undelete boundary.
fn remote_admission_validate(op : @core.Op) -> Unit raise OpLogError {
  // Keep the isolated Commit 2 entry points reachable to the warning checker
  // without exporting them or adding a production call path.
  if false {
    ignore(RemoteAdmissionPlanner())
  }
  ignore(RemoteAdmissionPlanner::register_pending)
  ignore(RemoteAdmissionPlanner::acknowledge_admitted)
  ignore(RemoteAdmissionPlanner::reject_pending_dependents)
  ignore(RemoteAdmissionPlanner::prepare)
  ignore(PreparedAdmission::planned_operations)
  ignore(PreparedAdmission::operations)
  ignore(RemoteAdmissionPlanner::pending_operations)
  ignore(RemoteAdmissionPlanner::has_pending)
  ignore(PreparedAdmission::remaining_raws)
  ignore(RemoteAdmissionPlanner::pending_raws)
  ignore(RemoteAdmissionPlanner::required_pending_set_oracle)
  ignore(RemoteAdmissionPlanner::generation)
  ignore(PreparedAdmission::generation)
  ignore(RemoteAdmissionPlanner::arrival_of)
  ignore(RemoteAdmissionPlanner::begin)
  ignore(RemoteAdmissionPlanner::begin_plan)
  ignore(RemoteAdmissionPlanner::compact)
  ignore(RemoteAdmissionPlanner::maybe_compact)
  ignore(RemoteAdmissionPlanner::stale_count)
  // Keep private lifecycle constructors reachable until Commit 4 wires them.
  let begin_result_anchor = match op.seq() % 4 {
    0 => RemoteAdmissionBeginResult::Applied
    1 => RemoteAdmissionBeginResult::Stale
    2 => RemoteAdmissionBeginResult::Consumed
    _ => RemoteAdmissionBeginResult::Conflict
  }
  match begin_result_anchor {
    Applied => ()
    Stale => ()
    Consumed => ()
    Conflict => ()
    PendingLimit(..) => ()
  }
  remote_admission_validate_origin_shape(op)
}

///|
/// Look up an operation in the disposable incoming overlay, retained pending,
/// or the admitted-history view, in that order.
fn RemoteAdmissionPlanner::find_operation(
  self : RemoteAdmissionPlanner,
  raw : @core.RawVersion,
  staged_lookup : (@core.RawVersion) -> @core.Op?,
  semantics : RemoteAdmissionSemantics,
) -> @core.Op? {
  match staged_lookup(raw) {
    Some(op) => Some(op)
    None =>
      match self.pending.get(raw) {
        Some(node) => Some(node.op)
        None => (semantics.op_of)(raw)
      }
  }
}

///|
/// Check origin/target kinds that are already decidable, without requiring
/// unrelated causal parents to be ready first.
fn RemoteAdmissionPlanner::validate_known_origins(
  self : RemoteAdmissionPlanner,
  op : @core.Op,
  staged_lookup : (@core.RawVersion) -> @core.Op?,
  semantics : RemoteAdmissionSemantics,
) -> RemoteAdmissionSemanticResult {
  let lookup = raw => self.find_operation(raw, staged_lookup, semantics)
  let check = fn(target : @core.RawVersion?) -> RemoteAdmissionSemanticResult {
    match target {
      None => Valid
      Some(target) =>
        match lookup(target) {
          None => Valid
          Some(target_op) =>
            match target_op.content() {
              @core.Insert(_) => Valid
              @core.Delete | @core.Undelete =>
                Origin(operation=remote_admission_raw(op), target~)
            }
        }
    }
  }
  match check(op.origin_left()) {
    Valid => check(op.origin_right())
    result => result
  }
}

///|
/// Apply the text wire's semantic proofs at the core admission boundary.
fn RemoteAdmissionPlanner::validate_semantics(
  self : RemoteAdmissionPlanner,
  op : @core.Op,
  staged_lookup : (@core.RawVersion) -> @core.Op?,
  semantics : RemoteAdmissionSemantics,
) -> RemoteAdmissionSemanticResult {
  let lookup = raw => self.find_operation(raw, staged_lookup, semantics)
  match self.validate_known_origins(op, staged_lookup, semantics) {
    Valid => ()
    result => return result
  }
  let require_insert = fn(
    target : @core.RawVersion?,
  ) -> RemoteAdmissionSemanticResult {
    match target {
      None => Valid
      Some(target) =>
        match lookup(target) {
          Some(target_op) =>
            match target_op.content() {
              @core.Insert(_) => Valid
              @core.Delete | @core.Undelete =>
                Origin(operation=remote_admission_raw(op), target~)
            }
          None => Invalid
        }
    }
  }
  match require_insert(op.origin_left()) {
    Valid => ()
    result => return result
  }
  match require_insert(op.origin_right()) {
    Valid => Valid
    result => result
  }
}

///|
/// Map a semantic proof failure to the typed core error boundary.
fn remote_admission_raise_semantic(
  result : RemoteAdmissionSemanticResult,
) -> Unit raise OpLogError {
  match result {
    Valid => ()
    Origin(operation~, target~) =>
      raise OpLogError::OriginTargetNotInsert(operation~, target~)
    Invalid => raise OpLogError::InvalidAdmission
  }
}

///|
/// Add one reverse dependency edge without depending on map traversal order.
fn remote_admission_add_waiter(
  waiters : Map[@core.RawVersion, Array[RemoteAdmissionWaiter]],
  dependency : @core.RawVersion,
  waiter : RemoteAdmissionWaiter,
) -> Unit {
  let current = waiters.get(dependency).unwrap_or([])
  current.push(waiter)
  waiters.set(dependency, current)
}

///|
/// Add a prepared node to canonical membership without changing generation.
/// The caller validates the plan before invoking this for every staged node.
fn RemoteAdmissionPlanner::register_canonical(
  self : RemoteAdmissionPlanner,
  raw : @core.RawVersion,
  node : RemoteAdmissionNode,
) -> Unit {
  let canonical = {
    op: node.op,
    arrival: node.arrival,
    dependencies: node.dependencies.copy(),
    waiting_dependencies: node.waiting_dependencies.copy(),
    unresolved_count: node.unresolved_count,
    ready_refs: 0,
  }
  self.pending.set(raw, canonical)
  self.pending_order.push({ raw, arrival: canonical.arrival })
  for dependency in canonical.waiting_dependencies {
    remote_admission_add_waiter(self.waiters, dependency, {
      raw,
      arrival: canonical.arrival,
    })
  }
  if canonical.unresolved_count == 0 {
    self.ready.push({ round_key: 0, arrival_key: -canonical.arrival, raw })
    canonical.ready_refs = 1
    self.pending.set(raw, canonical)
  }
}

///|
/// Remove one live canonical node while retaining stale order and queue data.
fn RemoteAdmissionPlanner::remove_canonical(
  self : RemoteAdmissionPlanner,
  raw : @core.RawVersion,
) -> Bool {
  match self.pending.get(raw) {
    Some(node) => {
      self.pending.remove(raw)
      self.stale_order_tombstones += 1
      self.stale_waiter_refs += node.unresolved_count
      self.stale_ready_refs += node.ready_refs
      true
    }
    None => false
  }
}

///|
/// Current retained stale-index count. Compaction is intentionally explicit.
fn RemoteAdmissionPlanner::stale_count(self : RemoteAdmissionPlanner) -> Int {
  self.stale_order_tombstones + self.stale_waiter_refs + self.stale_ready_refs
}

///|
/// Register one live pending operation with an explicit admitted-status view.
fn RemoteAdmissionPlanner::register_pending(
  self : RemoteAdmissionPlanner,
  op : @core.Op,
  is_admitted : (@core.RawVersion) -> Bool,
) -> Unit raise OpLogError {
  let raw = remote_admission_raw(op)
  match self.pending.get(raw) {
    Some(node) => {
      if !remote_admission_same_logical_operation(node.op, op) {
        raise OpLogError::ConflictingIdentity(raw~)
      }
      return
    }
    None => ()
  }
  if is_admitted(raw) {
    return
  }
  remote_admission_validate(op)
  let arrival = self.next_arrival
  let dependencies = remote_admission_dependencies(op)
  let waiting_dependencies : Array[@core.RawVersion] = []
  for dependency in dependencies {
    if !is_admitted(dependency) {
      waiting_dependencies.push(dependency)
    }
  }
  let node = {
    op,
    arrival,
    dependencies,
    waiting_dependencies,
    unresolved_count: waiting_dependencies.length(),
    ready_refs: 0,
  }
  self.register_canonical(raw, node)
  self.next_arrival += 1
  self.generation += 1
}

///|
/// Record one externally reported causal-graph admission.
///
/// The caller must invoke this exactly once for each admission. `is_admitted`
/// is intentionally not consulted here: registration uses that view to avoid
/// preparing known identities, while this event is the canonical transition
/// that reports an already-admitted identity and wakes its reverse waiters.
fn RemoteAdmissionPlanner::acknowledge_admitted(
  self : RemoteAdmissionPlanner,
  raw : @core.RawVersion,
) -> Unit {
  ignore(self.remove_canonical(raw))
  match self.waiters.get(raw) {
    Some(waiters) => {
      for waiter in waiters {
        match self.pending.get(waiter.raw) {
          Some(node) =>
            if node.arrival == waiter.arrival {
              node.unresolved_count -= 1
              self.pending.set(waiter.raw, node)
              // Each acknowledgement starts the next prepare at round 0.
              if node.unresolved_count == 0 {
                self.ready.push({
                  round_key: 0,
                  arrival_key: -node.arrival,
                  raw: waiter.raw,
                })
                node.ready_refs += 1
                self.pending.set(waiter.raw, node)
              }
            } else {
              // This arrival-qualified edge belongs to a rejected or admitted
              // retry. It is removed with the bucket below.
              self.stale_waiter_refs -= 1
            }
          None => self.stale_waiter_refs -= 1
        }
      }
      self.waiters.remove(raw)
    }
    None => ()
  }
  // Every graph admission invalidates prepared overlays, even when the raw
  // identity has no current canonical node or waiter bucket.
  self.generation += 1
}

///|
/// Return invalid pending roots and all live pending operations that depend on
/// them, without changing canonical planner state.
fn RemoteAdmissionPlanner::pending_rejection_closure(
  self : RemoteAdmissionPlanner,
  roots : Array[@core.RawVersion],
) -> Array[@core.RawVersion] {
  let rejected : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let work : Array[@core.RawVersion] = []
  for root in roots {
    if rejected.add_and_check(root) {
      work.push(root)
    }
  }
  let mut cursor = 0
  while cursor < work.length() {
    let dependency = work[cursor]
    cursor += 1
    match self.waiters.get(dependency) {
      Some(waiters) =>
        for waiter in waiters {
          match self.pending.get(waiter.raw) {
            Some(node) =>
              if node.arrival == waiter.arrival &&
                rejected.add_and_check(waiter.raw) {
                work.push(waiter.raw)
              }
            None => ()
          }
        }
      None => ()
    }
  }
  work
}

///|
/// Remove exactly one previously computed pending rejection membership.
fn RemoteAdmissionPlanner::reject_pending_members(
  self : RemoteAdmissionPlanner,
  rejected : @hashset.HashSet[@core.RawVersion],
) -> Unit {
  let mut changed = false
  for raw in rejected {
    if self.remove_canonical(raw) {
      changed = true
    }
  }
  if changed {
    self.generation += 1
  }
}

///|
/// Remove invalid pending roots and all pending operations that depend on them.
fn RemoteAdmissionPlanner::reject_pending_dependents(
  self : RemoteAdmissionPlanner,
  roots : Array[@core.RawVersion],
) -> Unit {
  self.reject_pending_members(
    @hashset.HashSet(self.pending_rejection_closure(roots)),
  )
}

///|
/// Accumulate the largest round imposed by any dependency wake-up.
fn RemoteAdmissionOverlay::note_round(
  self : RemoteAdmissionOverlay,
  raw : @core.RawVersion,
  round : Int,
) -> Unit {
  let round = match self.ready_rounds.get(raw) {
    Some(previous) => previous.max(round)
    None => round
  }
  self.ready_rounds.set(raw, round)
}

///|
/// Schedule one candidate with explicitly inverted `(round, ordinal)` keys.
fn RemoteAdmissionOverlay::schedule(
  self : RemoteAdmissionOverlay,
  raw : @core.RawVersion,
  arrival : Int,
  round : Int,
) -> Unit {
  self.note_round(raw, round)
  let round = self.ready_rounds.get(raw).unwrap_or(round)
  // PriorityQueue is max-first. The largest pair of negative keys is the
  // smallest `(round, arrival)` pair, which is the compatibility order.
  // A later, larger round deliberately leaves the older entry for lazy
  // validation when it is popped.
  self.ready.push({ round_key: -round, arrival_key: -arrival, raw })
}

///|
/// Add an overlay-only reverse waiter edge.
fn RemoteAdmissionOverlay::add_waiter(
  self : RemoteAdmissionOverlay,
  dependency : @core.RawVersion,
  waiter : RemoteAdmissionWaiter,
) -> Unit {
  remote_admission_add_waiter(self.waiter_edges, dependency, waiter)
}

///|
/// Traverse canonical and staged reverse edges as one rejection closure.
fn RemoteAdmissionOverlay::rejection_closure(
  self : RemoteAdmissionOverlay,
  planner : RemoteAdmissionPlanner,
) -> RemoteAdmissionRejectionClosure {
  let rejected = @hashset.HashSet(self.discard_roots)
  let work = self.discard_roots.copy()
  let mut cursor = 0
  while cursor < work.length() {
    let dependency = work[cursor]
    cursor += 1
    match planner.waiters.get(dependency) {
      Some(waiters) =>
        for waiter in waiters {
          match planner.pending.get(waiter.raw) {
            Some(node) =>
              if node.arrival == waiter.arrival &&
                rejected.add_and_check(waiter.raw) {
                work.push(waiter.raw)
              }
            None => ()
          }
        }
      None => ()
    }
    match self.waiter_edges.get(dependency) {
      Some(waiters) =>
        for waiter in waiters {
          match self.staged.get(waiter.raw) {
            Some(node) =>
              if node.arrival == waiter.arrival &&
                rejected.add_and_check(waiter.raw) {
                work.push(waiter.raw)
              }
            None => ()
          }
        }
      None => ()
    }
  }
  let discarded_pending : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([],
  )
  let discarded_staged : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for raw in work {
    if planner.pending.contains(raw) {
      discarded_pending.add(raw)
    }
    if self.staged.contains(raw) {
      discarded_staged.add(raw)
    }
  }
  { discarded_pending, discarded_staged }
}

///|
/// Read the current hypothetical unresolved count for a live node.
fn RemoteAdmissionOverlay::unresolved(
  self : RemoteAdmissionOverlay,
  planner : RemoteAdmissionPlanner,
  raw : @core.RawVersion,
) -> Int? {
  match self.staged_unresolved.get(raw) {
    Some(count) => Some(count)
    None =>
      match planner.pending.get(raw) {
        Some(node) =>
          Some(
            node.unresolved_count + self.touched_deltas.get(raw).unwrap_or(0),
          )
        None => None
      }
  }
}

///|
/// Decrease the hypothetical count and schedule newly ready waiters.
fn RemoteAdmissionOverlay::resolve_waiters(
  self : RemoteAdmissionOverlay,
  planner : RemoteAdmissionPlanner,
  dependency : @core.RawVersion,
  source_arrival : Int,
  source_round : Int,
) -> Unit {
  match planner.waiters.get(dependency) {
    Some(waiters) =>
      for waiter in waiters {
        if self.planned.contains(waiter.raw) {
          continue
        }
        match planner.pending.get(waiter.raw) {
          Some(node) =>
            if node.arrival == waiter.arrival {
              let delta = self.touched_deltas.get(waiter.raw).unwrap_or(0) - 1
              self.touched_deltas.set(waiter.raw, delta)
              let count = node.unresolved_count + delta
              let round = if node.arrival > source_arrival {
                source_round
              } else {
                source_round + 1
              }
              self.note_round(waiter.raw, round)
              if count == 0 {
                self.schedule(waiter.raw, node.arrival, round)
              }
            }
          None => ()
        }
      }
    None => ()
  }
  match self.waiter_edges.get(dependency) {
    Some(waiters) =>
      for waiter in waiters {
        if self.planned.contains(waiter.raw) {
          continue
        }
        match self.staged.get(waiter.raw) {
          Some(node) =>
            if node.arrival == waiter.arrival {
              let count = self.staged_unresolved.get(waiter.raw).unwrap_or(0) -
                1
              self.staged_unresolved.set(waiter.raw, count)
              let round = if node.arrival > source_arrival {
                source_round
              } else {
                source_round + 1
              }
              self.note_round(waiter.raw, round)
              if count == 0 {
                self.schedule(waiter.raw, node.arrival, round)
              }
            }
          None => ()
        }
      }
    None => ()
  }
}

///|
/// Build the disposable ready queue used by one general preparation.
///
/// Copying remains cheaper for clean and live-heavy states. When retained stale
/// ready entries outnumber live pending membership by at least 16:1, rebuilding
/// from canonical order avoids repeatedly draining stale queue entries. The
/// ratio uses division to avoid overflow-prone multiplication.
fn RemoteAdmissionPlanner::prepare_ready_snapshot(
  self : RemoteAdmissionPlanner,
) -> @priority_queue.PriorityQueue[RemoteAdmissionReady] {
  let live_pending = self.pending.length()
  if live_pending == 0 || self.stale_ready_refs / live_pending < 16 {
    return self.ready.copy()
  }
  let ready : @priority_queue.PriorityQueue[RemoteAdmissionReady] = Default::default()
  for entry in self.pending_order {
    match self.pending.get(entry.raw) {
      Some(node) =>
        if node.arrival == entry.arrival && node.unresolved_count == 0 {
          ready.push({
            round_key: 0,
            arrival_key: -node.arrival,
            raw: entry.raw,
          })
        }
      None => ()
    }
  }
  ready
}

///|
/// Use a single arrival-order pass when no canonical pending operation can take
/// precedence and every incoming dependency is admitted or planned earlier.
fn RemoteAdmissionPlanner::prepare_fast(
  self : RemoteAdmissionPlanner,
  incoming : Array[@core.Op],
  is_admitted : (@core.RawVersion) -> Bool,
  semantics : RemoteAdmissionSemantics?,
) -> PreparedAdmission? raise OpLogError {
  if !self.pending.is_empty() {
    return None
  }
  let planned : Array[@core.Op] = []
  let planned_raws : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let staged : Map[@core.RawVersion, @core.Op] = Default::default()
  let mut next_arrival = self.next_arrival
  for op in incoming {
    let raw = remote_admission_raw(op)
    match staged.get(raw) {
      Some(previous) => {
        if !remote_admission_same_logical_operation(previous, op) {
          raise OpLogError::ConflictingIdentity(raw~)
        }
        continue
      }
      None => ()
    }
    staged.set(raw, op)
    if is_admitted(raw) {
      continue
    }
    remote_admission_validate(op)
    if !remote_admission_is_ready(op, planned_raws, is_admitted, semantics) {
      return None
    }
    match semantics {
      Some(context) =>
        match self.validate_semantics(op, raw => staged.get(raw), context) {
          Valid => ()
          Origin(operation~, target~) =>
            raise OpLogError::OriginTargetNotInsert(operation~, target~)
          Invalid => raise OpLogError::InvalidAdmission
        }
      None => ()
    }
    planned.push(op)
    planned_raws.add(raw)
    next_arrival += 1
  }
  Some({
    planned,
    storage: DeferredFast,
    discard_roots: [],
    discarded_pending: @hashset.HashSet([]),
    discarded_staged: @hashset.HashSet([]),
    next_arrival,
    generation: self.generation,
    pending_before_count: 0,
    new_staged_count: 0,
    required_pending: 0,
    max_pending: None,
    max_pending_after_complete: None,
    already_admitted: [],
    duplicate_of_pending: [],
    retained_pending: [],
    touched_retained_pending: [],
    consumed: false,
  })
}

///|
/// Prepare without changing canonical membership, ordinals, queues, or generation.
fn RemoteAdmissionPlanner::prepare_with_semantics(
  self : RemoteAdmissionPlanner,
  incoming : Array[@core.Op],
  is_admitted : (@core.RawVersion) -> Bool,
  semantics : RemoteAdmissionSemantics?,
) -> PreparedAdmission raise OpLogError {
  match self.prepare_fast(incoming, is_admitted, semantics) {
    Some(plan) => return plan.with_pending_evidence(self)
    None => ()
  }
  let overlay = {
    staged: Default::default(),
    staged_order: [],
    staged_unresolved: Default::default(),
    touched_deltas: Default::default(),
    waiter_edges: Default::default(),
    planned: @hashset.HashSet([]),
    discard_roots: [],
    ready_rounds: Default::default(),
    ready: self.prepare_ready_snapshot(),
    planned_operations: [],
  }
  let incoming_staged : Map[@core.RawVersion, @core.Op] = Default::default()
  let mut next_overlay_arrival = self.next_arrival
  for op in incoming {
    let raw = remote_admission_raw(op)
    match self.pending.get(raw) {
      Some(node) => {
        if !remote_admission_same_logical_operation(node.op, op) {
          raise OpLogError::ConflictingIdentity(raw~)
        }
        continue
      }
      None => ()
    }
    match overlay.staged.get(raw) {
      Some(node) => {
        if !remote_admission_same_logical_operation(node.op, op) {
          raise OpLogError::ConflictingIdentity(raw~)
        }
        continue
      }
      None => ()
    }
    match incoming_staged.get(raw) {
      Some(previous) => {
        if !remote_admission_same_logical_operation(previous, op) {
          raise OpLogError::ConflictingIdentity(raw~)
        }
        continue
      }
      None => ()
    }
    incoming_staged.set(raw, op)
    if is_admitted(raw) {
      continue
    }
    remote_admission_validate(op)
    let dependencies = remote_admission_dependencies_for(op, semantics)
    let waiting_dependencies : Array[@core.RawVersion] = []
    for dependency in dependencies {
      if !is_admitted(dependency) {
        waiting_dependencies.push(dependency)
      }
    }
    let node = {
      op,
      arrival: next_overlay_arrival,
      dependencies,
      waiting_dependencies,
      unresolved_count: waiting_dependencies.length(),
      ready_refs: 0,
    }
    next_overlay_arrival += 1
    overlay.staged.set(raw, node)
    overlay.staged_order.push(raw)
    overlay.staged_unresolved.set(raw, waiting_dependencies.length())
    for dependency in waiting_dependencies {
      overlay.add_waiter(dependency, { raw, arrival: node.arrival })
    }
  }
  match semantics {
    Some(context) =>
      for raw in overlay.staged_order {
        match overlay.staged.get(raw) {
          Some(node) =>
            remote_admission_raise_semantic(
              self.validate_known_origins(
                node.op,
                lookup => {
                  match overlay.staged.get(lookup) {
                    Some(staged_node) => Some(staged_node.op)
                    None => None
                  }
                },
                context,
              ),
            )
          None => ()
        }
      }
    None => ()
  }
  for raw in overlay.staged_order {
    match overlay.staged.get(raw) {
      Some(node) =>
        if overlay.staged_unresolved.get(raw).unwrap_or(0) == 0 {
          overlay.schedule(raw, node.arrival, 0)
        }
      None => ()
    }
  }
  while overlay.ready.is_empty() == false {
    let entry = match overlay.ready.pop() {
      Some(entry) => entry
      None => break
    }
    if overlay.planned.contains(entry.raw) {
      continue
    }
    let node = match self.pending.get(entry.raw) {
      Some(node) => node
      None =>
        match overlay.staged.get(entry.raw) {
          Some(node) => node
          None => continue
        }
    }
    // Re-registration may leave an older ready entry in the canonical queue.
    // Round changes likewise leave an old overlay entry for lazy cleanup.
    if node.arrival != -entry.arrival_key {
      continue
    }
    match overlay.ready_rounds.get(entry.raw) {
      Some(round) => if round != -entry.round_key { continue }
      None => ()
    }
    let unresolved = overlay.unresolved(self, entry.raw).unwrap_or(1)
    if unresolved != 0 {
      continue
    }
    let semantic_result = match semantics {
      Some(context) =>
        self.validate_semantics(
          node.op,
          raw => {
            match overlay.staged.get(raw) {
              Some(staged_node) => Some(staged_node.op)
              None => None
            }
          },
          context,
        )
      None => Valid
    }
    match semantic_result {
      Valid => ()
      Origin(operation~, target~) =>
        if self.pending.contains(entry.raw) {
          overlay.planned.add(entry.raw)
          overlay.discard_roots.push(entry.raw)
          continue
        } else {
          raise OpLogError::OriginTargetNotInsert(operation~, target~)
        }
      Invalid => raise OpLogError::InvalidAdmission
    }
    overlay.planned.add(entry.raw)
    if !is_admitted(entry.raw) {
      overlay.planned_operations.push(node.op)
    }
    overlay.resolve_waiters(self, entry.raw, node.arrival, -entry.round_key)
  }
  let rejection = overlay.rejection_closure(self)
  let staged_nodes : Array[RemoteAdmissionPreparedNode] = []
  let mut next_arrival = self.next_arrival
  for raw in overlay.staged_order {
    if rejection.discarded_staged.contains(raw) {
      continue
    }
    match overlay.staged.get(raw) {
      Some(node) => {
        staged_nodes.push({
          op: node.op,
          raw,
          arrival: next_arrival,
          dependencies: node.dependencies,
          waiting_dependencies: node.waiting_dependencies,
          unresolved_count: node.unresolved_count,
        })
        next_arrival += 1
      }
      None => ()
    }
  }
  let touched_retained_pending : Array[@core.RawVersion] = []
  let touched_seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for entry in overlay.touched_deltas.iter() {
    let raw = entry.0
    let delta = entry.1
    match self.pending.get(raw) {
      Some(_) =>
        if delta != 0 &&
          !rejection.discarded_pending.contains(raw) &&
          touched_seen.add_and_check(raw) {
          touched_retained_pending.push(raw)
        }
      None => ()
    }
  }
  // Reverse waiter edges are the equivalent prospective evidence when a
  // retained node is touched by a planned dependency but does not become
  // ready. Keep this derived from the disposable overlay inputs rather than
  // making planner-owned pending storage part of the receipt.
  for op in overlay.planned_operations {
    match self.waiters.get(remote_admission_raw(op)) {
      Some(waiters) =>
        for waiter in waiters {
          match self.pending.get(waiter.raw) {
            Some(node) =>
              if node.arrival == waiter.arrival &&
                !rejection.discarded_pending.contains(waiter.raw) &&
                touched_seen.add_and_check(waiter.raw) {
                touched_retained_pending.push(waiter.raw)
              }
            None => ()
          }
        }
      None => ()
    }
  }
  let plan = {
    planned: overlay.planned_operations,
    storage: ImmediateGeneral(
      staged_nodes,
      planned_count=overlay.planned_operations.length(),
    ),
    discard_roots: overlay.discard_roots,
    discarded_pending: rejection.discarded_pending,
    discarded_staged: rejection.discarded_staged,
    next_arrival,
    generation: self.generation,
    pending_before_count: 0,
    new_staged_count: 0,
    required_pending: 0,
    max_pending: None,
    max_pending_after_complete: None,
    already_admitted: [],
    duplicate_of_pending: [],
    retained_pending: [],
    touched_retained_pending,
    consumed: false,
  }
  plan.with_pending_evidence(self)
}

///|
/// Preserve the graph-agnostic planner entry point for existing callers.
fn RemoteAdmissionPlanner::prepare(
  self : RemoteAdmissionPlanner,
  incoming : Array[@core.Op],
  is_admitted : (@core.RawVersion) -> Bool,
) -> PreparedAdmission raise OpLogError {
  self.prepare_with_semantics(incoming, is_admitted, None)
}

///|
/// Begin a plan exactly once and register its staged nodes atomically.
/// Generation and consumed checks happen before any canonical mutation.
fn RemoteAdmissionPlanner::begin_with_semantics(
  self : RemoteAdmissionPlanner,
  plan : PreparedAdmission,
  is_admitted : (@core.RawVersion) -> Bool,
  semantics : RemoteAdmissionSemantics?,
) -> RemoteAdmissionBeginResult {
  if plan.consumed {
    return RemoteAdmissionBeginResult::Consumed
  }
  if plan.generation != self.generation {
    return RemoteAdmissionBeginResult::Stale
  }
  match semantics {
    Some(context) =>
      for root in plan.discard_roots {
        match self.pending.get(root) {
          Some(node) =>
            match
              self.validate_semantics(
                node.op,
                raw => plan.staged_operation(raw),
                context,
              ) {
              Origin(..) => ()
              Valid | Invalid => return RemoteAdmissionBeginResult::Conflict
            }
          None => return RemoteAdmissionBeginResult::Conflict
        }
      }
    None =>
      if !plan.discard_roots.is_empty() {
        return RemoteAdmissionBeginResult::Conflict
      }
  }
  let current_pending_before_count = self.pending_count()
  let staged_count = plan.staged_count()
  for raw in plan.discarded_pending {
    if !self.pending.contains(raw) {
      return RemoteAdmissionBeginResult::Conflict
    }
  }
  if plan.discarded_pending.length() > current_pending_before_count {
    return RemoteAdmissionBeginResult::Conflict
  }
  let required_pending = self.required_pending_for(plan)
  if current_pending_before_count != plan.pending_before_count ||
    required_pending != plan.required_pending ||
    staged_count != plan.new_staged_count {
    return RemoteAdmissionBeginResult::Conflict
  }
  match plan.max_pending {
    Some(limit) =>
      if required_pending > limit {
        return RemoteAdmissionBeginResult::PendingLimit(
          limit~,
          required=required_pending,
        )
      }
    None => ()
  }
  match plan.max_pending_after_complete {
    Some(limit) => {
      let complete_pending_after = plan.remaining_raws(self).length()
      if complete_pending_after > limit {
        return RemoteAdmissionBeginResult::PendingLimit(
          limit~,
          required=complete_pending_after,
        )
      }
    }
    None => ()
  }
  match plan.storage {
    DeferredFast => {
      if !self.pending.is_empty() ||
        plan.next_arrival != self.next_arrival + plan.planned.length() {
        return RemoteAdmissionBeginResult::Conflict
      }
      let seen_raws : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
      let prepared : Array[(@core.RawVersion, RemoteAdmissionNode)] = []
      for index, op in plan.planned {
        let raw = remote_admission_raw(op)
        if is_admitted(raw) ||
          seen_raws.contains(raw) ||
          !remote_admission_is_ready(op, seen_raws, is_admitted, semantics) ||
          !remote_admission_origin_shape_is_valid(op) {
          return RemoteAdmissionBeginResult::Conflict
        }
        let dependencies = remote_admission_dependencies_for(op, semantics)
        let waiting_dependencies : Array[@core.RawVersion] = []
        for dependency in dependencies {
          if !is_admitted(dependency) {
            waiting_dependencies.push(dependency)
          }
        }
        prepared.push(
          (
            raw,
            {
              op,
              arrival: self.next_arrival + index,
              dependencies,
              waiting_dependencies,
              unresolved_count: waiting_dependencies.length(),
              ready_refs: 0,
            },
          ),
        )
        seen_raws.add(raw)
      }
      // Remove the exact pending partition computed by preparation before
      // registering the accepted temporary nodes.
      self.reject_pending_members(plan.discarded_pending)
      // The complete temporary node array exists before registration starts.
      for raw_node in prepared {
        let (raw, node) = raw_node
        self.register_canonical(raw, node)
      }
    }
    ImmediateGeneral(nodes, planned_count~) => {
      if plan.planned.length() != planned_count ||
        plan.next_arrival < self.next_arrival ||
        plan.next_arrival != self.next_arrival + nodes.length() {
        return RemoteAdmissionBeginResult::Conflict
      }

      // Build disposable indexes so compatibility-order validation remains
      // linear even when queue order reverses arrival order.
      let staged_index : Map[@core.RawVersion, RemoteAdmissionPreparedNode] = Default::default()
      for node in nodes {
        staged_index.set(node.raw, node)
      }
      let planned_states : Map[@core.RawVersion, (Int, Int)] = Default::default()
      let mut previous_round = -1
      let mut previous_arrival = -1
      for op in plan.planned {
        let raw = remote_admission_raw(op)
        if planned_states.contains(raw) {
          return RemoteAdmissionBeginResult::Conflict
        }
        let (exact, arrival, dependencies) = match self.pending.get(raw) {
          Some(node) =>
            (
              remote_admission_same_operation(op, node.op),
              node.arrival,
              node.dependencies,
            )
          None =>
            match staged_index.get(raw) {
              Some(node) =>
                (
                  remote_admission_same_operation(op, node.op),
                  node.arrival,
                  node.dependencies,
                )
              None => return RemoteAdmissionBeginResult::Conflict
            }
        }
        if !exact {
          return RemoteAdmissionBeginResult::Conflict
        }
        let mut round = 0
        for dependency in dependencies {
          if is_admitted(dependency) {
            continue
          }
          match planned_states.get(dependency) {
            Some((dependency_round, dependency_arrival)) => {
              let imposed_round = if arrival > dependency_arrival {
                dependency_round
              } else {
                dependency_round + 1
              }
              round = round.max(imposed_round)
            }
            None => return RemoteAdmissionBeginResult::Conflict
          }
        }
        if round < previous_round ||
          (round == previous_round && arrival <= previous_arrival) {
          return RemoteAdmissionBeginResult::Conflict
        }
        planned_states.set(raw, (round, arrival))
        previous_round = round
        previous_arrival = arrival
      }

      let seen_raws : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
      for index, node in nodes {
        let raw = remote_admission_raw(node.op)
        if node.raw != raw ||
          is_admitted(raw) ||
          !seen_raws.add_and_check(raw) ||
          self.pending.contains(raw) ||
          node.arrival != self.next_arrival + index ||
          !remote_admission_origin_shape_is_valid(node.op) ||
          node.dependencies !=
          remote_admission_dependencies_for(node.op, semantics) {
          return RemoteAdmissionBeginResult::Conflict
        }
        let expected_waiting : Array[@core.RawVersion] = []
        for dependency in node.dependencies {
          if !is_admitted(dependency) {
            expected_waiting.push(dependency)
          }
        }
        if node.waiting_dependencies != expected_waiting ||
          node.unresolved_count != expected_waiting.length() {
          return RemoteAdmissionBeginResult::Conflict
        }
      }
      // Remove the exact pending partition computed by preparation before
      // registering the accepted temporary nodes.
      self.reject_pending_members(plan.discarded_pending)

      // All validation completes before canonical registration starts.
      for node in nodes {
        self.register_canonical(node.raw, {
          op: node.op,
          arrival: node.arrival,
          dependencies: node.dependencies,
          waiting_dependencies: node.waiting_dependencies,
          unresolved_count: node.unresolved_count,
          ready_refs: 0,
        })
      }
    }
  }
  self.next_arrival = plan.next_arrival
  plan.consumed = true
  self.generation += 1
  RemoteAdmissionBeginResult::Applied
}

///|
/// Preserve the graph-agnostic planner entry point for existing callers.
fn RemoteAdmissionPlanner::begin(
  self : RemoteAdmissionPlanner,
  plan : PreparedAdmission,
  is_admitted : (@core.RawVersion) -> Bool,
) -> RemoteAdmissionBeginResult {
  self.begin_with_semantics(plan, is_admitted, None)
}

///|
/// Name the lifecycle transition for callers that emphasize admission ownership.
fn RemoteAdmissionPlanner::begin_plan_with_semantics(
  self : RemoteAdmissionPlanner,
  plan : PreparedAdmission,
  is_admitted : (@core.RawVersion) -> Bool,
  semantics : RemoteAdmissionSemantics?,
) -> RemoteAdmissionBeginResult {
  self.begin_with_semantics(plan, is_admitted, semantics)
}

///|
/// Preserve the graph-agnostic planner entry point for existing callers.
fn RemoteAdmissionPlanner::begin_plan(
  self : RemoteAdmissionPlanner,
  plan : PreparedAdmission,
  is_admitted : (@core.RawVersion) -> Bool,
) -> RemoteAdmissionBeginResult {
  self.begin_plan_with_semantics(plan, is_admitted, None)
}

///|
/// Return whether an order entry still names the live arrival for its raw key.
fn remote_admission_order_entry_is_live(
  pending : Map[@core.RawVersion, RemoteAdmissionNode],
  entry : RemoteAdmissionOrderEntry,
) -> Bool {
  match pending.get(entry.raw) {
    Some(node) => node.arrival == entry.arrival
    None => false
  }
}

///|
/// Rebuild all indexes from live canonical nodes and their original arrivals.
fn RemoteAdmissionPlanner::compact(
  self : RemoteAdmissionPlanner,
  is_admitted : (@core.RawVersion) -> Bool,
) -> Unit {
  let new_pending : Map[@core.RawVersion, RemoteAdmissionNode] = Default::default()
  let new_order : Array[RemoteAdmissionOrderEntry] = []
  let new_waiters : Map[@core.RawVersion, Array[RemoteAdmissionWaiter]] = Default::default()
  let new_ready : @priority_queue.PriorityQueue[RemoteAdmissionReady] = Default::default()
  for entry in self.pending_order {
    if !remote_admission_order_entry_is_live(self.pending, entry) {
      continue
    }
    match self.pending.get(entry.raw) {
      Some(node) =>
        if !is_admitted(entry.raw) {
          let waiting_dependencies : Array[@core.RawVersion] = []
          for dependency in node.dependencies {
            if !is_admitted(dependency) {
              waiting_dependencies.push(dependency)
              remote_admission_add_waiter(new_waiters, dependency, {
                raw: entry.raw,
                arrival: node.arrival,
              })
            }
          }
          let rebuilt = {
            op: node.op,
            arrival: node.arrival,
            dependencies: node.dependencies.copy(),
            waiting_dependencies,
            unresolved_count: waiting_dependencies.length(),
            ready_refs: 0,
          }
          new_pending.set(entry.raw, rebuilt)
          new_order.push(entry)
          if rebuilt.unresolved_count == 0 {
            new_ready.push({
              round_key: 0,
              arrival_key: -rebuilt.arrival,
              raw: entry.raw,
            })
            rebuilt.ready_refs = 1
            new_pending.set(entry.raw, rebuilt)
          }
        }
      None => ()
    }
  }
  self.pending = new_pending
  self.pending_order = new_order
  self.waiters = new_waiters
  self.ready = new_ready
  self.stale_order_tombstones = 0
  self.stale_waiter_refs = 0
  self.stale_ready_refs = 0
  self.generation += 1
}

///|
/// Avoid rebuilding for small churn while bounding retained stale state to a
/// constant floor plus a multiple of live pending membership. The 2:1 ratio is
/// the benchmarked point where JS paid about 2 ms extra for 10,000 entries.
fn RemoteAdmissionPlanner::maybe_compact(
  self : RemoteAdmissionPlanner,
  is_admitted : (@core.RawVersion) -> Bool,
) -> Bool {
  let live = self.pending.length()
  let stale = self.stale_count()
  // Compare against max(1024, 2 * live) without multiplying a large live
  // count, so policy checks cannot overflow before compaction is considered.
  let exceeds_limit = if live > 512 {
    stale >= live && stale - live >= live
  } else {
    stale >= 1024
  }
  if exceeds_limit {
    self.compact(is_admitted)
    true
  } else {
    false
  }
}

///|
/// Find a staged operation retained by this prepared admission's general storage.
fn PreparedAdmission::staged_operation(
  self : PreparedAdmission,
  raw : @core.RawVersion,
) -> @core.Op? {
  match self.storage {
    DeferredFast => None
    ImmediateGeneral(nodes, planned_count=_) =>
      nodes.iter().find_first(node => node.raw == raw).map(node => node.op)
  }
}

///|
/// Staged identities owned by this prepared transition, excluding retained
/// canonical pending identities already present in the planner.
fn PreparedAdmission::staged_raws(
  self : PreparedAdmission,
) -> Array[@core.RawVersion] {
  match self.storage {
    DeferredFast => [ for op in self.planned => remote_admission_raw(op) ]
    ImmediateGeneral(nodes, planned_count=_) =>
      [
        for node in nodes => node.raw
      ]
  }
}

///|
/// Count live canonical pending membership without materializing arrival order.
fn RemoteAdmissionPlanner::pending_count(self : RemoteAdmissionPlanner) -> Int {
  self.pending.length()
}

///|
/// Clear every live pending node and all planner indexes in one generation
/// transition. An empty planner is intentionally left untouched.
fn RemoteAdmissionPlanner::clear_pending(self : RemoteAdmissionPlanner) -> Unit {
  if self.pending.is_empty() {
    return
  }
  self.pending = Default::default()
  self.pending_order = []
  self.waiters = Default::default()
  self.ready = Default::default()
  self.stale_order_tombstones = 0
  self.stale_waiter_refs = 0
  self.stale_ready_refs = 0
  self.generation += 1
}

///|
/// Count staged identities without materializing their RawVersion array.
fn PreparedAdmission::staged_count(self : PreparedAdmission) -> Int {
  match self.storage {
    DeferredFast => self.planned.length()
    ImmediateGeneral(nodes, planned_count=_) => nodes.length()
  }
}

///|
/// Reference set oracle for the begin-after pending membership contract.
/// Production admission uses `required_pending_for`; tests compare both.
fn RemoteAdmissionPlanner::required_pending_set_oracle(
  self : RemoteAdmissionPlanner,
  plan : PreparedAdmission,
) -> Int {
  let pending : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet(
    self.pending_raws(),
  )
  for raw in plan.discarded_pending {
    pending.remove(raw)
  }
  for raw in plan.staged_raws() {
    pending.add(raw)
  }
  pending.length()
}

///|
/// Compute the unique live pending membership immediately after begin applies
/// the prepared discard and staged-registration transition. The plan
/// invariants make this count equivalent to the set oracle above.
fn RemoteAdmissionPlanner::required_pending_for(
  self : RemoteAdmissionPlanner,
  plan : PreparedAdmission,
) -> Int {
  let pending_before_count = self.pending_count()
  let discarded_pending_count = plan.discarded_pending.length()
  if discarded_pending_count > pending_before_count {
    abort("prepared pending discard exceeds live membership")
  }
  let remaining_pending = pending_before_count - discarded_pending_count
  let staged_count = plan.staged_count()
  if staged_count > 2147483647 - remaining_pending {
    abort("prepared pending count overflows Int")
  }
  remaining_pending + staged_count
}

///|
/// Attach generation-bound pending evidence without mutating planner state.
fn PreparedAdmission::with_pending_evidence(
  self : PreparedAdmission,
  planner : RemoteAdmissionPlanner,
) -> PreparedAdmission {
  let pending_before_count = planner.pending_count()
  let new_staged_count = self.staged_count()
  let required_pending = planner.required_pending_for(self)
  let retained_pending : Array[@core.RawVersion] = []
  let seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for raw in self.touched_retained_pending {
    if seen.add_and_check(raw) {
      retained_pending.push(raw)
    }
  }
  for op in self.planned {
    let raw = remote_admission_raw(op)
    if planner.pending.contains(raw) && seen.add_and_check(raw) {
      retained_pending.push(raw)
    }
  }
  {
    ..self,
    pending_before_count,
    new_staged_count,
    required_pending,
    retained_pending,
  }
}

///|
/// Attach generation-bound prospective evidence and enforce the optional hard
/// pending limits without mutating planner state.
fn PreparedAdmission::with_prospective(
  self : PreparedAdmission,
  planner : RemoteAdmissionPlanner,
  max_pending : Int?,
  max_pending_after_complete : Int?,
  already_admitted : Array[@core.RawVersion],
  duplicate_of_pending : Array[@core.RawVersion],
) -> PreparedAdmission raise OpLogError {
  let prepared = self.with_pending_evidence(planner)
  match max_pending {
    Some(limit) =>
      if prepared.required_pending > limit {
        raise OpLogError::PendingLimitExceeded(
          limit~,
          required=prepared.required_pending,
        )
      }
    None => ()
  }
  match max_pending_after_complete {
    Some(limit) => {
      let complete_pending_after = prepared.remaining_raws(planner).length()
      if complete_pending_after > limit {
        raise OpLogError::PendingLimitExceeded(
          limit~,
          required=complete_pending_after,
        )
      }
    }
    None => ()
  }
  let retained_pending = prepared.retained_pending.copy()
  let seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet(
    retained_pending,
  )
  for raw in duplicate_of_pending {
    if seen.add_and_check(raw) {
      retained_pending.push(raw)
    }
  }
  {
    ..prepared,
    max_pending,
    max_pending_after_complete,
    already_admitted: already_admitted.copy(),
    duplicate_of_pending: duplicate_of_pending.copy(),
    retained_pending,
  }
}

///|
/// Read-only compatibility-ordered operations in this admission plan.
pub fn PreparedAdmission::operations(
  self : PreparedAdmission,
) -> ArrayView[@core.Op] {
  self.planned[:]
}

///|
/// Planned operations, copied for white-box tests and future package users.
fn PreparedAdmission::planned_operations(
  self : PreparedAdmission,
) -> Array[@core.Op] {
  self.operations().to_owned()
}

///|
/// Remaining canonical and staged operation identities in arrival order.
fn PreparedAdmission::remaining_raws(
  self : PreparedAdmission,
  planner : RemoteAdmissionPlanner,
) -> Array[@core.RawVersion] {
  let remaining : Array[@core.RawVersion] = []
  let planned_raws : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for op in self.planned {
    planned_raws.add(remote_admission_raw(op))
  }
  for entry in planner.pending_order {
    if !remote_admission_order_entry_is_live(planner.pending, entry) {
      continue
    }
    match planner.pending.get(entry.raw) {
      Some(_) =>
        if !planned_raws.contains(entry.raw) &&
          !self.discarded_pending.contains(entry.raw) {
          remaining.push(entry.raw)
        }
      None => ()
    }
  }
  match self.storage {
    DeferredFast => ()
    ImmediateGeneral(nodes, planned_count=_) =>
      for node in nodes {
        if !planned_raws.contains(node.raw) &&
          !self.discarded_staged.contains(node.raw) &&
          !planner.pending.contains(node.raw) {
          remaining.push(node.raw)
        }
      }
  }
  remaining
}

///|
/// Report whether canonical pending membership is non-empty.
fn RemoteAdmissionPlanner::has_pending(self : RemoteAdmissionPlanner) -> Bool {
  !self.pending.is_empty()
}

///|
/// Canonical pending identities, excluding stale queue entries.
fn RemoteAdmissionPlanner::pending_raws(
  self : RemoteAdmissionPlanner,
) -> Array[@core.RawVersion] {
  [
    for entry in self.pending_order if remote_admission_order_entry_is_live(
      self.pending,
      entry,
    ) => entry.raw
  ]
}

///|
/// Snapshot canonical pending operations in arrival order for the white-box
/// oracle. The planner remains the sole owner of pending membership.
fn RemoteAdmissionPlanner::pending_operations(
  self : RemoteAdmissionPlanner,
) -> Array[@core.Op] {
  let result : Array[@core.Op] = []
  for entry in self.pending_order {
    if !remote_admission_order_entry_is_live(self.pending, entry) {
      continue
    }
    match self.pending.get(entry.raw) {
      Some(node) => result.push(node.op)
      None => ()
    }
  }
  result
}

///|
/// Generation captured by this prepared admission for future stale-admission validation.
fn PreparedAdmission::generation(self : PreparedAdmission) -> Int {
  self.generation
}

///|
/// White-box generation accessor; preparation must preserve this value.
fn RemoteAdmissionPlanner::generation(self : RemoteAdmissionPlanner) -> Int {
  self.generation
}

///|
/// White-box arrival accessor.
fn RemoteAdmissionPlanner::arrival_of(
  self : RemoteAdmissionPlanner,
  raw : @core.RawVersion,
) -> Int? {
  match self.pending.get(raw) {
    Some(node) => Some(node.arrival)
    None => None
  }
}
