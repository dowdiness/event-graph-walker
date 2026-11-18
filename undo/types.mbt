///| Types for undo/redo tracking

///|
#derive(Debug, Eq)
pub enum CompensatingEditResult {
  Applied
  Stale
}

///|
pub fn CompensatingEditResult::applied() -> CompensatingEditResult {
  Applied
}

///|
pub fn CompensatingEditResult::stale() -> CompensatingEditResult {
  Stale
}

///|
#derive(Debug, Eq)
pub enum UndoOpType {
  Insert
  Delete
}

///|
/// A single tracked operation.
/// `target_lv` is the LV of the element being inserted/deleted (NOT the op LV).
/// For inserts: the inserted item's LV.
/// For deletes: the deleted item's LV (the tombstone to revive on undo).
#derive(Debug)
pub struct UndoItem {
  priv target_lv : Int32
  priv op_type : UndoOpType
  priv content : String?
}

///|
/// Track an insertion of the element at `target_lv`.
pub fn UndoItem::insert(target_lv : Int32, content : String) -> UndoItem {
  { target_lv, op_type: Insert, content: Some(content), }
}

///|
/// Track deletion of the element at `target_lv`, not the deletion operation LV.
pub fn UndoItem::delete(target_lv : Int32, content : String) -> UndoItem {
  { target_lv, op_type: Delete, content: Some(content), }
}

///|
/// A group of operations undone/redone together
#derive(Debug)
struct UndoGroup {
  items : Array[UndoItem]
  timestamp : Int32
}

///|
/// Errors that can occur during undo/redo operations
pub(all) suberror UndoError {
  /// The document or local undo target violated an internal invariant.
  Internal(detail~ : String)
}

///|
pub fn UndoError::message(self : UndoError) -> String {
  match self {
    Internal(detail~) => "Internal undo error: \{detail}"
  }
}

///|
// All undo errors are non-retryable by design.
pub fn UndoError::is_retryable(self : UndoError) -> Bool {
  ignore(self)
  false
}

// ---------------------------------------------------------------------------
// Explicit trait-method promotions (E0079).
// `#doc(hidden)` keeps these out of the generated interface while preserving
// dot-syntax and cross-package use.
// ---------------------------------------------------------------------------

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend CompensatingEditResult with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend CompensatingEditResult with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend CompensatingEditResult with Eq::{not_equal}

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend UndoGroup with @debug.Debug::{to_repr}

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend UndoItem with @debug.Debug::{to_repr}

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend UndoOpType with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend UndoOpType with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend UndoOpType with Eq::{not_equal}
