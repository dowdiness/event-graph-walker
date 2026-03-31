///| Document - User-facing CRDT document API

///|

///| Manages the FugueTree, OpLog, and CausalGraph together

///|
/// Cursor for fast sequential append. Caches the last insert position
/// and LV to skip position_to_lv() on the next sequential insert.
struct InsertCursor {
  position : Int // last insert position (0-based)
  lv : Int // LV of last inserted item
  at_end : Bool // whether origin_right was None (end of document)
} derive(Show)

///|
/// Provides position-based operations (insert/delete at cursor position)
pub struct Document {
  priv tree : @fugue.FugueTree[String]
  priv oplog : @oplog.OpLog
  agent_id : String
  // Position cache: maps position -> VisibleRun via O(log n) OrderTree lookup.
  // Invalidated on any modification (set to None). Rebuilt lazily on demand.
  priv mut position_cache : @order_tree.OrderTree[VisibleRun]?
  // Insert cursor: caches last insert position/LV for sequential append fast-path.
  priv mut cursor : InsertCursor?
} derive(Show)

///|
/// Create a new document for an agent
pub fn Document::new(agent_id : String) -> Document {
  let oplog = @oplog.OpLog::new(agent_id)
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  { tree, oplog, agent_id, position_cache: None, cursor: None }
}

///|
/// Get the current text content
pub fn Document::to_text(self : Document) -> String {
  self.tree.to_text()
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
/// Get the current frontier as an array of LVs
pub fn Document::get_frontier_array(self : Document) -> Array[Int] {
  self.oplog.get_frontier().0.copy()
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
/// Build the position cache from visible tree items using OrderTree.
fn Document::build_position_cache(
  self : Document,
) -> @order_tree.OrderTree[VisibleRun] {
  let items = self.tree.get_visible_items()
  let runs : Array[VisibleRun] = Array::new(capacity=items.length())
  for i = 0; i < items.length(); i = i + 1 {
    let (lv, item) = items[i]
    runs.push({ start_lv: lv.0, text: item.content, count: 1 })
  }
  @order_tree.OrderTree::from_array(runs)
}

///|
/// Get or build the position cache (lazy initialization).
fn Document::get_position_cache(
  self : Document,
) -> @order_tree.OrderTree[VisibleRun] {
  match self.position_cache {
    Some(cache) => cache
    None => {
      let cache = self.build_position_cache()
      self.position_cache = Some(cache)
      cache
    }
  }
}

///|
/// Get the LV at a specific 0-based visible position.
/// Uses O(log n) lookup via OrderTree::find on the position cache.
fn Document::lv_at_position(self : Document, position : Int) -> Int? {
  let cache = self.get_position_cache()
  match cache.find(position) {
    Some(fr) => Some(fr.elem.start_lv + fr.offset)
    None => None
  }
}

///|
/// Invalidate the position cache (call after any modification)
fn Document::invalidate_cache(self : Document) -> Unit {
  self.position_cache = None
}

///|
/// Map a user position (0-based cursor position) to the LV at that position.
///
/// Returns the LV of the item before the cursor position,
/// or -1 if at the start of the document.
fn Document::position_to_lv(self : Document, position : Int) -> Int {
  if position == 0 {
    return -1
  }
  let cache = self.get_position_cache()
  let total = @rle.Spanning::span(cache)
  let target = if position > total { total - 1 } else { position - 1 }
  if target < 0 {
    return -1
  }
  match self.lv_at_position(target) {
    Some(lv) => lv
    None => -1
  }
}

///|
/// Insert text at a cursor position.
///
/// Splits multi-character strings into individual character operations.
/// Returns the last operation created (or a no-op for empty strings).
pub fn Document::insert(
  self : Document,
  position : Int,
  text : String,
) -> @core.Op raise DocumentError {
  let mut current_pos = position
  let mut last_op : @core.Op? = None
  let mut cache_valid = self.position_cache is Some(_)

  for i = 0; i < text.length(); i = i + 1 {
    let ch = text[i:i + 1].to_string()

    // Cursor fast-path: skip cache lookup for sequential append
    let (origin_left, origin_right) = match self.cursor {
      Some(c) if current_pos == c.position + 1 => {
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
        // After lookups, keep cache_valid true so the incremental insert_at
        // maintains it, avoiding O(n) rebuild.
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

    let op = self.oplog.insert(ch, origin_left, origin_right) catch {
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
      content: ch,
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
      match self.position_cache {
        Some(cache) =>
          cache.insert_at(current_pos, { start_lv: op.lv(), text: ch, count: 1 })
        None => cache_valid = false
      }
    }
    // Update cursor (no invalidation here — done per-branch above or once after loop)
    self.cursor = Some({
      position: current_pos,
      lv: op.lv(),
      at_end: origin_right == -1,
    })

    last_op = Some(op)
    current_pos = current_pos + 1
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

  let cache = self.get_position_cache()
  let total = @rle.Spanning::span(cache)
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

  // Incremental cache update: delete at known position
  match self.position_cache {
    Some(cache) =>
      match cache.delete_at(position) {
        Some(_) => ()
        None => self.invalidate_cache()
      }
    None => ()
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

  let cache = self.get_position_cache()
  let total = @rle.Spanning::span(cache)
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
/// Create and apply an undelete operation for a specific LV
/// Used by undo to revive a deleted item and create a syncable op
pub fn Document::undelete(
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
/// Create and apply a delete operation for a specific LV
/// Used by undo to delete a specific item and create a syncable op
pub fn Document::delete_by_lv(
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
/// Apply a remote operation to this document
pub fn Document::apply_remote(
  self : Document,
  op : @core.Op,
) -> Unit raise DocumentError {
  self.cursor = None
  // Add to oplog (buffering if parents are missing)
  let applied_ops = self.oplog.apply_remote(op) catch {
    e => raise DocumentError::OpLog(e)
  }

  // Invalidate before any tree mutation so exception paths can't leave stale cache.
  if applied_ops.length() > 0 {
    self.invalidate_cache()
  }

  // Apply any newly-resolved operations to the tree
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
        // Get Lamport timestamp and agent from causal graph for proper ordering
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
      }
      @core.Delete =>
        match origin_left {
          Some(lv) => {
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
          }
          None => ()
        }
      @core.Undelete =>
        match origin_left {
          Some(lv) => {
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
          }
          None => ()
        }
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
  self.cursor = None
  self.oplog.validate_remote_batch(remote_ops, remote_frontier) catch {
    e => raise DocumentError::OpLog(e)
  }
  // Invalidate before merge so partial-merge failures can't leave stale cache.
  // TODO(phase3): Replace invalidate_cache() with MergeCache for incremental
  // position cache updates during merge. MergeCache::new() decides whether to
  // do incremental updates or drop-and-rebuild based on merge_size vs doc_size.
  self.invalidate_cache()
  // Use the branch module's merge convenience function
  @branch.merge_remote_ops(self.tree, self.oplog, remote_ops) catch {
    e => raise DocumentError::Branch(e)
  }
}

///|
/// Get the number of visible characters in the document.
/// Delegates to the internal FugueTree.
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
  let cache = self.get_position_cache()
  let mut pos = 0
  for run in cache.iter() {
    if lv >= run.start_lv && lv < run.start_lv + run.count {
      return Some(pos + (lv - run.start_lv))
    }
    pos = pos + run.count
  }
  None
}
