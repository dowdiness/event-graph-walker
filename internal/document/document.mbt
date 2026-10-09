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
  // Package-local change application hooks used only by white-box boundary tests.
  priv mut apply_changes_hooks : ApplyChangesBoundaryHooks?
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
    apply_changes_hooks: None,
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
/// Graph-owned current version snapshot.
pub fn Document::current_graph_version(
  self : Document,
) -> @causal_graph.GraphVersion {
  self.oplog.causal_graph().current_graph_version()
}

///|
/// Resolve and validate a graph version against the resident causal graph.
pub fn Document::resolve_graph_version(
  self : Document,
  version : @causal_graph.GraphVersion,
) -> @core.Frontier? {
  self.oplog.causal_graph().resolve_graph_version(version)
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
        { start_lv: op.lv(), text: ch_str, count: 1, },
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

  // Collect all target LVs before mutating; position input is prevalidated.
  let target_lvs : Array[Int] = []
  for i = start; i < end; i = i + 1 {
    match self.lv_at_position(i) {
      Some(lv) => target_lvs.push(lv)
      None => raise DocumentError::InvalidPosition(pos=i)
    }
  }

  // Invalidate before the first mutation so exception paths cannot leave a
  // stale cache behind.
  let indexed = IndexedState::from_snapshot(self.indexed_state.take_cache())
  for lv in target_lvs {
    let op = self.oplog.delete(lv) catch { e => raise DocumentError::OpLog(e) }
    // The canonical cache stays detached throughout the range. Reuse target
    // projection so a post-commit failure repairs or fails closed at authority.
    self.project_local_target(op)
  }
  if indexed.delete_range_known(start, end, target_lvs) {
    self.indexed_state.restore_cache(indexed.take_cache())
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
  self.project_local_target(op)
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
  self.project_local_target(op)
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
  if self.target_is_visible(target_lv) {
    ignore(self.commit_delete_by_lv(target_lv))
    Applied
  } else {
    Stale
  }
}

///|
/// Undelete a deleted target, or return Stale when it is already visible.
pub fn Document::undelete_if_deleted(
  self : Document,
  target_lv : Int,
) -> TargetEditResult raise DocumentError {
  self.ensure_projection_ready()
  if self.target_is_visible(target_lv) {
    Stale
  } else {
    ignore(self.commit_undelete_by_lv(target_lv))
    Applied
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
  match self.apply_changes_projection_failure() {
    Some(failure) =>
      match failure(applied_ops) {
        Some(error) => raise error
        None => ()
      }
    None => ()
  }
  let cg = self.oplog.causal_graph()
  workspace.project_all(self.tree, applied_ops, cg)
}

///|
/// Apply one remote operation through the typed batch-change application shell.
pub fn Document::apply_remote(
  self : Document,
  op : @core.Op,
) -> Unit raise DocumentError {
  let changes = self.apply_changes([op])
  ignore(changes.report())
}

///|
/// Merge a complete-frontier remote batch through the typed change application shell.
/// Closure validation remains the only merge-specific responsibility.
pub fn Document::merge_remote(
  self : Document,
  remote_ops : Array[@core.Op],
  remote_frontier : Array[@core.RawVersion],
) -> Unit raise DocumentError {
  self.oplog.validate_remote_batch(remote_ops, remote_frontier) catch {
    e => raise DocumentError::OpLog(e)
  }
  let changes = self.apply_changes(remote_ops)
  ignore(changes.report())
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
/// Collect locally recorded operations absent from a peer's sparse version.
pub fn Document::collect_missing_ops(
  self : Document,
  peer : @causal_graph.GraphVersion,
) -> Array[@core.Op] raise DocumentError {
  self.oplog.collect_missing_ops(peer) catch {
    error => raise DocumentError::OpLog(error)
  }
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

// --- Explicit trait-method promotions (E0079) ---

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend InsertCursor with @debug.Debug::{to_repr}

///|
/// Visibility is owned by ItemState, including merge delete counts. A missing
/// identity remains an invariant failure; only an existing hidden item is stale.
fn Document::target_is_visible(
  self : Document,
  lv : Int,
) -> Bool raise DocumentError {
  match self.tree.get(@fugue.Lv(lv)) {
    Some(item) => item.state.is_visible(delete_count=item.delete_count)
    None => raise DocumentError::Fugue(@fugue.MissingItem(id=@fugue.Lv(lv)))
  }
}

///|
/// Project one committed compensating edit while preserving a warm index.
/// Cache detachment ensures an internal projection failure cannot leave stale
/// derived state readable. Cold indexes are never rebuilt per undo character.
fn Document::project_local_target(
  self : Document,
  op : @core.Op,
) -> Unit raise DocumentError {
  let indexed = IndexedState::from_snapshot(self.indexed_state.take_cache())
  let change = {
    errdefer self.recover_projection(self.get_frontier())
    apply_projection_with_visible_change(
      self.tree,
      op,
      self.oplog.causal_graph(),
    )
  }
  if !indexed.is_ready() {
    return
  }
  let valid = if @fugue_projection.is_became_hidden(change) {
    let lv = @fugue_projection.visibility_identity(change)
    match indexed.lv_to_position(self.tree, lv.0) {
      Some(position) => indexed.delete_at(position)
      None => false
    }
  } else if @fugue_projection.is_became_visible(change) {
    let lv = @fugue_projection.visibility_identity(change)
    match self.tree.get(lv) {
      Some(item) =>
        indexed.insert_visible(self.tree, lv.0, {
          start_lv: lv.0,
          text: item.content,
          count: 1,
        })
        is Some(_)
      None => false
    }
  } else {
    true
  }
  if valid {
    self.indexed_state.restore_cache(indexed.take_cache())
  }
}

///|
/// Read one visible character through the position index without a root scan.
pub fn Document::visible_content_at(self : Document, position : Int) -> String? {
  match self.lv_at_position(position) {
    Some(lv) => self.tree.get(@fugue.Lv(lv)).map(item => item.content)
    None => None
  }
}

///|
/// Capture just a validated visible interval for local undo recording.
pub fn Document::visible_entries_between(
  self : Document,
  start : Int,
  end : Int,
) -> Array[(Int, String)] raise DocumentError {
  self.ensure_projection_ready()
  if start < 0 ||
    end < start ||
    end > self.indexed_state.visible_span(self.tree) {
    raise DocumentError::InvalidPosition(pos=end)
  }
  let entries : Array[(Int, String)] = Array(capacity=end - start)
  for position = start; position < end; position = position + 1 {
    match self.lv_at_position(position) {
      Some(lv) =>
        match self.tree.get(@fugue.Lv(lv)) {
          Some(item) => entries.push((lv, item.content))
          None =>
            raise DocumentError::Fugue(@fugue.MissingItem(id=@fugue.Lv(lv)))
        }
      None => raise DocumentError::InvalidPosition(pos=position)
    }
  }
  entries
}
