///| Undo grouping data structures (private to container).
///
/// Captures a snapshot of the *pre-state* for each forward op so the undo
/// engine can synthesize the inverse later. No group id, no timestamp —
/// groups are identified by position in the undo/redo stack.

///|
priv enum UndoItem {
  TextInsert(block~ : @mt.TreeNodeId, lv~ : Int, content~ : String)
  TextDelete(block~ : @mt.TreeNodeId, lv~ : Int, content~ : String)
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
} derive(Debug)

///|
priv struct UndoGroup {
  items : Array[UndoItem]
} derive(Debug)
