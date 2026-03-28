///| Kleppmann's undo-do-redo algorithm for conflict-free concurrent tree moves.
///
/// ## The problem
///
/// In a collaborative tree editor two peers can issue concurrent moves that
/// conflict.  For example:
///
///   Peer A (ts 3): move N₁ under N₂
///   Peer B (ts 4): move N₂ under N₁
///
/// If each peer simply applies ops as they arrive, peer A sees the sequence
/// (3 then 4) and peer B sees (4 then 3) — two different trees.  Worse, one
/// of these orderings produces a cycle (N₁ → N₂ → N₁) while the other does
/// not, so the two peers cannot agree on which moves are valid.
///
/// ## The solution: total order + undo-do-redo
///
/// Assign every op a Lamport timestamp that is globally comparable across peers.
/// Maintain the log sorted by (timestamp, agent).  Whenever a new op arrives —
/// regardless of delivery order — insert it at its correct position in the total
/// order:
///
///   1. Undo all ops that sort after the insertion point.
///   2. Apply ("do") the new op.
///   3. Re-apply ("redo") the undone ops in order.
///
/// Because every replica processes the same total-ordered sequence the final tree
/// is identical everywhere, achieving strong eventual consistency.
///
/// ## Cycle prevention
///
/// During the redo phase a previously-valid move may now create a cycle (because
/// an earlier op has changed the tree topology).  Such a move is skipped but
/// still recorded in the log as `Skipped`.  The skip is deterministic: every
/// replica will skip exactly the same moves, so the converged tree is always
/// acyclic.
///
/// ## Forward-create
///
/// Ops may arrive before the op that first created their target node (common
/// under out-of-order delivery).  In that case `do_op` synthesizes the node at
/// the op's specified location (`Created`).  When the true create op later
/// arrives it is a no-op because the node already exists.  This ensures correct
/// convergence regardless of delivery order.

///|
/// The effect an op had on the tree, recorded so it can be reversed.
///
/// The undo-do-redo algorithm must be able to exactly reverse every op it has
/// applied.  There are three distinct cases:
///
/// - `Skipped`  — the op was a no-op (cycle detected); nothing to reverse.
/// - `Created`  — the op forward-created a new node; reverse by removing it.
/// - `Moved`    — the op repositioned an existing node; reverse by restoring
///               its old (parent, position).
///
/// `undo_info` is stored per log entry and is refreshed after every redo pass
/// because the undo information for a given op can change as earlier ops are
/// inserted: an op that previously created a node may now merely move it (if
/// the create op has since been inserted before it).
priv enum UndoInfo {
  /// Op was a no-op because it would have created a cycle.
  Skipped
  /// Op forward-created a new node; undo by removing it entirely.
  Created
  /// Op moved an existing node; undo by restoring (old_parent, old_position).
  Moved(TreeNodeId, @fi.FractionalIndex)
}

///|
/// A log entry pairing an operation with its current undo information.
///
/// `undo_info` is `mut` because the redo phase overwrites it: after a new op
/// is inserted at an earlier position, every entry that was replayed gets fresh
/// undo information reflecting the new tree state in which it was re-applied.
priv struct LogEntry {
  op : TreeMoveOp
  mut undo_info : UndoInfo
}

///|
/// An ordered log of move operations that maintains the convergence invariant.
///
/// **Invariant:** `entries` is always sorted by (timestamp, agent).  This total
/// order is the same on every replica, so replaying the log always produces the
/// same tree regardless of how ops were delivered.
///
/// `seen` is a dedup set keyed by (agent, timestamp).  Because each replica has
/// a globally unique agent id and a monotonically increasing Lamport clock, this
/// pair identifies an op uniquely; applying the same op twice would otherwise
/// corrupt the log.
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
/// Total order for operations: first by Lamport timestamp, then by agent id.
///
/// Lamport timestamps track causal happens-before across all peers.  Two ops
/// with the same timestamp were issued concurrently (neither caused the other).
/// The agent id tie-break makes the order deterministic even for concurrent ops:
/// every replica will sort them identically, so every redo phase applies them
/// in the same sequence.
fn compare_ops(a : TreeMoveOp, b : TreeMoveOp) -> Int {
  let ts_cmp = a.timestamp.compare(b.timestamp)
  if ts_cmp != 0 {
    return ts_cmp
  }
  a.agent.compare(b.agent)
}

///|
/// Dedup key for an operation: "agent:timestamp".
///
/// A (replica_id, lamport_timestamp) pair uniquely identifies an op: each
/// replica's Lamport clock is strictly monotone so no two of its ops share a
/// timestamp, and distinct replicas have distinct ids.  Storing only this pair
/// (not the full op payload) keeps the dedup map small.
fn dedup_key(op : TreeMoveOp) -> String {
  op.agent + ":" + op.timestamp.to_string()
}

///|
/// Apply a single op to the tree and return the information needed to undo it.
///
/// This is the "do" step of undo-do-redo.  It has three cases:
///
/// **Case 1 — forward-create** (`target` not yet in the tree):
///   The op references a node that hasn't been created yet (its create op
///   hasn't arrived).  We synthesize the node at the op's location so that
///   subsequent ops that depend on it can be applied correctly.  If the
///   synthesized position would form a cycle (possible because earlier
///   out-of-order ops may have already placed this target in some ancestor's
///   parent chain via dangling pointers) we skip instead of creating.
///
/// **Case 2 — cycle skip** (`target` exists but move forms a cycle):
///   The move would make an ancestor a descendant of itself.  We record this
///   as `Skipped` so `undo_entry` is a no-op — there is nothing to reverse.
///   The op remains in the log so that if the topology later changes (via an
///   earlier op being inserted) the redo phase can try it again.
///
/// **Case 3 — normal move** (`target` exists, no cycle):
///   Record the node's current (parent, position) as undo information, then
///   move it to (new_parent, position).
fn do_op(tree : MovableTree, op : TreeMoveOp) -> UndoInfo {
  if not(tree.contains(op.target)) {
    // Forward-create: node doesn't exist yet.
    // Cycle check is still required: an earlier op may have placed op.target
    // as a dangling ancestor entry, making op.new_parent a descendant of it.
    if tree.would_create_cycle(op.target, op.new_parent) {
      Skipped
    } else {
      tree.apply_create(op.target, op.new_parent, op.position)
      Created
    }
  } else if tree.would_create_cycle(op.target, op.new_parent) {
    // Move would form a cycle — skip deterministically.
    Skipped
  } else {
    // Normal move: snapshot old location for undo.
    let old_parent = match tree.parent(op.target) {
      Some(p) => p
      None => root_id // unreachable: node is contained
    }
    let old_position = match tree.get_position(op.target) {
      Some(p) => p
      None => @fi.FractionalIndex::new([0]) // unreachable: node is contained
    }
    tree.apply_move(op.target, op.new_parent, op.position)
    Moved(old_parent, old_position)
  }
}

///|
/// Reverse a single op's effect on the tree using its recorded undo info.
///
/// This is the exact inverse of `do_op`:
/// - `Skipped` → op changed nothing, so nothing to reverse.
/// - `Created` → op synthesized a new node; remove it entirely.
/// - `Moved`   → op repositioned a node; move it back to its old location.
///
/// Called in reverse log order (newest-to-oldest) during the undo phase so
/// that the tree is unwound back to the state it was in just before the
/// insertion point.
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
/// ### Why undo-do-redo is necessary
///
/// Suppose the log already contains ops at timestamps [1, 3, 5] and a new op
/// arrives with timestamp 2.  Simply appending it would give the wrong tree:
/// ops 3 and 5 were applied to a tree that didn't include op 2, so their
/// effects are relative to a topology that no longer reflects the intended
/// total order.
///
/// Instead we must replay: undo ops 3 and 5 (restoring the tree to the state
/// after op 1), apply op 2, then redo ops 3 and 5.  The final tree is the
/// same as if the ops had arrived in order 1 → 2 → 3 → 5 from the start.
///
/// ### Concrete example
///
///   Log before: [create A under root (ts 1), move A under B (ts 3)]
///   New op:      create B under root (ts 2)
///
///   1. Dedup check — not seen before, continue.
///   2. Insertion point — ts 2 < ts 3, so insert_idx = 1.
///   3. Undo — undo "move A under B" (A goes back to wherever it was before ts 3,
///             which may be root if op ts 1 had placed it there).
///   4. Do   — apply "create B under root" (ts 2). B now exists.
///   5. Insert — log becomes [ts 1, ts 2, ts 3 (undo info stale)].
///   6. Redo — re-apply "move A under B" (ts 3) in the new tree that contains B.
///             A ends up under B.  undo_info updated to Moved(root, …).
///
/// ### Steps
///
/// 1. **Dedup** — identical ops may arrive multiple times (e.g. during full-log
///    sync).  The `seen` map rejects duplicates before any tree mutation.
///
/// 2. **Find insertion point** — linear scan for the first entry with a greater
///    (timestamp, agent).  All entries before this index sort before the new op;
///    all entries from this index onward sort after it and must be replayed.
///
/// 3. **Undo** — walk the suffix (insertion_point … end) in reverse order,
///    calling `undo_entry` for each.  Reverse order is critical: we must undo
///    the newest-applied op first so intermediate states are consistent.
///
/// 4. **Do** — apply the new op via `do_op`, which handles forward-create,
///    cycle detection, and normal moves.
///
/// 5. **Insert** — splice the new entry into `entries` at `insert_idx`.
///
/// 6. **Redo** — walk forward from `insert_idx + 1` to end, re-applying each
///    op with `do_op` and storing the fresh undo info.  Undo info must be
///    refreshed because the tree topology has changed: a move that previously
///    was `Skipped` (cycle) may now be valid, and vice versa.
pub fn TreeOpLog::apply(
  self : TreeOpLog,
  tree : MovableTree,
  op : TreeMoveOp,
) -> Unit {
  // Step 1: Dedup — reject ops we have already applied.
  let key = dedup_key(op)
  match self.seen.get(key) {
    Some(true) => return
    _ => ()
  }
  self.seen.set(key, true)
  // Step 2: Find insertion point.
  // Scan left-to-right; the first entry that sorts after the new op is where
  // it belongs.  If no such entry exists, append at the end.
  let mut insert_idx = self.entries.length()
  for i = 0; i < self.entries.length(); i = i + 1 {
    if compare_ops(op, self.entries[i].op) < 0 {
      insert_idx = i
      break
    }
  }
  // Step 3: Undo — reverse the suffix that will be replayed.
  // Walk newest-to-oldest so each undo restores a consistent intermediate state.
  for i = self.entries.length() - 1; i >= insert_idx; i = i - 1 {
    undo_entry(tree, self.entries[i])
  }
  // Step 4: Do — apply the new op in the now-unwound tree.
  let undo_info = do_op(tree, op)
  let new_entry : LogEntry = { op, undo_info }
  // Step 5: Insert — splice the new entry into the sorted log.
  self.entries.insert(insert_idx, new_entry)
  // Step 6: Redo — re-apply the suffix with fresh undo information.
  // Undo info is refreshed because cycle-skip status may have changed now that
  // an earlier op has been inserted and altered the tree topology.
  for i = insert_idx + 1; i < self.entries.length(); i = i + 1 {
    self.entries[i].undo_info = do_op(tree, self.entries[i].op)
  }
}
