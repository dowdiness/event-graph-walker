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
fn Document::apply_block_text_op(
  self : Document,
  id : @mt.TreeNodeId,
  op : BlockTextOp,
) -> Unit raise DocumentError {
  if !self.tree.contains(id) {
    raise DocumentError::TargetNotFound
  }
  let block = self.get_or_create_text(id)
  block.apply_op(op.op)
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
    let (lv, timestamp, version) = self.next_version_with_raw()
    let parents = self.raw_parents_for_lv(lv)
    let op : BlockTextOp = {
      block: id,
      op: block.make_insert_op_at(
        pos + i,
        lv,
        ch.to_string(),
        timestamp,
        self.agent_id,
      ),
    }
    self.apply_block_text_op(id, op)
    let _ = self.record_text_op(op)
    let _ = self.record_sync_text_op({ version, parents, block: id, op: op.op })
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
  let (lv, timestamp, version) = self.next_version_with_raw()
  let parents = self.raw_parents_for_lv(lv)
  let op : BlockTextOp = {
    block: id,
    op: block.make_delete_op_at(pos, timestamp, self.agent_id),
  }
  self.apply_block_text_op(id, op)
  let _ = self.record_text_op(op)
  let _ = self.record_sync_text_op({ version, parents, block: id, op: op.op })
}

///|
/// Replace all text in a block using a deterministic delete-then-insert sequence.
///
/// This is a convenience helper, not a transaction boundary: peers syncing
/// mid-sequence may observe intermediate partial states until all generated ops
/// have arrived and been applied.
pub fn Document::replace_text(
  self : Document,
  id : @mt.TreeNodeId,
  text : String,
) -> Unit raise DocumentError {
  if !self.is_alive(id) {
    raise DocumentError::TargetNotFound
  }
  let mut remaining = self.text_len(id)
  while remaining > 0 {
    self.delete_text(id, remaining - 1)
    remaining = remaining - 1
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

///|
pub fn Document::export_text_ops(self : Document) -> Array[BlockTextOp] {
  self.text_ops.copy()
}

///|
pub fn Document::apply_remote_text_op(
  self : Document,
  op : BlockTextOp,
) -> Unit {
  if !self.record_text_op(op) {
    return
  }
  let timestamp = text_op_timestamp(op.op)
  if timestamp > self.lamport_clock {
    self.lamport_clock = timestamp
  }
  let applied = try {
    self.apply_block_text_op(op.block, op)
    true
  } catch {
    _ => false
  }
  if !applied {
    self.defer_text_op(op)
    return
  }
  self.flush_pending_text_ops(op.block)
}
