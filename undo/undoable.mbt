///| Undoable — interface between UndoManager and a document

///|
/// Implement this trait on a document type to make it compatible with UndoManager.
/// TextState in the text package provides the canonical implementation.
pub(open) trait Undoable {
  lv_to_position(Self, Int) -> Int?
  delete_lv(Self, Int) -> Unit raise UndoError
  undelete_lv(Self, Int) -> Unit raise UndoError
}
