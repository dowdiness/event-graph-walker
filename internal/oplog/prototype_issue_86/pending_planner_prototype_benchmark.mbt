// PROTOTYPE for Issue #86. This package is not production code.
// Question: can a persistent reverse dependency index plus a deterministic
// ready queue reproduce OpLog's fixed-point order at materially lower cost?
// Run with: moon bench --release internal/oplog/prototype_issue_86

///|
priv struct PrototypeReady {
  round_key : Int
  index_key : Int
} derive(Eq, Compare)

///|
priv struct PrototypeNode {
  op : @core.Op
  mut unresolved : Int
  mut ready_round : Int
  mut active : Bool
}

///|
priv struct PrototypePlanner {
  nodes : Array[PrototypeNode]
  pending : Map[@core.RawVersion, Int]
  waiters : Map[@core.RawVersion, Array[Int]]
  resolved : @hashset.HashSet[@core.RawVersion]
  ready : @priority_queue.PriorityQueue[PrototypeReady]
}

///|
fn PrototypePlanner::PrototypePlanner(
  known? : Array[@core.RawVersion] = [],
) -> PrototypePlanner {
  let resolved : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for raw in known {
    resolved.add(raw)
  }
  {
    nodes: [],
    pending: Map([]),
    waiters: Map([]),
    resolved,
    ready: @priority_queue.PriorityQueue([]),
  }
}

///|
fn PrototypePlanner::add(
  self : PrototypePlanner,
  op : @core.Op,
) -> Unit raise @oplog.OpLogError {
  if (op.is_delete() || op.is_undelete()) && op.origin_left() is None {
    raise @oplog.OpLogError::MissingOrigin
  }
  let raw = @core.RawVersion::new(op.agent(), op.seq())
  if self.pending.contains(raw) || self.resolved.contains(raw) {
    return
  }
  let index = self.nodes.length()
  let dependencies : Array[@core.RawVersion] = []
  for parent in op.parents_iter() {
    if !dependencies.contains(parent) {
      dependencies.push(parent)
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
  let mut unresolved = 0
  for dependency in dependencies {
    if !self.resolved.contains(dependency) {
      unresolved += 1
      match self.waiters.get(dependency) {
        Some(indices) => indices.push(index)
        None => self.waiters[dependency] = [index]
      }
    }
  }
  self.nodes.push({ op, unresolved, ready_round: 0, active: true })
  self.pending[raw] = index
  if unresolved == 0 {
    self.ready.push({ round_key: 0, index_key: -index })
  }
}

///|
fn PrototypePlanner::drain(self : PrototypePlanner) -> Array[@core.Op] {
  let planned : Array[@core.Op] = []
  while self.ready.pop() is Some(entry) {
    let round = -entry.round_key
    let index = -entry.index_key
    let node = self.nodes[index]
    if !node.active {
      continue
    }
    node.active = false
    let raw = @core.RawVersion::new(node.op.agent(), node.op.seq())
    self.pending.remove(raw)
    self.resolved.add(raw)
    planned.push(node.op)
    match self.waiters.get(raw) {
      None => ()
      Some(indices) =>
        for dependent_index in indices {
          let dependent = self.nodes[dependent_index]
          if dependent.active {
            dependent.unresolved -= 1
            let next_round = round +
              (if index >= dependent_index { 1 } else { 0 })
            dependent.ready_round = dependent.ready_round.max(next_round)
            if dependent.unresolved == 0 {
              self.ready.push({
                round_key: -dependent.ready_round,
                index_key: -dependent_index,
              })
            }
          }
        }
    }
  }
  planned
}

///|
fn PrototypePlanner::discard_dependents(
  self : PrototypePlanner,
  roots : Array[@core.RawVersion],
) -> Unit {
  let queue = roots.copy()
  let rejected : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let mut head = 0
  while head < queue.length() {
    let raw = queue[head]
    head += 1
    if rejected.contains(raw) {
      continue
    }
    rejected.add(raw)
    match self.pending.get(raw) {
      Some(index) => {
        self.nodes[index].active = false
        self.pending.remove(raw)
      }
      None => ()
    }
    match self.waiters.get(raw) {
      Some(indices) =>
        for index in indices {
          let dependent = self.nodes[index]
          if dependent.active {
            queue.push(
              @core.RawVersion::new(dependent.op.agent(), dependent.op.seq()),
            )
          }
        }
      None => ()
    }
  }
}

///|
fn PrototypePlanner::pending_count(self : PrototypePlanner) -> Int {
  self.pending.length()
}

///|
fn prototype_plan_batch(ops : Array[@core.Op]) -> Array[@core.Op] {
  let planner = PrototypePlanner()
  for op in ops {
    try! planner.add(op)
  }
  planner.drain()
}

///|
fn prototype_apply_one_at_a_time(ops : Array[@core.Op]) -> Int {
  let planner = PrototypePlanner()
  let mut applied = 0
  for op in ops {
    try! planner.add(op)
    applied += planner.drain().length()
  }
  applied
}

///|
fn prototype_remote_chain(n : Int) -> Array[@core.Op] {
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
fn prototype_reverse(ops : Array[@core.Op]) -> Array[@core.Op] {
  [
    for i in 0..<ops.length() => ops[ops.length() - i - 1]
  ]
}

///|
fn prototype_remote_branches(depth : Int) -> Array[@core.Op] {
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
fn assert_same_order(ops : Array[@core.Op]) -> Unit {
  let current = try! @oplog.OpLog::new("local").plan_remote(ops)
  let prototype = prototype_plan_batch(ops)
  guard current.length() == prototype.length() else {
    abort("prototype planned length differs")
  }
  for i in 0..<current.length() {
    guard current[i].agent() == prototype[i].agent() &&
      current[i].seq() == prototype[i].seq() else {
      abort("prototype planned order differs")
    }
  }
}

///|
fn assert_scan_order_semantics() -> Unit {
  let parent = @core.RawVersion::new("parent", 0)
  let ops = [
    @core.Op::new_insert(-1, [parent], "child-before", 0, "x", None, None),
    @core.Op::new_insert(-1, [], "independent", 0, "x", None, None),
    @core.Op::new_insert(-1, [], "parent", 0, "x", None, None),
    @core.Op::new_insert(-1, [parent], "child-after", 0, "x", None, None),
  ]
  assert_same_order(ops)
  let planned = prototype_plan_batch(ops)
  let expected = ["independent", "parent", "child-after", "child-before"]
  for i in 0..<expected.length() {
    guard planned[i].agent() == expected[i] else {
      abort("prototype did not preserve fixed-point scan order")
    }
  }
}

///|
fn assert_pending_semantics() -> Unit {
  let root = @core.RawVersion::new("root", 0)
  let ghost = @core.RawVersion::new("ghost", 0)
  let planner = PrototypePlanner()
  let root_op = @core.Op::new_insert(-1, [ghost], "root", 0, "r", None, None)
  let child_op = @core.Op::new_insert(-1, [root], "child", 0, "c", None, None)
  try! planner.add(root_op)
  try! planner.add(root_op)
  try! planner.add(child_op)
  guard planner.pending_count() == 2 && planner.drain().is_empty() else {
    abort("prototype pending or duplicate behavior differs")
  }
  planner.discard_dependents([root])
  guard planner.pending_count() == 0 else {
    abort("prototype dependent cleanup differs")
  }
  try! planner.add(@core.Op::new_insert(-1, [], "root", 0, "retry", None, None))
  try! planner.add(child_op)
  guard planner.drain().length() == 2 else {
    abort("prototype failed to converge after cleanup and retry")
  }
  let malformed = @core.Op::new_delete(-1, [], "bad", 0, None)
  try planner.add(malformed) catch {
    _ => ()
  } noraise {
    _ => abort("prototype accepted a malformed delete")
  }
}

///|
fn assert_known_dependency_semantics() -> Unit {
  let raw = @core.RawVersion::new("known", 0)
  let seed = @core.Op::new_insert(-1, [], "known", 0, "s", None, None)
  let child = @core.Op::new_insert(
    -1,
    [raw],
    "child",
    0,
    "c",
    Some(raw),
    Some(raw),
  )
  let current_log = @oplog.OpLog::new("local")
  ignore(try! current_log.apply_remote(seed))
  let current = try! current_log.plan_remote([child])
  let prototype = PrototypePlanner(known=[raw])
  try! prototype.add(child)
  let planned = prototype.drain()
  guard current.length() == 1 &&
    planned.length() == 1 &&
    current[0].agent() == planned[0].agent() else {
    abort("prototype did not honor known graph dependencies")
  }
}

///|
test "prototype #86 - reverse chain batch (100)" (b : @bench.T) {
  let ops = prototype_reverse(prototype_remote_chain(100))
  assert_same_order(ops)
  assert_scan_order_semantics()
  assert_pending_semantics()
  assert_known_dependency_semantics()
  b.bench(fn() { b.keep(prototype_plan_batch(ops).length()) }, count=1)
}

///|
test "prototype #86 - reverse chain batch (1000)" (b : @bench.T) {
  let ops = prototype_reverse(prototype_remote_chain(1000))
  b.bench(fn() { b.keep(prototype_plan_batch(ops).length()) }, count=1)
}

///|
test "prototype #86 - reverse chain batch (10000)" (b : @bench.T) {
  let ops = prototype_reverse(prototype_remote_chain(10000))
  b.bench(fn() { b.keep(prototype_plan_batch(ops).length()) }, count=1)
}

///|
/// Planner-only characterization. `OpLog::apply_remote` also commits graph and
/// oplog state, so its timing is not used as an apples-to-apples baseline.
test "prototype #86 - reverse chain incremental (100)" (b : @bench.T) {
  let ops = prototype_reverse(prototype_remote_chain(100))
  b.bench(fn() { b.keep(prototype_apply_one_at_a_time(ops)) }, count=1)
}

///|
test "prototype #86 - reverse chain incremental (1000)" (b : @bench.T) {
  let ops = prototype_reverse(prototype_remote_chain(1000))
  b.bench(fn() { b.keep(prototype_apply_one_at_a_time(ops)) }, count=1)
}

///|
test "prototype #86 - reverse chain incremental (10000)" (b : @bench.T) {
  let ops = prototype_reverse(prototype_remote_chain(10000))
  b.bench(fn() { b.keep(prototype_apply_one_at_a_time(ops)) }, count=1)
}

///|
test "baseline #86 - current reverse branches plan batch (4 x 250)" (
  b : @bench.T,
) {
  let ops = prototype_reverse(prototype_remote_branches(250))
  b.bench(
    fn() {
      let planned = try! @oplog.OpLog::new("local").plan_remote(ops)
      b.keep(planned.length())
    },
    count=1,
  )
}

///|
test "prototype #86 - reverse branches batch (4 x 250)" (b : @bench.T) {
  let ops = prototype_reverse(prototype_remote_branches(250))
  assert_same_order(ops)
  b.bench(fn() { b.keep(prototype_plan_batch(ops).length()) }, count=1)
}

///|
test "prototype #86 - reverse branches incremental (4 x 250)" (b : @bench.T) {
  let ops = prototype_reverse(prototype_remote_branches(250))
  b.bench(fn() { b.keep(prototype_apply_one_at_a_time(ops)) }, count=1)
}
