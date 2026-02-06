///| Document - User-facing CRDT document API

///|

///| Manages the FugueTree, OpLog, and CausalGraph together

///|
/// Provides position-based operations (insert/delete at cursor position)
pub struct Document {
  priv tree : @fugue.FugueTree[String]
  priv oplog : @oplog.OpLog
  agent_id : String
  // Position cache: maps position -> (Lv, Item[String]) for O(1) lookup
  // Invalidated on any modification (set to None)
  priv mut position_cache : Array[(@fugue.Lv, @fugue.Item[String])]?
} derive(Show)

///|
/// Create a new document for an agent
pub fn Document::new(agent_id : String) -> Document {
  let oplog = @oplog.OpLog::new(agent_id)
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  { tree, oplog, agent_id, position_cache: None }
}

///|
/// Get the current text content
pub fn Document::to_text(self : Document) -> String {
  self.tree.to_text()
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
/// Get or build the position cache (lazy initialization)
fn Document::get_position_cache(
  self : Document,
) -> Array[(@fugue.Lv, @fugue.Item[String])] {
  match self.position_cache {
    Some(cache) => cache
    None => {
      let cache = self.tree.get_visible_items()
      self.position_cache = Some(cache)
      cache
    }
  }
}

///|
/// Invalidate the position cache (call after any modification)
fn Document::invalidate_cache(self : Document) -> Unit {
  self.position_cache = None
}

///| Map a user position (0-based cursor position) to the LV at that position

///|

///| Returns the LV of the item before the cursor position

///|
/// Returns -1 if at the start of the document
fn Document::position_to_lv(self : Document, position : Int) -> Int {
  if position == 0 {
    return -1
  }

  // Use cached visible items for O(1) lookup after first access
  let items_list = self.get_position_cache()

  // Find the LV at position - 1
  if position > items_list.length() {
    // Position beyond end, use last item
    if items_list.length() > 0 {
      let (id, _) = items_list[items_list.length() - 1]
      return id.0
    } else {
      return -1
    }
  }
  let (id, _) = items_list[position - 1]
  id.0
}

///| Insert text at a cursor position

///|

///|
/// Returns the last operation that was created (for multi-character inserts)
pub fn Document::insert(
  self : Document,
  position : Int,
  text : String,
) -> @core.Op raise DocumentError {
  // Insert each character one by one
  let mut current_pos = position
  let mut last_op : @core.Op? = None

  // Get initial cache for position lookups (will be invalidated after first insert)
  let mut items_list = self.get_position_cache()

  // Iterate through each character in the string
  for i = 0; i < text.length(); i = i + 1 {
    // Extract single character as string
    let ch = text[i:i + 1].to_string() catch {
      _ => continue // Skip invalid indices
    }

    // Map position to LV using cached items
    let origin_left = self.position_to_lv(current_pos)

    // Find origin_right (the item after the cursor)
    let origin_right = if current_pos == 0 {
      // At start, find first visible item
      if items_list.length() > 0 {
        let (id, _) = items_list[0]
        id.0
      } else {
        -1
      }
    } else if current_pos < items_list.length() {
      let (id, _) = items_list[current_pos]
      id.0
    } else {
      -1
    }

    // Create and apply the operation for this character
    let op = self.oplog.insert(ch, origin_left, origin_right) catch {
      e => raise DocumentError::OpLog(e)
    }

    // Get Lamport timestamp and agent from causal graph for proper ordering
    let (timestamp, agent) = match self.oplog.graph[op.lv] {
      Some(entry) => (entry.timestamp, entry.agent)
      None =>
        raise DocumentError::OpLog(
          @oplog.OpLogError::MissingLocalVersion(lv=op.lv),
        )
    }

    // Apply to tree and invalidate cache
    self.tree.insert({
      id: @fugue.Lv(op.lv),
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
    self.invalidate_cache()

    // Rebuild cache for next iteration if there are more characters
    if i + 1 < text.length() {
      items_list = self.get_position_cache()
    }
    last_op = Some(op)
    current_pos = current_pos + 1
  }

  // Return the last operation (or create a dummy one if text was empty)
  match last_op {
    Some(op) => op
    None =>
      // Empty string inserted - create a no-op
      // This shouldn't happen in practice, but we need to return something
      self.oplog.insert("", -1, -1) catch {
        e => raise DocumentError::OpLog(e)
      }
  }
}

///| Delete character at a cursor position

///|

///|
/// Returns Some(operation) if successful, None if position is invalid
pub fn Document::delete(
  self : Document,
  position : Int,
) -> @core.Op raise DocumentError {
  if position < 0 {
    raise DocumentError::InvalidPosition(pos=position)
  }

  // Use cached visible items for O(1) lookup
  let items_list = self.get_position_cache()
  if position >= items_list.length() {
    raise DocumentError::InvalidPosition(pos=position)
  }

  // Get the LV of the item to delete
  let (target_lv, _) = items_list[position]

  // Create and apply delete operation
  let op = self.oplog.delete(target_lv.0) catch {
    e => raise DocumentError::OpLog(e)
  }
  self.tree.delete(target_lv) catch {
    e => raise DocumentError::Fugue(e)
  }

  // Invalidate cache after modification
  self.invalidate_cache()
  op
}

///|
/// Create and apply an undelete operation for a specific LV
/// Used by undo to revive a deleted item and create a syncable op
pub fn Document::undelete(
  self : Document,
  target_lv : Int,
) -> @core.Op raise DocumentError {
  let op = self.oplog.undelete(target_lv) catch {
    e => raise DocumentError::OpLog(e)
  }
  self.tree.undelete(@fugue.Lv(target_lv)) catch {
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
  let op = self.oplog.delete(target_lv) catch {
    e => raise DocumentError::OpLog(e)
  }
  self.tree.delete(@fugue.Lv(target_lv)) catch {
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
  // Add to oplog (buffering if parents are missing)
  let applied_ops = self.oplog.apply_remote(op) catch {
    e => raise DocumentError::OpLog(e)
  }

  // Invalidate before any tree mutation so exception paths can't leave stale cache.
  if applied_ops.length() > 0 {
    self.invalidate_cache()
  }

  // Apply any newly-resolved operations to the tree
  for applied in applied_ops {
    let origin_left : @fugue.Lv? = match applied.origin_left {
      None => None
      Some(raw) =>
        match self.oplog.graph.raw_to_lv(raw) {
          Some(lv) => Some(@fugue.Lv(lv))
          None => raise DocumentError::MissingOrigin(raw~)
        }
    }
    let origin_right : @fugue.Lv? = match applied.origin_right {
      None => None
      Some(raw) =>
        match self.oplog.graph.raw_to_lv(raw) {
          Some(lv) => Some(@fugue.Lv(lv))
          None => raise DocumentError::MissingOrigin(raw~)
        }
    }
    match applied.content {
      @core.Insert(text) => {
        // Get Lamport timestamp and agent from causal graph for proper ordering
        let (timestamp, agent) = match self.oplog.graph[applied.lv] {
          Some(entry) => (entry.timestamp, entry.agent)
          None =>
            raise DocumentError::OpLog(
              @oplog.OpLogError::MissingLocalVersion(lv=applied.lv),
            )
        }
        self.tree.insert({
          id: @fugue.Lv(applied.lv),
          content: text,
          origin_left,
          origin_right,
          timestamp: @fugue.Timestamp(timestamp),
          agent: @fugue.ReplicaId(agent),
        })
      }
      @core.Delete =>
        match origin_left {
          Some(lv) =>
            self.tree.delete(lv) catch {
              e => raise DocumentError::Fugue(e)
            }
          None => ()
        }
      @core.Undelete =>
        match origin_left {
          Some(lv) =>
            self.tree.undelete(lv) catch {
              e => raise DocumentError::Fugue(e)
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
  self.oplog.validate_remote_batch(remote_ops, remote_frontier) catch {
    e => raise DocumentError::OpLog(e)
  }
  // Invalidate before merge so partial-merge failures can't leave stale cache.
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
  // Return a copy to prevent callers from mutating internal cache
  self.get_position_cache().copy()
}

///|
/// Map a local version to its visible position in the document.
pub fn Document::lv_to_position(self : Document, lv : Int) -> Int? {
  self.tree.lv_to_position(@fugue.Lv(lv))
}
