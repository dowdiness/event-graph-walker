///| Document — public API for the movable-tree CRDT.
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
/// last `:` to recover `{agent, counter}`. Pass `Document::new` a replica_id
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
pub(all) struct BlockTextOp {
  block : @mt.TreeNodeId
  op : TextOp
}

///|
pub(all) struct VersionedTreeOp {
  version : @core.RawVersion
  parents : Array[@core.RawVersion]
  op : @mt.TreeOp
}

///|
pub(all) struct VersionedBlockTextOp {
  version : @core.RawVersion
  parents : Array[@core.RawVersion]
  block : @mt.TreeNodeId
  op : TextOp
}

///|
pub(all) struct SyncMessage {
  tree_ops : Array[VersionedTreeOp]
  text_ops : Array[VersionedBlockTextOp]
}

///|
priv enum SyncOpRecord {
  Tree(VersionedTreeOp)
  Text(VersionedBlockTextOp)
}

///|
pub(all) enum PendingSyncOp {
  Tree(VersionedTreeOp)
  Text(VersionedBlockTextOp)
}

///|
/// Summary of an `apply_remote_sync_message` call.
///
/// - `applied_tree_ops` / `applied_text_ops` count ops that landed in the
///   document state, whether on the initial pass or a later `flush_pending_sync_ops`
///   iteration.
/// - `duplicate_ops` counts ops whose version was already recorded (silent
///   idempotent skip — the frontier did not advance for them).
/// - `pending_ops` is the number of ops that remain in the sync pending queue
///   after the flush, waiting for ancestors that have not yet arrived. Inspect
///   via `Document::pending_sync_ops` when `pending_ops > 0`.
///
/// Text ops that land in the causal graph but whose target block is not yet
/// in the tree are routed to a separate per-block queue (`pending_text_ops`)
/// and are still counted as `applied_text_ops` here — that queue is an
/// internal handler-routing detail, not a sync-protocol pending state.
///
/// `applied_*_ops` reflects sync-layer version dedup, not payload-layer
/// state change. If the same op was previously ingested via the direct
/// `apply_remote_op` / `apply_remote_text_op` APIs and then arrives via a
/// sync message under a fresh version record, it will be counted as applied
/// even though the payload-level dedup makes the actual mutation a no-op.
/// Mixing direct and sync ingestion of the same op stream is therefore not
/// recommended if these counters need to mirror real state changes.
pub(all) struct SyncReport {
  applied_tree_ops : Int
  applied_text_ops : Int
  duplicate_ops : Int
  pending_ops : Int
}

///|
fn text_op_timestamp(op : TextOp) -> Int {
  match op {
    Insert(insert_op) => insert_op.timestamp
    Delete(delete_op) => delete_op.timestamp
  }
}

///|
fn text_op_agent(op : TextOp) -> String {
  match op {
    Insert(insert_op) => insert_op.agent
    Delete(delete_op) => delete_op.agent
  }
}

///|
fn compare_text_ops(a : BlockTextOp, b : BlockTextOp) -> Int {
  let ts_cmp = text_op_timestamp(a.op).compare(text_op_timestamp(b.op))
  if ts_cmp != 0 {
    return ts_cmp
  }
  let agent_cmp = text_op_agent(a.op).compare(text_op_agent(b.op))
  if agent_cmp != 0 {
    return agent_cmp
  }
  let block_cmp = a.block.compare(b.block)
  if block_cmp != 0 {
    return block_cmp
  }
  match (a.op, b.op) {
    (Insert(insert_a), Insert(insert_b)) => insert_a.id.compare(insert_b.id)
    (Insert(_), Delete(_)) => -1
    (Delete(_), Insert(_)) => 1
    (Delete(delete_a), Delete(delete_b)) =>
      delete_a.target.compare(delete_b.target)
  }
}

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
fn text_op_key(op : BlockTextOp) -> String {
  let block = encode_field(tree_node_id_key(op.block))
  match op.op {
    Insert(insert_op) =>
      "text-insert|" +
      block +
      "|" +
      encode_field(insert_op.agent) +
      "|" +
      insert_op.timestamp.to_string() +
      "|" +
      insert_op.id.to_string() +
      "|" +
      encode_field(insert_op.content)
    Delete(delete_op) =>
      "text-delete|" +
      block +
      "|" +
      encode_field(delete_op.agent) +
      "|" +
      delete_op.timestamp.to_string() +
      "|" +
      delete_op.target.to_string()
  }
}

///|
fn raw_version_key(version : @core.RawVersion) -> String {
  version.to_string()
}

///|
/// Compare two property ops using the document's total op ordering.
fn compare_property_ops(a : @mt.TreePropertyOp, b : @mt.TreePropertyOp) -> Int {
  compare_ops(@mt.SetProperty(a), @mt.SetProperty(b))
}

///|
pub struct Document {
  priv tree : @mt.MovableTree
  priv log : @mt.TreeOpLog
  priv graph : @cg.CausalGraph
  priv agent_id : String
  priv mut next_counter : Int
  priv mut lamport_clock : Int
  priv ops : Array[@mt.TreeOp]
  priv seen_ops : Map[String, Bool]
  priv text_ops : Array[BlockTextOp]
  priv seen_text_ops : Map[String, Bool]
  priv sync_ops_by_version : Map[String, SyncOpRecord]
  priv seen_sync_versions : Map[String, Bool]
  priv mut pending_sync_ops : Array[PendingSyncOp]
  priv pending_text_ops : Map[String, Array[BlockTextOp]]
  priv property_state : Map[PropertyKey, @mt.TreePropertyOp]
  priv blocks : Map[@mt.TreeNodeId, TextBlock]
}

///|
/// Create a new empty Document owned by the given replica.
///
/// `replica_id` must be **globally unique per replica instance** — not just per
/// user. If the same user opens the document on two devices, each device must
/// supply a distinct `replica_id` (e.g. a UUID or a "user/device" compound).
/// Reusing the same id on two replicas causes node-id collisions and silent op
/// loss during synchronization.
pub fn Document::new(replica_id : String) -> Document raise DocumentError {
  if replica_id == "" {
    raise EmptyReplicaId
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
    text_ops: [],
    seen_text_ops: Map::new(),
    sync_ops_by_version: Map::new(),
    seen_sync_versions: Map::new(),
    pending_sync_ops: [],
    pending_text_ops: Map::new(),
    property_state: Map::new(),
    blocks: Map::new(),
  }
}

///|
/// Allocate a fresh node id local to this agent and bump the counter.
fn Document::alloc_id(self : Document) -> @mt.TreeNodeId {
  let id : @mt.TreeNodeId = { agent: self.agent_id, counter: self.next_counter }
  self.next_counter = self.next_counter + 1
  id
}

///|
/// Allocate a new causal version. Returns (lv, timestamp).
fn Document::next_version(self : Document) -> (Int, Int) raise DocumentError {
  let frontier = self.graph.get_frontier()
  let parents = frontier.0
  let lv = self.graph.add_version(parents, self.agent_id) catch {
    _ => raise DocumentError::Internal(detail="failed to allocate LV")
  }
  let graph_timestamp = match self.graph.get_entry(lv) {
    Some(entry) => entry.timestamp
    None => self.lamport_clock + 1
  }
  let timestamp = graph_timestamp.max(self.lamport_clock + 1)
  self.lamport_clock = timestamp
  (lv, timestamp)
}

///|
fn Document::raw_version_for_lv(
  self : Document,
  lv : Int,
) -> @core.RawVersion raise DocumentError {
  match self.graph.lv_to_raw(lv) {
    Some(version) => version
    None => raise DocumentError::Internal(detail="missing raw version for lv")
  }
}

///|
fn Document::next_version_with_raw(
  self : Document,
) -> (Int, Int, @core.RawVersion) raise DocumentError {
  let (lv, timestamp) = self.next_version()
  let version = self.raw_version_for_lv(lv)
  (lv, timestamp, version)
}

///|
fn Document::raw_parents_for_lv(
  self : Document,
  lv : Int,
) -> Array[@core.RawVersion] raise DocumentError {
  let entry = match self.graph.get_entry(lv) {
    Some(entry) => entry
    None => raise DocumentError::Internal(detail="missing graph entry for lv")
  }
  let parents : Array[@core.RawVersion] = []
  for parent_lv in entry.parents {
    parents.push(self.raw_version_for_lv(parent_lv))
  }
  parents
}

///|
/// Insert a replicated op into the export history if it has not been seen yet.
fn Document::record_op(self : Document, op : @mt.TreeOp) -> Bool {
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
fn Document::record_text_op(self : Document, op : BlockTextOp) -> Bool {
  let key = text_op_key(op)
  match self.seen_text_ops.get(key) {
    Some(true) => false
    _ => {
      self.seen_text_ops.set(key, true)
      let mut insert_idx = self.text_ops.length()
      for i = 0; i < self.text_ops.length(); i = i + 1 {
        if compare_text_ops(op, self.text_ops[i]) < 0 {
          insert_idx = i
          break
        }
      }
      self.text_ops.insert(insert_idx, op)
      true
    }
  }
}

///|
fn Document::record_sync_tree_op(self : Document, op : VersionedTreeOp) -> Bool {
  let key = raw_version_key(op.version)
  match self.seen_sync_versions.get(key) {
    Some(true) => false
    _ => {
      self.seen_sync_versions.set(key, true)
      self.sync_ops_by_version[key] = Tree(op)
      true
    }
  }
}

///|
fn Document::record_sync_text_op(
  self : Document,
  op : VersionedBlockTextOp,
) -> Bool {
  let key = raw_version_key(op.version)
  match self.seen_sync_versions.get(key) {
    Some(true) => false
    _ => {
      self.seen_sync_versions.set(key, true)
      self.sync_ops_by_version[key] = Text(op)
      true
    }
  }
}

///|
fn Document::defer_pending_sync_op(self : Document, op : PendingSyncOp) -> Unit {
  self.pending_sync_ops.push(op)
}

///|
fn Document::resolve_parent_lvs(
  self : Document,
  parents : Array[@core.RawVersion],
) -> Array[Int]? {
  let resolved : Array[Int] = []
  for parent in parents {
    match self.graph.raw_to_lv(parent) {
      Some(lv) => resolved.push(lv)
      None => return None
    }
  }
  Some(resolved)
}

///|
fn Document::observe_remote_timestamp(self : Document, timestamp : Int) -> Unit {
  if timestamp > self.lamport_clock {
    self.lamport_clock = timestamp
  }
}

///|
fn Document::try_apply_versioned_tree_op(
  self : Document,
  op : VersionedTreeOp,
) -> Bool {
  let parent_lvs = match self.resolve_parent_lvs(op.parents) {
    Some(parent_lvs) => parent_lvs
    None => return false
  }
  let added = self.graph.add_version_with_seq(
    parent_lvs,
    op.version.agent,
    op.version.seq,
  ) catch {
    _ => -1
  }
  if added < 0 {
    return false
  }
  if !self.record_op(op.op) {
    return true
  }
  let timestamp = match op.op {
    @mt.Move(move_op) => move_op.timestamp
    @mt.SetProperty(prop_op) => prop_op.timestamp
  }
  self.observe_remote_timestamp(timestamp)
  match op.op {
    @mt.Move(move_op) => {
      self.apply_move_op(move_op)
      self.flush_pending_text_ops(move_op.target)
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
  true
}

///|
fn Document::try_apply_versioned_text_op(
  self : Document,
  op : VersionedBlockTextOp,
) -> Bool {
  let parent_lvs = match self.resolve_parent_lvs(op.parents) {
    Some(parent_lvs) => parent_lvs
    None => return false
  }
  let added = self.graph.add_version_with_seq(
    parent_lvs,
    op.version.agent,
    op.version.seq,
  ) catch {
    _ => -1
  }
  if added < 0 {
    return false
  }
  // The version is now in the causal graph. apply_remote_text_op may
  // internally route the op to pending_text_ops if its target block is
  // not yet present in the tree (an unusual but possible state — e.g.
  // when the op stream bypasses normal causal ordering). That is a
  // handler-internal queue, not a sync-protocol pending state, so we
  // report success once the version has been recorded.
  self.apply_remote_text_op({ block: op.block, op: op.op })
  true
}

///|
fn Document::try_apply_pending_sync_op(
  self : Document,
  op : PendingSyncOp,
) -> Bool {
  match op {
    Tree(tree_op) => self.try_apply_versioned_tree_op(tree_op)
    Text(text_op) => self.try_apply_versioned_text_op(text_op)
  }
}

///|
/// Drain pending sync ops that have become applicable and report how many
/// tree/text ops were applied during the drain.
fn Document::flush_pending_sync_ops(self : Document) -> (Int, Int) {
  let mut applied_tree = 0
  let mut applied_text = 0
  let mut progressed = true
  while progressed {
    progressed = false
    let pending = self.pending_sync_ops.copy()
    self.pending_sync_ops = []
    for op in pending {
      if self.try_apply_pending_sync_op(op) {
        progressed = true
        match op {
          Tree(_) => applied_tree = applied_tree + 1
          Text(_) => applied_text = applied_text + 1
        }
      } else {
        self.defer_pending_sync_op(op)
      }
    }
  }
  (applied_tree, applied_text)
}

///|
fn Document::versioned_sync_ops_between(
  self : Document,
  from : @core.Frontier,
  to : @core.Frontier,
) -> SyncMessage raise DocumentError {
  let (_, advance_rle) = self.graph.diff_frontiers_lvs(from, to)
  let advance_lvs = advance_rle.iter_units().collect()
  let tree_ops : Array[VersionedTreeOp] = []
  let text_ops : Array[VersionedBlockTextOp] = []
  for lv in advance_lvs {
    let version = self.raw_version_for_lv(lv)
    let key = raw_version_key(version)
    match self.sync_ops_by_version.get(key) {
      Some(Tree(op)) => tree_ops.push(op)
      Some(Text(op)) => text_ops.push(op)
      None =>
        raise DocumentError::Internal(
          detail="missing sync payload for graph version",
        )
    }
  }
  { tree_ops, text_ops }
}

///|
fn Document::pending_text_key(_self : Document, id : @mt.TreeNodeId) -> String {
  tree_node_id_key(id)
}

///|
fn Document::defer_text_op(self : Document, op : BlockTextOp) -> Unit {
  let key = self.pending_text_key(op.block)
  let pending = match self.pending_text_ops.get(key) {
    Some(existing) => existing.copy()
    None => []
  }
  let mut insert_idx = pending.length()
  for i = 0; i < pending.length(); i = i + 1 {
    if compare_text_ops(op, pending[i]) < 0 {
      insert_idx = i
      break
    }
  }
  pending.insert(insert_idx, op)
  self.pending_text_ops[key] = pending
}

///|
fn Document::flush_pending_text_ops(
  self : Document,
  id : @mt.TreeNodeId,
) -> Unit {
  let key = self.pending_text_key(id)
  let pending = match self.pending_text_ops.get(key) {
    Some(existing) => existing.copy()
    None => return
  }
  let still_pending : Array[BlockTextOp] = []
  for op in pending {
    let applied = try {
      self.apply_block_text_op(id, op)
      true
    } catch {
      _ => false
    }
    if !applied {
      still_pending.push(op)
    }
  }
  if still_pending.is_empty() {
    self.pending_text_ops.remove(key)
  } else {
    self.pending_text_ops[key] = still_pending
  }
}

///|
/// Re-apply the latest known property mutations to every currently-existing node.
fn Document::reapply_properties(self : Document) -> Unit {
  self.property_state.each(fn(_, op) {
    if self.tree.contains(op.target) {
      self.tree.set_property(op.target, op.key, op.value)
    }
  })
}

///|
/// Apply a property op with last-writer-wins semantics by (timestamp, agent, payload).
fn Document::apply_property_op(
  self : Document,
  op : @mt.TreePropertyOp,
) -> Unit {
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
fn Document::apply_move_op(self : Document, op : @mt.TreeMoveOp) -> Unit {
  self.log.apply(self.tree, op)
  self.reapply_properties()
}

///|
/// Register a remote operation in the local Lamport clock and causal graph.
fn Document::observe_remote_op(self : Document, op : @mt.TreeOp) -> Unit {
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
fn Document::is_local_parent_valid(
  self : Document,
  parent : @mt.TreeNodeId,
) -> Bool {
  parent == @mt.root_id || self.tree.is_alive(parent)
}

///|
/// Compute a fractional index that sorts after the last child of the given parent.
fn Document::position_after_last_child(
  self : Document,
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
fn Document::position_after_sibling(
  self : Document,
  parent : @mt.TreeNodeId,
  after : @mt.TreeNodeId,
) -> @fi.FractionalIndex raise DocumentError {
  let children = self.tree.children(parent)
  let mut after_idx = -1
  for i = 0; i < children.length(); i = i + 1 {
    if children[i] == after {
      after_idx = i
      break
    }
  }
  if after_idx < 0 {
    // `after` not found among children — fall back to appending at end
    // Inline rather than delegating to position_after_last_child to avoid
    // a redundant children() call (which allocates and sorts).
    if children.is_empty() {
      return @fi.FractionalIndex::between(left=None, right=None)
    }
    let last_pos = self.tree.get_position(children[children.length() - 1])
    return @fi.FractionalIndex::between(left=last_pos, right=None)
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
      _ =>
        raise Internal(
          detail="position_after_sibling: children must have positions",
        )
    }
  }
}

///|
/// Compute a fractional index that sorts immediately before a given sibling.
///
/// Falls back to inserting before the first child when `before` is not found
/// among `parent`'s children (e.g. deleted or moved to another parent).
fn Document::position_before_sibling(
  self : Document,
  parent : @mt.TreeNodeId,
  before : @mt.TreeNodeId,
) -> @fi.FractionalIndex raise DocumentError {
  let children = self.tree.children(parent)
  let mut before_idx = -1
  for i = 0; i < children.length(); i = i + 1 {
    if children[i] == before {
      before_idx = i
      break
    }
  }
  if before_idx < 0 {
    // `before` not found among children — fall back to inserting at start
    if children.is_empty() {
      return @fi.FractionalIndex::between(left=None, right=None)
    }
    let first_pos = self.tree.get_position(children[0])
    return @fi.FractionalIndex::between(left=None, right=first_pos)
  }
  let before_pos = self.tree.get_position(children[before_idx])
  if before_idx == 0 {
    // `before` is the first child — insert before it
    @fi.FractionalIndex::between(left=None, right=before_pos)
  } else {
    let prev_pos = self.tree.get_position(children[before_idx - 1])
    match (prev_pos, before_pos) {
      (Some(pp), Some(bp)) =>
        if pp.compare(bp) >= 0 {
          @fi.FractionalIndex::between(left=None, right=Some(bp))
        } else {
          @fi.FractionalIndex::between(left=Some(pp), right=Some(bp))
        }
      _ =>
        raise Internal(
          detail="position_before_sibling: children must have positions",
        )
    }
  }
}

///|
/// Create a new node as the last child of the given parent.
///
/// Returns the id of the newly created node.
pub fn Document::create_node(
  self : Document,
  parent~ : @mt.TreeNodeId,
) -> @mt.TreeNodeId raise DocumentError {
  if !self.is_local_parent_valid(parent) {
    raise ParentNotFound
  }
  let id = self.alloc_id()
  let (lv, timestamp, version) = self.next_version_with_raw()
  let parents = self.raw_parents_for_lv(lv)
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
  let _ = self.record_sync_tree_op({ version, parents, op: @mt.Move(move_op) })
  id
}

///|
/// Create a new node immediately after a given sibling under the same parent.
///
/// The new node is inserted between `after` and the next sibling (if any).
/// Returns the id of the newly created node.
pub fn Document::create_node_after(
  self : Document,
  parent~ : @mt.TreeNodeId,
  after~ : @mt.TreeNodeId,
) -> @mt.TreeNodeId raise DocumentError {
  if !self.is_local_parent_valid(parent) {
    raise ParentNotFound
  }
  let id = self.alloc_id()
  let (lv, timestamp, version) = self.next_version_with_raw()
  let parents = self.raw_parents_for_lv(lv)
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
  let _ = self.record_sync_tree_op({ version, parents, op: @mt.Move(move_op) })
  id
}

///|
/// Validate that a move operation is legal (target exists, parent valid, no cycle).
fn Document::validate_move(
  self : Document,
  target : @mt.TreeNodeId,
  new_parent : @mt.TreeNodeId,
) -> Unit raise DocumentError {
  if !self.tree.contains(target) {
    raise TargetNotFound
  }
  if !self.is_local_parent_valid(new_parent) {
    raise ParentNotFound
  }
  if self.tree.would_create_cycle(target, new_parent) {
    raise CycleDetected
  }
}

///|
/// Stamp, apply, and record a move operation.
fn Document::emit_move_op(
  self : Document,
  target : @mt.TreeNodeId,
  new_parent : @mt.TreeNodeId,
  position : @fi.FractionalIndex,
) -> Unit raise DocumentError {
  let (lv, timestamp, version) = self.next_version_with_raw()
  let parents = self.raw_parents_for_lv(lv)
  let move_op : @mt.TreeMoveOp = {
    timestamp,
    target,
    new_parent,
    position,
    agent: self.agent_id,
  }
  self.apply_move_op(move_op)
  let _ = self.record_op(@mt.Move(move_op))
  let _ = self.record_sync_tree_op({ version, parents, op: @mt.Move(move_op) })
}

///|
/// Move a node to be the last child of a new parent.
pub fn Document::move_node(
  self : Document,
  target~ : @mt.TreeNodeId,
  new_parent~ : @mt.TreeNodeId,
) -> Unit raise DocumentError {
  self.validate_move(target, new_parent)
  let position = self.position_after_last_child(new_parent)
  self.emit_move_op(target, new_parent, position)
}

///|
/// Move a node to be immediately after a given sibling under the specified parent.
pub fn Document::move_node_after(
  self : Document,
  target~ : @mt.TreeNodeId,
  parent~ : @mt.TreeNodeId,
  after~ : @mt.TreeNodeId,
) -> Unit raise DocumentError {
  self.validate_move(target, parent)
  let position = self.position_after_sibling(parent, after)
  self.emit_move_op(target, parent, position)
}

///|
/// Move a node to be immediately before a given sibling under the specified parent.
pub fn Document::move_node_before(
  self : Document,
  target~ : @mt.TreeNodeId,
  parent~ : @mt.TreeNodeId,
  before~ : @mt.TreeNodeId,
) -> Unit raise DocumentError {
  self.validate_move(target, parent)
  let position = self.position_before_sibling(parent, before)
  self.emit_move_op(target, parent, position)
}

///|
/// Delete a node by moving it to the trash.
pub fn Document::delete_node(
  self : Document,
  target : @mt.TreeNodeId,
) -> Unit raise DocumentError {
  if !self.tree.contains(target) {
    raise TargetNotFound
  }
  let (lv, timestamp, version) = self.next_version_with_raw()
  let parents = self.raw_parents_for_lv(lv)
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
  let _ = self.record_sync_tree_op({ version, parents, op: @mt.Move(move_op) })
}

///|
/// Get the children of a node, sorted by fractional index.
pub fn Document::children(
  self : Document,
  parent : @mt.TreeNodeId,
) -> Array[@mt.TreeNodeId] {
  self.tree.children(parent)
}

///|
/// Check whether a node is alive (exists and not in the trash).
pub fn Document::is_alive(self : Document, id : @mt.TreeNodeId) -> Bool {
  self.tree.is_alive(id)
}

///|
/// Set a property on a node.
pub fn Document::set_property(
  self : Document,
  id : @mt.TreeNodeId,
  key : String,
  value : String,
) -> Unit {
  if !self.tree.contains(id) {
    return
  }
  let (lv, timestamp, version) = self.next_version_with_raw() catch {
    _ => return
  }
  let parents = self.raw_parents_for_lv(lv) catch { _ => return }
  let op : @mt.TreePropertyOp = {
    timestamp,
    target: id,
    key,
    value,
    agent: self.agent_id,
  }
  self.apply_property_op(op)
  let _ = self.record_op(@mt.SetProperty(op))
  let _ = self.record_sync_tree_op({ version, parents, op: @mt.SetProperty(op) })
}

///|
/// Get a property from a node.
pub fn Document::get_property(
  self : Document,
  id : @mt.TreeNodeId,
  key : String,
) -> String? {
  self.tree.get_property(id, key)
}

///|
/// Export all operations in timestamp order, suitable for sending to a remote peer.
pub fn Document::export_ops(self : Document) -> Array[@mt.TreeOp] {
  self.ops.copy()
}

///|
/// Export the full document sync payload.
///
/// Tree ops are replayed before text ops on receipt so newly-created blocks
/// exist before their text history is applied.
pub fn Document::export_sync_message(
  self : Document,
) -> SyncMessage raise DocumentError {
  self.versioned_sync_ops_between(
    @core.Frontier::from_array([]),
    self.graph.get_frontier(),
  )
}

///|
pub fn Document::get_version_vector(self : Document) -> @cg.VersionVector {
  @cg.VersionVector::from_frontier(self.graph, self.graph.get_frontier())
}

///|
pub fn Document::export_sync_message_since(
  self : Document,
  vv : @cg.VersionVector,
) -> SyncMessage raise DocumentError {
  let from = vv.to_frontier(self.graph)
  self.versioned_sync_ops_between(from, self.graph.get_frontier())
}

///|
/// Apply an operation received from a remote peer.
///
/// The operation is recorded in the causal graph for local version tracking,
/// then dispatched to the structural move log or the property replication layer.
pub fn Document::apply_remote_op(self : Document, op : @mt.TreeOp) -> Unit {
  if !self.record_op(op) {
    return
  }
  self.observe_remote_op(op)
  match op {
    @mt.Move(move_op) => {
      self.apply_move_op(move_op)
      self.flush_pending_text_ops(move_op.target)
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

///|
/// Apply a remote sync payload in replay-safe order.
///
/// Returns a `SyncReport` summarising how many ops were applied, were
/// duplicate no-ops, or remain pending because their ancestors have not yet
/// arrived. Pending ops can be inspected via `Document::pending_sync_ops`.
pub fn Document::apply_remote_sync_message(
  self : Document,
  message : SyncMessage,
) -> SyncReport {
  let mut applied_tree = 0
  let mut applied_text = 0
  let mut duplicates = 0
  for op in message.tree_ops {
    if !self.record_sync_tree_op(op) {
      duplicates = duplicates + 1
      continue
    }
    if self.try_apply_versioned_tree_op(op) {
      applied_tree = applied_tree + 1
    } else {
      self.defer_pending_sync_op(Tree(op))
    }
  }
  for op in message.text_ops {
    if !self.record_sync_text_op(op) {
      duplicates = duplicates + 1
      continue
    }
    if self.try_apply_versioned_text_op(op) {
      applied_text = applied_text + 1
    } else {
      self.defer_pending_sync_op(Text(op))
    }
  }
  let (flushed_tree, flushed_text) = self.flush_pending_sync_ops()
  {
    applied_tree_ops: applied_tree + flushed_tree,
    applied_text_ops: applied_text + flushed_text,
    duplicate_ops: duplicates,
    pending_ops: self.pending_sync_ops.length(),
  }
}

///|
/// Snapshot of sync ops still waiting for unresolved ancestors. The returned
/// array is a copy — mutating it does not affect the document.
pub fn Document::pending_sync_ops(self : Document) -> Array[PendingSyncOp] {
  self.pending_sync_ops.copy()
}
