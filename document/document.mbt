///| Document - User-facing CRDT document API

///|

///| Manages the FugueTree, OpLog, and CausalGraph together

///|
/// Provides position-based operations (insert/delete at cursor position)
pub struct Document {
  priv tree : @fugue.FugueTree
  priv oplog : @oplog.OpLog
  agent_id : String
} derive(Show)

///|
/// Create a new document for an agent
pub fn Document::new(agent_id : String) -> Document {
  let oplog = @oplog.OpLog::new(agent_id)
  let tree = @fugue.FugueTree::new()
  { tree, oplog, agent_id }
}

///|
/// Get the current text content
pub fn Document::to_text(self : Document) -> String {
  self.tree.to_text()
}

///|
/// Get the current frontier
pub fn Document::get_frontier(self : Document) -> @causal_graph.Frontier {
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
) -> Array[@causal_graph.RawVersion] raise DocumentError {
  self.oplog.get_frontier_raw() catch {
    e => raise DocumentError::OpLog(e)
  }
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

  // Get all visible items in proper tree order
  let items_list = self.tree.get_visible_items()

  // Find the LV at position - 1
  if position > items_list.length() {
    // Position beyond end, use last item
    if items_list.length() > 0 {
      let (id, _) = items_list[items_list.length() - 1]
      return id
    } else {
      return -1
    }
  }
  let (id, _) = items_list[position - 1]
  id
}

///| Insert text at a cursor position

///|

///|
/// Returns the last operation that was created (for multi-character inserts)
pub fn Document::insert(
  self : Document,
  position : Int,
  text : String,
) -> @oplog.Op raise DocumentError {
  // Insert each character one by one
  let mut current_pos = position
  let mut last_op : @oplog.Op? = None

  // Iterate through each character in the string
  for i = 0; i < text.length(); i = i + 1 {
    // Extract single character as string
    let ch = text[i:i + 1].to_string() catch {
      _ => continue // Skip invalid indices
    }

    // Map position to LV
    let origin_left = self.position_to_lv(current_pos)

    // Find origin_right (the item after the cursor)
    let items_list : Array[(Int, @fugue.Item)] = self.tree.get_visible_items()
    let origin_right = if current_pos == 0 {
      // At start, find first visible item
      if items_list.length() > 0 {
        let (id, _) = items_list[0]
        id
      } else {
        -1
      }
      // Find item at position
    } else if current_pos < items_list.length() {
      let (id, _) = items_list[current_pos]
      id
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

    // Apply to tree
    self.tree.insert(op.lv, ch, origin_left, origin_right, timestamp, agent)
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
) -> @oplog.Op raise DocumentError {
  if position < 0 {
    raise DocumentError::InvalidPosition(pos=position)
  }

  // Get all visible items in proper tree order
  let items_list = self.tree.get_visible_items()
  if position >= items_list.length() {
    raise DocumentError::InvalidPosition(pos=position)
  }

  // Get the LV of the item to delete
  let (target_lv, _) = items_list[position]

  // Create and apply delete operation
  let op = self.oplog.delete(target_lv) catch {
    e => raise DocumentError::OpLog(e)
  }
  self.tree.delete(target_lv) catch {
    e => raise DocumentError::Fugue(e)
  }
  op
}

///|
/// Create and apply an undelete operation for a specific LV
/// Used by undo to revive a deleted item and create a syncable op
pub fn Document::undelete(
  self : Document,
  target_lv : Int,
) -> @oplog.Op raise DocumentError {
  let op = self.oplog.undelete(target_lv) catch {
    e => raise DocumentError::OpLog(e)
  }
  self.tree.undelete(target_lv) catch {
    e => raise DocumentError::Fugue(e)
  }
  op
}

///|
/// Create and apply a delete operation for a specific LV
/// Used by undo to delete a specific item and create a syncable op
pub fn Document::delete_by_lv(
  self : Document,
  target_lv : Int,
) -> @oplog.Op raise DocumentError {
  let op = self.oplog.delete(target_lv) catch {
    e => raise DocumentError::OpLog(e)
  }
  self.tree.delete(target_lv) catch {
    e => raise DocumentError::Fugue(e)
  }
  op
}

///|
/// Apply a remote operation to this document
pub fn Document::apply_remote(
  self : Document,
  op : @oplog.Op,
) -> Unit raise DocumentError {
  // Add to oplog (buffering if parents are missing)
  let applied_ops = self.oplog.apply_remote(op) catch {
    e => raise DocumentError::OpLog(e)
  }

  // Apply any newly-resolved operations to the tree
  for applied in applied_ops {
    let origin_left = match applied.origin_left {
      None => -1
      Some(raw) =>
        match self.oplog.graph.raw_to_lv(raw) {
          Some(lv) => lv
          None => raise DocumentError::MissingOrigin(raw~)
        }
    }
    let origin_right = match applied.origin_right {
      None => -1
      Some(raw) =>
        match self.oplog.graph.raw_to_lv(raw) {
          Some(lv) => lv
          None => raise DocumentError::MissingOrigin(raw~)
        }
    }
    match applied.content {
      @oplog.Insert(text) => {
        // Get Lamport timestamp and agent from causal graph for proper ordering
        let (timestamp, agent) = match self.oplog.graph[applied.lv] {
          Some(entry) => (entry.timestamp, entry.agent)
          None =>
            raise DocumentError::OpLog(
              @oplog.OpLogError::MissingLocalVersion(lv=applied.lv),
            )
        }
        self.tree.insert(
          applied.lv,
          text,
          origin_left,
          origin_right,
          timestamp,
          agent,
        )
      }
      @oplog.Delete =>
        if origin_left != -1 {
          self.tree.delete(origin_left) catch {
            e => raise DocumentError::Fugue(e)
          }
        }
      @oplog.Undelete =>
        if origin_left != -1 {
          self.tree.undelete(origin_left) catch {
            e => raise DocumentError::Fugue(e)
          }
        }
    }
  }
}

///|
/// Merge remote operations into this document
pub fn Document::merge_remote(
  self : Document,
  remote_ops : Array[@oplog.Op],
  remote_frontier : Array[@causal_graph.RawVersion],
) -> Unit raise DocumentError {
  self.oplog.validate_remote_batch(remote_ops, remote_frontier) catch {
    e => raise DocumentError::OpLog(e)
  }
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
pub fn Document::get_all_ops(self : Document) -> Array[@oplog.Op] {
  self.oplog.get_all_ops()
}

///|
/// Compute the diff between two frontiers and collect operations.
/// Returns (retreat_ops, advance_ops).
pub fn Document::diff_and_collect(
  self : Document,
  from : @causal_graph.Frontier,
  to : @causal_graph.Frontier,
) -> (Array[@oplog.Op], Array[@oplog.Op]) {
  self.oplog.diff_and_collect(from, to)
}

///|
/// Checkout a branch at the given frontier.
pub fn Document::checkout_branch(
  self : Document,
  frontier : @causal_graph.Frontier,
) -> @branch.Branch raise DocumentError {
  @branch.Branch::checkout(self.oplog, frontier) catch {
    e => raise DocumentError::Branch(e)
  }
}

///|
/// Get visible items from the tree.
pub fn Document::get_visible_items(
  self : Document,
) -> Array[(Int, @fugue.Item)] {
  self.tree.get_visible_items()
}

///|
/// Map a local version to its visible position in the document.
pub fn Document::lv_to_position(self : Document, lv : Int) -> Int? {
  self.tree.lv_to_position(lv)
}
