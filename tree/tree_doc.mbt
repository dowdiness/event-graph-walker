///| TreeDoc — public API for the movable-tree CRDT.
///
/// Integrates MovableTree + TreeOpLog with CausalGraph to provide
/// Lamport timestamps, version tracking, and multi-peer synchronization.

///|
/// Re-export TreeNodeId so consumers don't need the internal package.
pub using @mt {type TreeNodeId}

///|
/// Re-export the root sentinel so consumers don't need the internal package.
pub let root_id : @mt.TreeNodeId = @mt.root_id

///|
/// Re-export the trash sentinel so consumers don't need the internal package.
pub let trash_id : @mt.TreeNodeId = @mt.trash_id

///|
/// Stable string key for a node id, safe to use as a Map key.
/// Format: "agent:counter".
///
/// **Important:** `agent` must not contain `:` — the JS bridge splits on the
/// last `:` to recover `{agent, counter}`. Pass `TreeDoc::new` a replica_id
/// without colons (e.g. a UUID or "user/device" with `/` separator).
pub fn tree_node_id_key(id : @mt.TreeNodeId) -> String {
  id.agent + ":" + id.counter.to_string()
}

///|
/// Equality check for node ids.
/// Use this instead of `==` when TreeNodeId's Eq impl is not visible.
pub fn tree_node_id_eq(a : @mt.TreeNodeId, b : @mt.TreeNodeId) -> Bool {
  a.agent == b.agent && a.counter == b.counter
}

///|
/// Construct a TreeNodeId from agent and counter.
/// Inverse of `tree_node_id_key`.
pub fn tree_node_id_new(agent : String, counter : Int) -> @mt.TreeNodeId {
  { agent, counter }
}

///|
/// Extract the agent field from a TreeNodeId.
pub fn tree_node_id_agent(id : @mt.TreeNodeId) -> String {
  id.agent
}

///|
/// Extract the counter field from a TreeNodeId.
pub fn tree_node_id_counter(id : @mt.TreeNodeId) -> Int {
  id.counter
}

///|
/// A collaborative tree document backed by the movable-tree CRDT.
///
/// Each local mutation generates a Lamport-timestamped operation that can be
/// exported and applied on remote peers for convergent replication.
priv struct PropertyKey {
  id : @mt.TreeNodeId
  key : String
} derive(Eq, Hash)

///|
/// Compare two replicated tree ops by Lamport timestamp, agent, and payload.
fn compare_ops(a : @mt.TreeOp, b : @mt.TreeOp) -> Int {
  let (a_timestamp, a_agent) = match a {
    @mt.Move(op) => (op.timestamp, op.agent)
    @mt.SetProperty(op) => (op.timestamp, op.agent)
  }
  let (b_timestamp, b_agent) = match b {
    @mt.Move(op) => (op.timestamp, op.agent)
    @mt.SetProperty(op) => (op.timestamp, op.agent)
  }
  let ts_cmp = a_timestamp.compare(b_timestamp)
  if ts_cmp != 0 {
    return ts_cmp
  }
  let agent_cmp = a_agent.compare(b_agent)
  if agent_cmp != 0 {
    return agent_cmp
  }
  match (a, b) {
    (@mt.Move(op_a), @mt.Move(op_b)) => {
      let target_cmp = op_a.target.compare(op_b.target)
      if target_cmp != 0 {
        return target_cmp
      }
      let parent_cmp = op_a.new_parent.compare(op_b.new_parent)
      if parent_cmp != 0 {
        return parent_cmp
      }
      op_a.position.compare(op_b.position)
    }
    (@mt.Move(_), @mt.SetProperty(_)) => -1
    (@mt.SetProperty(_), @mt.Move(_)) => 1
    (@mt.SetProperty(op_a), @mt.SetProperty(op_b)) => {
      let target_cmp = op_a.target.compare(op_b.target)
      if target_cmp != 0 {
        return target_cmp
      }
      let key_cmp = op_a.key.compare(op_b.key)
      if key_cmp != 0 {
        return key_cmp
      }
      op_a.value.compare(op_b.value)
    }
  }
}

///|
/// Length-prefix-encode a string field so it cannot be confused with a
/// separator or an adjacent field.  For example: `"foo"` → `"3:foo"`.
fn encode_field(s : String) -> String {
  s.length().to_string() + ":" + s
}

///|
/// Build a collision-safe dedup key for a replicated tree op.
///
/// Each variable-length string field is length-prefix-encoded so that no
/// combination of field values can produce the same key as a different op.
/// For example, `key="a|b", value="c"` and `key="a", value="b|c"` would
/// collide under a naive `|`-joined format but not here.
fn op_key(op : @mt.TreeOp) -> String {
  match op {
    @mt.Move(move_op) =>
      "move|" +
      encode_field(move_op.agent) +
      "|" +
      move_op.timestamp.to_string() +
      "|" +
      encode_field(move_op.target.to_string()) +
      "|" +
      encode_field(move_op.new_parent.to_string()) +
      "|" +
      encode_field(move_op.position.to_string())
    @mt.SetProperty(prop_op) =>
      "prop|" +
      encode_field(prop_op.agent) +
      "|" +
      prop_op.timestamp.to_string() +
      "|" +
      encode_field(prop_op.target.to_string()) +
      "|" +
      encode_field(prop_op.key) +
      "|" +
      encode_field(prop_op.value)
  }
}

///|
/// Compare two property ops using the document's total op ordering.
fn compare_property_ops(a : @mt.TreePropertyOp, b : @mt.TreePropertyOp) -> Int {
  compare_ops(@mt.SetProperty(a), @mt.SetProperty(b))
}

///|
pub struct TreeDoc {
  priv tree : @mt.MovableTree
  priv log : @mt.TreeOpLog
  priv graph : @cg.CausalGraph
  priv agent_id : String
  priv mut next_counter : Int
  priv mut lamport_clock : Int
  priv ops : Array[@mt.TreeOp]
  priv seen_ops : Map[String, Bool]
  priv property_state : Map[PropertyKey, @mt.TreePropertyOp]
}

///|
/// Create a new empty TreeDoc owned by the given replica.
///
/// `replica_id` must be **globally unique per replica instance** — not just per
/// user. If the same user opens the document on two devices, each device must
/// supply a distinct `replica_id` (e.g. a UUID or a "user/device" compound).
/// Reusing the same id on two replicas causes node-id collisions and silent op
/// loss during synchronization.
pub fn TreeDoc::new(replica_id : String) -> TreeDoc {
  if replica_id == "" {
    abort("TreeDoc::new: replica_id must be non-empty")
  }
  {
    tree: @mt.MovableTree::new(),
    log: @mt.TreeOpLog::new(),
    graph: @cg.CausalGraph::new(),
    agent_id: replica_id,
    next_counter: 0,
    lamport_clock: -1,
    ops: [],
    seen_ops: Map::new(),
    property_state: Map::new(),
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
  let mut graph_timestamp = self.lamport_clock + 1
  let lv = self.graph.add_version(parents, self.agent_id) catch { _ => -1 }
  if lv >= 0 {
    match self.graph.get_entry(lv) {
      Some(entry) => graph_timestamp = entry.timestamp
      None => ()
    }
  }
  let timestamp = graph_timestamp.max(self.lamport_clock + 1)
  self.lamport_clock = timestamp
  timestamp
}

///|
/// Insert a replicated op into the export history if it has not been seen yet.
fn TreeDoc::record_op(self : TreeDoc, op : @mt.TreeOp) -> Bool {
  let key = op_key(op)
  match self.seen_ops.get(key) {
    Some(true) => false
    _ => {
      self.seen_ops.set(key, true)
      let mut insert_idx = self.ops.length()
      for i = 0; i < self.ops.length(); i = i + 1 {
        if compare_ops(op, self.ops[i]) < 0 {
          insert_idx = i
          break
        }
      }
      self.ops.insert(insert_idx, op)
      true
    }
  }
}

///|
/// Re-apply the latest known property mutations to every currently-existing node.
fn TreeDoc::reapply_properties(self : TreeDoc) -> Unit {
  self.property_state.each(fn(_, op) {
    if self.tree.contains(op.target) {
      self.tree.set_property(op.target, op.key, op.value)
    }
  })
}

///|
/// Apply a property op with last-writer-wins semantics by (timestamp, agent, payload).
fn TreeDoc::apply_property_op(self : TreeDoc, op : @mt.TreePropertyOp) -> Unit {
  let prop_key : PropertyKey = { id: op.target, key: op.key }
  let should_apply = match self.property_state.get(prop_key) {
    Some(current) => compare_property_ops(current, op) < 0
    None => true
  }
  if should_apply {
    self.property_state.set(prop_key, op)
    if self.tree.contains(op.target) {
      self.tree.set_property(op.target, op.key, op.value)
    }
  }
}

///|
/// Apply a structural move op and then restore replicated properties that may
/// have been dropped by undo/redo.
fn TreeDoc::apply_move_op(self : TreeDoc, op : @mt.TreeMoveOp) -> Unit {
  self.log.apply(self.tree, op)
  self.reapply_properties()
}

///|
/// Register a remote operation in the local Lamport clock and causal graph.
fn TreeDoc::observe_remote_op(self : TreeDoc, op : @mt.TreeOp) -> Unit {
  let (timestamp, agent) = match op {
    @mt.Move(move_op) => (move_op.timestamp, move_op.agent)
    @mt.SetProperty(prop_op) => (prop_op.timestamp, prop_op.agent)
  }
  if timestamp > self.lamport_clock {
    self.lamport_clock = timestamp
  }
  let frontier = self.graph.get_frontier()
  let parents = frontier.0
  let _ = self.graph.add_version(parents, agent) catch { _ => 0 }
}

///|
/// Check whether a parent id is valid for a local structural mutation.
///
/// Only root (always live) and live tree nodes are accepted.
/// Deleted nodes (in the trash subtree) and trash_id itself are rejected —
/// callers must use `delete_node` to move nodes to trash.
fn TreeDoc::is_local_parent_valid(
  self : TreeDoc,
  parent : @mt.TreeNodeId,
) -> Bool {
  parent == @mt.root_id || self.tree.is_alive(parent)
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
/// Compute a fractional index that sorts immediately after a given sibling.
///
/// Falls back to appending after the last child when `after` is not found
/// among `parent`'s children (e.g. deleted or moved to another parent).
/// Handles equal fractional positions (from concurrent inserts) by treating
/// the sibling pair as if `after` is the last child.
fn TreeDoc::position_after_sibling(
  self : TreeDoc,
  parent : @mt.TreeNodeId,
  after : @mt.TreeNodeId,
) -> @fi.FractionalIndex {
  let children = self.tree.children(parent)
  // Find the index of `after` in the sorted children list
  let mut after_idx = -1
  for i = 0; i < children.length(); i = i + 1 {
    if children[i] == after {
      after_idx = i
      break
    }
  }
  if after_idx < 0 {
    // `after` not found among children — fall back to appending at end
    return self.position_after_last_child(parent)
  }
  let after_pos = self.tree.get_position(after)
  if after_idx == children.length() - 1 {
    // `after` is the last child — insert after it
    @fi.FractionalIndex::between(left=after_pos, right=None)
  } else {
    let next_pos = self.tree.get_position(children[after_idx + 1])
    // Guard against equal positions (concurrent inserts resolved by node id).
    // FractionalIndex::between aborts when left >= right, so fall back to
    // inserting after `after` with an open right bound.
    match (after_pos, next_pos) {
      (Some(ap), Some(np)) =>
        if ap.compare(np) >= 0 {
          @fi.FractionalIndex::between(left=Some(ap), right=None)
        } else {
          @fi.FractionalIndex::between(left=Some(ap), right=Some(np))
        }
      _ => @fi.FractionalIndex::between(left=after_pos, right=next_pos)
    }
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
  if not(self.is_local_parent_valid(parent)) {
    abort("TreeDoc::create_node: parent does not exist locally")
  }
  let id = self.alloc_id()
  let timestamp = self.next_timestamp()
  let position = self.position_after_last_child(parent)
  let move_op : @mt.TreeMoveOp = {
    timestamp,
    target: id,
    new_parent: parent,
    position,
    agent: self.agent_id,
  }
  self.apply_move_op(move_op)
  let _ = self.record_op(@mt.Move(move_op))
  id
}

///|
/// Create a new node immediately after a given sibling under the same parent.
///
/// The new node is inserted between `after` and the next sibling (if any).
/// Returns the id of the newly created node.
pub fn TreeDoc::create_node_after(
  self : TreeDoc,
  parent~ : @mt.TreeNodeId,
  after~ : @mt.TreeNodeId,
) -> @mt.TreeNodeId {
  if not(self.is_local_parent_valid(parent)) {
    abort("TreeDoc::create_node_after: parent does not exist locally")
  }
  let id = self.alloc_id()
  let timestamp = self.next_timestamp()
  let position = self.position_after_sibling(parent, after)
  let move_op : @mt.TreeMoveOp = {
    timestamp,
    target: id,
    new_parent: parent,
    position,
    agent: self.agent_id,
  }
  self.apply_move_op(move_op)
  let _ = self.record_op(@mt.Move(move_op))
  id
}

///|
/// Move a node to be the last child of a new parent.
pub fn TreeDoc::move_node(
  self : TreeDoc,
  target~ : @mt.TreeNodeId,
  new_parent~ : @mt.TreeNodeId,
) -> Unit {
  if not(self.tree.contains(target)) {
    abort("TreeDoc::move_node: target does not exist locally")
  }
  if not(self.is_local_parent_valid(new_parent)) {
    abort("TreeDoc::move_node: new parent does not exist locally")
  }
  if self.tree.would_create_cycle(target, new_parent) {
    abort("TreeDoc::move_node: move would create a cycle")
  }
  let timestamp = self.next_timestamp()
  let position = self.position_after_last_child(new_parent)
  let move_op : @mt.TreeMoveOp = {
    timestamp,
    target,
    new_parent,
    position,
    agent: self.agent_id,
  }
  self.apply_move_op(move_op)
  let _ = self.record_op(@mt.Move(move_op))
}

///|
/// Delete a node by moving it to the trash.
pub fn TreeDoc::delete_node(self : TreeDoc, target : @mt.TreeNodeId) -> Unit {
  if not(self.tree.contains(target)) {
    abort("TreeDoc::delete_node: target does not exist locally")
  }
  let timestamp = self.next_timestamp()
  let position = self.position_after_last_child(@mt.trash_id)
  let move_op : @mt.TreeMoveOp = {
    timestamp,
    target,
    new_parent: @mt.trash_id,
    position,
    agent: self.agent_id,
  }
  self.apply_move_op(move_op)
  let _ = self.record_op(@mt.Move(move_op))
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
  if not(self.tree.contains(id)) {
    return
  }
  let timestamp = self.next_timestamp()
  let op : @mt.TreePropertyOp = {
    timestamp,
    target: id,
    key,
    value,
    agent: self.agent_id,
  }
  self.apply_property_op(op)
  let _ = self.record_op(@mt.SetProperty(op))
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
pub fn TreeDoc::export_ops(self : TreeDoc) -> Array[@mt.TreeOp] {
  self.ops.copy()
}

///|
/// Apply an operation received from a remote peer.
///
/// The operation is recorded in the causal graph for local version tracking,
/// then dispatched to the structural move log or the property replication layer.
pub fn TreeDoc::apply_remote_op(self : TreeDoc, op : @mt.TreeOp) -> Unit {
  if not(self.record_op(op)) {
    return
  }
  self.observe_remote_op(op)
  match op {
    @mt.Move(move_op) => {
      self.apply_move_op(move_op)
      if move_op.target.agent == self.agent_id &&
        move_op.target.counter >= self.next_counter {
        self.next_counter = move_op.target.counter + 1
      }
    }
    @mt.SetProperty(prop_op) => {
      self.apply_property_op(prop_op)
      if prop_op.target.agent == self.agent_id &&
        prop_op.target.counter >= self.next_counter {
        self.next_counter = prop_op.target.counter + 1
      }
    }
  }
}
