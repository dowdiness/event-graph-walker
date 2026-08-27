///| Document - User-facing CRDT document API

///|

///| Manages the FugueTree, OpLog, and CausalGraph together

///|
/// Cursor for fast sequential append. Caches the position immediately
/// after the last insert and the LV of that op, to skip position_to_lv()
/// on the next sequential insert.
struct InsertCursor {
  next_position : Int // position right after the last-inserted item
  lv : Int // LV of last inserted item
  at_end : Bool // whether origin_right was None (end of document)
} derive(Debug)

///|
/// Provides position-based operations (insert/delete at cursor position)
pub struct Document {
  priv mut tree : @fugue.FugueTree[String]
  priv oplog : @oplog.OpLog
  agent_id : String
  // Lazy visible projection index. IndexedState owns the position cache and
  // its incremental updates; Fugue remains the lifecycle authority.
  priv indexed_state : IndexedState
  // Insert cursor: caches last insert position/LV for sequential append fast-path.
  priv mut cursor : InsertCursor?
  // Document-owned health for the Fugue-derived projection.
  priv mut projection_health : ProjectionHealth
  // Target evidence required to validate a recovered tree before it becomes Ready.
  priv mut projection_verification : ProjectionRecoveryVerification?
  // Package-local admission hooks used only by white-box boundary tests.
  priv mut admission_hooks : AdmissionBoundaryHooks?
}

///|
/// Create a new document for an agent
pub fn Document::new(agent_id : String) -> Document {
  let oplog = @oplog.OpLog(agent_id)
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  {
    tree,
    oplog,
    agent_id,
    indexed_state: IndexedState::new(),
    cursor: None,
    projection_health: ProjectionHealth::Ready,
    projection_verification: None,
    admission_hooks: None,
  }
}

///|
/// Get the current text content
pub fn Document::to_text(self : Document) -> String {
  self.ensure_projection_ready_for_read()
  self.indexed_state.text(self.tree)
}

///|
pub fn Document::agent_id(self : Document) -> String {
  self.agent_id
}

///|
/// Get the current frontier
pub fn Document::get_frontier(self : Document) -> @core.Frontier {
  self.oplog.get_frontier()
}

///|
/// Return live core-owned remote pending membership without reading projection state.
pub fn Document::pending_count(self : Document) -> Int {
  self.oplog.pending_count()
}

///|
/// Clear core-owned remote pending membership without touching authority or projection state.
pub fn Document::clear_pending(self : Document) -> Unit {
  self.oplog.clear_pending()
}

///|
/// Read-only view of the document's causal DAG.
///
/// The returned `CausalSnapshot` is a live alias over the internal causal
/// graph — it reflects subsequent mutations to this `Document`. It is not a
/// point-in-time copy; callers needing a stable baseline must capture the
/// fields they care about (e.g. `frontier()`, which already returns a fresh
/// array) before further edits.
pub fn Document::causal_snapshot(self : Document) -> @history.CausalSnapshot {
  let graph = self.oplog.causal_graph()
  @history.CausalSnapshot::CausalSnapshot(
    fn() { graph.op_count() },
    fn(lv) {
      match graph.get_entry(lv) {
        Some(entry) =>
          Some(
            @history.SnapshotEntry::SnapshotEntry(
              entry.parents,
              entry.agent,
              entry.seq,
            ),
          )
        None => None
      }
    },
    fn() { graph.get_frontier().to_array() },
    fn(lv) { graph.children_count(lv) },
  )
}

///|
/// Get the current frontier as an array of LVs
pub fn Document::get_frontier_array(self : Document) -> Array[Int] {
  self.oplog.get_frontier().to_array()
}

///|
/// Get frontier as RawVersions for network sync
pub fn Document::get_frontier_raw(
  self : Document,
) -> Array[@core.RawVersion] raise DocumentError {
  self.oplog.get_frontier_raw() catch {
    e => raise DocumentError::OpLog(e)
  }
}

///|
/// Get the LV at a specific 0-based visible position.
/// Uses O(log n) lookup via IndexedState's OrderTree projection.
fn Document::lv_at_position(self : Document, position : Int) -> Int? {
  self.ensure_projection_ready_for_read()
  self.indexed_state.lv_at_position(self.tree, position)
}

///|
/// Invalidate the position cache (call after any modification)
fn Document::invalidate_cache(self : Document) -> Unit {
  self.indexed_state.invalidate()
}

///|
/// Map a user position (0-based cursor position) to the LV at that position.
///
/// Returns the LV of the item before the cursor position,
/// or -1 if at the start of the document.
fn Document::position_to_lv(self : Document, position : Int) -> Int {
  self.ensure_projection_ready_for_read()
  self.indexed_state.position_to_lv(self.tree, position)
}

///|
/// Insert text at a cursor position.
///
/// `position` is an item-space offset — the unit the position cache,
/// `position_to_lv`, and `lv_at_position` use (one slot per CRDT item).
/// The public `text` facade (`TextState::insert`) bounds positions
/// against `visible_count()` (also item-space) and forwards them
/// through unchanged.
///
/// Iterates `text` by Unicode codepoint (not UTF-16 code unit). Each
/// codepoint produces a single Op carrying its 1- or 2-code-unit string,
/// so a non-BMP character like `"😀"` becomes one atomic Op rather than
/// two splittable surrogate-half ops. See issue #31.
pub fn Document::insert(
  self : Document,
  position : Int,
  text : String,
) -> @core.Op raise DocumentError {
  self.ensure_projection_ready()
  let mut current_pos = position
  let mut last_op : @core.Op? = None
  let mut cache_valid = self.indexed_state.is_ready()
  for ch in text {
    let ch_str = ch.to_string()

    // Cursor fast-path: skip cache lookup for sequential append
    let (origin_left, origin_right) = match self.cursor {
      Some(c) if current_pos == c.next_position => {
        let ol = c.lv
        let or = if c.at_end {
          -1 // origin_right = None (end of document)
        } else {
          // Partial hit: use existing cache for origin_right lookup.
          // Cache is valid — no mutation since last update.
          if !cache_valid {
            cache_valid = true
          }
          match self.lv_at_position(current_pos) {
            Some(lv) => lv
            None => -1
          }
        }
        (ol, or)
      }
      _ => {
        // Cursor miss: use existing cache (or lazy-build) for lookups.
        // The cache is always valid at the start of insert() — every mutation
        // either maintains it incrementally or sets it to None.
        if !cache_valid {
          cache_valid = true
        }
        let ol = self.position_to_lv(current_pos)
        let or = match self.lv_at_position(current_pos) {
          Some(lv) => lv
          None => -1
        }
        (ol, or)
      }
    }
    let op = self.oplog.insert(ch_str, origin_left, origin_right) catch {
      e => raise DocumentError::OpLog(e)
    }
    let (timestamp, agent) = match self.oplog.causal_graph()[op.lv()] {
      Some(entry) => (entry.timestamp, entry.agent)
      None =>
        raise DocumentError::OpLog(
          @oplog.OpLogError::MissingLocalVersion(lv=op.lv()),
        )
    }
    self.tree.insert(
      {
        id: @fugue.Lv(op.lv()),
        content: ch_str,
        origin_left: if origin_left == -1 {
          None
        } else {
          Some(@fugue.Lv(origin_left))
        },
        origin_right: if origin_right == -1 {
          None
        } else {
          Some(@fugue.Lv(origin_right))
        },
        timestamp: @fugue.Timestamp(timestamp),
        agent: @fugue.ReplicaId(agent),
      },
      sequence=op.seq(),
    )
    if cache_valid {
      cache_valid = self.indexed_state.insert_at(
        current_pos,
        { start_lv: op.lv(), text: ch_str, count: 1 },
        self.tree.get(@fugue.Lv(op.lv())).unwrap(),
      )
    }
    last_op = Some(op)
    current_pos = current_pos + 1
    self.cursor = Some({
      next_position: current_pos,
      lv: op.lv(),
      at_end: origin_right == -1,
    })
  }
  if !cache_valid {
    self.invalidate_cache()
  }
  match last_op {
    Some(op) => op
    None =>
      self.oplog.insert("", -1, -1) catch {
        e => raise DocumentError::OpLog(e)
      }
  }
}

///|
/// Validate that an Op's Insert content carries exactly one Unicode scalar
/// value (codepoint) and is well-formed UTF-16. Used at every remote-ingress
/// point (`apply_remote`, `merge_remote`) so peer ops or replayed logs that
/// carry lone surrogates or batched text can't reach the FugueTree and
/// produce malformed convergence (issue #31).
fn validate_insert_content(text : String) -> Unit raise DocumentError {
  let len = text.length()
  if len == 0 {
    // Pre-Step-2 Document::insert("") creates an empty fallback Op that ships
    // through sync. Allow empty content through validation so upgraded peers
    // can still apply ops produced by pre-fix peers. New code paths produce
    // one Op per codepoint (never empty) so this branch is purely a
    // backward-compat pass-through.
    return
  }
  let cu0 = text[0].to_int()
  let consumed = if cu0 >= 0xD800 && cu0 <= 0xDBFF {
    // High surrogate — must be immediately followed by a low surrogate.
    if len < 2 {
      raise DocumentError::ContentError(reason=MalformedUtf16)
    }
    let cu1 = text[1].to_int()
    if cu1 < 0xDC00 || cu1 > 0xDFFF {
      raise DocumentError::ContentError(reason=MalformedUtf16)
    }
    2
  } else if cu0 >= 0xDC00 && cu0 <= 0xDFFF {
    // Bare low surrogate — invalid.
    raise DocumentError::ContentError(reason=MalformedUtf16)
  } else {
    1
  }
  if consumed != len {
    raise DocumentError::ContentError(reason=MultipleCodepoints)
  }
}

///|
/// Validate every Insert op in `ops` before any storage mutation. Delete /
/// Undelete ops carry no text content and are passed through.
fn validate_remote_ops(ops : ArrayView[@core.Op]) -> Unit raise DocumentError {
  for op in ops {
    match op.content() {
      @core.Insert(text) => validate_insert_content(text)
      @core.Delete | @core.Undelete => ()
    }
  }
}

///|
/// Delete the character at a cursor position.
///
/// Raises `InvalidPosition` if the position is negative or beyond the last character.
pub fn Document::delete(
  self : Document,
  position : Int,
) -> @core.Op raise DocumentError {
  self.ensure_projection_ready()
  self.cursor = None
  if position < 0 {
    raise DocumentError::InvalidPosition(pos=position)
  }

  let total = self.indexed_state.visible_span(self.tree)
  if position >= total {
    raise DocumentError::InvalidPosition(pos=position)
  }

  let target_lv = match self.lv_at_position(position) {
    Some(lv) => lv
    None => raise DocumentError::InvalidPosition(pos=position)
  }

  let op = self.oplog.delete(target_lv) catch {
    e => raise DocumentError::OpLog(e)
  }
  let cg = self.oplog.causal_graph()
  let (del_ts, del_agent) = match cg[op.lv()] {
    Some(entry) => (entry.timestamp, entry.agent)
    None =>
      raise DocumentError::OpLog(
        @oplog.OpLogError::MissingLocalVersion(lv=op.lv()),
      )
  }
  self.tree.delete_with_ts(@fugue.Lv(target_lv), del_ts, del_agent) catch {
    e => raise DocumentError::Fugue(e)
  }

  // Incremental index update: delete at known position
  if self.indexed_state.is_ready() && !self.indexed_state.delete_at(position) {
    self.invalidate_cache()
  }
  op
}

///|
/// Delete the half-open range `[start, end)`.
pub fn Document::delete_range(
  self : Document,
  start : Int,
  end : Int,
) -> Unit raise DocumentError {
  self.ensure_projection_ready()
  self.cursor = None
  if start < 0 {
    raise DocumentError::InvalidPosition(pos=start)
  }
  if end < start {
    raise DocumentError::InvalidPosition(pos=end)
  }

  let total = self.indexed_state.visible_span(self.tree)
  if end > total {
    raise DocumentError::InvalidPosition(pos=end)
  }
  if start == end {
    return
  }

  // Collect all target LVs before mutating (cache is invalidated after first delete)
  let target_lvs : Array[Int] = []
  for i = start; i < end; i = i + 1 {
    match self.lv_at_position(i) {
      Some(lv) => target_lvs.push(lv)
      None => raise DocumentError::InvalidPosition(pos=i)
    }
  }

  // Invalidate before the first mutation so exception paths cannot leave a
  // stale cache behind.
  self.invalidate_cache()
  let cg = self.oplog.causal_graph()
  for lv in target_lvs {
    let op = self.oplog.delete(lv) catch { e => raise DocumentError::OpLog(e) }
    let (del_ts, del_agent) = match cg[op.lv()] {
      Some(entry) => (entry.timestamp, entry.agent)
      None =>
        raise DocumentError::OpLog(
          @oplog.OpLogError::MissingLocalVersion(lv=op.lv()),
        )
    }
    self.tree.delete_with_ts(@fugue.Lv(lv), del_ts, del_agent) catch {
      e => raise DocumentError::Fugue(e)
    }
  }
}

///|
/// Replace the half-open range `[start, end)` with `text`.
pub fn Document::replace_range(
  self : Document,
  start : Int,
  end : Int,
  text : String,
) -> Unit raise DocumentError {
  self.ensure_projection_ready()
  self.delete_range(start, end)
  if text.length() == 0 {
    return
  }
  let _ = self.insert(start, text)
}

///|
/// Validate that a local CRDT target exists before allocating a new op.
fn Document::validate_target_lv(
  self : Document,
  target_lv : Int,
) -> Unit raise DocumentError {
  match self.tree.get(@fugue.Lv(target_lv)) {
    Some(_) => ()
    None =>
      raise DocumentError::Fugue(@fugue.MissingItem(id=@fugue.Lv(target_lv)))
  }
}

///|
/// Classify one remote Fugue origin without mutating pending or projection state.
fn Document::preflight_remote_origin(
  self : Document,
  graph : @causal_graph.CausalGraph,
  origin : @core.RawVersion,
  planned_inserts : @hashset.HashSet[@core.RawVersion],
  planned_noninserts : @hashset.HashSet[@core.RawVersion],
) -> DocumentError? {
  match graph.raw_to_lv(origin) {
    Some(lv) =>
      match self.tree.get(@fugue.Lv(lv)) {
        Some(_) => None
        None =>
          Some(
            DocumentError::Fugue(
              @fugue.FugueError::MissingItem(id=@fugue.Lv(lv)),
            ),
          )
      }
    None =>
      if planned_inserts.contains(origin) {
        None
      } else if planned_noninserts.contains(origin) {
        Some(DocumentError::MissingOrigin(raw=origin))
      } else {
        None
      }
  }
}

///|
/// Result of a target-aware delete or undelete request.
pub enum TargetEditResult {
  Applied
  Stale
}

///|
/// Commit an undelete operation after target preflight.
fn Document::commit_undelete_by_lv(
  self : Document,
  target_lv : Int,
) -> @core.Op raise DocumentError {
  self.cursor = None
  let op = self.oplog.undelete(target_lv) catch {
    e => raise DocumentError::OpLog(e)
  }
  let cg = self.oplog.causal_graph()
  let (undel_ts, undel_agent) = match cg[op.lv()] {
    Some(entry) => (entry.timestamp, entry.agent)
    None =>
      raise DocumentError::OpLog(
        @oplog.OpLogError::MissingLocalVersion(lv=op.lv()),
      )
  }
  self.tree.undelete_with_ts(@fugue.Lv(target_lv), undel_ts, undel_agent) catch {
    e => raise DocumentError::Fugue(e)
  }
  self.invalidate_cache()
  op
}

///|
/// Commit a delete operation after target preflight.
fn Document::commit_delete_by_lv(
  self : Document,
  target_lv : Int,
) -> @core.Op raise DocumentError {
  self.cursor = None
  let op = self.oplog.delete(target_lv) catch {
    e => raise DocumentError::OpLog(e)
  }
  let cg = self.oplog.causal_graph()
  let (del_ts, del_agent) = match cg[op.lv()] {
    Some(entry) => (entry.timestamp, entry.agent)
    None =>
      raise DocumentError::OpLog(
        @oplog.OpLogError::MissingLocalVersion(lv=op.lv()),
      )
  }
  self.tree.delete_with_ts(@fugue.Lv(target_lv), del_ts, del_agent) catch {
    e => raise DocumentError::Fugue(e)
  }
  self.invalidate_cache()
  op
}

///|
/// Create and apply an undelete operation for a specific LV.
pub fn Document::undelete(
  self : Document,
  target_lv : Int,
) -> @core.Op raise DocumentError {
  self.ensure_projection_ready()
  self.validate_target_lv(target_lv)
  self.commit_undelete_by_lv(target_lv)
}

///|
/// Create and apply a delete operation for a specific LV.
pub fn Document::delete_by_lv(
  self : Document,
  target_lv : Int,
) -> @core.Op raise DocumentError {
  self.ensure_projection_ready()
  self.validate_target_lv(target_lv)
  self.commit_delete_by_lv(target_lv)
}

///|
/// Delete a visible target, or return Stale when it is already deleted.
pub fn Document::delete_if_visible(
  self : Document,
  target_lv : Int,
) -> TargetEditResult raise DocumentError {
  self.ensure_projection_ready()
  self.validate_target_lv(target_lv)
  match self.tree.lv_to_position(@fugue.Lv(target_lv)) {
    Some(_) => {
      ignore(self.commit_delete_by_lv(target_lv))
      Applied
    }
    None => Stale
  }
}

///|
/// Undelete a deleted target, or return Stale when it is already visible.
pub fn Document::undelete_if_deleted(
  self : Document,
  target_lv : Int,
) -> TargetEditResult raise DocumentError {
  self.ensure_projection_ready()
  self.validate_target_lv(target_lv)
  match self.tree.lv_to_position(@fugue.Lv(target_lv)) {
    Some(_) => Stale
    None => {
      ignore(self.commit_undelete_by_lv(target_lv))
      Applied
    }
  }
}

///|
/// Project operations already committed by OpLog into Fugue and its cache.
fn Document::project_remote_ops(
  self : Document,
  applied_ops : ArrayView[@core.Op],
  workspace : ProjectionWorkspace,
) -> Unit raise DocumentError {
  if applied_ops.length() == 0 {
    return
  }
  self.observe_projection_finalization(applied_ops)
  match self.admission_projection_failure() {
    Some(failure) =>
      match failure(applied_ops) {
        Some(error) => raise error
        None => ()
      }
    None => ()
  }
  let cg = self.oplog.causal_graph()
  for applied in applied_ops {
    workspace.project(self.tree, applied, cg)
  }
}

///|
/// Apply one remote operation through the typed batch-admission shell while
/// preserving the legacy Unit-returning error contract.
pub fn Document::apply_remote(
  self : Document,
  op : @core.Op,
) -> Unit raise DocumentError {
  let admission = self.admit_remote([op])
  admission.raise_legacy_remote_error()
}

///|
/// Merge a complete-frontier remote batch through the typed admission shell.
/// Closure validation remains the only merge-specific responsibility.
pub fn Document::merge_remote(
  self : Document,
  remote_ops : Array[@core.Op],
  remote_frontier : Array[@core.RawVersion],
) -> Unit raise DocumentError {
  self.oplog.validate_remote_batch(remote_ops, remote_frontier) catch {
    e => raise DocumentError::OpLog(e)
  }
  let admission = self.admit_remote(remote_ops)
  admission.raise_legacy_remote_error()
}

///|
/// Get the number of visible characters in the document.
pub fn Document::visible_count(self : Document) -> Int {
  self.ensure_projection_ready_for_read()
  self.tree.visible_count()
}

///|
/// Get all operations from the oplog.
pub fn Document::get_all_ops(self : Document) -> Array[@core.Op] {
  self.oplog.get_all_ops()
}

///|
/// Get all operation runs without decompression (for sync export).
pub fn Document::get_all_runs(self : Document) -> Array[@core.OpRun] {
  self.oplog.get_all_runs()
}

///|
/// Compute the diff between two frontiers and collect operations.
/// Returns (retreat_ops, advance_ops).
pub fn Document::diff_and_collect(
  self : Document,
  from : @core.Frontier,
  to : @core.Frontier,
) -> (Array[@core.Op], Array[@core.Op]) {
  self.oplog.diff_and_collect(from, to)
}

///|
/// Checkout a branch at the given frontier.
pub fn Document::checkout_branch(
  self : Document,
  frontier : @core.Frontier,
) -> @branch.Branch raise DocumentError {
  @branch.Branch::checkout(self.oplog, frontier) catch {
    e => raise DocumentError::Branch(e)
  }
}

///|
/// Get visible items from the tree (returns a copy for safety).
pub fn Document::get_visible_items(
  self : Document,
) -> Array[(@fugue.Lv, @fugue.Item[String])] {
  self.ensure_projection_ready_for_read()
  // Delegate to tree traversal — VisibleRun doesn't store enough
  // information to reconstruct full Item structs.
  self.tree.get_visible_items()
}

///|
/// Map a local version to its visible position in the document.
pub fn Document::lv_to_position(self : Document, lv : Int) -> Int? {
  self.ensure_projection_ready_for_read()
  self.indexed_state.lv_to_position(self.tree, lv)
}
