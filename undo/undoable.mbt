///| Undoable — interface between UndoManager and a document

///|
/// Implement this trait on a document type to make it compatible with UndoManager.
/// TextState in the text package provides the canonical implementation.
pub(open) trait Undoable {
  fn delete_lv(Self, Int) -> CompensatingEditResult raise UndoError
  fn undelete_lv(Self, Int) -> CompensatingEditResult raise UndoError
}
