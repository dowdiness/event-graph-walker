///| Undoable impl for TextState
///  Lives in text/ package where TextState's private fields are accessible.

///|
fn map_target_edit_result(
  result : @document.TargetEditResult,
) -> @undo.CompensatingEditResult {
  match result {
    @document.TargetEditResult::Applied =>
      @undo.CompensatingEditResult::applied()
    @document.TargetEditResult::Stale => @undo.CompensatingEditResult::stale()
  }
}

///|
pub impl @undo.Undoable for TextState with fn delete_lv(self, lv) {
  let result = self.inner.delete_if_visible(lv) catch {
    _ =>
      raise @undo.UndoError::Internal(detail="document error during delete_lv")
  }
  map_target_edit_result(result)
}

///|
pub impl @undo.Undoable for TextState with fn undelete_lv(self, lv) {
  let result = self.inner.undelete_if_deleted(lv) catch {
    _ =>
      raise @undo.UndoError::Internal(
        detail="document error during undelete_lv",
      )
  }
  map_target_edit_result(result)
}
