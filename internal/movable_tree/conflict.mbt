///| Kleppmann's undo-do-redo conflict resolution for concurrent tree moves.
///
/// When operations arrive out of causal order (common in distributed systems),
/// the log replays operations in timestamp order by undoing newer ops,
/// inserting the new op, then redoing the undone ops with fresh state.

///|
/// Undo information captured when an operation is applied to the tree.
/// Used to reverse the effect of an operation during the undo phase.
priv enum UndoInfo {
  /// Op was skipped (would have created a cycle)
  Skipped
  /// Op created a new node (undo = remove_node)
  Created
  /// Op moved an existing node from (old_parent, old_position)
  Moved(TreeNodeId, @fi.FractionalIndex)
}

///|
/// A log entry pairing an operation with its undo information.
priv struct LogEntry {
  op : TreeMoveOp
  mut undo_info : UndoInfo
}

///|
/// Operation log that applies tree move operations using Kleppmann's
/// undo-do-redo algorithm for conflict resolution.
///
/// Operations are maintained in sorted order by (timestamp, agent) to ensure
/// deterministic replay regardless of arrival order.
pub struct TreeOpLog {
  priv entries : Array[LogEntry]
  priv seen : Map[String, Bool]
}

///|
/// Create a new empty operation log.
pub fn TreeOpLog::new() -> TreeOpLog {
  { entries: [], seen: Map::new() }
}

///|
/// Return all operations in timestamp order.
pub fn TreeOpLog::all_ops(self : TreeOpLog) -> Array[TreeMoveOp] {
  let result : Array[TreeMoveOp] = []
  for i = 0; i < self.entries.length(); i = i + 1 {
    result.push(self.entries[i].op)
  }
  result
}

///|
/// Compare two operations by (timestamp, agent) for total ordering.
/// Returns negative if a < b, zero if equal, positive if a > b.
fn compare_ops(a : TreeMoveOp, b : TreeMoveOp) -> Int {
  let ts_cmp = a.timestamp - b.timestamp
  if ts_cmp != 0 {
    return ts_cmp
  }
  a.agent.compare(b.agent)
}

///|
/// Build a dedup key for an operation: "agent:timestamp".
fn dedup_key(op : TreeMoveOp) -> String {
  op.agent + ":" + op.timestamp.to_string()
}

///|
/// Apply a single operation to the tree and return its undo info.
///
/// - If the target node doesn't exist yet, create it → `Created`
/// - If the move would create a cycle, skip it → `Skipped`
/// - Otherwise, move the node and record old parent/position → `Moved`
fn do_op(tree : MovableTree, op : TreeMoveOp) -> UndoInfo {
  if not(tree.contains(op.target)) {
    // Node doesn't exist yet — create it
    tree.apply_create(op.target, op.new_parent, op.position)
    Created
  } else if tree.would_create_cycle(op.target, op.new_parent) {
    // Move would create a cycle — skip
    Skipped
  } else {
    // Move the node, recording old state for undo
    let old_parent = match tree.parent(op.target) {
      Some(p) => p
      None => root_id // Should not happen for a contained node
    }
    let old_position = match tree.get_position(op.target) {
      Some(p) => p
      None => @fi.FractionalIndex::new([0]) // Should not happen
    }
    tree.apply_move(op.target, op.new_parent, op.position)
    Moved(old_parent, old_position)
  }
}

///|
/// Undo a single entry's effect on the tree.
fn undo_entry(tree : MovableTree, entry : LogEntry) -> Unit {
  match entry.undo_info {
    Skipped => ()
    Created => tree.remove_node(entry.op.target)
    Moved(old_parent, old_position) =>
      tree.apply_move(entry.op.target, old_parent, old_position)
  }
}

///|
/// Apply an operation to the tree using Kleppmann's undo-do-redo algorithm.
///
/// 1. Dedup: skip if already seen.
/// 2. Find insertion point in (timestamp, agent) sorted order.
/// 3. Undo: reverse all entries from end back to insertion point.
/// 4. Do: apply the new operation.
/// 5. Insert the new entry at the correct position.
/// 6. Redo: re-apply all entries after the insertion point with fresh undo info.
pub fn TreeOpLog::apply(
  self : TreeOpLog,
  tree : MovableTree,
  op : TreeMoveOp,
) -> Unit {
  // Step 1: Dedup
  let key = dedup_key(op)
  match self.seen.get(key) {
    Some(true) => return
    _ => ()
  }
  self.seen.set(key, true)
  // Step 2: Find insertion point (index where new op should go)
  // All entries before this index have smaller (timestamp, agent)
  let mut insert_idx = self.entries.length()
  for i = 0; i < self.entries.length(); i = i + 1 {
    if compare_ops(op, self.entries[i].op) < 0 {
      insert_idx = i
      break
    }
  }
  // Step 3: Undo — walk from end back to insertion point
  for i = self.entries.length() - 1; i >= insert_idx; i = i - 1 {
    undo_entry(tree, self.entries[i])
  }
  // Step 4: Apply the new operation
  let undo_info = do_op(tree, op)
  let new_entry : LogEntry = { op, undo_info }
  // Step 5: Insert at the correct position
  self.entries.insert(insert_idx, new_entry)
  // Step 6: Redo — walk from insertion point + 1 to end, re-applying with fresh undo info
  for i = insert_idx + 1; i < self.entries.length(); i = i + 1 {
    self.entries[i].undo_info = do_op(tree, self.entries[i].op)
  }
}
