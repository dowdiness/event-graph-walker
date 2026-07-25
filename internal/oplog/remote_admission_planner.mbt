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
/// A max-first queue entry. Negative keys invert the desired min order.
priv struct RemoteAdmissionReady {
  round_key : Int
  arrival_key : Int
  raw : @core.RawVersion
} derive(Eq, Compare)

///|
/// Non-mutating preparation result. Its fields are private to this package.
pub struct RemoteAdmissionPlan {
  priv planned : Array[@core.Op]
  priv planned_raws : @hashset.HashSet[@core.RawVersion]
  priv staged : Map[@core.RawVersion, @core.Op]
  priv staged_arrivals : Map[@core.RawVersion, Int]
  priv staged_order : Array[@core.RawVersion]
  priv initial_unresolved : Map[@core.RawVersion, Int]
  priv initial_waiting : Map[@core.RawVersion, Array[@core.RawVersion]]
  priv next_arrival : Int
  priv generation : Int
  priv mut consumed : Bool
}

///|
/// Result of the private begin transition. These states are deliberately not
/// OpLog errors: public error variants belong to the integration commit.
priv enum RemoteAdmissionBeginResult {
  Applied
  Stale
  Consumed
  Conflict
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
    stale_order_tombstones: 0,
    stale_waiter_refs: 0,
    stale_ready_refs: 0,
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
  ignore(RemoteAdmissionPlan::operations)
  ignore(RemoteAdmissionPlanner::pending_operations)
  ignore(RemoteAdmissionPlanner::has_pending)
  ignore(RemoteAdmissionPlan::remaining_raws)
  ignore(RemoteAdmissionPlanner::pending_raws)
  ignore(RemoteAdmissionPlanner::generation)
  ignore(RemoteAdmissionPlan::generation)
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
  }
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
  if is_admitted(raw) || self.pending.contains(raw) {
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
  let mut changed = false
  for raw in work {
    if self.remove_canonical(raw) {
      changed = true
    }
  }
  if changed {
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
  let initial_unresolved : Map[@core.RawVersion, Int] = Map::default()
  let initial_waiting : Map[@core.RawVersion, Array[@core.RawVersion]] = Map::default()
  for raw in overlay.staged_order {
    match overlay.staged.get(raw) {
      Some(node) => {
        initial_unresolved.set(raw, node.unresolved_count)
        initial_waiting.set(raw, node.waiting_dependencies.copy())
      }
      None => ()
    }
  }
  {
    planned: overlay.planned_operations,
    planned_raws: overlay.planned,
    staged: overlay.staged.map((_, node) => node.op),
    staged_arrivals: overlay.staged.map((_, node) => node.arrival),
    staged_order: overlay.staged_order,
    initial_unresolved,
    initial_waiting,
    next_arrival: next_overlay_arrival,
    generation: self.generation,
    consumed: false,
  }
}

///|
/// Begin a plan exactly once and register its staged nodes atomically.
/// Generation and consumed checks happen before any canonical mutation.
fn RemoteAdmissionPlanner::begin(
  self : RemoteAdmissionPlanner,
  plan : RemoteAdmissionPlan,
) -> RemoteAdmissionBeginResult {
  if plan.consumed {
    return RemoteAdmissionBeginResult::Consumed
  }
  if plan.generation != self.generation {
    return RemoteAdmissionBeginResult::Stale
  }
  // A generation match normally proves this. Keep the validation explicit so
  // an ill-formed private plan still cannot partially register its prefix.
  let seen_raws : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for raw in plan.staged_order {
    if !seen_raws.add_and_check(raw) {
      return RemoteAdmissionBeginResult::Conflict
    }
  }
  let seen_arrivals : @hashset.HashSet[Int] = @hashset.HashSet([])
  if plan.next_arrival < self.next_arrival ||
    plan.next_arrival != self.next_arrival + plan.staged_order.length() ||
    plan.staged.length() != plan.staged_order.length() ||
    plan.staged_arrivals.length() != plan.staged_order.length() ||
    plan.initial_unresolved.length() != plan.staged_order.length() ||
    plan.initial_waiting.length() != plan.staged_order.length() ||
    plan.planned_raws.length() != plan.planned.length() {
    return RemoteAdmissionBeginResult::Conflict
  }
  let seen_planned : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for op in plan.planned {
    let raw = remote_admission_raw(op)
    if !seen_planned.add_and_check(raw) ||
      !plan.planned_raws.contains(raw) ||
      (!self.pending.contains(raw) && !plan.staged.contains(raw)) {
      return RemoteAdmissionBeginResult::Conflict
    }
  }
  for index, raw in plan.staged_order {
    if self.pending.contains(raw) {
      return RemoteAdmissionBeginResult::Conflict
    }
    match plan.staged.get(raw) {
      Some(op) =>
        match plan.staged_arrivals.get(raw) {
          Some(arrival) =>
            if remote_admission_raw(op) != raw ||
              arrival != self.next_arrival + index ||
              !seen_arrivals.add_and_check(arrival) ||
              plan.initial_unresolved.get(raw) is None ||
              plan.initial_waiting.get(raw) is None {
              return RemoteAdmissionBeginResult::Conflict
            }
          None => return RemoteAdmissionBeginResult::Conflict
        }
      None => return RemoteAdmissionBeginResult::Conflict
    }
  }
  for raw in plan.staged_order {
    match plan.staged.get(raw) {
      Some(op) =>
        match plan.staged_arrivals.get(raw) {
          Some(arrival) =>
            match
              (plan.initial_unresolved.get(raw), plan.initial_waiting.get(raw)) {
              (Some(unresolved_count), Some(waiting_dependencies)) =>
                self.register_canonical(raw, {
                  op,
                  arrival,
                  dependencies: remote_admission_dependencies(op),
                  waiting_dependencies: waiting_dependencies.copy(),
                  unresolved_count,
                  ready_refs: 0,
                })
              (_, _) => ()
            }
          None => ()
        }
      None => ()
    }
  }
  self.next_arrival = plan.next_arrival
  plan.consumed = true
  self.generation += 1
  RemoteAdmissionBeginResult::Applied
}

///|
/// Name the lifecycle transition for callers that emphasize plan ownership.
fn RemoteAdmissionPlanner::begin_plan(
  self : RemoteAdmissionPlanner,
  plan : RemoteAdmissionPlan,
) -> RemoteAdmissionBeginResult {
  self.begin(plan)
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
  let new_pending : Map[@core.RawVersion, RemoteAdmissionNode] = Map::default()
  let new_order : Array[RemoteAdmissionOrderEntry] = []
  let new_waiters : Map[@core.RawVersion, Array[RemoteAdmissionWaiter]] = Map::default()
  let new_ready : @priority_queue.PriorityQueue[RemoteAdmissionReady] = @priority_queue.PriorityQueue::default()
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
  let stale_limit = (live * 2).max(1024)
  if self.stale_count() >= stale_limit {
    self.compact(is_admitted)
    true
  } else {
    false
  }
}

///|
/// Read-only compatibility-ordered operations in this admission plan.
pub fn RemoteAdmissionPlan::operations(
  self : RemoteAdmissionPlan,
) -> ArrayView[@core.Op] {
  self.planned[:]
}

///|
/// Planned operations, copied for white-box tests and future package users.
fn RemoteAdmissionPlan::planned_operations(
  self : RemoteAdmissionPlan,
) -> Array[@core.Op] {
  self.operations().to_owned()
}

///|
/// Remaining canonical and staged operation identities in arrival order.
fn RemoteAdmissionPlan::remaining_raws(
  self : RemoteAdmissionPlan,
  planner : RemoteAdmissionPlanner,
) -> Array[@core.RawVersion] {
  let remaining : Array[@core.RawVersion] = []
  for entry in planner.pending_order {
    if !remote_admission_order_entry_is_live(planner.pending, entry) {
      continue
    }
    match planner.pending.get(entry.raw) {
      Some(_) =>
        if !self.planned_raws.contains(entry.raw) {
          remaining.push(entry.raw)
        }
      None => ()
    }
  }
  for raw in self.staged_order {
    if !self.planned_raws.contains(raw) && !planner.pending.contains(raw) {
      remaining.push(raw)
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
