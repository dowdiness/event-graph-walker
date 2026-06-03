///| Property-based tests for Branch checkout, advance, version-vector checkout,

///| and remote merge orchestration over OpLog/Fugue.

///|
struct TraceSnapshot {
  frontier : @core.Frontier
  text : String
  visible_count : Int
} derive(Debug)

///|
struct BranchTrace {
  ops : Array[@core.Op]
  snapshots : Array[TraceSnapshot]
  from_index : Int
  to_index : Int
  merge_split : Int
} derive(Debug)

///|
fn rand_bounded(rs : @splitmix.RandomState, bound : Int) -> Int {
  if bound <= 0 {
    0
  } else {
    rs.next_uint64().to_int().abs() % bound
  }
}

///|
fn trace_agent(index : Int) -> String {
  "branch-agent-\{index}"
}

///|
fn trace_char(rs : @splitmix.RandomState) -> String {
  let chars : Array[String] = ["a", "b", "c", "d", "e", "f", "g", "h"]
  chars[rand_bounded(rs, chars.length())]
}

///|
fn random_insert_origin(
  inserted_lvs : Array[Int],
  rs : @splitmix.RandomState,
) -> Int {
  if inserted_lvs.is_empty() || rand_bounded(rs, 4) == 0 {
    -1
  } else {
    inserted_lvs[rand_bounded(rs, inserted_lvs.length())]
  }
}

///|
fn random_existing_lv(
  inserted_lvs : Array[Int],
  rs : @splitmix.RandomState,
) -> Int {
  inserted_lvs[rand_bounded(rs, inserted_lvs.length())]
}

///|
fn generate_agent_ops(
  agent : String,
  op_count : Int,
  rs : @splitmix.RandomState,
) -> Array[@core.Op] {
  let oplog = @oplog.OpLog::new(agent)
  let inserted_lvs : Array[Int] = []
  let ops : Array[@core.Op] = []
  for i in 0..<op_count {
    if i == 0 {
      let op = try! oplog.insert(trace_char(rs), -1, -1)
      inserted_lvs.push(op.lv())
      ops.push(op)
    } else if i == 1 {
      let target = random_existing_lv(inserted_lvs, rs)
      let op = if rand_bounded(rs, 2) == 0 {
        try! oplog.delete(target)
      } else {
        try! oplog.undelete(target)
      }
      ops.push(op)
    } else {
      let choice = rand_bounded(rs, 6)
      if choice < 3 {
        let origin_left = random_insert_origin(inserted_lvs, rs)
        let op = try! oplog.insert(trace_char(rs), origin_left, -1)
        inserted_lvs.push(op.lv())
        ops.push(op)
      } else if choice < 5 {
        let target = random_existing_lv(inserted_lvs, rs)
        ops.push(try! oplog.delete(target))
      } else {
        let target = random_existing_lv(inserted_lvs, rs)
        ops.push(try! oplog.undelete(target))
      }
    }
  }
  ops
}

///|
fn interleave_agent_ops(
  agent_ops : Array[Array[@core.Op]],
  rs : @splitmix.RandomState,
) -> Array[@core.Op] {
  let next_indices = Array::make(agent_ops.length(), 0)
  let mut remaining = 0
  for ops in agent_ops {
    remaining = remaining + ops.length()
  }
  let result : Array[@core.Op] = []
  while remaining > 0 {
    let available_agents : Array[Int] = []
    for agent_index, ops in agent_ops {
      if next_indices[agent_index] < ops.length() {
        available_agents.push(agent_index)
      }
    }
    let agent_index = available_agents[rand_bounded(
        rs,
        available_agents.length(),
      )]
    let op_index = next_indices[agent_index]
    result.push(agent_ops[agent_index][op_index])
    next_indices[agent_index] = op_index + 1
    remaining = remaining - 1
  }
  result
}

///|
fn replay_ops(ops : Array[@core.Op]) -> @oplog.OpLog {
  let oplog = @oplog.OpLog::new("branch-trace-collector")
  for op in ops {
    ignore(try! oplog.apply_remote(op))
  }
  oplog
}

///|
fn snapshot_frontier(
  oplog : @oplog.OpLog,
  frontier : @core.Frontier,
) -> TraceSnapshot {
  let branch = try! Branch::checkout(oplog, frontier)
  {
    frontier: @core.Frontier::from_array(frontier.0.copy()),
    text: branch.to_text(),
    visible_count: branch.visible_count(),
  }
}

///|
fn snapshot_current(oplog : @oplog.OpLog) -> TraceSnapshot {
  snapshot_frontier(oplog, oplog.get_frontier())
}

///|
fn add_version_vector_snapshot(
  oplog : @oplog.OpLog,
  snapshots : Array[TraceSnapshot],
  vv : @causal_graph.VersionVector,
) -> Unit {
  let frontier = vv.to_frontier(oplog.causal_graph())
  snapshots.push(snapshot_frontier(oplog, frontier))
}

///|
fn add_extra_snapshots(
  oplog : @oplog.OpLog,
  agent_counts : Array[Int],
  snapshots : Array[TraceSnapshot],
  rs : @splitmix.RandomState,
) -> Unit {
  for agent_index, count in agent_counts {
    if count > 0 {
      let vv = @causal_graph.VersionVector::new().set(
        trace_agent(agent_index),
        count - 1,
      )
      add_version_vector_snapshot(oplog, snapshots, vv)
    }
  }
  for _ in 0..<4 {
    let mut vv = @causal_graph.VersionVector::new()
    let mut included = false
    for agent_index, count in agent_counts {
      if count > 0 && rand_bounded(rs, 2) == 0 {
        vv = vv.set(trace_agent(agent_index), rand_bounded(rs, count))
        included = true
      }
    }
    if !included && !agent_counts.is_empty() {
      let agent_index = rand_bounded(rs, agent_counts.length())
      let count = agent_counts[agent_index]
      if count > 0 {
        vv = vv.set(trace_agent(agent_index), rand_bounded(rs, count))
      }
    }
    add_version_vector_snapshot(oplog, snapshots, vv)
  }
}

///|
fn replay_with_snapshots(
  ops : Array[@core.Op],
) -> (@oplog.OpLog, Array[TraceSnapshot]) {
  let oplog = @oplog.OpLog::new("branch-trace-collector")
  let snapshots : Array[TraceSnapshot] = [snapshot_current(oplog)]
  for op in ops {
    ignore(try! oplog.apply_remote(op))
    snapshots.push(snapshot_current(oplog))
  }
  (oplog, snapshots)
}

///|
fn normalize_trace(
  ops : Array[@core.Op],
  snapshots : Array[TraceSnapshot],
  from_index : Int,
  to_index : Int,
  merge_split : Int,
) -> BranchTrace {
  let snapshot_count = snapshots.length()
  let normalized_from = from_index % snapshot_count
  let to_candidate = to_index % snapshot_count
  let normalized_to = if snapshot_count > 1 && to_candidate == normalized_from {
    (normalized_from + 1) % snapshot_count
  } else {
    to_candidate
  }
  let normalized_split = if merge_split < 0 {
    0
  } else if merge_split > ops.length() {
    ops.length()
  } else {
    merge_split
  }
  {
    ops,
    snapshots,
    from_index: normalized_from,
    to_index: normalized_to,
    merge_split: normalized_split,
  }
}

///|
fn build_trace(
  ops : Array[@core.Op],
  agent_counts : Array[Int],
  from_index : Int,
  to_index : Int,
  merge_split : Int,
  rs : @splitmix.RandomState,
) -> BranchTrace {
  let (oplog, snapshots) = replay_with_snapshots(ops)
  add_extra_snapshots(oplog, agent_counts, snapshots, rs)
  normalize_trace(ops, snapshots, from_index, to_index, merge_split)
}

///|
fn build_trace_without_extra_snapshots(
  ops : Array[@core.Op],
  from_index : Int,
  to_index : Int,
  merge_split : Int,
) -> BranchTrace {
  let (_, snapshots) = replay_with_snapshots(ops)
  normalize_trace(ops, snapshots, from_index, to_index, merge_split)
}

///|
impl @quickcheck.Arbitrary for BranchTrace with fn arbitrary(size, random_state) {
  let rs = random_state.split()
  let size_cap = if size < 0 { 0 } else { size }
  let agent_count = 2 + rand_bounded(rs, 3)
  let max_ops_per_agent = if size_cap < 4 {
    2
  } else if size_cap > 24 {
    8
  } else {
    2 + size_cap / 4
  }
  let agent_ops : Array[Array[@core.Op]] = []
  let agent_counts : Array[Int] = []
  for agent_index in 0..<agent_count {
    let count = 2 + rand_bounded(rs, max_ops_per_agent - 1)
    let ops = generate_agent_ops(trace_agent(agent_index), count, rs)
    agent_counts.push(ops.length())
    agent_ops.push(ops)
  }
  let ops = interleave_agent_ops(agent_ops, rs)
  let snapshot_budget = ops.length() + agent_count + 5
  let from_index = rand_bounded(rs, snapshot_budget)
  let to_index = rand_bounded(rs, snapshot_budget)
  let merge_split = rand_bounded(rs, ops.length() + 1)
  build_trace(ops, agent_counts, from_index, to_index, merge_split, rs)
}

///|
impl @qc.Shrink for BranchTrace with fn shrink(self) {
  let results : Array[BranchTrace] = []
  let len = self.ops.length()
  if len > 0 {
    results.push(build_trace_without_extra_snapshots([], 0, 0, 0))
    let half = len / 2
    if half > 0 {
      results.push(
        build_trace_without_extra_snapshots(
          self.ops[:half].to_owned(),
          self.from_index,
          self.to_index,
          self.merge_split,
        ),
      )
    }
    results.push(
      build_trace_without_extra_snapshots(
        self.ops[:len - 1].to_owned(),
        self.from_index,
        self.to_index,
        self.merge_split,
      ),
    )
  }
  results.iter()
}

///|
fn BranchTrace::from_snapshot(self : BranchTrace) -> TraceSnapshot {
  self.snapshots[self.from_index]
}

///|
fn BranchTrace::to_snapshot(self : BranchTrace) -> TraceSnapshot {
  self.snapshots[self.to_index]
}

///|
fn BranchTrace::full_snapshot(self : BranchTrace) -> TraceSnapshot {
  self.snapshots[self.ops.length()]
}

///|
fn BranchTrace::replay(self : BranchTrace) -> @oplog.OpLog {
  replay_ops(self.ops)
}

///|
fn BranchTrace::local_ops(self : BranchTrace) -> Array[@core.Op] {
  self.ops[:self.merge_split].to_owned()
}

///|
fn BranchTrace::remote_ops(self : BranchTrace) -> Array[@core.Op] {
  self.ops[self.merge_split:].to_owned()
}

///|
fn branch_matches_snapshot(branch : Branch, snapshot : TraceSnapshot) -> Bool {
  branch.to_text() == snapshot.text &&
  branch.visible_count() == snapshot.visible_count &&
  branch.at_frontier(snapshot.frontier)
}

///|
fn branches_match(lhs : Branch, rhs : Branch) -> Bool {
  lhs.to_text() == rhs.to_text() &&
  lhs.visible_count() == rhs.visible_count() &&
  lhs.at_frontier(rhs.get_frontier())
}

///|
fn snapshots_match_trace(
  oplog : @oplog.OpLog,
  snapshots : Array[TraceSnapshot],
) -> Bool {
  for snapshot in snapshots {
    let branch = try! Branch::checkout(oplog, snapshot.frontier)
    if !branch_matches_snapshot(branch, snapshot) {
      return false
    }
  }
  true
}

///|
test "property generator: samples are valid branch traces" {
  let traces : Array[BranchTrace] = @quickcheck.samples(16)
  let mut saw_multi_tip_frontier = false
  let mut saw_delete_or_undelete = false
  for trace in traces {
    let oplog = trace.replay()
    inspect(snapshots_match_trace(oplog, trace.snapshots), content="true")
    if trace.full_snapshot().frontier.0.length() > 1 {
      saw_multi_tip_frontier = true
    }
    for op in trace.ops {
      if op.is_delete() || op.is_undelete() {
        saw_delete_or_undelete = true
      }
    }
  }
  inspect(saw_multi_tip_frontier, content="true")
  inspect(saw_delete_or_undelete, content="true")
}

///|
fn prop_checkout_advance_matches_checkout(trace : BranchTrace) -> Bool {
  let oplog = trace.replay()
  if !snapshots_match_trace(oplog, trace.snapshots) {
    return false
  }
  let from_snapshot = trace.from_snapshot()
  let to_snapshot = trace.to_snapshot()
  let from_branch = try! Branch::checkout(oplog, from_snapshot.frontier)
  let advanced = try! from_branch.advance(to_snapshot.frontier)
  let checked = try! Branch::checkout(oplog, to_snapshot.frontier)
  branches_match(advanced, checked) &&
  branch_matches_snapshot(checked, to_snapshot)
}

///|
test "property: checkout(from).advance(to) equals checkout(to)" {
  @qc.quick_check_fn(prop_checkout_advance_matches_checkout)
}

///|
fn prop_advance_to_current_frontier_is_noop(trace : BranchTrace) -> Bool {
  let oplog = trace.replay()
  let snapshot = trace.from_snapshot()
  let branch = try! Branch::checkout(oplog, snapshot.frontier)
  let advanced = try! branch.advance(branch.get_frontier())
  branch_matches_snapshot(advanced, snapshot)
}

///|
test "property: advancing to current frontier is a no-op" {
  @qc.quick_check_fn(prop_advance_to_current_frontier_is_noop)
}

///|
fn prop_advance_roundtrip_restores_text_and_count(trace : BranchTrace) -> Bool {
  let oplog = trace.replay()
  let from_snapshot = trace.from_snapshot()
  let to_snapshot = trace.to_snapshot()
  let branch = try! Branch::checkout(oplog, from_snapshot.frontier)
  let moved = try! branch.advance(to_snapshot.frontier)
  let restored = try! moved.advance(from_snapshot.frontier)
  branch_matches_snapshot(restored, from_snapshot)
}

///|
test "property: advance from-to-from restores original text and visible count" {
  @qc.quick_check_fn(prop_advance_roundtrip_restores_text_and_count)
}

///|
fn prop_checkout_version_vector_matches_to_frontier(
  trace : BranchTrace,
) -> Bool {
  let oplog = trace.replay()
  let snapshot = trace.to_snapshot()
  let vv = @causal_graph.VersionVector::from_frontier(
    oplog.causal_graph(),
    snapshot.frontier,
  )
  let frontier = vv.to_frontier(oplog.causal_graph())
  let via_vv = try! Branch::checkout_version_vector(oplog, vv)
  let via_frontier = try! Branch::checkout(oplog, frontier)
  branches_match(via_vv, via_frontier) &&
  branch_matches_snapshot(via_frontier, snapshot)
}

///|
test "property: checkout_version_vector equals checkout via to_frontier" {
  @qc.quick_check_fn(prop_checkout_version_vector_matches_to_frontier)
}

///|
fn prop_merge_remote_ops_matches_full_checkout(trace : BranchTrace) -> Bool {
  let oplog = replay_ops(trace.local_ops())
  let branch = try! Branch::checkout(oplog, oplog.get_frontier())
  let merged = try! branch.merge_remote_ops(trace.remote_ops())
  let full = try! Branch::checkout(oplog, oplog.get_frontier())
  branches_match(merged, full) &&
  branch_matches_snapshot(full, trace.full_snapshot())
}

///|
test "property: merge_remote_ops equals full checkout of merged frontier" {
  @qc.quick_check_fn(prop_merge_remote_ops_matches_full_checkout)
}
