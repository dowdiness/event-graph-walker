///| Operation log implementation

///|
/// OpLog - stores operations with causal graph
pub struct OpLog {
  priv operations : @rle.Rle[@core.OpRun] // All operations in LV order, RLE-compressed
  priv planner : RemoteAdmissionPlanner // Canonical remote pending owner
  priv graph : @causal_graph.CausalGraph // The causal graph
  priv agent_id : String // This agent's ID
}

///|
/// Create a new OpLog
pub fn OpLog::new(agent_id : String) -> OpLog {
  {
    operations: @rle.Rle::Rle(),
    planner: RemoteAdmissionPlanner(),
    graph: @causal_graph.CausalGraph::new(),
    agent_id,
  }
}

///|
/// Get the causal graph (read-only accessor for sibling packages)
pub fn OpLog::causal_graph(self : OpLog) -> @causal_graph.CausalGraph {
  self.graph
}

///|
/// Add a new operation to the log
fn OpLog::add_op(self : OpLog, op : @core.Op) -> Unit {
  let run = @core.OpRun::from_op(op)
  match self.operations.append(run) {
    Ok(_) => ()
    Err(_) => () // OpRun with count=1 always has span > 0
  }
}

///|
/// Create and add an insert operation
pub fn OpLog::insert(
  self : OpLog,
  text : String,
  origin_left : Int,
  origin_right : Int,
) -> @core.Op raise OpLogError {
  let parents = self.graph.get_frontier().to_array()
  let parents_raw : Array[@core.RawVersion] = []
  for lv in parents {
    match self.graph.lv_to_raw(lv) {
      Some(raw) => parents_raw.push(raw)
      None => raise OpLogError::MissingLocalVersion(lv~)
    }
  }
  // Resolve both insertion origins before allocating a causal version.
  // A failed origin lookup must not leave an orphaned graph entry.
  let origin_left_raw = self.raw_from_lv(origin_left)
  let origin_right_raw = self.raw_from_lv(origin_right)
  let lv = self.graph.add_version(parents, self.agent_id) catch {
    error => raise OpLogError::CausalGraphError(error~)
  }

  // Get the seq for this operation from the graph
  let seq = match self.graph.lv_to_raw(lv) {
    Some(raw) => raw.seq
    None => raise OpLogError::MissingLocalVersion(lv~)
  }
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
  self.planner.acknowledge_admitted(@core.RawVersion::new(op.agent(), op.seq()))
  ignore(
    self.planner.maybe_compact(raw => self.graph.raw_to_lv(raw) is Some(_)),
  )
  op
}

///|
/// Create and add a delete operation
pub fn OpLog::delete(
  self : OpLog,
  origin_left : Int,
) -> @core.Op raise OpLogError {
  let origin_left_raw = self.raw_target_from_lv(origin_left)
  let parents = self.graph.get_frontier().to_array()
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
  let op = @core.Op::new_delete(
    lv,
    parents_raw,
    self.agent_id,
    seq,
    Some(origin_left_raw),
  )
  self.add_op(op)
  self.planner.acknowledge_admitted(@core.RawVersion::new(op.agent(), op.seq()))
  ignore(
    self.planner.maybe_compact(raw => self.graph.raw_to_lv(raw) is Some(_)),
  )
  op
}

///|
/// Create and add an undelete operation
pub fn OpLog::undelete(
  self : OpLog,
  origin_left : Int,
) -> @core.Op raise OpLogError {
  let origin_left_raw = self.raw_target_from_lv(origin_left)
  let parents = self.graph.get_frontier().to_array()
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
  let op = @core.Op::new_undelete(
    lv,
    parents_raw,
    self.agent_id,
    seq,
    Some(origin_left_raw),
  )
  self.add_op(op)
  self.planner.acknowledge_admitted(@core.RawVersion::new(op.agent(), op.seq()))
  ignore(
    self.planner.maybe_compact(raw => self.graph.raw_to_lv(raw) is Some(_)),
  )
  op
}

///|
/// Get the operation at a specific local version (LV).
///
/// Returns `None` for negative LVs, the sentinel value -1, or any LV
/// beyond the end of the log. All valid LVs in `[0, op_count())` are
/// guaranteed to return `Some`.
pub fn OpLog::get_op(self : OpLog, lv : Int) -> @core.Op? {
  if lv < 0 {
    return None
  }
  match self.operations.find(lv) {
    Some(pos) =>
      match self.operations.get(pos.run) {
        Some(run) => run.decompress(pos.offset)
        None => None
      }
    None => None
  }
}

///|
/// Collect operations for a list of LVs, silently skipping invalid indices.
///
/// This is the batch counterpart of `get_op`: given a slice of LVs
/// (e.g. from `walk_and_collect` or `diff_and_collect`) it returns the
/// corresponding operations in the same order, omitting any LV that is
/// out of range.
pub fn OpLog::get_ops(self : OpLog, lvs : Array[Int]) -> Array[@core.Op] {
  lvs.filter_map(lv => self.get_op(lv))
}

///|
/// Collect operations for an RLE-compressed list of LV ranges.
///
/// Expands the compressed ranges by slicing operation runs directly, silently
/// skipping any invalid index. This is the compressed counterpart of `get_ops`.
pub fn OpLog::get_ops_rle(
  self : OpLog,
  lvs : @rle.Rle[@core.LvRange],
) -> Array[@core.Op] {
  let result : Array[@core.Op] = []
  for range in lvs.iter() {
    // LVs are assigned densely, so an LV range is also a positional slice of
    // the operation runs. Slicing runs once avoids an RLE lookup per LV.
    for
      slice in self.operations.range_clamped(start=range.start, end=range.end()) {
      for offset in slice.start..<slice.end {
        match slice.value.decompress(offset) {
          Some(op) => result.push(op)
          None => ()
        }
      }
    }
  }
  result
}

///|
/// Get all operations by expanding all runs.
pub fn OpLog::get_all_ops(self : OpLog) -> Array[@core.Op] {
  let result : Array[@core.Op] = []
  for run in self.operations.iter() {
    run.decompress_into(result)
  }
  result
}

///|
/// Get all operation runs without decompression.
/// Used by sync export_all for zero-copy serialization.
pub fn OpLog::get_all_runs(self : OpLog) -> Array[@core.OpRun] {
  let result : Array[@core.OpRun] = []
  for run in self.operations.iter() {
    result.push(run)
  }
  result
}

///|
/// Get operation count
pub fn OpLog::op_count(self : OpLog) -> Int {
  self.operations.span()
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
  let frontier = self.graph.get_frontier().iter()
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
/// Validate that a remote batch is closed w.r.t. parents and frontier.
/// Repeated identities are collapsed when logically equal and rejected when not.
pub fn OpLog::validate_remote_batch(
  self : OpLog,
  remote_ops : Array[@core.Op],
  remote_frontier : Array[@core.RawVersion],
) -> Unit raise OpLogError {
  let batch : Map[@core.RawVersion, @core.Op] = Map::default()
  for op in remote_ops {
    let raw = @core.RawVersion::new(op.agent(), op.seq())
    match batch.get(raw) {
      Some(previous) =>
        if !remote_admission_same_logical_operation(previous, op) {
          raise OpLogError::ConflictingIdentity(raw~)
        }
      None => batch.set(raw, op)
    }
  }
  for op in remote_ops {
    for parent in op.parents() {
      if self.graph.raw_to_lv(parent) is None && !batch.contains(parent) {
        raise OpLogError::MissingRemoteParent(raw=parent)
      }
    }
  }
  for raw in remote_frontier {
    if self.graph.raw_to_lv(raw) is None && !batch.contains(raw) {
      raise OpLogError::MissingRemoteFrontier(raw~)
    }
  }
}

///|
/// Report whether remote operations are waiting for dependencies.
pub fn OpLog::has_pending(self : OpLog) -> Bool {
  self.planner.has_pending()
}

///|
/// Compare incoming operations with full payloads retained in admitted history.
fn OpLog::preflight_remote_identities(
  self : OpLog,
  incoming : Array[@core.Op],
) -> Unit raise OpLogError {
  for op in incoming {
    let raw = remote_admission_raw(op)
    match self.graph.raw_to_lv(raw) {
      Some(lv) =>
        match self.get_op(lv) {
          Some(admitted) =>
            if !remote_admission_same_logical_operation(admitted, op) {
              raise OpLogError::ConflictingIdentity(raw~)
            }
          None => raise OpLogError::MissingLocalVersion(lv~)
        }
      None => ()
    }
  }
}

///|
/// Prepare a remote admission without changing graph, log, or planner state.
pub fn OpLog::prepare_remote(
  self : OpLog,
  incoming : Array[@core.Op],
) -> RemoteAdmissionPlan raise OpLogError {
  self.preflight_remote_identities(incoming)
  self.planner.prepare(incoming, raw => self.graph.raw_to_lv(raw) is Some(_))
}

///|
/// Plan the operations that remote application would drain without mutating
/// the causal graph or pending planner. The result preserves drain order.
pub fn OpLog::plan_remote(
  self : OpLog,
  incoming : Array[@core.Op],
) -> Array[@core.Op] raise OpLogError {
  let plan = self.prepare_remote(incoming)
  plan.operations().to_owned()
}

///|
/// Remove invalid pending operations and their causal dependents.
pub fn OpLog::discard_pending_dependents(
  self : OpLog,
  roots : Array[@core.RawVersion],
) -> Unit {
  self.planner.reject_pending_dependents(roots)
  ignore(
    self.planner.maybe_compact(raw => self.graph.raw_to_lv(raw) is Some(_)),
  )
}

///|
/// Apply a remote operation through the prepared-plan compatibility wrapper.
pub fn OpLog::apply_remote(
  self : OpLog,
  op : @core.Op,
) -> Array[@core.Op] raise OpLogError {
  // Preserve the old complete upfront malformed-origin validation boundary.
  if (op.is_delete() || op.is_undelete()) && op.origin_left() is None {
    raise OpLogError::MissingOrigin
  }
  let plan = self.prepare_remote([op])
  self.commit_remote(plan)
}

///|
/// Translate planner lifecycle failures to the public OpLog error boundary.
fn OpLog::begin_remote_plan(
  self : OpLog,
  plan : RemoteAdmissionPlan,
) -> Unit raise OpLogError {
  match
    self.planner.begin_plan(plan, raw => self.graph.raw_to_lv(raw) is Some(_)) {
    RemoteAdmissionBeginResult::Applied => ()
    RemoteAdmissionBeginResult::Stale =>
      raise OpLogError::StaleRemoteAdmissionPlan
    RemoteAdmissionBeginResult::Consumed =>
      raise OpLogError::ConsumedRemoteAdmissionPlan
    RemoteAdmissionBeginResult::Conflict =>
      raise OpLogError::InvalidRemoteAdmissionPlan
  }
}

///|
/// Commit a prepared remote plan with an injectable single-operation shell.
fn OpLog::commit_remote_with(
  self : OpLog,
  plan : RemoteAdmissionPlan,
  commit_one : (@core.Op) -> @core.Op raise OpLogError,
) -> Array[@core.Op] raise OpLogError {
  self.begin_remote_plan(plan)
  let committed : Array[@core.Op] = []
  for op in plan.operations() {
    let result : Result[@core.Op, OpLogError] = Ok(commit_one(op)) catch {
      error => Err(error)
    }
    match result {
      Err(OpLogError::CausalGraphError(error~)) => {
        ignore(
          self.planner.maybe_compact(raw => self.graph.raw_to_lv(raw) is Some(_)),
        )
        raise OpLogError::PartialRemoteAdmission(committed~, error~)
      }
      Err(error) => {
        ignore(
          self.planner.maybe_compact(raw => self.graph.raw_to_lv(raw) is Some(_)),
        )
        raise error
      }
      Ok(local_op) => {
        self.planner.acknowledge_admitted(remote_admission_raw(op))
        committed.push(local_op)
      }
    }
  }
  ignore(
    self.planner.maybe_compact(raw => self.graph.raw_to_lv(raw) is Some(_)),
  )
  committed
}

///|
/// Commit one operation using the production graph/log shell.
fn OpLog::commit_one_remote(
  self : OpLog,
  op : @core.Op,
) -> @core.Op raise OpLogError {
  let (keep_pending, local_op) = self.try_apply_remote(op)
  guard !keep_pending else {
    abort("prepared remote operation lost dependency readiness")
  }
  match local_op {
    Some(committed) => committed
    None => abort("prepared remote operation was admitted outside OpLog")
  }
}

///|
/// Commit a prepared remote admission exactly once.
pub fn OpLog::commit_remote(
  self : OpLog,
  plan : RemoteAdmissionPlan,
) -> Array[@core.Op] raise OpLogError {
  self.commit_remote_with(plan, op => self.commit_one_remote(op))
}

///|
/// Resolve a target LV for a delete or undelete operation.
/// Unlike insert origins, a target cannot be the root sentinel.
fn OpLog::raw_target_from_lv(
  self : OpLog,
  lv : Int,
) -> @core.RawVersion raise OpLogError {
  guard lv != -1 else { raise OpLogError::MissingLocalVersion(lv~) }
  match self.graph.lv_to_raw(lv) {
    Some(raw) => raw
    None => raise OpLogError::MissingLocalVersion(lv~)
  }
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
  let raw = @core.RawVersion::new(op.agent(), op.seq())
  match self.graph.raw_to_lv(raw) {
    Some(_) => return (false, None)
    None => ()
  }
  let origin_left = op.origin_left()
  let origin_right = op.origin_right()
  let content = op.content()
  if (op.is_delete() || op.is_undelete()) && origin_left is None {
    raise OpLogError::MissingOrigin
  }
  let local_parents : Array[Int] = []
  for parent in op.parents_iter() {
    match self.graph.raw_to_lv(parent) {
      Some(lv) => local_parents.push(lv)
      None => return (true, None)
    }
  }
  match self.lv_from_raw(origin_left) {
    Some(_) => ()
    None => return (true, None)
  }
  match self.lv_from_raw(origin_right) {
    Some(_) => ()
    None => return (true, None)
  }
  let raw_parents = op.parents()
  let local_lv = self.graph.add_version_with_seq(
    local_parents,
    op.agent(),
    op.seq(),
  ) catch {
    error => raise OpLogError::CausalGraphError(error~)
  }
  let local_op = match content {
    @core.Insert(text) =>
      @core.Op::new_insert(
        local_lv,
        raw_parents,
        op.agent(),
        op.seq(),
        text,
        origin_left,
        origin_right,
      )
    @core.Delete =>
      @core.Op::new_delete(
        local_lv,
        raw_parents,
        op.agent(),
        op.seq(),
        origin_left,
      )
    @core.Undelete =>
      @core.Op::new_undelete(
        local_lv,
        raw_parents,
        op.agent(),
        op.seq(),
        origin_left,
      )
  }
  self.add_op(local_op)
  (false, Some(local_op))
}
