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
pub struct UndoItem {
  target_lv : Int
  op_type : UndoOpType
  content : String?
} derive(Show)

///|
/// A group of operations undone/redone together
pub struct UndoGroup {
  items : Array[UndoItem]
  timestamp : Int
} derive(Show)
