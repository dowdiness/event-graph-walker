///| Undoable impl for TextState
///  Lives in text/ package where TextState's private fields are accessible.

///|
pub impl @undo.Undoable for TextState with fn lv_to_position(self, lv) {
  self.inner.lv_to_position(lv)
}

///|
pub impl @undo.Undoable for TextState with fn delete_lv(self, lv) {
  let _ = self.inner.delete_by_lv(lv) catch {
    // A missing Fugue item violates the local undo target invariant.
    @document.DocumentError::Fugue(_) =>
      raise @undo.UndoError::Internal(
        detail="missing document item during delete_lv",
      )
    // Any other DocumentError is an internal error — propagate
    _ =>
      raise @undo.UndoError::Internal(detail="document error during delete_lv")
  }
}

///|
pub impl @undo.Undoable for TextState with fn undelete_lv(self, lv) {
  let _ = self.inner.undelete(lv) catch {
    // A missing Fugue item violates the local undo target invariant.
    @document.DocumentError::Fugue(_) =>
      raise @undo.UndoError::Internal(
        detail="missing document item during undelete_lv",
      )
    // Any other DocumentError is an internal error — propagate
    _ =>
      raise @undo.UndoError::Internal(
        detail="document error during undelete_lv",
      )
  }
}
