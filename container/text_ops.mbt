///| Text operations on Document.

///|
fn Document::get_or_create_text(
  self : Document,
  id : @mt.TreeNodeId,
) -> TextBlock {
  match self.blocks.get(id) {
    Some(block) => block
    None => {
      let block = TextBlock::new()
      self.blocks[id] = block
      block
    }
  }
}

///|
/// Insert text at the given character position in a block's text content.
pub fn Document::insert_text(
  self : Document,
  id : @mt.TreeNodeId,
  pos : Int,
  text : String,
) -> Unit raise DocumentError {
  if !self.is_alive(id) {
    raise DocumentError::TargetNotFound
  }
  let block = self.get_or_create_text(id)
  for i, ch in text {
    let (lv, timestamp) = self.next_version()
    block.insert_at(pos + i, lv, ch.to_string(), timestamp, self.agent_id)
  }
}

///|
/// Delete a character at the given position in a block's text content.
pub fn Document::delete_text(
  self : Document,
  id : @mt.TreeNodeId,
  pos : Int,
) -> Unit raise DocumentError {
  if !self.is_alive(id) {
    raise DocumentError::TargetNotFound
  }
  let block = self.get_or_create_text(id)
  let (_, timestamp) = self.next_version()
  block.delete_at(pos, timestamp, self.agent_id)
}

///|
/// Replace all text in a block atomically.
/// Snapshots visible LVs before deleting to avoid CRDT target drift.
pub fn Document::replace_text(
  self : Document,
  id : @mt.TreeNodeId,
  text : String,
) -> Unit raise DocumentError {
  if !self.is_alive(id) {
    raise DocumentError::TargetNotFound
  }
  match self.blocks.get(id) {
    Some(block) =>
      block.delete_all(self.agent_id, fn() raise DocumentError {
        let (_, timestamp) = self.next_version()
        timestamp
      })
    None => ()
  }
  if text != "" {
    self.insert_text(id, 0, text)
  }
}

///|
/// Get the text content of a block.
pub fn Document::get_text(self : Document, id : @mt.TreeNodeId) -> String {
  match self.blocks.get(id) {
    Some(block) => block.text()
    None => ""
  }
}

///|
/// Get the text length of a block.
pub fn Document::text_len(self : Document, id : @mt.TreeNodeId) -> Int {
  match self.blocks.get(id) {
    Some(block) => block.len()
    None => 0
  }
}
