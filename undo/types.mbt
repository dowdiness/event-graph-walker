///| Types for undo/redo tracking

///|
pub enum UndoOpType {
  Insert
  Delete
} derive(Show, Eq)

///|
/// A single tracked operation.
/// `target_lv` is the LV of the element being inserted/deleted (NOT the op LV).
/// For inserts: the inserted item's LV.
/// For deletes: the deleted item's LV (the tombstone to revive on undo).
struct UndoItem {
  target_lv : Int
  op_type : UndoOpType
  content : String?
} derive(Show)

///|
/// A group of operations undone/redone together
struct UndoGroup {
  items : Array[UndoItem]
  timestamp : Int
} derive(Show)

///|
/// Errors that can occur during undo/redo operations
pub(all) suberror UndoError {
  ItemNotFound
  Internal(detail~ : String)
}

///|
pub fn UndoError::message(self : UndoError) -> String {
  match self {
    ItemNotFound => "Undo target item not found in document"
    Internal(detail~) => "Internal undo error: \{detail}"
  }
}

///|
pub fn UndoError::is_retryable(self : UndoError) -> Bool {
  match self {
    ItemNotFound => false
    Internal(_) => false
  }
}
