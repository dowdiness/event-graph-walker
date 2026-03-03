///| Undoable impl for TextDoc
///  Lives in text/ package where TextDoc's private fields are accessible.

///|
pub impl @undo.Undoable for TextDoc with lv_to_position(self, lv) {
  self.inner.lv_to_position(lv)
}

///|
pub impl @undo.Undoable for TextDoc with delete_lv(self, lv) {
  let _ = self.inner.delete_by_lv(lv) catch {
    _ => raise @undo.UndoError::ItemNotFound
  }
}

///|
pub impl @undo.Undoable for TextDoc with undelete_lv(self, lv) {
  let _ = self.inner.undelete(lv) catch {
    _ => raise @undo.UndoError::ItemNotFound
  }
}
