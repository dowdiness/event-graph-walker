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
  priv tree : @fugue.FugueTree[String]
  priv oplog : @oplog.OpLog
  agent_id : String
  // Lazy visible projection index. IndexedState owns the position cache and
  // its incremental updates; Fugue remains the lifecycle authority.
  priv indexed_state : IndexedState
  // Insert cursor: caches last insert position/LV for sequential append fast-path.
  priv mut cursor : InsertCursor?
}

///|
/// Create a new document for an agent
pub fn Document::new(agent_id : String) -> Document {
  let oplog = @oplog.OpLog::new(agent_id)
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  { tree, oplog, agent_id, indexed_state: IndexedState::new(), cursor: None }
}

///|
/// Get the current text content
pub fn Document::to_text(self : Document) -> String {
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
    self.tree.insert({
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
    })
    if cache_valid {
      cache_valid = self.indexed_state.insert_at(current_pos, {
        start_lv: op.lv(),
        text: ch_str,
        count: 1,
      })
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
/// Classify one remote Fugue origin without raising, so all invalid pending
/// dependents can be discarded before the first error is propagated.
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
/// Validate remote Fugue origins for the complete pending-drain plan before
/// the OpLog can allocate any of its local versions.
fn Document::preflight_remote_targets(
  self : Document,
  ops : ArrayView[@core.Op],
) -> Unit raise DocumentError {
  let graph = self.oplog.causal_graph()
  let planned_inserts : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let planned_noninserts : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([],
  )
  for op in ops {
    let raw = @core.RawVersion::new(op.agent(), op.seq())
    match op.content() {
      @core.Insert(_) => planned_inserts.add(raw)
      @core.Delete | @core.Undelete => planned_noninserts.add(raw)
    }
  }
  let mut failure : DocumentError? = None
  let invalid_roots : Array[@core.RawVersion] = []
  for op in ops {
    let raw = @core.RawVersion::new(op.agent(), op.seq())
    for origin in [op.origin_left(), op.origin_right()] {
      match origin {
        None => ()
        Some(origin) =>
          match
            self.preflight_remote_origin(
              graph, origin, planned_inserts, planned_noninserts,
            ) {
            None => ()
            Some(error) => {
              invalid_roots.push(raw)
              if failure is None {
                failure = Some(error)
              }
            }
          }
      }
    }
  }
  if !invalid_roots.is_empty() {
    self.oplog.discard_pending_dependents(invalid_roots)
  }
  match failure {
    None => ()
    Some(error) => raise error
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
  self.validate_target_lv(target_lv)
  self.commit_undelete_by_lv(target_lv)
}

///|
/// Create and apply a delete operation for a specific LV.
pub fn Document::delete_by_lv(
  self : Document,
  target_lv : Int,
) -> @core.Op raise DocumentError {
  self.validate_target_lv(target_lv)
  self.commit_delete_by_lv(target_lv)
}

///|
/// Delete a visible target, or return Stale when it is already deleted.
pub fn Document::delete_if_visible(
  self : Document,
  target_lv : Int,
) -> TargetEditResult raise DocumentError {
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
priv enum RemoteAdmissionOutcome {
  Complete(Array[@core.Op])
  Partial(Array[@core.Op], @causal_graph.CausalGraphError)
}

///|
/// Translate only partial admission into a projection-ready outcome.
fn commit_remote_plan(
  plan : @oplog.RemoteAdmissionPlan,
  commit : (@oplog.RemoteAdmissionPlan) -> Array[@core.Op] raise @oplog.OpLogError,
) -> RemoteAdmissionOutcome raise DocumentError {
  try commit(plan) catch {
    @oplog.OpLogError::PartialRemoteAdmission(committed~, error~) =>
      RemoteAdmissionOutcome::Partial(committed, error)
    error => raise DocumentError::OpLog(error)
  } noraise {
    applied => RemoteAdmissionOutcome::Complete(applied)
  }
}

///|
/// Project operations already committed by OpLog into Fugue and its cache.
fn Document::project_remote_ops(
  self : Document,
  applied_ops : ArrayView[@core.Op],
) -> Unit raise DocumentError {
  if applied_ops.length() == 0 {
    return
  }
  // For small batches with a warm cache, update incrementally to avoid
  // the O(n) full rebuild. For large batches, invalidate and rebuild lazily.
  let mut incremental = applied_ops.length() <= 3 &&
    self.indexed_state.is_ready()
  if !incremental {
    self.invalidate_cache()
  }
  let cg = self.oplog.causal_graph()
  for applied in applied_ops {
    let origin_left : @fugue.Lv? = match applied.origin_left() {
      None => None
      Some(raw) =>
        match cg.raw_to_lv(raw) {
          Some(lv) => Some(@fugue.Lv(lv))
          None => raise DocumentError::MissingOrigin(raw~)
        }
    }
    let origin_right : @fugue.Lv? = match applied.origin_right() {
      None => None
      Some(raw) =>
        match cg.raw_to_lv(raw) {
          Some(lv) => Some(@fugue.Lv(lv))
          None => raise DocumentError::MissingOrigin(raw~)
        }
    }
    match applied.content() {
      @core.Insert(text) => {
        let (timestamp, agent) = match cg[applied.lv()] {
          Some(entry) => (entry.timestamp, entry.agent)
          None =>
            raise DocumentError::OpLog(
              @oplog.OpLogError::MissingLocalVersion(lv=applied.lv()),
            )
        }
        self.tree.insert({
          id: @fugue.Lv(applied.lv()),
          content: text,
          origin_left,
          origin_right,
          timestamp: @fugue.Timestamp(timestamp),
          agent: @fugue.ReplicaId(agent),
        })
        // Incremental index update: find position of newly visible item
        if incremental {
          match self.tree.lv_to_position(@fugue.Lv(applied.lv())) {
            Some(pos) =>
              if !self.indexed_state.insert_at(pos, {
                  start_lv: applied.lv(),
                  text,
                  count: 1,
                }) {
                self.invalidate_cache()
                incremental = false
              }
            None => {
              self.invalidate_cache()
              incremental = false
            }
          }
        }
      }
      @core.Delete =>
        match origin_left {
          Some(lv) => {
            // For incremental: find position BEFORE deleting from tree
            let pos_before = if incremental {
              self.lv_to_position(lv.0)
            } else {
              None
            }
            let visible_before = self.tree.visible_count()
            let (del_ts, del_agent) = match cg[applied.lv()] {
              Some(entry) => (entry.timestamp, entry.agent)
              None =>
                raise DocumentError::OpLog(
                  @oplog.OpLogError::MissingLocalVersion(lv=applied.lv()),
                )
            }
            self.tree.delete_with_ts(lv, del_ts, del_agent) catch {
              e => raise DocumentError::Fugue(e)
            }
            // Only update the index if item actually became invisible
            if incremental && self.tree.visible_count() < visible_before {
              match pos_before {
                Some(pos) =>
                  if !self.indexed_state.delete_at(pos) {
                    self.invalidate_cache()
                    incremental = false
                  }
                None => {
                  self.invalidate_cache()
                  incremental = false
                }
              }
            }
          }
          None => ()
        }
      @core.Undelete =>
        match origin_left {
          Some(lv) => {
            let visible_before = self.tree.visible_count()
            let (undel_ts, undel_agent) = match cg[applied.lv()] {
              Some(entry) => (entry.timestamp, entry.agent)
              None =>
                raise DocumentError::OpLog(
                  @oplog.OpLogError::MissingLocalVersion(lv=applied.lv()),
                )
            }
            self.tree.undelete_with_ts(lv, undel_ts, undel_agent) catch {
              e => raise DocumentError::Fugue(e)
            }
            // If item became visible, insert into the index
            if incremental && self.tree.visible_count() > visible_before {
              match (self.tree.lv_to_position(lv), self.tree[lv]) {
                (Some(pos), Some(item)) =>
                  if !self.indexed_state.insert_at(pos, {
                      start_lv: lv.0,
                      text: item.content,
                      count: 1,
                    }) {
                    self.invalidate_cache()
                    incremental = false
                  }
                _ => {
                  self.invalidate_cache()
                  incremental = false
                }
              }
            }
          }
          None => ()
        }
    }
  }
}

///|
/// Apply a remote operation with an injectable prepared-plan commit shell.
fn Document::apply_remote_with(
  self : Document,
  op : @core.Op,
  commit : (@oplog.RemoteAdmissionPlan) -> Array[@core.Op] raise @oplog.OpLogError,
) -> Unit raise DocumentError {
  self.cursor = None
  // Validate Insert content before touching the oplog so malformed peer ops
  // can't persist (issue #31).
  validate_remote_ops([op][:])
  let plan = self.oplog.prepare_remote([op]) catch {
    e => raise DocumentError::OpLog(e)
  }
  self.preflight_remote_targets(plan.operations())
  // Check the incoming operation independently so an unready operation with
  // a graph-known but structurally missing origin is rejected before pending.
  self.preflight_remote_targets([op][:])
  // Detach before admission so a fallible commit cannot observe a stale
  // canonical cache. The exact cache is restored once the outcome is known.
  let detached_cache = self.indexed_state.take_cache()
  let outcome = try commit_remote_plan(plan, commit) catch {
    error => {
      self.indexed_state.restore_cache(detached_cache)
      raise error
    }
  } noraise {
    outcome => outcome
  }
  match outcome {
    RemoteAdmissionOutcome::Complete(applied_ops) => {
      self.indexed_state.restore_cache(detached_cache)
      self.project_remote_ops(applied_ops[:])
    }
    RemoteAdmissionOutcome::Partial(committed, error) => {
      self.indexed_state.restore_cache(detached_cache)
      self.project_remote_ops(committed[:])
      raise DocumentError::OpLog(
        @oplog.OpLogError::PartialRemoteAdmission(committed~, error~),
      )
    }
  }
}

///|
/// Apply a remote operation to this document
pub fn Document::apply_remote(
  self : Document,
  op : @core.Op,
) -> Unit raise DocumentError {
  self.apply_remote_with(op, plan => self.oplog.commit_remote(plan))
}

///|
/// Merge remote operations with an injectable prepared-plan commit shell.
fn Document::merge_remote_with(
  self : Document,
  remote_ops : Array[@core.Op],
  remote_frontier : Array[@core.RawVersion],
  commit : (@oplog.RemoteAdmissionPlan) -> Array[@core.Op] raise @oplog.OpLogError,
) -> Unit raise DocumentError {
  self.cursor = None
  // Validate the complete batch before touching state, so malformed content
  // and invalid batch closure fail atomically (issue #31).
  validate_remote_ops(remote_ops[:])
  self.oplog.validate_remote_batch(remote_ops, remote_frontier) catch {
    e => raise DocumentError::OpLog(e)
  }
  let plan = self.oplog.prepare_remote(remote_ops) catch {
    e => raise DocumentError::OpLog(e)
  }
  self.preflight_remote_targets(plan.operations())
  // Retain the pre-commit frontier. Branch advances this shared tree once
  // admission has committed the prepared plan.
  let branch = @branch.Branch::from_tree_and_oplog(self.tree, self.oplog)
  // Invalidate before merge so admission and partial-merge failures cannot
  // leave a stale position cache behind.
  self.invalidate_cache()
  let outcome = commit_remote_plan(plan, commit)
  match outcome {
    RemoteAdmissionOutcome::Complete(_) => {
      let _ = branch.advance(self.oplog.get_frontier()) catch {
        e => raise DocumentError::Branch(e)
      }
    }
    RemoteAdmissionOutcome::Partial(committed, error) => {
      let _ = branch.advance(self.oplog.get_frontier()) catch {
        e => raise DocumentError::Branch(e)
      }
      raise DocumentError::OpLog(
        @oplog.OpLogError::PartialRemoteAdmission(committed~, error~),
      )
    }
  }
}

///|
/// Merge remote operations into this document
pub fn Document::merge_remote(
  self : Document,
  remote_ops : Array[@core.Op],
  remote_frontier : Array[@core.RawVersion],
) -> Unit raise DocumentError {
  self.merge_remote_with(remote_ops, remote_frontier, plan => {
    self.oplog.commit_remote(plan)
  })
}

///|
/// Get the number of visible characters in the document.
pub fn Document::visible_count(self : Document) -> Int {
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
  // Delegate to tree traversal — VisibleRun doesn't store enough
  // information to reconstruct full Item structs.
  self.tree.get_visible_items()
}

///|
/// Map a local version to its visible position in the document.
pub fn Document::lv_to_position(self : Document, lv : Int) -> Int? {
  self.indexed_state.lv_to_position(self.tree, lv)
}
