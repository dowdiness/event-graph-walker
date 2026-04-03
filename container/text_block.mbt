///| Per-block text state machine.
///
/// Each tree node that has text content gets a TextBlock. The FugueTree
/// uses global LVs from the shared CausalGraph (Path A). Per-block arrays
/// are sparse — a block with LVs [100, 105, 200] allocates a 201-slot
/// items array. This is the accepted tradeoff for Path A simplicity.
/// Internal dense-ItemId refactoring is a future optimization.

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
/// Insert a character at a visible position in this block's text.
///
/// Resolves Fugue origins (origin_left, origin_right) internally from
/// the visible items at `pos`. The caller provides only the position,
/// a global LV, and causal metadata.
fn TextBlock::insert_at(
  self : TextBlock,
  pos : Int,
  lv : Int,
  content : String,
  timestamp : Int,
  agent : String,
) -> Unit raise DocumentError {
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
  let origin_left : @fugue.Lv? = if pos == 0 {
    None
  } else {
    Some(items[pos - 1].0)
  }
  let origin_right : @fugue.Lv? = if pos >= items.length() {
    None
  } else {
    Some(items[pos].0)
  }
  self.tree.insert({
    id: @fugue.Lv(lv),
    content,
    origin_left,
    origin_right,
    timestamp: @fugue.Timestamp(timestamp),
    agent: @fugue.ReplicaId(agent),
  })
  self.text_cache = None
}

///|
/// Delete the character at a visible position in this block's text.
fn TextBlock::delete_at(
  self : TextBlock,
  pos : Int,
  del_timestamp : Int,
  del_agent : String,
) -> Unit raise DocumentError {
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
  self.tree.delete_with_ts(item_lv, del_timestamp, del_agent) catch {
    _ =>
      raise DocumentError::Internal(
        detail="TextBlock delete: missing item at lv=" + item_lv.0.to_string(),
      )
  }
  self.text_cache = None
}

///|
/// Get the current visible text of this block.
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
/// Get the visible character count.
fn TextBlock::len(self : TextBlock) -> Int {
  self.tree.visible_count()
}

///|
/// Delete all visible items by their LVs.
/// Snapshots the visible set first, then deletes each by identity.
fn TextBlock::delete_all(
  self : TextBlock,
  agent_id : String,
  alloc_timestamp : () -> Int raise DocumentError,
) -> Unit raise DocumentError {
  let visible = self.tree.get_visible_items()
  for i in 0..<visible.length() {
    let (item_lv, _) = visible[i]
    let timestamp = alloc_timestamp()
    self.tree.delete_with_ts(item_lv, timestamp, agent_id) catch {
      _ =>
        raise DocumentError::Internal(
          detail="delete_all: missing item at lv=" + item_lv.0.to_string(),
        )
    }
  }
  self.text_cache = None
}
