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
/// Construct an OpLog for one replica identity.
pub fn OpLog::OpLog(agent_id : String) -> OpLog {
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
  let op = @core.Op::insert(
    lv,
    parents_raw,
    self.agent_id,
    seq,
    text,
    origin_left_raw,
    origin_right_raw,
  )
  self.add_op(op)
  self.planner.acknowledge_admitted(@core.RawVersion(op.agent(), op.seq()))
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
  let op = @core.Op::delete(
    lv,
    parents_raw,
    self.agent_id,
    seq,
    Some(origin_left_raw),
  )
  self.add_op(op)
  self.planner.acknowledge_admitted(@core.RawVersion(op.agent(), op.seq()))
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
  let op = @core.Op::undelete(
    lv,
    parents_raw,
    self.agent_id,
    seq,
    Some(origin_left_raw),
  )
  self.add_op(op)
  self.planner.acknowledge_admitted(@core.RawVersion(op.agent(), op.seq()))
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
    let raw = @core.RawVersion(op.agent(), op.seq())
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
/// Return the live canonical pending membership count.
pub fn OpLog::pending_count(self : OpLog) -> Int {
  self.planner.pending_count()
}

///|
/// Clear all canonical pending membership without touching authority state.
pub fn OpLog::clear_pending(self : OpLog) -> Unit {
  self.planner.clear_pending()
}

///|
/// Classify duplicate delivery evidence without treating it as terminal
/// ownership. The resulting arrays are unique and preserve incoming order.
fn OpLog::remote_admission_duplicate_evidence(
  self : OpLog,
  incoming : Array[@core.Op],
) -> (Array[@core.RawVersion], Array[@core.RawVersion]) {
  let already_admitted : Array[@core.RawVersion] = []
  let duplicate_of_pending : Array[@core.RawVersion] = []
  let admitted_seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let pending_seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for op in incoming {
    let raw = remote_admission_raw(op)
    if self.graph.raw_to_lv(raw) is Some(_) {
      if admitted_seen.add_and_check(raw) {
        already_admitted.push(raw)
      }
    } else if self.planner.pending.contains(raw) {
      if pending_seen.add_and_check(raw) {
        duplicate_of_pending.push(raw)
      }
    }
  }
  (already_admitted, duplicate_of_pending)
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
/// Look up an admitted operation without expanding the resident history.
fn OpLog::admitted_op(self : OpLog, raw : @core.RawVersion) -> @core.Op? {
  match self.graph.raw_to_lv(raw) {
    Some(lv) => self.get_op(lv)
    None => None
  }
}

///|
/// Build the core semantic view without giving the planner graph ownership.
fn OpLog::remote_admission_semantics(self : OpLog) -> RemoteAdmissionSemantics {
  { op_of: raw => self.admitted_op(raw) }
}

///|
/// Prepare a remote admission without changing graph, log, or planner state.
///
/// `max_pending` is a hard bound on the unique pending membership immediately
/// after begin applies the prepared discard and staged-registration transition.
/// It covers both complete and partial commit outcomes.
pub fn OpLog::prepare_remote(
  self : OpLog,
  incoming : Array[@core.Op],
  max_pending? : Int,
) -> PreparedAdmission raise OpLogError {
  self.preflight_remote_identities(incoming)
  let (already_admitted, duplicate_of_pending) = self.remote_admission_duplicate_evidence(
    incoming,
  )
  let prepared = self.planner.prepare_with_semantics(
    incoming,
    raw => self.graph.raw_to_lv(raw) is Some(_),
    Some(self.remote_admission_semantics()),
  )
  prepared.with_prospective(
    self.planner,
    max_pending,
    already_admitted,
    duplicate_of_pending,
  )
}

///|
/// Preview the operations that remote application would drain without mutating
/// the causal graph or pending planner. The result preserves drain order.
pub fn OpLog::plan_remote(
  self : OpLog,
  incoming : Array[@core.Op],
) -> Array[@core.Op] raise OpLogError {
  let prepared = self.prepare_remote(incoming)
  prepared.operations().to_owned()
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
/// Apply a remote operation through the prepared-admission compatibility wrapper.
pub fn OpLog::apply_remote(
  self : OpLog,
  op : @core.Op,
) -> Array[@core.Op] raise OpLogError {
  // Preserve the old complete upfront malformed-origin validation boundary.
  if (op.is_delete() || op.is_undelete()) && op.origin_left() is None {
    raise OpLogError::MissingOrigin
  }
  let prepared = self.prepare_remote([op])
  self.commit_remote(prepared)
}

///|
/// Translate planner lifecycle failures to the public OpLog error boundary.
fn OpLog::begin_admission(
  self : OpLog,
  prepared : PreparedAdmission,
) -> Unit raise OpLogError {
  match
    self.planner.begin_plan_with_semantics(
      prepared,
      raw => self.graph.raw_to_lv(raw) is Some(_),
      Some(self.remote_admission_semantics()),
    ) {
    RemoteAdmissionBeginResult::Applied => ()
    RemoteAdmissionBeginResult::Stale => raise OpLogError::StaleAdmission
    RemoteAdmissionBeginResult::Consumed => raise OpLogError::ConsumedAdmission
    RemoteAdmissionBeginResult::Conflict => raise OpLogError::InvalidAdmission
    RemoteAdmissionBeginResult::PendingLimit(limit~, required~) =>
      raise OpLogError::PendingLimitExceeded(limit~, required~)
  }
}

///|
/// Commit a prepared admission through the typed post-begin outcome seam.
fn OpLog::commit_admission_with(
  self : OpLog,
  prepared : PreparedAdmission,
  commit_one : (@core.Op) -> @core.Op raise @causal_graph.CausalGraphError,
) -> AdmissionOutcome raise OpLogError {
  let frontier_before = self.get_frontier()
  self.begin_admission(prepared)
  let committed : Array[@core.Op] = []
  for op in prepared.operations() {
    let result : Result[@core.Op, @causal_graph.CausalGraphError] = Ok(
      commit_one(op),
    ) catch {
      error => Err(error)
    }
    match result {
      Err(error) => {
        ignore(
          self.planner.maybe_compact(raw => self.graph.raw_to_lv(raw) is Some(_)),
        )
        return AdmissionOutcome::Partial(
          receipt=self.admission_receipt(prepared, committed, frontier_before),
          error~,
        )
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
  AdmissionOutcome::Complete(
    self.admission_receipt(prepared, committed, frontier_before),
  )
}

///|
/// Commit a prepared admission with an injectable legacy error shell. The
/// canonical typed transition is still implemented by commit_admission_with.
fn OpLog::commit_remote_with(
  self : OpLog,
  prepared : PreparedAdmission,
  commit_one : (@core.Op) -> @core.Op raise OpLogError,
) -> Array[@core.Op] raise OpLogError {
  let outcome = self.commit_admission_with(prepared, op => {
    let result : Result[@core.Op, OpLogError] = Ok(commit_one(op)) catch {
      error => Err(error)
    }
    match result {
      Ok(local_op) => local_op
      Err(OpLogError::CausalGraphError(error~)) => raise error
      Err(_) => abort("non-causal error escaped the post-begin admission seam")
    }
  })
  match outcome {
    AdmissionOutcome::Complete(receipt) => receipt.committed().to_owned()
    AdmissionOutcome::Partial(receipt~, error~) =>
      raise OpLogError::PartialRemoteAdmission(
        committed=receipt.committed().to_owned(),
        error~,
      )
  }
}

///|
/// Commit one operation through the narrow post-begin causal-error seam.
fn OpLog::commit_one_remote_for_admission(
  self : OpLog,
  op : @core.Op,
) -> @core.Op raise @causal_graph.CausalGraphError {
  let result : Result[(Bool, @core.Op?), OpLogError] = Ok(
    self.try_apply_remote(op),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::CausalGraphError(error~)) => raise error
    Err(_) => abort("non-causal error escaped the production admission seam")
    Ok((keep_pending, local_op)) => {
      guard !keep_pending else {
        abort("prepared remote operation lost dependency readiness")
      }
      match local_op {
        Some(committed) => committed
        None => abort("prepared remote operation was admitted outside OpLog")
      }
    }
  }
}

///|
/// Legacy single-operation shell retained for white-box compatibility tests.
fn OpLog::commit_one_remote(
  self : OpLog,
  op : @core.Op,
) -> @core.Op raise OpLogError {
  let result : Result[@core.Op, @causal_graph.CausalGraphError] = Ok(
    self.commit_one_remote_for_admission(op),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(committed) => committed
    Err(error) => raise OpLogError::CausalGraphError(error~)
  }
}

///|
/// Commit a prepared admission with a narrow per-operation causal failure
/// capability. The normal Document path uses `commit_admission`; this adapter
/// lets a direct dependent exercise the typed partial boundary without owning
/// planner or pending state.
pub fn OpLog::commit_admission_with_failure(
  self : OpLog,
  prepared : PreparedAdmission,
  failure : (@core.Op) -> @causal_graph.CausalGraphError?,
) -> AdmissionOutcome raise OpLogError {
  self.commit_admission_with(prepared, op => {
    match failure(op) {
      Some(error) => raise error
      None => self.commit_one_remote_for_admission(op)
    }
  })
}

///|
/// Commit a prepared remote admission through the typed capability.
pub fn OpLog::commit_admission(
  self : OpLog,
  prepared : PreparedAdmission,
) -> AdmissionOutcome raise OpLogError {
  self.commit_admission_with(prepared, op => {
    self.commit_one_remote_for_admission(op)
  })
}

///|
/// Commit a prepared remote admission exactly once through the legacy result
/// shape. Partial typed evidence is translated only after receipt construction.
pub fn OpLog::commit_remote(
  self : OpLog,
  prepared : PreparedAdmission,
) -> Array[@core.Op] raise OpLogError {
  self.commit_remote_with(prepared, op => self.commit_one_remote(op))
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
  let raw = @core.RawVersion(op.agent(), op.seq())
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
      @core.Op::insert(
        local_lv,
        raw_parents,
        op.agent(),
        op.seq(),
        text,
        origin_left,
        origin_right,
      )
    @core.Delete =>
      @core.Op::delete(local_lv, raw_parents, op.agent(), op.seq(), origin_left)
    @core.Undelete =>
      @core.Op::undelete(
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
