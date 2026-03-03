///| Undoable impl for TextDoc
///  Lives in text/ package where TextDoc's private fields are accessible.

///|
pub impl @undo.Undoable for TextDoc with lv_to_position(self, lv) {
  self.inner.lv_to_position(lv)
}

///|
pub impl @undo.Undoable for TextDoc with delete_lv(self, lv) {
  let _ = try {
    self.inner.delete_by_lv(lv)
  } catch {
    // Fugue MissingItem: item already deleted by a concurrent op — skip silently
    @document.DocumentError::Fugue(_) => raise @undo.UndoError::ItemNotFound
    // Any other DocumentError is an internal error — propagate
    _ => raise @undo.UndoError::Internal(detail="document error during delete_lv")
  }
}

///|
pub impl @undo.Undoable for TextDoc with undelete_lv(self, lv) {
  let _ = try {
    self.inner.undelete(lv)
  } catch {
    // Fugue MissingItem: item not in tree — skip silently
    @document.DocumentError::Fugue(_) => raise @undo.UndoError::ItemNotFound
    // Any other DocumentError is an internal error — propagate
    _ => raise @undo.UndoError::Internal(detail="document error during undelete_lv")
  }
}
