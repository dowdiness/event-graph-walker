///| Integration helpers for TextDoc + UndoManager

///|
/// Insert text and record each character's LV for undo tracking.
/// Each character is inserted individually so its LV is captured.
/// Time grouping in UndoManager batches them into a single undo group.
pub fn TextDoc::insert_and_record(
  self : TextDoc,
  pos : Pos,
  text : String,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  for i = 0; i < text.length(); i = i + 1 {
    let ch = text[i:i + 1].to_string() catch { _ => continue }
    let change = self.insert(Pos::at(pos.value() + i), ch)
    match change.target_lv(self.inner) {
      Some(lv) =>
        mgr.record_insert(lv, change.agent(), timestamp_ms, content=Some(ch))
      None => ()
    }
  }
}

///|
/// Delete a character and record its target LV for undo tracking.
/// Looks up the deleted item's content before deletion for redo display.
pub fn TextDoc::delete_and_record(
  self : TextDoc,
  pos : Pos,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  let items = self.inner.get_visible_items()
  let content : String? = if pos.value() < items.length() {
    Some(items[pos.value()].1.content)
  } else {
    None
  }
  let change = self.delete(pos)
  match change.target_lv(self.inner) {
    Some(lv) => mgr.record_delete(lv, change.agent(), timestamp_ms, content~)
    None => ()
  }
}
