///| Merge algorithm implementation

///|

///| Implements the three-phase retreat-advance-apply merge strategy

///|
/// MergeContext - state during merge operation
pub struct MergeContext {
  priv tree : @fugue.FugueTree[String] // The FugueMax tree being merged
  priv oplog : @oplog.OpLog // Operation log
}

///|
/// Create a new merge context
pub fn MergeContext::new(
  tree : @fugue.FugueTree[String],
  oplog : @oplog.OpLog,
) -> MergeContext {
  { tree, oplog }
}

///|
/// Apply operations from the advance set.
///
/// Integrates operations into the tree in topological order.
pub fn MergeContext::apply_operations(
  self : MergeContext,
  operations : @rle.Rle[@core.LvRange],
) -> Unit raise BranchError {
  let cg = self.oplog.causal_graph()

  // Apply each operation in order (Rle is already topologically sorted)
  for range in operations.iter() {
    for lv = range.start; lv < range.end(); lv = lv + 1 {
      match self.oplog.get_op(lv) {
        Some(op) =>
          match op.content() {
            @core.Insert(text) => {
              let origin_left : @fugue.Lv? = match op.origin_left() {
                None => None
                Some(raw) =>
                  match cg.raw_to_lv(raw) {
                    Some(mapped) => Some(@fugue.Lv(mapped))
                    None => raise BranchError::MissingOrigin(raw~)
                  }
              }
              let origin_right : @fugue.Lv? = match op.origin_right() {
                None => None
                Some(raw) =>
                  match cg.raw_to_lv(raw) {
                    Some(mapped) => Some(@fugue.Lv(mapped))
                    None => raise BranchError::MissingOrigin(raw~)
                  }
              }
              // Get Lamport timestamp and agent from causal graph for proper ordering
              let lv = op.lv()
              let (timestamp, agent) = match cg[lv] {
                Some(entry) => (entry.timestamp, entry.agent)
                None => raise BranchError::MissingOp(lv~)
              }

              // Insert into tree with FugueMax algorithm
              self.tree.insert({
                id: @fugue.Lv(lv),
                content: text,
                origin_left,
                origin_right,
                timestamp: @fugue.Timestamp(timestamp),
                agent: @fugue.ReplicaId(agent),
              })
            }
            @core.Delete =>
              match op.origin_left() {
                None => ()
                Some(raw) =>
                  match cg.raw_to_lv(raw) {
                    Some(mapped) => {
                      let (del_ts, del_agent) = match cg[lv] {
                        Some(entry) => (entry.timestamp, entry.agent)
                        None => raise BranchError::MissingOp(lv~)
                      }
                      self.tree.delete_with_ts(
                        @fugue.Lv(mapped),
                        del_ts,
                        del_agent,
                      ) catch {
                        e => raise BranchError::Fugue(e)
                      }
                    }
                    None => raise BranchError::MissingOrigin(raw~)
                  }
              }
            @core.Undelete =>
              match op.origin_left() {
                None => ()
                Some(raw) =>
                  match cg.raw_to_lv(raw) {
                    Some(mapped) => {
                      let (undel_ts, undel_agent) = match cg[lv] {
                        Some(entry) => (entry.timestamp, entry.agent)
                        None => raise BranchError::MissingOp(lv~)
                      }
                      self.tree.undelete_with_ts(
                        @fugue.Lv(mapped),
                        undel_ts,
                        undel_agent,
                      ) catch {
                        e => raise BranchError::Fugue(e)
                      }
                    }
                    None => raise BranchError::MissingOrigin(raw~)
                  }
              }
          }
        None => raise BranchError::MissingOp(lv~)
      }
    }
  }
}

///|
/// Check if a given LV is contained in any range of the Rle.
fn rle_contains_lv(rle : @rle.Rle[@core.LvRange], lv : Int) -> Bool {
  for range in rle.iter() {
    if range.contains(lv) {
      return true
    }
  }
  false
}

///|
/// Remove operations from the retreat set.
///
/// For Insert ops: hides the item (force-delete).
/// For Delete/Undelete ops: recomputes the LWW winner from the oplog
/// by scanning for all Delete/Undelete ops targeting the same item
/// that remain in the common ancestor (not in the retreat set).
pub fn MergeContext::retreat_operations(
  self : MergeContext,
  operations : @rle.Rle[@core.LvRange],
) -> Unit raise BranchError {
  let cg = self.oplog.causal_graph()

  for range in operations.iter() {
    for lv = range.start; lv < range.end(); lv = lv + 1 {
      match self.oplog.get_op(lv) {
        Some(op) =>
          match op.content() {
            @core.Insert(_) =>
              // Retreat Insert: hide the item
              self.tree.delete(@fugue.Lv(lv)) catch {
                e => raise BranchError::Fugue(e)
              }
            @core.Delete | @core.Undelete => {
              // Retreat Delete/Undelete: recompute winner from remaining ops
              let target_lv = match op.origin_left() {
                None => continue
                Some(raw) =>
                  match cg.raw_to_lv(raw) {
                    Some(mapped) => mapped
                    None => raise BranchError::MissingOrigin(raw~)
                  }
              }
              // Scan oplog for all Delete/Undelete ops targeting this item
              // that are NOT in the retreat set (i.e., remain in common ancestor)
              let mut best_ts = 0
              let mut best_agent = ""
              let mut best_is_undelete = false
              let mut best_deleted = false
              let op_count = self.oplog.op_count()
              for i = 0; i < op_count; i = i + 1 {
                if rle_contains_lv(operations, i) {
                  continue // Skip retreated ops
                }
                match self.oplog.get_op(i) {
                  Some(other_op) => {
                    let is_del_or_undel = match other_op.content() {
                      @core.Delete | @core.Undelete => true
                      _ => false
                    }
                    if not(is_del_or_undel) {
                      continue
                    }
                    // Check if this op targets the same item
                    let other_target = match other_op.origin_left() {
                      None => continue
                      Some(raw) =>
                        match cg.raw_to_lv(raw) {
                          Some(t) => t
                          None => continue
                        }
                    }
                    if other_target != target_lv {
                      continue
                    }
                    // This op targets the same item and is in the common ancestor
                    let (other_ts, other_agent) = match cg[i] {
                      Some(entry) => (entry.timestamp, entry.agent)
                      None => continue
                    }
                    let other_is_undelete = match other_op.content() {
                      @core.Undelete => true
                      _ => false
                    }
                    if @fugue.should_win_delete(
                        other_ts, other_agent, other_is_undelete, best_ts,
                        best_agent, best_is_undelete,
                      ) {
                      best_ts = other_ts
                      best_agent = other_agent
                      best_is_undelete = other_is_undelete
                      best_deleted = not(other_is_undelete)
                    }
                  }
                  None => continue
                }
              }
              // Set the item to the recomputed winner state
              self.tree.set_delete_winner(
                @fugue.Lv(target_lv),
                best_deleted,
                best_ts,
                best_agent,
                best_is_undelete,
              ) catch {
                e => raise BranchError::Fugue(e)
              }
            }
          }
        None => raise BranchError::MissingOp(lv~)
      }
    }
  }
}

///|
/// Perform a full three-phase retreat-advance-apply merge.
///
/// 1. Calculate diff between current frontier and target frontier
/// 2. Retreat — remove operations not in target
/// 3. Advance — apply operations in target
pub fn merge(
  tree : @fugue.FugueTree[String],
  oplog : @oplog.OpLog,
  current_frontier : @core.Frontier,
  target_frontier : @core.Frontier,
) -> Unit raise BranchError {
  // Calculate retreat and advance sets (topologically sorted, RLE-compressed)
  let (retreat_rle, advance_rle) = oplog
    .causal_graph()
    .diff_frontiers_lvs(current_frontier, target_frontier)
  let ctx = MergeContext::new(tree, oplog)

  // Phase 1: Retreat - remove operations not in target (reverse topo order)
  ctx.retreat_operations(retreat_rle)

  // Phase 2: Advance - apply operations in target (topo order)
  ctx.apply_operations(advance_rle)
}

///|
/// Merge remote operations into local state using the eg-walker Branch system.
///
/// 1. Creates a Branch representing current state
/// 2. Uses Branch::merge_remote_ops which leverages the walker
/// 3. Updates the tree to match the merged branch
///
/// This is a convenience function for applying remote operations.
pub fn merge_remote_ops(
  tree : @fugue.FugueTree[String],
  oplog : @oplog.OpLog,
  remote_ops : Array[@core.Op],
) -> Unit raise BranchError {
  // Create a Branch representing the current state
  let branch = Branch::from_tree_and_oplog(tree, oplog)

  // Use Branch::merge_remote_ops which properly uses the walker
  // This leverages the eg-walker algorithm with causal ordering
  let _ = branch.merge_remote_ops(remote_ops)

  // The tree has been updated in-place through the branch
  // (since Branch reuses the same tree reference when only advancing)
}
