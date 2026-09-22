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
pub impl Show for TreeNodeId with fn output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
/// Sentinel identifier for the virtual root of the tree.
/// All top-level nodes are children of root.
pub let root_id : TreeNodeId = { agent: "__ROOT__", counter: -1, }

///|
/// Sentinel identifier for the trash (graveyard).
/// Nodes moved to trash are considered deleted but still exist in the tree
/// for undo/redo support.
pub let trash_id : TreeNodeId = { agent: "__TRASH__", counter: -2, }

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

// ---------------------------------------------------------------------------
// Explicit trait-method promotions (E0079).
// `#doc(hidden)` keeps these out of the generated interface while preserving
// dot-syntax and cross-package use.
// ---------------------------------------------------------------------------

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend TreeMoveOp with @debug.Debug::{to_repr}

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend TreeNodeId with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend TreeNodeId with Compare::{compare}

///|
#deprecated("Use `<` instead", skip_current_package=true)
#doc(hidden)
pub extend TreeNodeId with Compare::{op_lt}

///|
#deprecated("Use `<=` instead", skip_current_package=true)
#doc(hidden)
pub extend TreeNodeId with Compare::{op_le}

///|
#deprecated("Use `>=` instead", skip_current_package=true)
#doc(hidden)
pub extend TreeNodeId with Compare::{op_ge}

///|
#deprecated("Use `>` instead", skip_current_package=true)
#doc(hidden)
pub extend TreeNodeId with Compare::{op_gt}

///|
#doc(hidden)
pub extend TreeNodeId with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend TreeNodeId with Eq::{not_equal}

///|
#doc(hidden)
pub extend TreeNodeId with Hash::{hash}

///|
#deprecated("Use `Hash::hash_combine` via the trait instead", skip_current_package=true)
#doc(hidden)
pub extend TreeNodeId with Hash::{hash_combine}

///|
#doc(hidden)
pub extend TreeNodeId with Show::{to_string}

///|
#deprecated("Use `Show::output` via the trait or `to_string` instead", skip_current_package=true)
#doc(hidden)
pub extend TreeNodeId with Show::{output}

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend TreeOp with @debug.Debug::{to_repr}

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend TreePropertyOp with @debug.Debug::{to_repr}
