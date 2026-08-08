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
    error => {
      self.invalidate_cached_version()
      let detail = TextError::from_document_error(error, self.len()).debug()
      raise @undo.UndoError::Internal(
        detail="delete_lv target_lv=\{lv}: \{detail}",
      )
    }
  }
  let outcome = map_target_edit_result(result)
  if outcome is @undo.CompensatingEditResult::Applied {
    self.invalidate_cached_version()
  }
  outcome
}

///|
pub impl @undo.Undoable for TextState with fn undelete_lv(self, lv) {
  let result = self.inner.undelete_if_deleted(lv) catch {
    error => {
      self.invalidate_cached_version()
      let detail = TextError::from_document_error(error, self.len()).debug()
      raise @undo.UndoError::Internal(
        detail="undelete_lv target_lv=\{lv}: \{detail}",
      )
    }
  }
  let outcome = map_target_edit_result(result)
  if outcome is @undo.CompensatingEditResult::Applied {
    self.invalidate_cached_version()
  }
  outcome
}
