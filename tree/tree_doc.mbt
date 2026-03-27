///| TreeDoc — public API for the movable-tree CRDT.
///
/// Integrates MovableTree + TreeOpLog with CausalGraph to provide
/// Lamport timestamps, version tracking, and multi-peer synchronization.

///|
/// Re-export the root sentinel so consumers don't need the internal package.
pub let root_id : @mt.TreeNodeId = @mt.root_id

///|
/// Re-export the trash sentinel so consumers don't need the internal package.
pub let trash_id : @mt.TreeNodeId = @mt.trash_id

///|
/// A collaborative tree document backed by the movable-tree CRDT.
///
/// Each local mutation generates a Lamport-timestamped operation that can be
/// exported and applied on remote peers for convergent replication.
pub struct TreeDoc {
  priv tree : @mt.MovableTree
  priv log : @mt.TreeOpLog
  priv graph : @cg.CausalGraph
  priv agent_id : String
  priv mut next_counter : Int
}

///|
/// Create a new empty TreeDoc owned by the given agent.
pub fn TreeDoc::new(agent_id : String) -> TreeDoc {
  {
    tree: @mt.MovableTree::new(),
    log: @mt.TreeOpLog::new(),
    graph: @cg.CausalGraph::new(),
    agent_id,
    next_counter: 0,
  }
}

///|
/// Allocate a fresh node id local to this agent and bump the counter.
fn TreeDoc::alloc_id(self : TreeDoc) -> @mt.TreeNodeId {
  let id : @mt.TreeNodeId = { agent: self.agent_id, counter: self.next_counter }
  self.next_counter = self.next_counter + 1
  id
}

///|
/// Derive a Lamport timestamp by adding a version to the causal graph.
/// Returns the timestamp from the newly created graph entry.
fn TreeDoc::next_timestamp(self : TreeDoc) -> Int {
  let frontier = self.graph.get_frontier()
  let parents = frontier.0
  let lv = self.graph.add_version(parents, self.agent_id) catch {
    _ => return 0
  }
  match self.graph.get_entry(lv) {
    Some(entry) => entry.timestamp
    None => 0
  }
}

///|
/// Compute a fractional index that sorts after the last child of the given parent.
fn TreeDoc::position_after_last_child(
  self : TreeDoc,
  parent : @mt.TreeNodeId,
) -> @fi.FractionalIndex {
  let children = self.tree.children(parent)
  if children.is_empty() {
    @fi.FractionalIndex::between(left=None, right=None)
  } else {
    let last_id = children[children.length() - 1]
    let last_pos = self.tree.get_position(last_id)
    @fi.FractionalIndex::between(left=last_pos, right=None)
  }
}

///|
/// Create a new node as the last child of the given parent.
///
/// Returns the id of the newly created node.
pub fn TreeDoc::create_node(
  self : TreeDoc,
  parent~ : @mt.TreeNodeId,
) -> @mt.TreeNodeId {
  let id = self.alloc_id()
  let timestamp = self.next_timestamp()
  let position = self.position_after_last_child(parent)
  let op : @mt.TreeMoveOp = {
    timestamp,
    target: id,
    new_parent: parent,
    position,
    agent: self.agent_id,
  }
  self.log.apply(self.tree, op)
  id
}

///|
/// Move a node to be the last child of a new parent.
pub fn TreeDoc::move_node(
  self : TreeDoc,
  target~ : @mt.TreeNodeId,
  new_parent~ : @mt.TreeNodeId,
) -> Unit {
  let timestamp = self.next_timestamp()
  let position = self.position_after_last_child(new_parent)
  let op : @mt.TreeMoveOp = {
    timestamp,
    target,
    new_parent,
    position,
    agent: self.agent_id,
  }
  self.log.apply(self.tree, op)
}

///|
/// Delete a node by moving it to the trash.
pub fn TreeDoc::delete_node(self : TreeDoc, target : @mt.TreeNodeId) -> Unit {
  let timestamp = self.next_timestamp()
  let position = self.position_after_last_child(@mt.trash_id)
  let op : @mt.TreeMoveOp = {
    timestamp,
    target,
    new_parent: @mt.trash_id,
    position,
    agent: self.agent_id,
  }
  self.log.apply(self.tree, op)
}

///|
/// Get the children of a node, sorted by fractional index.
pub fn TreeDoc::children(
  self : TreeDoc,
  parent : @mt.TreeNodeId,
) -> Array[@mt.TreeNodeId] {
  self.tree.children(parent)
}

///|
/// Check whether a node is alive (exists and not in the trash).
pub fn TreeDoc::is_alive(self : TreeDoc, id : @mt.TreeNodeId) -> Bool {
  self.tree.is_alive(id)
}

///|
/// Set a property on a node.
pub fn TreeDoc::set_property(
  self : TreeDoc,
  id : @mt.TreeNodeId,
  key : String,
  value : String,
) -> Unit {
  self.tree.set_property(id, key, value)
}

///|
/// Get a property from a node.
pub fn TreeDoc::get_property(
  self : TreeDoc,
  id : @mt.TreeNodeId,
  key : String,
) -> String? {
  self.tree.get_property(id, key)
}

///|
/// Export all operations in timestamp order, suitable for sending to a remote peer.
pub fn TreeDoc::export_ops(self : TreeDoc) -> Array[@mt.TreeMoveOp] {
  self.log.all_ops()
}

///|
/// Apply an operation received from a remote peer.
///
/// The operation is fed into both the causal graph (for version tracking)
/// and the tree op log (which handles conflict resolution via undo-do-redo).
pub fn TreeDoc::apply_remote_op(self : TreeDoc, op : @mt.TreeMoveOp) -> Unit {
  // Register the remote operation in the causal graph
  let frontier = self.graph.get_frontier()
  let parents = frontier.0
  let _ = self.graph.add_version(parents, op.agent) catch { _ => 0 }
  // Apply to the tree through the op log (handles conflict resolution)
  self.log.apply(self.tree, op)
  // Advance our counter if the remote id would collide
  if op.target.agent == self.agent_id && op.target.counter >= self.next_counter {
    self.next_counter = op.target.counter + 1
  }
}
