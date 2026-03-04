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
    let ch = text[i:i + 1].to_string() catch { _ => continue }
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
