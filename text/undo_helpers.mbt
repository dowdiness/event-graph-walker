///| Integration helpers for TextDoc + UndoManager

///|
/// Insert text and record each character's LV for undo tracking.
pub fn TextDoc::insert_and_record(
  self : TextDoc,
  pos : Pos,
  text : String,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  let doc_len = self.len()
  let pos_val = pos.value()
  if pos_val > doc_len {
    raise TextError::InvalidPosition(pos=pos_val, len=doc_len)
  }
  for i = 0; i < text.length(); i = i + 1 {
    let ch = text[i:i + 1].to_string()
    let op = self.inner.insert(pos_val + i, ch) catch {
      err => raise TextError::from_document_error(err, doc_len)
    }
    mgr.record_insert(op.lv(), op.agent(), timestamp_ms, content=Some(ch))
  }
}

///|
/// Delete a character and record its target LV for undo tracking.
pub fn TextDoc::delete_and_record(
  self : TextDoc,
  pos : Pos,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  let doc_len = self.len()
  let pos_val = pos.value()
  if pos_val >= doc_len {
    raise TextError::InvalidPosition(pos=pos_val, len=doc_len)
  }
  let items = self.inner.get_visible_items()
  let content : String? = if pos_val < items.length() {
    Some(items[pos_val].1.content)
  } else {
    None
  }
  let op = self.inner.delete(pos_val) catch {
    err => raise TextError::from_document_error(err, doc_len)
  }
  match op.get_delete_target() {
    Some(raw) =>
      match self.inner.raw_to_lv(raw) {
        Some(lv) => mgr.record_delete(lv, op.agent(), timestamp_ms, content~)
        None => ()
      }
    None => ()
  }
}

///|
/// Delete a range and record the deleted LVs into the current undo group.
pub fn TextDoc::delete_range_and_record(
  self : TextDoc,
  range : Range,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  let doc_len = self.len()
  let (start, end) = checked_range_bounds(range, doc_len)
  if start == end {
    return
  }
  let items = self.inner.get_visible_items()
  try {
    self.inner.delete_range(start, end)
  } catch {
    err => raise TextError::from_document_error(err, doc_len)
  }
  let agent = self.inner.agent_id()
  for i = start; i < end; i = i + 1 {
    let (target_lv, item) = items[i]
    mgr.record_delete(target_lv.0, agent, timestamp_ms, content=Some(item.content))
  }
}

///|
/// Replace a range and record the delete+insert operations into one undo group.
pub fn TextDoc::replace_range_and_record(
  self : TextDoc,
  range : Range,
  text : String,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  self.delete_range_and_record(range, mgr, timestamp_ms~)
  self.insert_and_record(range.start, text, mgr, timestamp_ms~)
}
