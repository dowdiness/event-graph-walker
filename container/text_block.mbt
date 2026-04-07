///| Per-block text state machine.
///
/// Each tree node that has text content gets a TextBlock. The FugueTree
/// uses global LVs from the shared CausalGraph (Path A). Per-block arrays
/// are sparse — a block with LVs [100, 105, 200] allocates a 201-slot
/// items array. This is the accepted tradeoff for Path A simplicity.
/// Internal dense-ItemId refactoring is a future optimization.

///|
pub(all) struct TextInsertOp {
  id : Int
  content : String
  origin_left : Int?
  origin_right : Int?
  timestamp : Int
  agent : String
}

///|
pub(all) struct TextDeleteOp {
  target : Int
  timestamp : Int
  agent : String
}

///|
pub(all) enum TextOp {
  Insert(TextInsertOp)
  Delete(TextDeleteOp)
}

///|
priv struct TextBlock {
  tree : @fugue.FugueTree[String]
  mut text_cache : String?
}

///|
fn TextBlock::new() -> TextBlock {
  { tree: @fugue.FugueTree::new(), text_cache: None }
}

///|
/// Build a replayable insert operation by resolving Fugue origins from the
/// current visible items at `pos`.
fn TextBlock::make_insert_op_at(
  self : TextBlock,
  pos : Int,
  lv : Int,
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
  let origin_left : Int? = if pos == 0 {
    None
  } else {
    Some(items[pos - 1].0 .0)
  }
  let origin_right : Int? = if pos >= items.length() {
    None
  } else {
    Some(items[pos].0 .0)
  }
  Insert({ id: lv, content, origin_left, origin_right, timestamp, agent })
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
  Delete({ target: item_lv.0, timestamp: del_timestamp, agent: del_agent })
}

///|
fn TextBlock::apply_op(self : TextBlock, op : TextOp) -> Unit raise DocumentError {
  match op {
    Insert(insert_op) =>
      self.tree.insert({
        id: @fugue.Lv(insert_op.id),
        content: insert_op.content,
        origin_left: insert_op.origin_left.map(fn(id) { @fugue.Lv(id) }),
        origin_right: insert_op.origin_right.map(fn(id) { @fugue.Lv(id) }),
        timestamp: @fugue.Timestamp(insert_op.timestamp),
        agent: @fugue.ReplicaId(insert_op.agent),
      })
    Delete(delete_op) =>
      self.tree.delete_with_ts(
        @fugue.Lv(delete_op.target),
        delete_op.timestamp,
        delete_op.agent,
      ) catch {
        _ =>
          raise DocumentError::Internal(
            detail="TextBlock delete: missing item at lv=" +
              delete_op.target.to_string(),
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
