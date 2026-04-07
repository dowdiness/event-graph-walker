///| Core types for the movable tree CRDT.
///
/// Defines node identifiers, sentinel values (root/trash), and move operations.

///|
/// Unique identifier for a tree node, composed of an agent name and a counter.
pub(all) struct TreeNodeId {
  agent : String
  counter : Int
} derive(Eq, Hash, Debug, Compare)

///|
pub impl Show for TreeNodeId with output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
/// Sentinel identifier for the virtual root of the tree.
/// All top-level nodes are children of root.
pub let root_id : TreeNodeId = { agent: "__ROOT__", counter: -1 }

///|
/// Sentinel identifier for the trash (graveyard).
/// Nodes moved to trash are considered deleted but still exist in the tree
/// for undo/redo support.
pub let trash_id : TreeNodeId = { agent: "__TRASH__", counter: -2 }

///|
/// A timestamped move operation that relocates a node to a new parent
/// at a specific position among its siblings.
pub(all) struct TreeMoveOp {
  timestamp : Int
  target : TreeNodeId
  new_parent : TreeNodeId
  position : @fi.FractionalIndex
  agent : String
} derive(Debug)

///|
/// A timestamped property mutation on a tree node.
pub(all) struct TreePropertyOp {
  timestamp : Int
  target : TreeNodeId
  key : String
  value : String
  agent : String
} derive(Debug)

///|
/// A replicated tree operation.
pub(all) enum TreeOp {
  Move(TreeMoveOp)
  SetProperty(TreePropertyOp)
} derive(Debug)
