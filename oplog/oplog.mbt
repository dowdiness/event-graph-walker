///| Operation log implementation

///|
/// OpLog - stores operations with causal graph
pub struct OpLog {
  mut operations : Array[@core.Op] // All operations in LV order
  mut pending : Array[@core.Op] // Remote ops waiting for missing parents
  graph : @causal_graph.CausalGraph // The causal graph
  agent_id : String // This agent's ID
} derive(Show)

///|
/// Create a new OpLog
pub fn OpLog::new(agent_id : String) -> OpLog {
  {
    operations: [],
    pending: [],
    graph: @causal_graph.CausalGraph::new(),
    agent_id,
  }
}

///|
/// Add a new operation to the log
fn OpLog::add_op(self : OpLog, op : @core.Op) -> Unit {
  let ops = self.operations
  ops.push(op)
  self.operations = ops
}

///|
/// Create and add an insert operation
pub fn OpLog::insert(
  self : OpLog,
  text : String,
  origin_left : Int,
  origin_right : Int,
) -> @core.Op raise OpLogError {
  let parents = self.graph.get_frontier().0
  let parents_raw : Array[@core.RawVersion] = []
  for lv in parents {
    match self.graph.lv_to_raw(lv) {
      Some(raw) => parents_raw.push(raw)
      None => raise OpLogError::MissingLocalVersion(lv~)
    }
  }
  let lv = self.graph.add_version(parents, self.agent_id) catch {
    error => raise OpLogError::CausalGraphError(error~)
  }

  // Get the seq for this operation from the graph
  let seq = match self.graph.lv_to_raw(lv) {
    Some(raw) => raw.seq
    None => raise OpLogError::MissingLocalVersion(lv~)
  }
  let origin_left_raw = self.raw_from_lv(origin_left)
  let origin_right_raw = self.raw_from_lv(origin_right)
  let op = @core.Op::new_insert(
    lv,
    parents_raw,
    self.agent_id,
    seq,
    text,
    origin_left_raw,
    origin_right_raw,
  )
  self.add_op(op)
  op
}

///|
/// Create and add a delete operation
pub fn OpLog::delete(
  self : OpLog,
  origin_left : Int,
) -> @core.Op raise OpLogError {
  let parents = self.graph.get_frontier().0
  let parents_raw : Array[@core.RawVersion] = []
  for lv in parents {
    match self.graph.lv_to_raw(lv) {
      Some(raw) => parents_raw.push(raw)
      None => raise OpLogError::MissingLocalVersion(lv~)
    }
  }
  let lv = self.graph.add_version(parents, self.agent_id) catch {
    error => raise OpLogError::CausalGraphError(error~)
  }

  // Get the seq for this operation from the graph
  let seq = match self.graph.lv_to_raw(lv) {
    Some(raw) => raw.seq
    None => raise OpLogError::MissingLocalVersion(lv~)
  }
  let origin_left_raw = self.raw_from_lv(origin_left)
  let op = @core.Op::new_delete(
    lv,
    parents_raw,
    self.agent_id,
    seq,
    origin_left_raw,
  )
  self.add_op(op)
  op
}

///|
/// Create and add an undelete operation
pub fn OpLog::undelete(
  self : OpLog,
  origin_left : Int,
) -> @core.Op raise OpLogError {
  let parents = self.graph.get_frontier().0
  let parents_raw : Array[@core.RawVersion] = []
  for lv in parents {
    match self.graph.lv_to_raw(lv) {
      Some(raw) => parents_raw.push(raw)
      None => raise OpLogError::MissingLocalVersion(lv~)
    }
  }
  let lv = self.graph.add_version(parents, self.agent_id) catch {
    error => raise OpLogError::CausalGraphError(error~)
  }

  // Get the seq for this operation from the graph
  let seq = match self.graph.lv_to_raw(lv) {
    Some(raw) => raw.seq
    None => raise OpLogError::MissingLocalVersion(lv~)
  }
  let origin_left_raw = self.raw_from_lv(origin_left)
  let op = @core.Op::new_undelete(
    lv,
    parents_raw,
    self.agent_id,
    seq,
    origin_left_raw,
  )
  self.add_op(op)
  op
}

///|
/// Get operation by LV
pub fn OpLog::get_op(self : OpLog, lv : Int) -> @core.Op? {
  if lv >= 0 && lv < self.operations.length() {
    Some(self.operations[lv])
  } else {
    None
  }
}

///|
pub fn OpLog::get_ops(self : OpLog, lvs : Array[Int]) -> Array[@core.Op] {
  lvs.filter_map(lv => self.get_op(lv))
}

///|
/// Get all operations
pub fn OpLog::get_all_ops(self : OpLog) -> Array[@core.Op] {
  self.operations.copy()
}

///|
/// Get operation count
pub fn OpLog::op_count(self : OpLog) -> Int {
  self.operations.length()
}

///|
/// Get current frontier
pub fn OpLog::get_frontier(self : OpLog) -> @core.Frontier {
  self.graph.get_frontier()
}

///|
/// Get current frontier as RawVersions for network sync
pub fn OpLog::get_frontier_raw(
  self : OpLog,
) -> Array[@core.RawVersion] raise OpLogError {
  let frontier = self.graph.get_frontier().0
  let result : Array[@core.RawVersion] = []
  for lv in frontier {
    match self.graph.lv_to_raw(lv) {
      Some(raw) => result.push(raw)
      None => raise OpLogError::MissingLocalVersion(lv~)
    }
  }
  result
}

///|
/// Validate that a remote batch is closed w.r.t. parents and frontier
pub fn OpLog::validate_remote_batch(
  self : OpLog,
  remote_ops : Array[@core.Op],
  remote_frontier : Array[@core.RawVersion],
) -> Unit raise OpLogError {
  let mut batch : @immut/hashset.HashSet[@core.RawVersion] = @immut/hashset.new()
  for op in remote_ops {
    let raw = @core.RawVersion::new(op.agent, op.seq)
    batch = batch.add(raw)
  }
  for op in remote_ops {
    for parent in op.parents {
      if self.graph.raw_to_lv(parent) is None && not(batch.contains(parent)) {
        raise OpLogError::MissingRemoteParent(raw=parent)
      }
    }
  }
  for raw in remote_frontier {
    if self.graph.raw_to_lv(raw) is None && not(batch.contains(raw)) {
      raise OpLogError::MissingRemoteFrontier(raw~)
    }
  }
}

///|
/// Apply a remote operation
pub fn OpLog::apply_remote(
  self : OpLog,
  op : @core.Op,
) -> Array[@core.Op] raise OpLogError {
  let pending = self.pending
  pending.push(op)
  self.pending = pending
  self.drain_pending()
}

///|
/// Convert LV to RawVersion? with sentinel handling
fn OpLog::raw_from_lv(
  self : OpLog,
  lv : Int,
) -> @core.RawVersion? raise OpLogError {
  if lv == -1 {
    None
  } else {
    match self.graph.lv_to_raw(lv) {
      Some(raw) => Some(raw)
      None => raise OpLogError::MissingLocalVersion(lv~)
    }
  }
}

///|
/// Convert RawVersion? to LV, returning None if missing
fn OpLog::lv_from_raw(self : OpLog, raw : @core.RawVersion?) -> Int? {
  match raw {
    None => Some(-1)
    Some(rv) => self.graph.raw_to_lv(rv)
  }
}

///|
/// Try to add a remote op; returns (keep_pending, local_op)
fn OpLog::try_apply_remote(
  self : OpLog,
  op : @core.Op,
) -> (Bool, @core.Op?) raise OpLogError {
  let raw = @core.RawVersion::new(op.agent, op.seq)
  match self.graph.raw_to_lv(raw) {
    Some(_) => return (false, None)
    None => ()
  }
  let local_parents : Array[Int] = []
  for parent in op.parents {
    match self.graph.raw_to_lv(parent) {
      Some(lv) => local_parents.push(lv)
      None => return (true, None)
    }
  }
  let _local_origin_left = match self.lv_from_raw(op.origin_left) {
    Some(lv) => lv
    None => return (true, None)
  }
  let _local_origin_right = match self.lv_from_raw(op.origin_right) {
    Some(lv) => lv
    None => return (true, None)
  }
  if (op.content is @core.Delete || op.content is @core.Undelete) &&
    op.origin_left is None {
    raise OpLogError::MissingOrigin
  }
  let local_lv = self.graph.add_version_with_seq(
    local_parents,
    op.agent,
    op.seq,
  ) catch {
    error => raise OpLogError::CausalGraphError(error~)
  }
  let local_op = match op.content {
    @core.Insert(text) =>
      @core.Op::new_insert(
        local_lv,
        op.parents,
        op.agent,
        op.seq,
        text,
        op.origin_left,
        op.origin_right,
      )
    @core.Delete =>
      @core.Op::new_delete(
        local_lv,
        op.parents,
        op.agent,
        op.seq,
        op.origin_left,
      )
    @core.Undelete =>
      @core.Op::new_undelete(
        local_lv,
        op.parents,
        op.agent,
        op.seq,
        op.origin_left,
      )
  }
  self.add_op(local_op)
  (false, Some(local_op))
}

///|
/// Drain pending operations that now have all dependencies
fn OpLog::drain_pending(self : OpLog) -> Array[@core.Op] raise OpLogError {
  let applied : Array[@core.Op] = []
  let mut pending = self.pending
  let mut progress = true
  while progress {
    progress = false
    let remaining : Array[@core.Op] = []
    for op in pending {
      let (keep_pending, local_op) = self.try_apply_remote(op)
      if keep_pending {
        remaining.push(op)
      } else {
        match local_op {
          Some(applied_op) => {
            applied.push(applied_op)
            progress = true
          }
          None => ()
        }
      }
    }
    pending = remaining
  }
  self.pending = pending
  applied
}
