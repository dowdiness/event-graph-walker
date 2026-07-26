// Issue #86 question: can split storage isolate the ready fast path from general planner metadata without code-size/JIT contamination?
// Throwaway benchmark-only prototype; not production code or documentation.
// Run from event-graph-walker:
//   moon bench --package dowdiness/event-graph-walker/internal/oplog --file issue86_planner_optimization_benchmark.mbt --release
//   moon bench --package dowdiness/event-graph-walker/internal/oplog --file issue86_planner_optimization_benchmark.mbt --release --target js
// Saved source patch SHA256: 2c32d08f3fc0092d415d6a32007c8ef9ba168c39dd751cc69609b31e8307a00b

///|
/// Benchmark: Insert operations (linear, 100 ops)
fn issue86_remote_chain(n : Int) -> Array[@core.Op] {
  let ops : Array[@core.Op] = []
  for i in 0..<n {
    let parents = if i == 0 {
      []
    } else {
      [@core.RawVersion::new("remote", i - 1)]
    }
    ops.push(@core.Op::new_insert(-1, parents, "remote", i, "x", None, None))
  }
  ops
}

///|
// Benchmark-only copy of the historical pending-first fixed-point planner.
// This must remain independent of OpLog and receives admitted identities
// explicitly so the timed oracle has no hidden graph state.
fn issue86_fixed_point_oracle(
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
fn issue86_raws(ops : Array[@core.Op]) -> Array[@core.RawVersion] {
  [
    for op in ops => @core.RawVersion::new(op.agent(), op.seq())
  ]
}

///|
fn issue86_assert_raws(
  actual : Array[@core.RawVersion],
  expected : Array[@core.RawVersion],
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    assert_eq(actual[i], expected[i])
  }
}

///|
fn issue86_production_plan(
  ops : Array[@core.Op],
) -> (Array[@core.Op], Array[@core.RawVersion]) raise OpLogError {
  let oplog = OpLog::new("local")
  let plan = oplog.prepare_remote(ops)
  (plan.operations().to_owned(), plan.remaining_raws(oplog.planner))
}

///|
/// Benchmark-only: planned ops for production path timing. Creates a fresh
/// OpLog and delegates to the compatibility wrapper.
fn issue86_production_planned(
  ops : Array[@core.Op],
) -> Array[@core.Op] raise OpLogError {
  let oplog = OpLog::new("local")
  oplog.plan_remote(ops)
}

///|
// Compare both planned order and the exact remaining pending order before the
// benchmark closure. Each production comparison starts from an empty OpLog.
fn issue86_assert_planner_equivalence(ops : Array[@core.Op]) -> Unit raise {
  let (oracle_planned, oracle_remaining) = issue86_fixed_point_oracle(
    ops.copy(),
    [],
  )
  let (production_planned, production_remaining) = issue86_production_plan(ops)
  issue86_assert_raws(
    issue86_raws(oracle_planned),
    issue86_raws(production_planned),
  )
  issue86_assert_raws(issue86_raws(oracle_remaining), production_remaining)
  let public_planned = issue86_production_planned(ops)
  issue86_assert_raws(
    issue86_raws(public_planned),
    issue86_raws(oracle_planned),
  )
}

///|
fn issue86_reverse_ops(ops : Array[@core.Op]) -> Array[@core.Op] {
  let reversed : Array[@core.Op] = []
  for i in 0..<ops.length() {
    reversed.push(ops[ops.length() - i - 1])
  }
  reversed
}

///|
fn issue86_remote_branches(depth : Int) -> Array[@core.Op] {
  let agents = ["remote-a", "remote-b", "remote-c", "remote-d"]
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
fn issue86_all_ready_batch(n : Int) -> Array[@core.Op] {
  let ops : Array[@core.Op] = []
  for i in 0..<n {
    ops.push(@core.Op::new_insert(-1, [], "ready", i, "x", None, None))
  }
  ops
}

///|
fn issue86_duplicate_heavy_batch(
  unique_count : Int,
  copies : Int,
) -> Array[@core.Op] {
  let unique = issue86_all_ready_batch(unique_count)
  let ops : Array[@core.Op] = []
  for _ in 0..<copies {
    for op in unique {
      ops.push(op)
    }
  }
  ops
}

///|
// Benchmark-only overlay shell used by the general split-storage path.
fn issue86_remote_admission_new_overlay(
  planner : RemoteAdmissionPlanner,
) -> RemoteAdmissionOverlay {
  {
    staged: Map::default(),
    staged_order: [],
    staged_unresolved: Map::default(),
    touched_deltas: Map::default(),
    waiter_edges: Map::default(),
    planned: @hashset.HashSet([]),
    ready_rounds: Map::default(),
    ready: planner.ready.copy(),
    planned_operations: [],
  }
}

///|
fn issue86_remote_admission_initial_schedule(
  overlay : RemoteAdmissionOverlay,
) -> Unit {
  for raw in overlay.staged_order {
    match overlay.staged.get(raw) {
      Some(node) =>
        if overlay.staged_unresolved.get(raw).unwrap_or(0) == 0 {
          overlay.schedule(raw, node.arrival, 0)
        }
      None => ()
    }
  }
}

///|
fn issue86_remote_admission_drain(
  planner : RemoteAdmissionPlanner,
  overlay : RemoteAdmissionOverlay,
  is_admitted : (@core.RawVersion) -> Bool,
) -> Unit {
  while overlay.ready.is_empty() == false {
    let entry = match overlay.ready.pop() {
      Some(entry) => entry
      None => break
    }
    if overlay.planned.contains(entry.raw) {
      continue
    }
    let node = match planner.pending.get(entry.raw) {
      Some(node) => node
      None =>
        match overlay.staged.get(entry.raw) {
          Some(node) => node
          None => continue
        }
    }
    if node.arrival != -entry.arrival_key {
      continue
    }
    match overlay.ready_rounds.get(entry.raw) {
      Some(round) => if round != -entry.round_key { continue }
      None => ()
    }
    let unresolved = overlay.unresolved(planner, entry.raw).unwrap_or(1)
    if unresolved != 0 {
      continue
    }
    overlay.planned.add(entry.raw)
    if !is_admitted(entry.raw) {
      overlay.planned_operations.push(node.op)
    }
    overlay.resolve_waiters(planner, entry.raw, node.arrival, -entry.round_key)
  }
}

///|
// Final Issue #86 split-storage prototype (benchmark-only throwaway).
// DeferredFast keeps only operations; ImmediateGeneral retains normalized metadata.
priv struct BenchmarkCompactStagedNode {
  op : @core.Op
  raw : @core.RawVersion
  arrival : Int
  dependencies : Array[@core.RawVersion]
  waiting_dependencies : Array[@core.RawVersion]
  unresolved_count : Int
}

///|
priv enum BenchmarkSplitStorage {
  DeferredFast(Array[@core.Op])
  ImmediateGeneral(Array[BenchmarkCompactStagedNode])
}

///|
priv struct BenchmarkSplitPlan {
  planned : Array[@core.Op]
  storage : BenchmarkSplitStorage
  next_arrival : Int
  generation : Int
  mut consumed : Bool
}

///|
// Array normalization is intentional: this is the measured fast-path shape,
// preserving first occurrence across parents and both origins.
fn issue86_split_dependencies(op : @core.Op) -> Array[@core.RawVersion] {
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
fn issue86_split_storage_length(storage : BenchmarkSplitStorage) -> Int {
  match storage {
    DeferredFast(ops) => ops.length()
    ImmediateGeneral(nodes) => nodes.length()
  }
}

///|
fn issue86_split_storage_is_fast(plan : BenchmarkSplitPlan) -> Bool {
  match plan.storage {
    DeferredFast(_) => true
    ImmediateGeneral(_) => false
  }
}

///|
// Readiness-only fast path: parents_iter and origin matching avoid the
// allocation needed by canonical dependency normalization. Repeated
// dependencies are harmless because readiness is Boolean and idempotent.
fn issue86_split_ready(
  op : @core.Op,
  planned_raws : @hashset.HashSet[@core.RawVersion],
  is_admitted : (@core.RawVersion) -> Bool,
) -> Bool {
  for dependency in op.parents_iter() {
    if !is_admitted(dependency) && !planned_raws.contains(dependency) {
      return false
    }
  }
  match op.origin_left() {
    None => ()
    Some(origin) =>
      if !is_admitted(origin) && !planned_raws.contains(origin) {
        return false
      }
  }
  match op.origin_right() {
    None => ()
    Some(origin) =>
      if !is_admitted(origin) && !planned_raws.contains(origin) {
        return false
      }
  }
  true
}

///|
// Fast preparation keeps only the staged/planned operation Array; canonical
// dependency metadata remains deferred to begin or the general path.
fn issue86_split_fast_prepare(
  planner : RemoteAdmissionPlanner,
  incoming : Array[@core.Op],
  is_admitted : (@core.RawVersion) -> Bool,
) -> BenchmarkSplitPlan? raise OpLogError {
  if planner.has_pending() {
    return None
  }
  let staged : Array[@core.Op] = []
  let planned_raws : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let mut next_arrival = planner.next_arrival
  for op in incoming {
    let raw = remote_admission_raw(op)
    if is_admitted(raw) || planned_raws.contains(raw) {
      continue
    }
    remote_admission_validate(op)
    if !issue86_split_ready(op, planned_raws, is_admitted) {
      return None
    }
    staged.push(op)
    planned_raws.add(raw)
    next_arrival += 1
  }
  Some({
    planned: staged,
    storage: DeferredFast(staged),
    next_arrival,
    generation: planner.generation,
    consumed: false,
  })
}

///|
// General staging uses the production overlay and queue drain, but captures
// Array-normalized metadata into one ordered compact node Array at the end.
fn issue86_split_stage(
  planner : RemoteAdmissionPlanner,
  overlay : RemoteAdmissionOverlay,
  incoming : Array[@core.Op],
  is_admitted : (@core.RawVersion) -> Bool,
) -> Int raise OpLogError {
  let mut next_arrival = planner.next_arrival
  for op in incoming {
    let raw = remote_admission_raw(op)
    if is_admitted(raw) ||
      planner.pending.contains(raw) ||
      overlay.staged.contains(raw) {
      continue
    }
    remote_admission_validate(op)
    let dependencies = issue86_split_dependencies(op)
    let waiting_dependencies : Array[@core.RawVersion] = []
    for dependency in dependencies {
      if !is_admitted(dependency) {
        waiting_dependencies.push(dependency)
      }
    }
    let node = {
      op,
      arrival: next_arrival,
      dependencies,
      waiting_dependencies,
      unresolved_count: waiting_dependencies.length(),
      ready_refs: 0,
    }
    next_arrival += 1
    overlay.staged.set(raw, node)
    overlay.staged_order.push(raw)
    overlay.staged_unresolved.set(raw, node.unresolved_count)
    for dependency in node.waiting_dependencies {
      overlay.add_waiter(dependency, { raw, arrival: node.arrival })
    }
  }
  next_arrival
}

///|
fn issue86_split_general_prepare(
  planner : RemoteAdmissionPlanner,
  incoming : Array[@core.Op],
  is_admitted : (@core.RawVersion) -> Bool,
) -> BenchmarkSplitPlan raise OpLogError {
  let overlay = issue86_remote_admission_new_overlay(planner)
  let next_arrival = issue86_split_stage(
    planner, overlay, incoming, is_admitted,
  )
  issue86_remote_admission_initial_schedule(overlay)
  issue86_remote_admission_drain(planner, overlay, is_admitted)
  let staged_nodes : Array[BenchmarkCompactStagedNode] = []
  for raw in overlay.staged_order {
    match overlay.staged.get(raw) {
      Some(node) =>
        staged_nodes.push({
          op: node.op,
          raw,
          arrival: node.arrival,
          dependencies: node.dependencies,
          waiting_dependencies: node.waiting_dependencies,
          unresolved_count: node.unresolved_count,
        })
      None => ()
    }
  }
  {
    planned: overlay.planned_operations,
    storage: ImmediateGeneral(staged_nodes),
    next_arrival,
    generation: planner.generation,
    consumed: false,
  }
}

///|
fn issue86_split_hybrid_prepare(
  planner : RemoteAdmissionPlanner,
  incoming : Array[@core.Op],
  is_admitted : (@core.RawVersion) -> Bool,
) -> BenchmarkSplitPlan raise OpLogError {
  match issue86_split_fast_prepare(planner, incoming, is_admitted) {
    Some(plan) => plan
    None => issue86_split_general_prepare(planner, incoming, is_admitted)
  }
}

///|
fn issue86_split_clone_node(
  node : BenchmarkCompactStagedNode,
) -> BenchmarkCompactStagedNode {
  {
    op: node.op,
    raw: node.raw,
    arrival: node.arrival,
    dependencies: node.dependencies.copy(),
    waiting_dependencies: node.waiting_dependencies.copy(),
    unresolved_count: node.unresolved_count,
  }
}

///|
// Copy/accessor helpers preserve one ordered storage array per plan variant.
fn issue86_split_plan_copy(plan : BenchmarkSplitPlan) -> BenchmarkSplitPlan {
  match plan.storage {
    DeferredFast(ops) => {
      let copied = ops.copy()
      {
        planned: copied,
        storage: DeferredFast(copied),
        next_arrival: plan.next_arrival,
        generation: plan.generation,
        consumed: false,
      }
    }
    ImmediateGeneral(nodes) =>
      {
        planned: plan.planned.copy(),
        storage: ImmediateGeneral(nodes.map(issue86_split_clone_node)),
        next_arrival: plan.next_arrival,
        generation: plan.generation,
        consumed: false,
      }
  }
}

///|
fn issue86_split_same_operation(left : @core.Op, right : @core.Op) -> Bool {
  left.lv() == right.lv() &&
  left.parents() == right.parents() &&
  left.agent() == right.agent() &&
  left.seq() == right.seq() &&
  left.content() == right.content() &&
  left.origin_left() == right.origin_left() &&
  left.origin_right() == right.origin_right()
}

///|
// A successful commit acknowledges only the planned prefix. Begin never
// acknowledges: graph admission remains an explicit imperative-shell event.
fn issue86_split_commit_prefix(
  planner : RemoteAdmissionPlanner,
  plan : BenchmarkSplitPlan,
  successful_count : Int,
) -> Unit {
  let count = successful_count.min(plan.planned.length()).max(0)
  for index in 0..<count {
    planner.acknowledge_admitted(remote_admission_raw(plan.planned[index]))
  }
}

///|
fn issue86_split_commit_success(
  planner : RemoteAdmissionPlanner,
  plan : BenchmarkSplitPlan,
) -> Unit {
  issue86_split_commit_prefix(planner, plan, plan.planned.length())
}

///|
// Common validation happens before the variant-specific checks and before all
// canonical mutation. Every malformed capability therefore fails atomically.
fn issue86_split_validate_planned(
  planner : RemoteAdmissionPlanner,
  plan : BenchmarkSplitPlan,
) -> RemoteAdmissionBeginResult? {
  // This index is validation-only and dies before registration; the plan keeps
  // no staged map. It avoids an O(N²) scan when queue order reverses arrival.
  let staged_index : Map[@core.RawVersion, @core.Op] = match plan.storage {
    DeferredFast(ops) => {
      let index : Map[@core.RawVersion, @core.Op] = Map::default()
      for op in ops {
        index.set(remote_admission_raw(op), op)
      }
      index
    }
    ImmediateGeneral(nodes) => {
      let index : Map[@core.RawVersion, @core.Op] = Map::default()
      for node in nodes {
        index.set(node.raw, node.op)
      }
      index
    }
  }
  let seen_planned : Map[@core.RawVersion, Unit] = Map::default()
  for op in plan.planned {
    let raw = remote_admission_raw(op)
    if seen_planned.contains(raw) {
      return Some(RemoteAdmissionBeginResult::Conflict)
    }
    seen_planned.set(raw, ())
    let exact = match planner.pending.get(raw) {
      Some(node) => issue86_split_same_operation(op, node.op)
      None =>
        match staged_index.get(raw) {
          Some(staged_op) => issue86_split_same_operation(op, staged_op)
          None => false
        }
    }
    if !exact {
      return Some(RemoteAdmissionBeginResult::Conflict)
    }
  }
  None
}

///|
fn issue86_split_begin(
  planner : RemoteAdmissionPlanner,
  plan : BenchmarkSplitPlan,
  is_admitted : (@core.RawVersion) -> Bool,
) -> RemoteAdmissionBeginResult raise OpLogError {
  if plan.consumed {
    return RemoteAdmissionBeginResult::Consumed
  }
  if plan.generation != planner.generation {
    return RemoteAdmissionBeginResult::Stale
  }
  let storage_count = issue86_split_storage_length(plan.storage)
  if plan.next_arrival < planner.next_arrival ||
    plan.next_arrival != planner.next_arrival + storage_count {
    return RemoteAdmissionBeginResult::Conflict
  }
  match issue86_split_validate_planned(planner, plan) {
    Some(result) => return result
    None => ()
  }
  match plan.storage {
    DeferredFast(ops) => {
      if plan.planned.length() != ops.length() {
        return RemoteAdmissionBeginResult::Conflict
      }
      for index, op in ops {
        if !issue86_split_same_operation(plan.planned[index], op) {
          return RemoteAdmissionBeginResult::Conflict
        }
      }
      let seen_raws : Map[@core.RawVersion, Unit] = Map::default()
      let nodes : Array[(@core.RawVersion, RemoteAdmissionNode)] = []
      for index, op in ops {
        let raw = remote_admission_raw(op)
        if is_admitted(raw) ||
          seen_raws.contains(raw) ||
          planner.pending.contains(raw) {
          return RemoteAdmissionBeginResult::Conflict
        }
        seen_raws.set(raw, ())
        remote_admission_validate(op)
        let dependencies = issue86_split_dependencies(op)
        let waiting_dependencies : Array[@core.RawVersion] = []
        for dependency in dependencies {
          if !is_admitted(dependency) {
            waiting_dependencies.push(dependency)
          }
        }
        nodes.push(
          (
            raw,
            {
              op,
              arrival: planner.next_arrival + index,
              dependencies,
              waiting_dependencies,
              unresolved_count: waiting_dependencies.length(),
              ready_refs: 0,
            },
          ),
        )
      }
      // The temporary node Array is complete before registration starts.
      for raw_node in nodes {
        let (raw, node) = raw_node
        planner.register_canonical(raw, node)
      }
    }
    ImmediateGeneral(nodes) => {
      let seen_raws : Map[@core.RawVersion, Unit] = Map::default()
      for index, node in nodes {
        let raw = remote_admission_raw(node.op)
        if node.raw != raw ||
          is_admitted(raw) ||
          seen_raws.contains(raw) ||
          planner.pending.contains(raw) ||
          node.arrival != planner.next_arrival + index {
          return RemoteAdmissionBeginResult::Conflict
        }
        seen_raws.set(raw, ())
        remote_admission_validate(node.op)
        if node.dependencies != issue86_split_dependencies(node.op) {
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
      // Stored metadata is registered directly; begin does not recompute it.
      for node in nodes {
        planner.register_canonical(node.raw, {
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
  planner.next_arrival = plan.next_arrival
  plan.consumed = true
  planner.generation += 1
  RemoteAdmissionBeginResult::Applied
}

///|
fn issue86_split_result_is_applied(result : RemoteAdmissionBeginResult) -> Bool {
  match result {
    RemoteAdmissionBeginResult::Applied => true
    _ => false
  }
}

///|
// Compare both oracle order and production order outside the timed closure.
fn issue86_assert_split_plan(
  ops : Array[@core.Op],
  expect_fast : Bool,
) -> Unit raise {
  let (oracle_planned, oracle_remaining) = try! issue86_fixed_point_oracle(
    ops.copy(),
    [],
  )
  let (production_planned, production_remaining) = try! issue86_production_plan(
    ops,
  )
  issue86_assert_raws(
    issue86_raws(oracle_planned),
    issue86_raws(production_planned),
  )
  issue86_assert_raws(issue86_raws(oracle_remaining), production_remaining)
  let fast = try! issue86_split_fast_prepare(RemoteAdmissionPlanner(), ops, _ => {
    false
  })
  match fast {
    Some(plan) =>
      assert_true(expect_fast && issue86_split_storage_is_fast(plan))
    None => assert_true(!expect_fast)
  }
  let source_planner = RemoteAdmissionPlanner()
  let plan = try! issue86_split_hybrid_prepare(source_planner, ops, _ => false)
  assert_true(issue86_split_storage_is_fast(plan) == expect_fast)
  issue86_assert_raws(
    plan.planned |> issue86_raws,
    issue86_raws(oracle_planned),
  )
  issue86_assert_raws(
    plan.planned |> issue86_raws,
    issue86_raws(production_planned),
  )
  assert_eq(oracle_remaining.length(), 0)
  let begin_planner = RemoteAdmissionPlanner()
  let begin_plan = issue86_split_plan_copy(plan)
  assert_true(
    issue86_split_result_is_applied(
      try! issue86_split_begin(begin_planner, begin_plan, _ => false),
    ),
  )
  assert_true(begin_plan.consumed)
  issue86_split_commit_success(begin_planner, begin_plan)
  assert_eq(begin_planner.pending_raws().length(), 0)
  assert_true(!begin_planner.has_pending())
  assert_true(source_planner.pending_raws().length() == 0)
}

///|
test "oplog - issue86 split repeated parent-origin normalization guard" {
  let left = @core.RawVersion::new("issue86-split-repeat-left", 0)
  let right = @core.RawVersion::new("issue86-split-repeat-right", 0)
  let repeated = @core.Op::new_insert(
    -1,
    [left, right, left, right],
    "issue86-split-repeated",
    0,
    "x",
    Some(right),
    Some(left),
  )
  assert_eq(issue86_split_dependencies(repeated), [left, right])
  let normalized = issue86_split_dependencies(repeated)
  let normalized_ready = fn(
    admitted : @hashset.HashSet[@core.RawVersion],
    planned : @hashset.HashSet[@core.RawVersion],
  ) -> Bool {
    for dependency in normalized {
      if !admitted.contains(dependency) && !planned.contains(dependency) {
        return false
      }
    }
    true
  }
  let ready_admitted : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([
    left, right,
  ])
  let ready_planned : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([
    left, right,
  ])
  let unready_admitted : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([
    left,
  ])
  let unready_planned : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([
    left,
  ])
  for
    view in [
      (ready_admitted, @hashset.HashSet([]), true),
      (@hashset.HashSet([]), ready_planned, true),
      (unready_admitted, @hashset.HashSet([]), false),
      (@hashset.HashSet([]), unready_planned, false),
    ] {
    let (admitted, planned, expected) = view
    let actual = issue86_split_ready(repeated, planned, raw => {
      admitted.contains(raw)
    })
    assert_true(actual == expected)
    assert_true(actual == normalized_ready(admitted, planned))
  }
  let left_op = @core.Op::new_insert(
    -1,
    [],
    "issue86-split-repeat-left",
    0,
    "l",
    None,
    None,
  )
  let right_op = @core.Op::new_insert(
    -1,
    [],
    "issue86-split-repeat-right",
    0,
    "r",
    None,
    None,
  )
  issue86_assert_split_plan([repeated, right_op, left_op], false)
}

///|
test "oplog - issue86 split malformed capability is atomic" {
  let ops = issue86_all_ready_batch(2)
  let prepared = try! issue86_split_fast_prepare(
    RemoteAdmissionPlanner(),
    ops,
    _ => false,
  ).unwrap()
  let malformed = issue86_split_plan_copy(prepared)
  match malformed.storage {
    DeferredFast(staged) => staged.push(staged[0])
    ImmediateGeneral(_) => assert_true(false)
  }
  let planner = RemoteAdmissionPlanner()
  let result = try! issue86_split_begin(planner, malformed, _ => false)
  match result {
    RemoteAdmissionBeginResult::Conflict => ()
    _ => assert_true(false)
  }
  assert_eq(planner.pending_raws().length(), 0)
  assert_eq(planner.next_arrival, 0)
  assert_eq(planner.generation, 0)
}

///|
test "oplog - issue86 split pending-first lifecycle guard" {
  let parent = @core.Op::new_insert(
    -1,
    [],
    "issue86-split-pending-parent",
    0,
    "p",
    None,
    None,
  )
  let child = @core.Op::new_insert(
    -1,
    [remote_admission_raw(parent)],
    "issue86-split-pending-child",
    0,
    "c",
    None,
    None,
  )
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(child, _ => false)
  let plan = try! issue86_split_hybrid_prepare(planner, [parent], _ => false)
  assert_true(!issue86_split_storage_is_fast(plan))
  let (expected, _) = try! issue86_fixed_point_oracle([child, parent], [])
  issue86_assert_raws(plan.planned |> issue86_raws, issue86_raws(expected))
  assert_eq(plan.planned.length(), 2)
  assert_true(issue86_split_same_operation(plan.planned[0], parent))
  assert_true(issue86_split_same_operation(plan.planned[1], child))
  assert_true(
    issue86_split_result_is_applied(
      try! issue86_split_begin(planner, plan, _ => false),
    ),
  )
  issue86_split_commit_success(planner, plan)
  issue86_split_commit_prefix(planner, plan, 0)
  planner.acknowledge_admitted(remote_admission_raw(child))
  assert_eq(planner.pending_raws().length(), 0)
}

///|
test "oplog - issue86 split unresolved remains pending" {
  let unknown = @core.RawVersion::new("issue86-split-unresolved-unknown", 0)
  let child = @core.Op::new_insert(
    -1,
    [unknown],
    "issue86-split-unresolved-child",
    0,
    "c",
    None,
    None,
  )
  let planner = RemoteAdmissionPlanner()
  let plan = try! issue86_split_hybrid_prepare(planner, [child], _ => false)
  assert_true(!issue86_split_storage_is_fast(plan))
  assert_eq(plan.planned.length(), 0)
  match issue86_split_begin(planner, plan, _ => false) {
    RemoteAdmissionBeginResult::Applied => ()
    _ => assert_true(false)
  }
  assert_eq(planner.pending_raws(), [remote_admission_raw(child)])
}

///|
test "oplog - issue86 split partial prefix keeps remainder" {
  let ops = issue86_all_ready_batch(3)
  let planner = RemoteAdmissionPlanner()
  let plan = try! issue86_split_hybrid_prepare(planner, ops, _ => false)
  assert_true(issue86_split_storage_is_fast(plan))
  assert_true(
    issue86_split_result_is_applied(
      try! issue86_split_begin(planner, plan, _ => false),
    ),
  )
  issue86_split_commit_prefix(planner, plan, 1)
  issue86_assert_raws(planner.pending_raws(), issue86_raws([ops[1], ops[2]]))
}

///|
test "oplog - issue86 split generation stale before mutation" {
  let ops = issue86_all_ready_batch(2)
  let planner = RemoteAdmissionPlanner()
  let plan = try! issue86_split_hybrid_prepare(planner, ops, _ => false)
  planner.acknowledge_admitted(
    @core.RawVersion::new("issue86-split-stale-unrelated", 0),
  )
  let result = try! issue86_split_begin(planner, plan, _ => false)
  match result {
    RemoteAdmissionBeginResult::Stale => ()
    _ => assert_true(false)
  }
  assert_eq(planner.pending_raws().length(), 0)
  assert_eq(planner.next_arrival, 0)
}

///|
test "oplog - issue86 split consumed reuse before mutation" {
  let ops = issue86_all_ready_batch(2)
  let planner = RemoteAdmissionPlanner()
  let plan = try! issue86_split_hybrid_prepare(planner, ops, _ => false)
  assert_true(
    issue86_split_result_is_applied(
      try! issue86_split_begin(planner, plan, _ => false),
    ),
  )
  let pending_before = planner.pending_raws()
  let generation_before = planner.generation
  let second_result = try! issue86_split_begin(planner, plan, _ => false)
  match second_result {
    RemoteAdmissionBeginResult::Consumed => ()
    _ => assert_true(false)
  }
  issue86_assert_raws(planner.pending_raws(), pending_before)
  assert_eq(planner.generation, generation_before)
}

///|
// Current and split lifecycle measurements cover prepare, begin, and a full
// successful planned-prefix acknowledgement sequence.
fn issue86_current_admission_lifecycle(
  ops : Array[@core.Op],
) -> (Array[@core.RawVersion], Array[@core.RawVersion]) raise OpLogError {
  let planner = RemoteAdmissionPlanner()
  let plan = planner.prepare(ops, _ => false)
  match planner.begin(plan) {
    RemoteAdmissionBeginResult::Applied => ()
    _ => abort("current lifecycle begin failed")
  }
  let planned = issue86_raws(plan.operations().to_owned())
  for op in plan.operations() {
    planner.acknowledge_admitted(remote_admission_raw(op))
  }
  (planned, planner.pending_raws())
}

///|
fn issue86_split_admission_lifecycle(
  ops : Array[@core.Op],
) -> (Array[@core.RawVersion], Array[@core.RawVersion]) raise OpLogError {
  let planner = RemoteAdmissionPlanner()
  let plan = issue86_split_hybrid_prepare(planner, ops, _ => false)
  match issue86_split_begin(planner, plan, _ => false) {
    RemoteAdmissionBeginResult::Applied => ()
    _ => abort("split lifecycle begin failed")
  }
  let planned = issue86_raws(plan.planned)
  issue86_split_commit_success(planner, plan)
  (planned, planner.pending_raws())
}

///|
fn issue86_assert_admission_lifecycle(ops : Array[@core.Op]) -> Unit raise {
  let (oracle_planned, oracle_remaining) = issue86_fixed_point_oracle(
    ops.copy(),
    [],
  )
  assert_eq(oracle_remaining.length(), 0)
  let (current_planned, current_pending) = try! issue86_current_admission_lifecycle(
    ops,
  )
  let (split_planned, split_pending) = try! issue86_split_admission_lifecycle(
    ops,
  )
  issue86_assert_raws(current_planned, issue86_raws(oracle_planned))
  issue86_assert_raws(split_planned, issue86_raws(oracle_planned))
  assert_eq(current_pending.length(), 0)
  assert_eq(split_pending.length(), 0)
}

///|
fn issue86_oracle_prepared(
  ops : Array[@core.Op],
) -> Array[@core.RawVersion] raise OpLogError {
  let (planned, _) = issue86_fixed_point_oracle(ops.copy(), [])
  issue86_raws(planned)
}

///|
fn issue86_current_prepared(
  ops : Array[@core.Op],
) -> Array[@core.RawVersion] raise OpLogError {
  issue86_raws(issue86_production_planned(ops))
}

///|
fn issue86_split_prepared(
  ops : Array[@core.Op],
) -> Array[@core.RawVersion] raise OpLogError {
  let plan = issue86_split_hybrid_prepare(RemoteAdmissionPlanner(), ops, _ => {
    false
  })
  issue86_raws(plan.planned)
}

///|
fn issue86_assert_prepare_matrix(
  ops : Array[@core.Op],
  expect_fast : Bool,
) -> Unit raise {
  // Equality and lifecycle checks are deliberately outside timed closures.
  issue86_assert_planner_equivalence(ops)
  issue86_assert_split_plan(ops, expect_fast)
  let oracle = try! issue86_oracle_prepared(ops)
  let current = try! issue86_current_prepared(ops)
  let private_prepare = try! issue86_production_plan(ops)
  issue86_assert_raws(current, oracle)
  issue86_assert_raws(issue86_raws(private_prepare.0), oracle)
  issue86_assert_raws(private_prepare.1, [])
}

///|
test "oplog - issue86 oracle prepare ready1" (b : @bench.T) {
  let ops = issue86_all_ready_batch(1)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_oracle_prepared(ops)) })
}

///|
test "oplog - issue86 current prepare ready1" (b : @bench.T) {
  let ops = issue86_all_ready_batch(1)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_current_prepared(ops)) })
}

///|
test "oplog - issue86 split prepare ready1" (b : @bench.T) {
  let ops = issue86_all_ready_batch(1)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_split_prepared(ops)) })
}

///|
test "oplog - issue86 oracle prepare ready32" (b : @bench.T) {
  let ops = issue86_all_ready_batch(32)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_oracle_prepared(ops)) })
}

///|
test "oplog - issue86 current prepare ready32" (b : @bench.T) {
  let ops = issue86_all_ready_batch(32)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_current_prepared(ops)) })
}

///|
test "oplog - issue86 split prepare ready32" (b : @bench.T) {
  let ops = issue86_all_ready_batch(32)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_split_prepared(ops)) })
}

///|
test "oplog - issue86 oracle prepare inorder1" (b : @bench.T) {
  let ops = issue86_remote_chain(1)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_oracle_prepared(ops)) })
}

///|
test "oplog - issue86 current prepare inorder1" (b : @bench.T) {
  let ops = issue86_remote_chain(1)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_current_prepared(ops)) })
}

///|
test "oplog - issue86 split prepare inorder1" (b : @bench.T) {
  let ops = issue86_remote_chain(1)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_split_prepared(ops)) })
}

///|
test "oplog - issue86 oracle prepare inorder64" (b : @bench.T) {
  let ops = issue86_remote_chain(64)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_oracle_prepared(ops)) })
}

///|
test "oplog - issue86 current prepare inorder64" (b : @bench.T) {
  let ops = issue86_remote_chain(64)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_current_prepared(ops)) })
}

///|
test "oplog - issue86 split prepare inorder64" (b : @bench.T) {
  let ops = issue86_remote_chain(64)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_split_prepared(ops)) })
}

///|
test "oplog - issue86 oracle prepare duplicate32x8" (b : @bench.T) {
  let ops = issue86_duplicate_heavy_batch(32, 8)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_oracle_prepared(ops)) })
}

///|
test "oplog - issue86 current prepare duplicate32x8" (b : @bench.T) {
  let ops = issue86_duplicate_heavy_batch(32, 8)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_current_prepared(ops)) })
}

///|
test "oplog - issue86 split prepare duplicate32x8" (b : @bench.T) {
  let ops = issue86_duplicate_heavy_batch(32, 8)
  try! issue86_assert_prepare_matrix(ops, true)
  b.bench(fn() { b.keep(try! issue86_split_prepared(ops)) })
}

///|
test "oplog - issue86 oracle prepare branches4x250" (b : @bench.T) {
  let ops = issue86_reverse_ops(issue86_remote_branches(250))
  try! issue86_assert_prepare_matrix(ops, false)
  b.bench(fn() { b.keep(try! issue86_oracle_prepared(ops)) }, count=1)
}

///|
test "oplog - issue86 current prepare branches4x250" (b : @bench.T) {
  let ops = issue86_reverse_ops(issue86_remote_branches(250))
  try! issue86_assert_prepare_matrix(ops, false)
  b.bench(fn() { b.keep(try! issue86_current_prepared(ops)) }, count=1)
}

///|
test "oplog - issue86 split prepare branches4x250" (b : @bench.T) {
  let ops = issue86_reverse_ops(issue86_remote_branches(250))
  try! issue86_assert_prepare_matrix(ops, false)
  b.bench(fn() { b.keep(try! issue86_split_prepared(ops)) }, count=1)
}

///|
test "oplog - issue86 oracle prepare reverse10k" (b : @bench.T) {
  let ops = issue86_reverse_ops(issue86_remote_chain(10000))
  try! issue86_assert_prepare_matrix(ops, false)
  b.bench(fn() { b.keep(try! issue86_oracle_prepared(ops)) }, count=1)
}

///|
test "oplog - issue86 current prepare reverse10k" (b : @bench.T) {
  let ops = issue86_reverse_ops(issue86_remote_chain(10000))
  try! issue86_assert_prepare_matrix(ops, false)
  b.bench(fn() { b.keep(try! issue86_current_prepared(ops)) }, count=1)
}

///|
test "oplog - issue86 split prepare reverse10k" (b : @bench.T) {
  let ops = issue86_reverse_ops(issue86_remote_chain(10000))
  try! issue86_assert_prepare_matrix(ops, false)
  b.bench(fn() { b.keep(try! issue86_split_prepared(ops)) }, count=1)
}

///|
test "oplog - issue86 current lifecycle ready32" (b : @bench.T) {
  let ops = issue86_all_ready_batch(32)
  try! issue86_assert_admission_lifecycle(ops)
  b.bench(fn() { b.keep(try! issue86_current_admission_lifecycle(ops)) })
}

///|
test "oplog - issue86 split lifecycle ready32" (b : @bench.T) {
  let ops = issue86_all_ready_batch(32)
  try! issue86_assert_admission_lifecycle(ops)
  b.bench(fn() { b.keep(try! issue86_split_admission_lifecycle(ops)) })
}

///|
test "oplog - issue86 current lifecycle inorder64" (b : @bench.T) {
  let ops = issue86_remote_chain(64)
  try! issue86_assert_admission_lifecycle(ops)
  b.bench(fn() { b.keep(try! issue86_current_admission_lifecycle(ops)) })
}

///|
test "oplog - issue86 split lifecycle inorder64" (b : @bench.T) {
  let ops = issue86_remote_chain(64)
  try! issue86_assert_admission_lifecycle(ops)
  b.bench(fn() { b.keep(try! issue86_split_admission_lifecycle(ops)) })
}

///|
test "oplog - issue86 current lifecycle branches4x250" (b : @bench.T) {
  let ops = issue86_reverse_ops(issue86_remote_branches(250))
  try! issue86_assert_admission_lifecycle(ops)
  b.bench(
    fn() { b.keep(try! issue86_current_admission_lifecycle(ops)) },
    count=1,
  )
}

///|
test "oplog - issue86 split lifecycle branches4x250" (b : @bench.T) {
  let ops = issue86_reverse_ops(issue86_remote_branches(250))
  try! issue86_assert_admission_lifecycle(ops)
  b.bench(fn() { b.keep(try! issue86_split_admission_lifecycle(ops)) }, count=1)
}

///|
test "oplog - issue86 current lifecycle reverse10k" (b : @bench.T) {
  let ops = issue86_reverse_ops(issue86_remote_chain(10000))
  try! issue86_assert_admission_lifecycle(ops)
  b.bench(
    fn() { b.keep(try! issue86_current_admission_lifecycle(ops)) },
    count=1,
  )
}

///|
test "oplog - issue86 split lifecycle reverse10k" (b : @bench.T) {
  let ops = issue86_reverse_ops(issue86_remote_chain(10000))
  try! issue86_assert_admission_lifecycle(ops)
  b.bench(fn() { b.keep(try! issue86_split_admission_lifecycle(ops)) }, count=1)
}
