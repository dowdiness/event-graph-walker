///|
/// Graph-agnostic, private owner for remote-admission planning.
///
/// The mutable fields are deliberate: this is the planner's in-memory state
/// machine, not shared graph state. Preparation only mutates a disposable
/// overlay; canonical state changes happen through the explicit registration,
/// acknowledgement, and rejection transitions below.
priv struct RemoteAdmissionPlanner {
  pending : Map[@core.RawVersion, RemoteAdmissionNode]
  mut pending_order : Array[@core.RawVersion]
  waiters : Map[@core.RawVersion, Array[RemoteAdmissionWaiter]]
  ready : @priority_queue.PriorityQueue[RemoteAdmissionReady]
  mut next_arrival : Int
  mut generation : Int
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
  mut unresolved_count : Int
}

///|
/// A max-first queue entry. Negative keys invert the desired min order.
priv struct RemoteAdmissionReady {
  round_key : Int
  arrival_key : Int
  raw : @core.RawVersion
} derive(Eq, Compare)

///|
/// Non-mutating preparation result. Its fields are private to this package.
priv struct RemoteAdmissionPlan {
  planned : Array[@core.Op]
  planned_raws : @hashset.HashSet[@core.RawVersion]
  staged_order : Array[@core.RawVersion]
  generation : Int
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
  ready_rounds : Map[@core.RawVersion, Int]
  ready : @priority_queue.PriorityQueue[RemoteAdmissionReady]
  planned_operations : Array[@core.Op]
}

///|
/// Construct an empty planner; Commit 2 deliberately has no OpLog integration.
fn RemoteAdmissionPlanner::RemoteAdmissionPlanner() -> RemoteAdmissionPlanner {
  {
    pending: Map::default(),
    pending_order: [],
    waiters: Map::default(),
    ready: @priority_queue.PriorityQueue::default(),
    next_arrival: 0,
    generation: 0,
  }
}

///|
/// Return the operation identity.
fn remote_admission_raw(op : @core.Op) -> @core.RawVersion {
  @core.RawVersion::new(op.agent(), op.seq())
}

///|
/// Normalize all causal and origin edges while preserving first occurrence.
fn remote_admission_dependencies(op : @core.Op) -> Array[@core.RawVersion] {
  let dependencies : Array[@core.RawVersion] = []
  let seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for dependency in op.parents_iter() {
    if seen.add_and_check(dependency) {
      dependencies.push(dependency)
    }
  }
  match op.origin_left() {
    Some(origin) => if seen.add_and_check(origin) { dependencies.push(origin) }
    None => ()
  }
  match op.origin_right() {
    Some(origin) => if seen.add_and_check(origin) { dependencies.push(origin) }
    None => ()
  }
  dependencies
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
  ignore(RemoteAdmissionPlan::planned_operations)
  ignore(RemoteAdmissionPlan::remaining_raws)
  ignore(RemoteAdmissionPlanner::pending_raws)
  ignore(RemoteAdmissionPlanner::generation)
  ignore(RemoteAdmissionPlan::generation)
  ignore(RemoteAdmissionPlanner::arrival_of)
  if (op.is_delete() || op.is_undelete()) && op.origin_left() is None {
    raise OpLogError::MissingOrigin
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
/// Register one live pending operation with an explicit admitted-status view.
fn RemoteAdmissionPlanner::register_pending(
  self : RemoteAdmissionPlanner,
  op : @core.Op,
  is_admitted : (@core.RawVersion) -> Bool,
) -> Unit raise OpLogError {
  let raw = remote_admission_raw(op)
  if is_admitted(raw) || self.pending.contains(raw) {
    return
  }
  remote_admission_validate(op)
  let arrival = self.next_arrival
  let dependencies = remote_admission_dependencies(op)
  let mut unresolved_count = 0
  for dependency in dependencies {
    if !is_admitted(dependency) {
      unresolved_count += 1
      remote_admission_add_waiter(self.waiters, dependency, { raw, arrival })
    }
  }
  let node = { op, arrival, unresolved_count }
  self.pending.set(raw, node)
  self.pending_order.push(raw)
  self.next_arrival += 1
  if unresolved_count == 0 {
    self.ready.push({ round_key: 0, arrival_key: -node.arrival, raw })
  }
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
  self.pending.remove(raw)
  let seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  match self.waiters.get(raw) {
    Some(waiters) =>
      for waiter in waiters {
        match self.pending.get(waiter.raw) {
          Some(node) =>
            if node.arrival == waiter.arrival && seen.add_and_check(waiter.raw) {
              node.unresolved_count -= 1
              self.pending.set(waiter.raw, node)
              // Each acknowledgement starts the next prepare at round 0.
              if node.unresolved_count == 0 {
                self.ready.push({
                  round_key: 0,
                  arrival_key: -node.arrival,
                  raw: waiter.raw,
                })
              }
            }
          None => ()
        }
      }
    None => ()
  }
  self.generation += 1
}

///|
/// Remove invalid pending roots and all pending operations that depend on them.
fn RemoteAdmissionPlanner::reject_pending_dependents(
  self : RemoteAdmissionPlanner,
  roots : Array[@core.RawVersion],
) -> Unit {
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
  let remaining : Array[@core.RawVersion] = []
  for raw in self.pending_order {
    if rejected.contains(raw) {
      self.pending.remove(raw)
    } else {
      remaining.push(raw)
    }
  }
  if remaining.length() != self.pending_order.length() {
    self.pending_order = remaining
    self.generation += 1
  }
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
/// Prepare without changing canonical membership, ordinals, queues, or generation.
fn RemoteAdmissionPlanner::prepare(
  self : RemoteAdmissionPlanner,
  incoming : Array[@core.Op],
  is_admitted : (@core.RawVersion) -> Bool,
) -> RemoteAdmissionPlan raise OpLogError {
  let overlay = {
    staged: Map::default(),
    staged_order: [],
    staged_unresolved: Map::default(),
    touched_deltas: Map::default(),
    waiter_edges: Map::default(),
    planned: @hashset.HashSet([]),
    ready_rounds: Map::default(),
    ready: self.ready.copy(),
    planned_operations: [],
  }
  let mut next_overlay_arrival = self.next_arrival
  for op in incoming {
    let raw = remote_admission_raw(op)
    if is_admitted(raw) ||
      self.pending.contains(raw) ||
      overlay.staged.contains(raw) {
      continue
    }
    remote_admission_validate(op)
    let dependencies = remote_admission_dependencies(op)
    let node = { op, arrival: next_overlay_arrival, unresolved_count: 0 }
    next_overlay_arrival += 1
    overlay.staged.set(raw, node)
    overlay.staged_order.push(raw)
    let mut unresolved_count = 0
    for dependency in dependencies {
      if !is_admitted(dependency) {
        unresolved_count += 1
        overlay.add_waiter(dependency, { raw, arrival: node.arrival })
      }
    }
    overlay.staged_unresolved.set(raw, unresolved_count)
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
    overlay.planned.add(entry.raw)
    if !is_admitted(entry.raw) {
      overlay.planned_operations.push(node.op)
    }
    overlay.resolve_waiters(self, entry.raw, node.arrival, -entry.round_key)
  }
  {
    planned: overlay.planned_operations,
    planned_raws: overlay.planned,
    staged_order: overlay.staged_order,
    generation: self.generation,
  }
}

///|
/// Planned operations, copied for white-box tests and future package users.
fn RemoteAdmissionPlan::planned_operations(
  self : RemoteAdmissionPlan,
) -> Array[@core.Op] {
  self.planned.copy()
}

///|
/// Remaining canonical and staged operation identities in arrival order.
fn RemoteAdmissionPlan::remaining_raws(
  self : RemoteAdmissionPlan,
  planner : RemoteAdmissionPlanner,
) -> Array[@core.RawVersion] {
  let remaining : Array[@core.RawVersion] = []
  for raw in planner.pending_order {
    match planner.pending.get(raw) {
      Some(_) => if !self.planned_raws.contains(raw) { remaining.push(raw) }
      None => ()
    }
  }
  for raw in self.staged_order {
    if !self.planned_raws.contains(raw) {
      remaining.push(raw)
    }
  }
  remaining
}

///|
/// Canonical pending identities, excluding stale queue entries.
fn RemoteAdmissionPlanner::pending_raws(
  self : RemoteAdmissionPlanner,
) -> Array[@core.RawVersion] {
  [
    for raw in self.pending_order if self.pending.contains(raw) => raw
  ]
}

///|
/// Generation captured by this plan for future stale-plan validation.
fn RemoteAdmissionPlan::generation(self : RemoteAdmissionPlan) -> Int {
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
