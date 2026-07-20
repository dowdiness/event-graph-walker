///| Document — public API for the movable-tree CRDT.
///
/// Integrates MovableTree + TreeOpLog with CausalGraph to provide
/// Lamport timestamps, version tracking, and multi-peer synchronization.

///|
/// Stable façade-owned tree node identifier.
pub(all) struct TreeNodeId {
  priv inner : @mt.TreeNodeId
} derive(Eq, Hash, Debug, Compare)

///|
/// Construct a validated non-sentinel node identifier.
pub fn TreeNodeId::TreeNodeId(
  replica_id : String,
  sequence : Int,
) -> TreeNodeId raise DocumentError {
  if replica_id == "" || sequence < 0 {
    raise DocumentError::Internal(detail="invalid tree node identity")
  }
  { inner: { agent: replica_id, counter: sequence } }
}

///|
fn TreeNodeId::from_inner(inner : @mt.TreeNodeId) -> TreeNodeId {
  { inner, }
}

///|
fn TreeNodeId::to_inner(self : TreeNodeId) -> @mt.TreeNodeId {
  self.inner
}

///|
pub fn TreeNodeId::replica_id(self : TreeNodeId) -> String {
  self.inner.agent
}

///|
pub fn TreeNodeId::sequence(self : TreeNodeId) -> Int {
  self.inner.counter
}

///|
pub fn TreeNodeId::key(self : TreeNodeId) -> String {
  internal_node_key(self.inner)
}

///|
fn internal_node_key(id : @mt.TreeNodeId) -> String {
  id.agent.length().to_string() + ":" + id.agent + ":" + id.counter.to_string()
}

///|
/// Virtual tree root.
pub let root_id : TreeNodeId = TreeNodeId::from_inner(@mt.root_id)

///|
/// Virtual trash root.
pub let trash_id : TreeNodeId = TreeNodeId::from_inner(@mt.trash_id)

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
priv struct BlockTextOp {
  block : @mt.TreeNodeId
  op : TextOp
}

///|
priv struct VersionedTreeOp {
  version : @core.RawVersion
  parents : Array[@core.RawVersion]
  op : @mt.TreeOp
}

///|
priv struct VersionedBlockTextOp {
  version : @core.RawVersion
  parents : Array[@core.RawVersion]
  block : @mt.TreeNodeId
  op : TextOp
}

///|
pub(all) struct SyncMessage {
  priv tree_ops : Array[VersionedTreeOp]
  priv text_ops : Array[VersionedBlockTextOp]
  priv encoded_size : Int?
}

///|
/// Custom constructor for an immutable sync message.
fn SyncMessage::SyncMessage(
  tree_ops : Array[VersionedTreeOp],
  text_ops : Array[VersionedBlockTextOp],
  encoded_size : Int?,
) -> SyncMessage {
  { tree_ops: tree_ops.copy(), text_ops: text_ops.copy(), encoded_size }
}

///|
/// Opaque version vector for container synchronization and checkout.
pub(all) struct Version {
  priv inner : @cg.VersionVector
} derive(Debug, Eq)

///|
fn Version::Version(inner : @cg.VersionVector) -> Version {
  { inner, }
}

///|
/// Empty document version.
pub fn Version::empty() -> Version {
  Version(@cg.VersionVector::new())
}

///|
/// Sync session bound to one document.
pub(all) struct SyncSession {
  priv document : Document
}

///|
priv enum SyncOpRecord {
  Tree(VersionedTreeOp)
  Text(VersionedBlockTextOp)
}

///|
priv enum PendingSyncOp {
  Tree(VersionedTreeOp)
  Text(VersionedBlockTextOp)
}

///|
/// Provenance of a synchronization candidate during pure preparation.
priv enum SyncCandidate {
  FromPending(SyncOpRecord)
  FromMessage(SyncOpRecord)
  FromPendingAndMessage(SyncOpRecord)
}

///|
fn SyncCandidate::raw(self : SyncCandidate) -> SyncOpRecord {
  match self {
    FromPending(record) | FromMessage(record) | FromPendingAndMessage(record) =>
      record
  }
}

///|
fn SyncCandidate::observe_message(
  self : SyncCandidate,
  record : SyncOpRecord,
) -> SyncCandidate {
  match self {
    FromPending(_) | FromPendingAndMessage(_) => FromPendingAndMessage(record)
    FromMessage(_) => FromMessage(record)
  }
}

///|
/// A fully validated, receiver-specific synchronization transition.
priv struct PreparedSync {
  applicable : Array[SyncOpRecord]
  pending : Array[SyncOpRecord]
  duplicate_operations : Int
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
  priv applied_tree_ops : Int
  priv applied_text_ops : Int
  priv duplicate_ops : Int
  priv pending_ops : Int
}

///|
pub fn SyncReport::applied_tree_operations(self : SyncReport) -> Int {
  self.applied_tree_ops
}

///|
pub fn SyncReport::applied_text_operations(self : SyncReport) -> Int {
  self.applied_text_ops
}

///|
pub fn SyncReport::duplicate_operations(self : SyncReport) -> Int {
  self.duplicate_ops
}

///|
pub fn SyncReport::pending_operations(self : SyncReport) -> Int {
  self.pending_ops
}

///|
fn text_op_timestamp(op : TextOp) -> Int {
  match op {
    Insert(insert_op) => insert_op.timestamp
    Delete(delete_op) => delete_op.timestamp
    Undelete(undelete_op) => undelete_op.timestamp
  }
}

///|
fn text_op_agent(op : TextOp) -> String {
  match op {
    Insert(insert_op) => insert_op.agent
    Delete(delete_op) => delete_op.agent
    Undelete(undelete_op) => undelete_op.agent
  }
}

///|
// Kind priority Insert < Delete < Undelete: forces stable ordering when
// timestamp, agent, and block tie across different kinds.
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
    (Insert(_), Undelete(_)) => -1
    (Delete(_), Insert(_)) => 1
    (Delete(delete_a), Delete(delete_b)) =>
      delete_a.target.compare(delete_b.target)
    (Delete(_), Undelete(_)) => -1
    (Undelete(_), Insert(_)) => 1
    (Undelete(_), Delete(_)) => 1
    (Undelete(undelete_a), Undelete(undelete_b)) =>
      undelete_a.target.compare(undelete_b.target)
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
  let block = encode_field(internal_node_key(op.block))
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
    Undelete(undelete_op) =>
      "text-undelete|" +
      block +
      "|" +
      encode_field(undelete_op.agent) +
      "|" +
      undelete_op.timestamp.to_string() +
      "|" +
      undelete_op.target.to_string()
  }
}

///|
fn raw_version_key(version : @core.RawVersion) -> String {
  version.agent.length().to_string() +
  ":" +
  version.agent +
  ":" +
  version.seq.to_string()
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
  priv undo_stack : Array[UndoGroup]
  priv redo_stack : Array[UndoGroup]
  priv mut txn_depth : Int
  priv txn_buffer : Array[UndoItem]
  priv mut tracking_enabled : Bool
  priv mut undo_execution_mode : Bool
  priv sync_limits : @sync.Limits
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
  Document::new_with_sync_limits(replica_id, @sync.Limits::default())
}

///|
/// Create a document with explicit synchronization resource limits.
pub fn Document::new_with_sync_limits(
  replica_id : String,
  limits : @sync.Limits,
) -> Document raise DocumentError {
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
    seen_ops: Map::default(),
    text_ops: [],
    seen_text_ops: Map::default(),
    sync_ops_by_version: Map::default(),
    seen_sync_versions: Map::default(),
    pending_sync_ops: [],
    pending_text_ops: Map::default(),
    property_state: Map::default(),
    blocks: Map::default(),
    undo_stack: [],
    redo_stack: [],
    txn_depth: 0,
    txn_buffer: [],
    tracking_enabled: true,
    undo_execution_mode: false,
    sync_limits: limits,
  }
}

///|
/// Return a live, read-only view of this document's causal operation graph.
///
/// The snapshot reflects later tree and block-text mutations. Values returned
/// from the snapshot own their arrays and may be retained safely.
pub fn Document::causal_snapshot(self : Document) -> @history.CausalSnapshot {
  let graph = self.graph
  @history.CausalSnapshot::CausalSnapshot(
    fn() { graph.op_count() },
    fn(lv) {
      match graph.get_entry(lv) {
        Some(entry) =>
          Some(
            @history.SnapshotEntry::SnapshotEntry(
              entry.parents,
              entry.agent,
              entry.seq,
            ),
          )
        None => None
      }
    },
    fn() { graph.get_frontier().0.copy() },
    fn(lv) { graph.children_count(lv) },
  )
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
      if self.ops.is_empty() ||
        compare_ops(self.ops[self.ops.length() - 1], op) <= 0 {
        self.ops.push(op)
      } else {
        let mut low = 0
        let mut high = self.ops.length()
        while low < high {
          let middle = low + (high - low) / 2
          if compare_ops(self.ops[middle], op) <= 0 {
            low = middle + 1
          } else {
            high = middle
          }
        }
        self.ops.insert(low, op)
      }
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
      if self.text_ops.is_empty() ||
        compare_text_ops(self.text_ops[self.text_ops.length() - 1], op) <= 0 {
        self.text_ops.push(op)
      } else {
        let mut low = 0
        let mut high = self.text_ops.length()
        while low < high {
          let middle = low + (high - low) / 2
          if compare_text_ops(self.text_ops[middle], op) <= 0 {
            low = middle + 1
          } else {
            high = middle
          }
        }
        self.text_ops.insert(low, op)
      }
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
  SyncMessage::SyncMessage(tree_ops, text_ops, None)
}

///|
fn Document::pending_text_key(_self : Document, id : @mt.TreeNodeId) -> String {
  internal_node_key(id)
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
  parent~ : TreeNodeId,
) -> TreeNodeId raise DocumentError {
  let parent = parent.to_inner()
  self.with_implicit_transaction(() => {
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
    self.record_undo_item(TreeCreate(target=id, parent~, pos=position))
    TreeNodeId::from_inner(id)
  })
}

///|
/// Create a new node immediately after a given sibling under the same parent.
///
/// The new node is inserted between `after` and the next sibling (if any).
/// Returns the id of the newly created node.
pub fn Document::create_node_after(
  self : Document,
  parent~ : TreeNodeId,
  after~ : TreeNodeId,
) -> TreeNodeId raise DocumentError {
  let parent = parent.to_inner()
  let after = after.to_inner()
  self.with_implicit_transaction(() => {
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
    self.record_undo_item(TreeCreate(target=id, parent~, pos=position))
    TreeNodeId::from_inner(id)
  })
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
/// Capture (parent, position) immediately before a forthcoming move so the
/// resulting TreeMove undo record points at the right pre-state.
fn Document::snapshot_move_state(
  self : Document,
  target : @mt.TreeNodeId,
) -> (@mt.TreeNodeId, @fi.FractionalIndex)? {
  match (self.tree.parent(target), self.tree.get_position(target)) {
    (Some(p), Some(pos)) => Some((p, pos))
    _ => None
  }
}

///|
/// Move a node to be the last child of a new parent.
pub fn Document::move_node(
  self : Document,
  target~ : TreeNodeId,
  new_parent~ : TreeNodeId,
) -> Unit raise DocumentError {
  let target = target.to_inner()
  let new_parent = new_parent.to_inner()
  self.with_implicit_transaction(() => {
    self.validate_move(target, new_parent)
    let snapshot = self.snapshot_move_state(target)
    let position = self.position_after_last_child(new_parent)
    self.emit_move_op(target, new_parent, position)
    match snapshot {
      Some((old_parent, old_pos)) =>
        self.record_undo_item(
          TreeMove(
            target~,
            old_parent~,
            old_pos~,
            new_parent~,
            new_pos=position,
          ),
        )
      None => ()
    }
  })
}

///|
/// Move a node to be immediately after a given sibling under the specified parent.
pub fn Document::move_node_after(
  self : Document,
  target~ : TreeNodeId,
  parent~ : TreeNodeId,
  after~ : TreeNodeId,
) -> Unit raise DocumentError {
  let target = target.to_inner()
  let parent = parent.to_inner()
  let after = after.to_inner()
  self.with_implicit_transaction(() => {
    self.validate_move(target, parent)
    let snapshot = self.snapshot_move_state(target)
    let position = self.position_after_sibling(parent, after)
    self.emit_move_op(target, parent, position)
    match snapshot {
      Some((old_parent, old_pos)) =>
        self.record_undo_item(
          TreeMove(
            target~,
            old_parent~,
            old_pos~,
            new_parent=parent,
            new_pos=position,
          ),
        )
      None => ()
    }
  })
}

///|
/// Move a node to be immediately before a given sibling under the specified parent.
pub fn Document::move_node_before(
  self : Document,
  target~ : TreeNodeId,
  parent~ : TreeNodeId,
  before~ : TreeNodeId,
) -> Unit raise DocumentError {
  let target = target.to_inner()
  let parent = parent.to_inner()
  let before = before.to_inner()
  self.with_implicit_transaction(() => {
    self.validate_move(target, parent)
    let snapshot = self.snapshot_move_state(target)
    let position = self.position_before_sibling(parent, before)
    self.emit_move_op(target, parent, position)
    match snapshot {
      Some((old_parent, old_pos)) =>
        self.record_undo_item(
          TreeMove(
            target~,
            old_parent~,
            old_pos~,
            new_parent=parent,
            new_pos=position,
          ),
        )
      None => ()
    }
  })
}

///|
/// Delete a node by moving it to the trash.
pub fn Document::delete_node(
  self : Document,
  target : TreeNodeId,
) -> Unit raise DocumentError {
  let target = target.to_inner()
  self.with_implicit_transaction(() => {
    if !self.tree.contains(target) {
      raise TargetNotFound
    }
    let snapshot = self.snapshot_move_state(target)
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
    match snapshot {
      Some((old_parent, old_pos)) =>
        self.record_undo_item(TreeDelete(target~, old_parent~, old_pos~))
      None => ()
    }
  })
}

///|
/// Get the children of a node, sorted by fractional index.
pub fn Document::children(
  self : Document,
  parent : TreeNodeId,
) -> Array[TreeNodeId] {
  self.tree
  .children(parent.to_inner())
  .map(fn(id) { TreeNodeId::from_inner(id) })
}

///|
/// Get the parent of a node, or None if the node doesn't exist.
pub fn Document::parent(self : Document, id : TreeNodeId) -> TreeNodeId? {
  self.tree
  .parent(id.to_inner())
  .map(fn(value) { TreeNodeId::from_inner(value) })
}

///|
/// Check whether a node is alive (exists and not in the trash).
pub fn Document::is_alive(self : Document, id : TreeNodeId) -> Bool {
  self.tree.is_alive(id.to_inner())
}

///|
/// Set a property on a node.
///
/// Silent early-return paths (missing node, LV alloc failure) skip recording
/// an undo item so the stack reflects only mutations that actually landed.
pub fn Document::set_property(
  self : Document,
  id : TreeNodeId,
  key : String,
  value : String,
) -> Unit {
  let id = id.to_inner()
  if !self.tree.contains(id) {
    return
  }
  let old_value = self.tree.get_property(id, key)
  let _result : Result[Unit, DocumentError] = try {
    self.with_implicit_transaction(() => {
      self.emit_property_op(id, key, value)
      self.record_undo_item(
        PropertySet(target=id, key~, old_value~, new_value=value),
      )
    })
    Ok(())
  } catch {
    e => Err(e)
  }
}

///|
/// Get a property from a node.
pub fn Document::get_property(
  self : Document,
  id : TreeNodeId,
  key : String,
) -> String? {
  self.tree.get_property(id.to_inner(), key)
}

///|
/// Export the full document sync payload.
///
/// Tree ops are replayed before text ops on receipt so newly-created blocks
/// exist before their text history is applied.
fn Document::export_sync_message(
  self : Document,
) -> SyncMessage raise DocumentError {
  self.versioned_sync_ops_between(
    @core.Frontier::from_array([]),
    self.graph.get_frontier(),
  )
}

///|
fn Document::get_version_vector(self : Document) -> @cg.VersionVector {
  @cg.VersionVector::from_frontier(self.graph, self.graph.get_frontier())
}

///|
fn Document::export_sync_message_since(
  self : Document,
  vv : @cg.VersionVector,
) -> SyncMessage raise DocumentError {
  for agent in vv.agents() {
    let sequence = vv.sequence_for(agent).unwrap()
    if self.graph.raw_to_lv(@core.RawVersion::new(agent, sequence)) is None {
      raise DocumentError::SyncFailed(
        @sync.Failure::MissingDependency(replica_id=agent, sequence~),
      )
    }
  }
  let from = vv.to_frontier(self.graph)
  self.versioned_sync_ops_between(from, self.graph.get_frontier())
}

///|
/// Current stable version vector.
pub fn Document::version(self : Document) -> Version {
  Version(self.get_version_vector())
}

///|
/// Obtain a synchronization session for this document.
pub fn Document::sync(self : Document) -> SyncSession {
  { document: self }
}

///|
pub fn SyncSession::export_all(
  self : SyncSession,
) -> SyncMessage raise DocumentError {
  let message = self.document.export_sync_message()
  SyncMessage::SyncMessage(message.tree_ops, message.text_ops, None)
}

///|
pub fn SyncSession::export_since(
  self : SyncSession,
  version : Version,
) -> SyncMessage raise DocumentError {
  let message = self.document.export_sync_message_since(version.inner)
  SyncMessage::SyncMessage(message.tree_ops, message.text_ops, None)
}

///|
pub fn SyncSession::apply(
  self : SyncSession,
  message : SyncMessage,
) -> SyncReport raise DocumentError {
  let limits = self.document.sync_limits
  let pending_records : Array[SyncOpRecord] = []
  for pending in self.document.pending_sync_ops {
    let record = match pending {
      Tree(op) => SyncOpRecord::Tree(op)
      Text(op) => SyncOpRecord::Text(op)
    }
    pending_records.push(record)
  }
  let prepared = prepare_container_sync(
    message,
    limits,
    self.document.sync_ops_by_version,
    pending_records,
  ) catch {
    failure => raise DocumentError::SyncFailed(failure)
  }
  // Imperative shell: PreparedSync is only constructible after validation,
  // conflict checks, cycle detection, dependency resolution, and limits.
  let mut applied_tree = 0
  let mut applied_text = 0
  for record in prepared.applicable {
    match record {
      Tree(op) => {
        if !self.document.try_apply_versioned_tree_op(op) {
          abort("prepared tree sync command was not total")
        }
        applied_tree = applied_tree + 1
      }
      Text(op) => {
        if !self.document.try_apply_versioned_text_op(op) {
          abort("prepared text sync command was not total")
        }
        applied_text = applied_text + 1
      }
    }
    let key = sync_record_key(record)
    self.document.seen_sync_versions[key] = true
    self.document.sync_ops_by_version[key] = record
  }
  let next_pending : Array[PendingSyncOp] = []
  for record in prepared.pending {
    match record {
      Tree(op) => next_pending.push(PendingSyncOp::Tree(op))
      Text(op) => next_pending.push(PendingSyncOp::Text(op))
    }
  }
  self.document.pending_sync_ops = next_pending
  {
    applied_tree_ops: applied_tree,
    applied_text_ops: applied_text,
    duplicate_ops: prepared.duplicate_operations,
    pending_ops: next_pending.length(),
  }
}

///|
pub fn SyncSession::pending_sync_count(self : SyncSession) -> Int {
  self.document.pending_sync_ops.length()
}

///|
pub fn SyncSession::clear_pending_sync(self : SyncSession) -> Unit {
  self.document.pending_sync_ops = []
}
