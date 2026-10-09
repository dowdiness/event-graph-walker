///| Operation log implementation

///|
/// OpLog - stores operations with causal graph
pub struct OpLog {
  priv operations : @rle.Rle[@core.OpRun] // All operations in LV order, RLE-compressed
  priv pending_changes : PendingChanges // Canonical remote pending owner
  priv graph : @causal_graph.CausalGraph // The causal graph
  priv agent_id : String // This agent's ID
}

///|
/// Construct an OpLog for one replica identity.
pub fn OpLog::OpLog(agent_id : String) -> OpLog {
  {
    operations: @rle.Rle::Rle(),
    pending_changes: PendingChanges(),
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
  self.pending_changes.acknowledge_applied(
    @core.RawVersion(op.agent(), op.seq()),
  )
  ignore(
    self.pending_changes.maybe_compact(raw => {
      self.graph.raw_to_lv(raw) is Some(_)
    }),
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
  self.pending_changes.acknowledge_applied(
    @core.RawVersion(op.agent(), op.seq()),
  )
  ignore(
    self.pending_changes.maybe_compact(raw => {
      self.graph.raw_to_lv(raw) is Some(_)
    }),
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
  self.pending_changes.acknowledge_applied(
    @core.RawVersion(op.agent(), op.seq()),
  )
  ignore(
    self.pending_changes.maybe_compact(raw => {
      self.graph.raw_to_lv(raw) is Some(_)
    }),
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
  // OpRun local-version bounds are already sorted and non-overlapping. Search
  // those bounds directly instead of Rle::find: its lazy positional-prefix
  // rebuild would inspect every run after each append.
  let mut low = 0
  let mut high = self.operations.length()
  while low < high {
    let middle = low + (high - low) / 2
    let run = match self.operations.get(middle) {
      Some(value) => value
      None => return None
    }
    let (start, end) = run.lv_bounds()
    if lv < start {
      high = middle
    } else if lv >= end {
      low = middle + 1
    } else {
      return run.decompress(lv - start)
    }
  }
  None
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
/// Collect exactly the locally recorded operations absent from a peer's sparse
/// version. Sparse subtraction happens in the causal graph representation;
/// only identities in the resulting ranges are resolved and decompressed.
pub fn OpLog::collect_missing_ops(
  self : OpLog,
  peer : @causal_graph.GraphVersion,
) -> Array[@core.Op] raise OpLogError {
  self.collect_missing_ops_counted(peer).0
}

///|
fn OpLog::collect_missing_ops_counted(
  self : OpLog,
  peer : @causal_graph.GraphVersion,
) -> (Array[@core.Op], Int, Int, Int, Int) raise OpLogError {
  let current = self.graph.current_graph_version()
  let operations : Array[@core.Op] = []
  let mut missing_ranges = 0
  let mut identity_lookups = 0
  let mut operation_lookups = 0
  for entry in current.subtract_ranges(peer) {
    for range in entry.1 {
      missing_ranges = missing_ranges + 1
      let mut sequence = range.0
      while sequence < range.1 {
        identity_lookups = identity_lookups + 1
        let raw = @core.RawVersion(entry.0, sequence.reinterpret_as_int())
        let lv = match self.graph.raw_to_lv(raw) {
          Some(value) => value
          None => raise OpLogError::MissingLocalIdentity(raw~)
        }
        operation_lookups = operation_lookups + 1
        match self.get_op(lv) {
          Some(op) => operations.push(op)
          None => raise OpLogError::MissingLocalVersion(lv~)
        }
        sequence = sequence + 1U
      }
    }
  }
  (
    operations,
    missing_ranges,
    identity_lookups,
    operation_lookups,
    operations.length(),
  )
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
  let batch : Map[@core.RawVersion, @core.Op] = Default::default()
  for op in remote_ops {
    let raw = @core.RawVersion(op.agent(), op.seq())
    match batch.get(raw) {
      Some(previous) =>
        if !apply_changes_same_logical_operation(previous, op) {
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
  self.pending_changes.has_pending()
}

///|
/// Return the live canonical pending membership count.
pub fn OpLog::pending_count(self : OpLog) -> Int {
  self.pending_changes.pending_count()
}

///|
/// Clear all canonical pending membership without touching authority state.
pub fn OpLog::clear_pending(self : OpLog) -> Unit {
  self.pending_changes.clear_pending()
}

///|
/// Classify duplicate delivery evidence without treating it as terminal
/// ownership. The resulting arrays are unique and preserve incoming order.
fn OpLog::apply_changes_duplicate_evidence(
  self : OpLog,
  incoming : Array[@core.Op],
) -> (Array[@core.RawVersion], Array[@core.RawVersion]) {
  let already_applied : Array[@core.RawVersion] = []
  let duplicate_of_pending : Array[@core.RawVersion] = []
  let applied_seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let pending_seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for op in incoming {
    let raw = apply_changes_raw(op)
    if self.graph.raw_to_lv(raw) is Some(_) {
      if applied_seen.add_and_check(raw) {
        already_applied.push(raw)
      }
    } else if self.pending_changes.pending.contains(raw) {
      if pending_seen.add_and_check(raw) {
        duplicate_of_pending.push(raw)
      }
    }
  }
  (already_applied, duplicate_of_pending)
}

///|
/// Compare incoming operations with full payloads retained in recorded history.
fn OpLog::preflight_remote_identities(
  self : OpLog,
  incoming : Array[@core.Op],
) -> Unit raise OpLogError {
  for op in incoming {
    let raw = apply_changes_raw(op)
    match self.graph.raw_to_lv(raw) {
      Some(lv) =>
        match self.get_op(lv) {
          Some(applied) =>
            if !apply_changes_same_logical_operation(applied, op) {
              raise OpLogError::ConflictingIdentity(raw~)
            }
          None => raise OpLogError::MissingLocalVersion(lv~)
        }
      None => ()
    }
  }
}

///|
/// Look up an recorded operation without expanding the resident history.
fn OpLog::applied_op(self : OpLog, raw : @core.RawVersion) -> @core.Op? {
  match self.graph.raw_to_lv(raw) {
    Some(lv) => self.get_op(lv)
    None => None
  }
}

///|
/// Build the core semantic view without giving the pending-changes owner graph ownership.
fn OpLog::apply_changes_semantics(self : OpLog) -> ChangeSemantics {
  { op_of: raw => self.applied_op(raw), }
}

///|
/// Prepare a remote change application without changing graph, log, or pending-changes owner state.
///
/// `max_pending` is a hard bound on the unique pending membership immediately
/// after begin applies the prepared discard and staged-registration transition.
/// It covers both complete and partial commit outcomes. The optional
/// `max_pending_after_complete` is a separate compatibility bound on the live
/// pending membership after every planned operation commits successfully.
pub fn ApplyChanges::ApplyChanges(
  oplog : OpLog,
  incoming : Array[@core.Op],
  max_pending? : Int,
  max_pending_after_complete? : Int,
) -> ApplyChanges raise OpLogError {
  oplog.preflight_remote_identities(incoming)
  let (already_applied, duplicate_of_pending) = oplog.apply_changes_duplicate_evidence(
    incoming,
  )
  let action = oplog.pending_changes.prepare_with_semantics(
    incoming,
    raw => oplog.graph.raw_to_lv(raw) is Some(_),
    Some(oplog.apply_changes_semantics()),
  )
  action.with_prospective(
    oplog.pending_changes,
    max_pending,
    max_pending_after_complete,
    already_applied,
    duplicate_of_pending,
  )
}

///|
/// Preview the operations that remote application would drain without mutating
/// the causal graph or pending state. The result preserves drain order.
pub fn OpLog::plan_remote(
  self : OpLog,
  incoming : Array[@core.Op],
) -> Array[@core.Op] raise OpLogError {
  let action = ApplyChanges(self, incoming)
  action.operations().to_owned()
}

///|
/// Remove invalid pending operations and their causal dependents.
pub fn OpLog::discard_pending_dependents(
  self : OpLog,
  roots : Array[@core.RawVersion],
) -> Unit {
  self.pending_changes.reject_pending_dependents(roots)
  ignore(
    self.pending_changes.maybe_compact(raw => {
      self.graph.raw_to_lv(raw) is Some(_)
    }),
  )
}

///|
/// Apply a remote operation through the `ApplyChanges` action compatibility wrapper.
pub fn OpLog::apply_remote(
  self : OpLog,
  op : @core.Op,
) -> Array[@core.Op] raise OpLogError {
  // Preserve the old complete upfront malformed-origin validation boundary.
  if (op.is_delete() || op.is_undelete()) && op.origin_left() is None {
    raise OpLogError::MissingOrigin
  }
  match self.apply_changes(ApplyChanges(self, [op])) {
    ApplyChangesOutcome::Succeeded(report) => report.committed().to_owned()
    ApplyChangesOutcome::Failed(report~, error~) =>
      raise OpLogError::PartialApplyChanges(
        committed=report.committed().to_owned(),
        error~,
      )
  }
}

///|
/// Translate pending-changes owner lifecycle failures to the public OpLog error boundary.
fn OpLog::begin_apply_changes(
  self : OpLog,
  action : ApplyChanges,
) -> Unit raise OpLogError {
  match
    self.pending_changes.begin(
      action,
      raw => self.graph.raw_to_lv(raw) is Some(_),
      semantics=self.apply_changes_semantics(),
    ) {
    BeginApplyResult::Started => ()
    BeginApplyResult::Stale => raise OpLogError::StaleApplyChanges
    BeginApplyResult::Consumed => raise OpLogError::ConsumedApplyChanges
    BeginApplyResult::Conflict => raise OpLogError::InvalidApplyChanges
    BeginApplyResult::PendingLimit(limit~, required~) =>
      raise OpLogError::PendingLimitExceeded(limit~, required~)
  }
}

///|
fn OpLog::apply_changes_with(
  self : OpLog,
  action : ApplyChanges,
  commit_one : (@core.Op) -> @core.Op raise @causal_graph.CausalGraphError,
) -> ApplyChangesOutcome raise OpLogError {
  let frontier_before = self.get_frontier()
  self.begin_apply_changes(action)
  let committed : Array[@core.Op] = []
  for op in action.operations() {
    let result : Result[@core.Op, @causal_graph.CausalGraphError] = Ok(
      commit_one(op),
    ) catch {
      error => Err(error)
    }
    match result {
      Err(error) => {
        ignore(
          self.pending_changes.maybe_compact(raw => {
            self.graph.raw_to_lv(raw) is Some(_)
          }),
        )
        return ApplyChangesOutcome::Failed(
          report=self.apply_changes_report(action, committed, frontier_before),
          error~,
        )
      }
      Ok(local_op) => {
        self.pending_changes.acknowledge_applied(apply_changes_raw(op))
        committed.push(local_op)
      }
    }
  }
  ignore(
    self.pending_changes.maybe_compact(raw => {
      self.graph.raw_to_lv(raw) is Some(_)
    }),
  )
  ApplyChangesOutcome::Succeeded(
    self.apply_changes_report(action, committed, frontier_before),
  )
}

///|
/// Commit one operation through the narrow post-begin causal-error seam.
fn OpLog::commit_one_remote_for_apply_changes(
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
    Err(_) =>
      abort("non-causal error escaped the production change application seam")
    Ok((keep_pending, local_op)) => {
      guard !keep_pending else {
        abort("prepared remote operation lost dependency readiness")
      }
      match local_op {
        Some(committed) => committed
        None => abort("prepared remote operation was recorded outside OpLog")
      }
    }
  }
}

///|
/// Inject a causal failure before committing an operation.
pub fn OpLog::apply_changes_with_failure(
  self : OpLog,
  action : ApplyChanges,
  failure : (@core.Op) -> @causal_graph.CausalGraphError?,
) -> ApplyChangesOutcome raise OpLogError {
  self.apply_changes_with(action, op => {
    match failure(op) {
      Some(error) => raise error
      None => self.commit_one_remote_for_apply_changes(op)
    }
  })
}

///|
/// Commit a prepared remote change application through the typed capability.
pub fn OpLog::apply_changes(
  self : OpLog,
  action : ApplyChanges,
) -> ApplyChangesOutcome raise OpLogError {
  self.apply_changes_with(action, op => {
    self.commit_one_remote_for_apply_changes(op)
  })
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
