///| Explicit state of an item during merge operations.
///
/// During eg-walker's merge phase, each item passes through states that
/// track whether its insert operation has been applied in the current
/// traversal. This replaces the implicit `is_activated` boolean with a
/// richer four-state model that correctly handles retreat/advance cycles.

///|
pub enum ItemState {
  NotInserted
  Inserted
  Deleted
  Retreated
} derive(Debug, Eq)

///|
pub impl Show for ItemState with output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
pub impl Default for ItemState with default() -> ItemState {
  Inserted
}

///|
/// Retreat an insert operation: the item becomes invisible regardless of
/// its current state (Inserted or Deleted both collapse to Retreated).
pub fn ItemState::retreat_insert(self : ItemState) -> ItemState {
  ignore(self)
  Retreated
}

///|
/// Advance (re-apply) an insert operation: the item becomes Inserted
/// regardless of whether it was NotInserted or Retreated.
pub fn ItemState::advance_insert(self : ItemState) -> ItemState {
  ignore(self)
  Inserted
}

///|
/// Update state based on the current delete count.
///
/// Only meaningful for items that are currently Inserted or Deleted:
/// - Inserted with delete_count > 0 transitions to Deleted
/// - Deleted with delete_count == 0 transitions to Inserted
/// - Retreated and NotInserted are unaffected by delete operations
pub fn ItemState::update_from_delete_count(
  self : ItemState,
  delete_count : Int,
) -> ItemState {
  match self {
    Inserted => if delete_count > 0 { Deleted } else { Inserted }
    Deleted => if delete_count == 0 { Inserted } else { Deleted }
    Retreated => Retreated
    NotInserted => NotInserted
  }
}

///|
/// Check if the item is currently visible in the document.
///
/// An item is visible only when it is in the Inserted state AND has
/// no active delete operations (delete_count == 0).
pub fn ItemState::is_visible(self : ItemState, delete_count~ : Int) -> Bool {
  self == Inserted && delete_count == 0
}
