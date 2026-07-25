///| Types for undo/redo tracking

///|
pub enum CompensatingEditResult {
  Applied
  Stale
} derive(Debug, Eq)

///|
pub fn CompensatingEditResult::applied() -> CompensatingEditResult {
  Applied
}

///|
pub fn CompensatingEditResult::stale() -> CompensatingEditResult {
  Stale
}

///|
pub enum UndoOpType {
  Insert
  Delete
} derive(Debug, Eq)

///|
/// A single tracked operation.
/// `target_lv` is the LV of the element being inserted/deleted (NOT the op LV).
/// For inserts: the inserted item's LV.
/// For deletes: the deleted item's LV (the tombstone to revive on undo).
struct UndoItem {
  target_lv : Int
  op_type : UndoOpType
  content : String?
} derive(Debug)

///|
/// A group of operations undone/redone together
struct UndoGroup {
  items : Array[UndoItem]
  timestamp : Int
} derive(Debug)

///|
/// Errors that can occur during undo/redo operations
pub(all) suberror UndoError {
  /// Deprecated compatibility error for legacy Undoable Adapters.
  /// New Adapters return CompensatingEditResult::Stale instead.
  ItemNotFound
  /// The document or local undo target violated an internal invariant.
  Internal(detail~ : String)
}

///|
pub fn UndoError::message(self : UndoError) -> String {
  match self {
    ItemNotFound => "Undo target is stale or already absent"
    Internal(detail~) => "Internal undo error: \{detail}"
  }
}

///|
// All undo errors are non-retryable by design.
pub fn UndoError::is_retryable(self : UndoError) -> Bool {
  ignore(self)
  false
}
