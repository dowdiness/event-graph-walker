///| Undo grouping data structures (private to container).
///
/// Captures a snapshot of the *pre-state* for each forward op so the undo
/// engine can synthesize the inverse later. No group id, no timestamp —
/// groups are identified by position in the undo/redo stack.

///|
priv enum UndoItem {
  TextInsert(block~ : @mt.TreeNodeId, id~ : @core.RawVersion)
  TextDelete(block~ : @mt.TreeNodeId, id~ : @core.RawVersion)
  TreeMove(
    target~ : @mt.TreeNodeId,
    old_parent~ : @mt.TreeNodeId,
    old_pos~ : @fi.FractionalIndex,
    new_parent~ : @mt.TreeNodeId,
    new_pos~ : @fi.FractionalIndex
  )
  TreeCreate(
    target~ : @mt.TreeNodeId,
    parent~ : @mt.TreeNodeId,
    pos~ : @fi.FractionalIndex
  )
  TreeDelete(
    target~ : @mt.TreeNodeId,
    old_parent~ : @mt.TreeNodeId,
    old_pos~ : @fi.FractionalIndex
  )
  PropertySet(
    target~ : @mt.TreeNodeId,
    key~ : String,
    old_value~ : String?,
    new_value~ : String
  )
}

///|
priv struct UndoGroup {
  items : Array[UndoItem]
}

///|
priv enum ReplayDirection {
  UndoPass
  RedoPass
}

///|
/// A pure replay command referring back to its source group position.
priv struct ReplayCommand {
  source_index : Int
  item : UndoItem
}

///|
fn ReplayCommand::ReplayCommand(
  source_index : Int,
  item : UndoItem,
) -> ReplayCommand {
  { source_index, item }
}

///|
/// Deterministic stack transition after an unexpected command failure.
priv struct ReplayFailureTransition {
  remaining_source : Array[UndoItem]
  completed_opposite : Array[UndoItem]
}

///|
fn ReplayFailureTransition::ReplayFailureTransition(
  remaining_source : Array[UndoItem],
  completed_opposite : Array[UndoItem],
) -> ReplayFailureTransition {
  {
    remaining_source: remaining_source.copy(),
    completed_opposite: completed_opposite.copy(),
  }
}
