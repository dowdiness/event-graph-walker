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
  self.tree.set_batch_inserting(true)
  let batch_result : Result[Unit, BranchError] = try? (for
    range in operations.iter() {
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
  })
  self.tree.set_batch_inserting(false)
  match batch_result {
    Ok(_) => ()
    Err(e) => raise e
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
/// Remove operations from the retreat set using two-count approach.
///
/// For Insert ops: mark item as Retreated, decrement visible count.
/// For Delete/Undelete ops: adjust delete_count on target item as dirty tracker.
///
/// After all retreat operations, recompute LWW winners for dirty items
/// using DeleteIndex (O(d) per item instead of O(total_ops)).
pub fn MergeContext::retreat_operations(
  self : MergeContext,
  operations : @rle.Rle[@core.LvRange],
) -> Unit raise BranchError {
  let cg = self.oplog.causal_graph()
  let dirty_items : Array[Int] = []

  for range in operations.iter() {
    for lv = range.start; lv < range.end(); lv = lv + 1 {
      match self.oplog.get_op(lv) {
        Some(op) =>
          match op.content() {
            @core.Insert(_) =>
              // Retreat Insert: hide the item (force-delete)
              self.tree.delete(@fugue.Lv(lv)) catch {
                e => raise BranchError::Fugue(e)
              }
            @core.Delete => {
              // Retreat Delete: track as dirty for post-retreat LWW sweep
              let target_lv = match op.origin_left() {
                None => continue
                Some(raw) =>
                  match cg.raw_to_lv(raw) {
                    Some(mapped) => mapped
                    None => raise BranchError::MissingOrigin(raw~)
                  }
              }
              match self.tree[@fugue.Lv(target_lv)] {
                Some(item) => {
                  item.delete_count = item.delete_count - 1
                  dirty_items.push(target_lv)
                }
                None =>
                  raise BranchError::Fugue(
                    @fugue.FugueError::MissingItem(id=@fugue.Lv(target_lv)),
                  )
              }
            }
            @core.Undelete => {
              // Retreat Undelete: re-apply the delete it cancelled
              let target_lv = match op.origin_left() {
                None => continue
                Some(raw) =>
                  match cg.raw_to_lv(raw) {
                    Some(mapped) => mapped
                    None => raise BranchError::MissingOrigin(raw~)
                  }
              }
              match self.tree[@fugue.Lv(target_lv)] {
                Some(item) => {
                  item.delete_count = item.delete_count + 1
                  dirty_items.push(target_lv)
                }
                None =>
                  raise BranchError::Fugue(
                    @fugue.FugueError::MissingItem(id=@fugue.Lv(target_lv)),
                  )
              }
            }
          }
        None => raise BranchError::MissingOp(lv~)
      }
    }
  }

  // Post-retreat: recompute LWW winners for dirty items
  if dirty_items.length() > 0 {
    let delete_index = DeleteIndex::build(self.oplog)
    for target_lv in dirty_items {
      let winner = delete_index.recompute_winner(
        target_lv,
        self.oplog,
        operations,
      )
      self.tree.set_delete_winner(
        @fugue.Lv(target_lv),
        winner.deleted,
        winner.ts,
        winner.agent,
        winner.is_undelete,
      ) catch {
        e => raise BranchError::Fugue(e)
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
