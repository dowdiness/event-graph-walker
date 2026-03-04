///| Fugue tree error types

///|
pub(all) suberror FugueError {
  /// Item not found in the FugueTree by LV.
  /// Indicates an out-of-order or missing operation — always a bug, not a user error.
  MissingItem(id~ : Lv)
}
