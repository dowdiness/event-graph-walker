///| Per-block text state machine.
///
/// Each tree node that has text content gets a TextBlock. The FugueTree
/// uses global LVs from the shared CausalGraph (Path A). Per-block arrays
/// are sparse — a block with LVs [100, 105, 200] allocates a 201-slot
/// items array. This is the accepted tradeoff for Path A simplicity.
/// Internal dense-ItemId refactoring is a future optimization.

///|
priv struct TextInsertOp {
  id : @core.RawVersion
  content : String
  origin_left : @core.RawVersion?
  origin_right : @core.RawVersion?
  timestamp : Int
  agent : String
}

///|
priv struct TextDeleteOp {
  target : @core.RawVersion
  timestamp : Int
  agent : String
}

///|
priv struct TextUndeleteOp {
  target : @core.RawVersion
  timestamp : Int
  agent : String
}

///|
priv enum TextOp {
  Insert(TextInsertOp)
  Delete(TextDeleteOp)
  Undelete(TextUndeleteOp)
}

///|
priv struct TextBlock {
  tree : @fugue.FugueTree[String]
  stable_to_local : Map[@core.RawVersion, Int]
  local_to_stable : Map[Int, @core.RawVersion]
  mut next_local_id : Int
  mut text_cache : String?
}

///|
fn TextBlock::new() -> TextBlock {
  {
    tree: @fugue.FugueTree::new(),
    stable_to_local: Map::default(),
    local_to_stable: Map::default(),
    next_local_id: 0,
    text_cache: None,
  }
}

///|
fn TextBlock::stable_for_local(
  self : TextBlock,
  local_id : Int,
) -> @core.RawVersion raise DocumentError {
  match self.local_to_stable.get(local_id) {
    Some(id) => id
    None =>
      raise DocumentError::Internal(
        detail="TextBlock missing stable identity for local item",
      )
  }
}

///|
fn TextBlock::local_for_stable(
  self : TextBlock,
  stable_id : @core.RawVersion,
) -> Int raise DocumentError {
  match self.stable_to_local.get(stable_id) {
    Some(id) => id
    None =>
      raise DocumentError::Internal(
        detail="TextBlock missing local item for stable identity " +
          stable_id.to_string(),
      )
  }
}

///|
/// Build a replayable insert operation by resolving Fugue origins from the
/// current visible items at `pos`.
fn TextBlock::make_insert_op_at(
  self : TextBlock,
  pos : Int,
  id : @core.RawVersion,
  content : String,
  timestamp : Int,
  agent : String,
) -> TextOp raise DocumentError {
  let len = self.tree.visible_count()
  if pos < 0 || pos > len {
    raise DocumentError::Internal(
      detail="TextBlock insert_at: position " +
        pos.to_string() +
        " out of bounds (len=" +
        len.to_string() +
        ")",
    )
  }
  let items = self.tree.get_visible_items()
  let origin_left : @core.RawVersion? = if pos == 0 {
    None
  } else {
    Some(self.stable_for_local(items[pos - 1].0.0))
  }
  let origin_right : @core.RawVersion? = if pos >= items.length() {
    None
  } else {
    Some(self.stable_for_local(items[pos].0.0))
  }
  Insert({ id, content, origin_left, origin_right, timestamp, agent })
}

///|
/// Build a replayable delete operation for the currently visible item at `pos`.
fn TextBlock::make_delete_op_at(
  self : TextBlock,
  pos : Int,
  del_timestamp : Int,
  del_agent : String,
) -> TextOp raise DocumentError {
  let items = self.tree.get_visible_items()
  if pos < 0 || pos >= items.length() {
    raise DocumentError::Internal(
      detail="TextBlock delete_at: position " +
        pos.to_string() +
        " out of bounds (len=" +
        items.length().to_string() +
        ")",
    )
  }
  let (item_lv, _) = items[pos]
  Delete({
    target: self.stable_for_local(item_lv.0),
    timestamp: del_timestamp,
    agent: del_agent,
  })
}

///|
fn TextBlock::apply_op(
  self : TextBlock,
  op : TextOp,
) -> Unit raise DocumentError {
  match op {
    Insert(insert_op) => {
      if self.stable_to_local.get(insert_op.id) is Some(_) {
        return
      }
      let local_id = self.next_local_id
      self.next_local_id = self.next_local_id + 1
      let origin_left = match insert_op.origin_left {
        Some(id) => Some(@fugue.Lv(self.local_for_stable(id)))
        None => None
      }
      let origin_right = match insert_op.origin_right {
        Some(id) => Some(@fugue.Lv(self.local_for_stable(id)))
        None => None
      }
      self.stable_to_local[insert_op.id] = local_id
      self.local_to_stable[local_id] = insert_op.id
      self.tree.insert({
        id: @fugue.Lv(local_id),
        content: insert_op.content,
        origin_left,
        origin_right,
        timestamp: @fugue.Timestamp(insert_op.timestamp),
        agent: @fugue.ReplicaId(insert_op.agent),
      })
    }
    Delete(delete_op) =>
      self.tree.delete_with_ts(
        @fugue.Lv(self.local_for_stable(delete_op.target)),
        delete_op.timestamp,
        delete_op.agent,
      ) catch {
        _ =>
          raise DocumentError::Internal(
            detail="TextBlock delete: missing item at lv=" +
              delete_op.target.to_string(),
          )
      }
    Undelete(undelete_op) =>
      self.tree.undelete_with_ts(
        @fugue.Lv(self.local_for_stable(undelete_op.target)),
        undelete_op.timestamp,
        undelete_op.agent,
      ) catch {
        _ =>
          raise DocumentError::Internal(
            detail="TextBlock undelete: missing item at lv=" +
              undelete_op.target.to_string(),
          )
      }
  }
  self.text_cache = None
}

///|
fn TextBlock::text(self : TextBlock) -> String {
  match self.text_cache {
    Some(cached) => cached
    None => {
      let text = self.tree.to_text()
      self.text_cache = Some(text)
      text
    }
  }
}

///|
fn TextBlock::len(self : TextBlock) -> Int {
  self.tree.visible_count()
}
