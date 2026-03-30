///|
/// Inverted index mapping target_lv -> delete/undelete operation LVs.
/// Used for O(d) LWW winner recomputation after merge, where d = number
/// of delete/undelete ops on a single item (typically 0-2).
pub struct DeleteIndex {
  /// target_lv -> Array of op LVs that delete/undelete this item.
  index : Map[Int, Array[Int]]
}

///|
/// Result of LWW winner recomputation
pub(all) struct DeleteWinner {
  deleted : Bool
  ts : Int
  agent : String
  is_undelete : Bool
}

///|
/// Build the index by scanning all ops in the oplog once.
/// O(total_ops) but done once per merge, not per retreated delete.
pub fn DeleteIndex::build(oplog : @oplog.OpLog) -> DeleteIndex {
  let index : Map[Int, Array[Int]] = {}
  let cg = oplog.causal_graph()
  let count = oplog.op_count()
  for lv = 0; lv < count; lv = lv + 1 {
    match oplog.get_op(lv) {
      Some(op) =>
        match op.content() {
          @core.Delete | @core.Undelete =>
            match op.origin_left() {
              Some(raw) =>
                match cg.raw_to_lv(raw) {
                  Some(target) =>
                    match index.get(target) {
                      Some(arr) => arr.push(lv)
                      None => index.set(target, [lv])
                    }
                  None => ()
                }
              None => ()
            }
          _ => ()
        }
      None => ()
    }
  }
  { index, }
}

///|
/// Get all delete/undelete op LVs targeting a given item.
pub fn DeleteIndex::get_delete_ops(
  self : DeleteIndex,
  target_lv : Int,
) -> Array[Int] {
  match self.index.get(target_lv) {
    Some(ops) => ops
    None => []
  }
}

///|
/// Recompute the LWW winner for an item, excluding ops in the retreat set.
/// O(d) where d = number of delete/undelete ops on this item.
pub fn DeleteIndex::recompute_winner(
  self : DeleteIndex,
  target_lv : Int,
  oplog : @oplog.OpLog,
  retreat_set : @rle.Rle[@core.LvRange],
) -> DeleteWinner {
  let cg = oplog.causal_graph()
  let mut best_ts = 0
  let mut best_agent = ""
  let mut best_is_undelete = false
  let mut best_deleted = false
  let ops = self.get_delete_ops(target_lv)
  for op_lv in ops {
    // Skip ops in the retreat set
    if rle_contains_lv(retreat_set, op_lv) {
      continue
    }
    match oplog.get_op(op_lv) {
      Some(op) => {
        let (ts, agent) = match cg[op_lv] {
          Some(entry) => (entry.timestamp, entry.agent)
          None => continue
        }
        let is_undelete = match op.content() {
          @core.Undelete => true
          _ => false
        }
        if @fugue.should_win_delete(
            ts, agent, is_undelete, best_ts, best_agent, best_is_undelete,
          ) {
          best_ts = ts
          best_agent = agent
          best_is_undelete = is_undelete
          best_deleted = !is_undelete
        }
      }
      None => continue
    }
  }
  {
    deleted: best_deleted,
    ts: best_ts,
    agent: best_agent,
    is_undelete: best_is_undelete,
  }
}
