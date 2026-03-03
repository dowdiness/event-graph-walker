///| Minimal host API needed by UndoManager.
///  Uses only document-level types to avoid circular dependency
///  (document/ cannot import text/ since text/ already imports document/).
///  Mutating methods take `Self` (MoonBit structs are reference types).

///|
pub(open) trait Undoable {
  lv_to_position(Self, Int) -> Int?
  undelete_lv(Self, Int) -> @core.Op raise DocumentError
  delete_lv(Self, Int) -> @core.Op raise DocumentError
}
