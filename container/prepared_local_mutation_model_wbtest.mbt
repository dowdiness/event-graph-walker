///| Executable Phase A model for Issue #107.

///|
/// This remains test-only until a real prepared commit shell consumes it;
/// promoting an otherwise-unused wrapper would add accidental complexity.
/// The model assumes the `Document` already has exclusive process-local writer
/// ownership; its replica ID is structural identity, not a writer lease.
priv struct PreparedLocalTreeRecord {
  lv : Int
  sync : VersionedTreeOp
  undo : UndoItem
}

///|
priv struct DetachedLocalWriter {
  agent : String
  next_lv : Int
  next_seq : Int
  next_timestamp : Int
  parents : Array[@core.RawVersion]
}

///|
priv struct DetachedLocalStamp {
  lv : Int
  timestamp : Int
  version : @core.RawVersion
  parents : Array[@core.RawVersion]
}

///|
priv struct PreparedLocalMutationEvidence {
  delta_operation_count : Int
  successor_json : String
  successor_json_bytes : Int
  successor_canonical_bytes : Bytes
}

///|
priv struct PreparedLocalMutation {
  source : Document
  fence : PreparedLocalSourceSnapshot
  records : Array[PreparedLocalTreeRecord]
  evidence : PreparedLocalMutationEvidence
  mut consumed : Bool
  mut fail_before : Int?
}

///|
priv enum PreparedLocalMutationBegin {
  BeginReady(Document)
  BeginStale
  BeginConsumed
}

///|
priv enum PreparedLocalCommitResult {
  CommitAll(Int)
  CommitStale
  CommitConsumed
  CommitInterruptedBeforeMutation
  CommitPartial(Int)
}

///|
priv enum PreparedLocalRejection {
  SourceNotIdle
  SourceHasSyncPending
  SourceHasTextPending
  ParentUnavailable
}

///|
priv enum PreparedLocalPreparation {
  PreparationReady(PreparedLocalMutation)
  PreparationRejected(PreparedLocalRejection)
}

///|
priv struct PreparedLocalSourceSnapshot {
  version : Version
  full_json : String
  canonical_bytes : Bytes
  graph_operations : Int
  next_counter : Int
  lamport_clock : Int
  tree_operations : Int
  text_operations : Int
  sync_records : Int
  sync_pending : Int
  text_pending : Int
  undo_groups : Int
  redo_groups : Int
  transaction_depth : Int
  transaction_items : Int
  tracking_enabled : Bool
  undo_execution_mode : Bool
} derive(Eq)

///|
fn prepared_local_source_snapshot(
  document : Document,
) -> PreparedLocalSourceSnapshot raise DocumentError {
  let full = document.sync().export_all()
  {
    version: document.version(),
    full_json: full.to_json_string(),
    canonical_bytes: full.to_canonical_bytes(),
    graph_operations: document.graph.op_count(),
    next_counter: document.next_counter,
    lamport_clock: document.lamport_clock,
    tree_operations: document.ops.length(),
    text_operations: document.text_ops.length(),
    sync_records: document.sync_ops_by_version.length(),
    sync_pending: document.pending_sync_ops.length(),
    text_pending: document.pending_text_ops.length(),
    undo_groups: document.undo_stack.length(),
    redo_groups: document.redo_stack.length(),
    transaction_depth: document.txn_depth,
    transaction_items: document.txn_buffer.length(),
    tracking_enabled: document.tracking_enabled,
    undo_execution_mode: document.undo_execution_mode,
  }
}

///|
fn DetachedLocalWriter::from_document(
  document : Document,
) -> DetachedLocalWriter raise DocumentError {
  let frontier = document.graph.get_frontier()
  let parent_lvs = frontier.to_array()
  let parents : Array[@core.RawVersion] = []
  let mut graph_timestamp = 0
  for parent_lv in parent_lvs {
    parents.push(document.raw_version_for_lv(parent_lv))
    guard document.graph.get_entry(parent_lv) is Some(entry) else {
      raise DocumentError::Internal(
        detail="prepared local writer frontier entry is missing",
      )
    }
    graph_timestamp = graph_timestamp.max(entry.timestamp + 1)
  }
  let version_vector = @cg.VersionVector::from_frontier(
    document.graph,
    frontier,
  )
  {
    agent: document.agent_id,
    next_lv: document.graph.op_count(),
    next_seq: version_vector
    .sequence_for(document.agent_id)
    .map_or(0, sequence => sequence + 1),
    next_timestamp: graph_timestamp.max(document.lamport_clock + 1),
    parents,
  }
}

///|
fn DetachedLocalWriter::advance(
  self : DetachedLocalWriter,
) -> (DetachedLocalStamp, DetachedLocalWriter) {
  let version = @core.RawVersion::new(self.agent, self.next_seq)
  let stamp : DetachedLocalStamp = {
    lv: self.next_lv,
    timestamp: self.next_timestamp,
    version,
    parents: self.parents.copy(),
  }
  let next : DetachedLocalWriter = {
    agent: self.agent,
    next_lv: self.next_lv + 1,
    next_seq: self.next_seq + 1,
    next_timestamp: self.next_timestamp + 1,
    parents: [version],
  }
  (stamp, next)
}

///|
fn clone_prepared_tree_op(op : @mt.TreeOp) -> @mt.TreeOp {
  match op {
    @mt.Move(move_op) =>
      @mt.Move({
        timestamp: move_op.timestamp,
        target: move_op.target,
        new_parent: move_op.new_parent,
        position: @fi.FractionalIndex::new(move_op.position.elements()),
        agent: move_op.agent,
      })
    @mt.SetProperty(property) =>
      @mt.SetProperty({
        timestamp: property.timestamp,
        target: property.target,
        key: property.key,
        value: property.value,
        agent: property.agent,
      })
  }
}

///|
fn clone_prepared_versioned_tree(op : VersionedTreeOp) -> VersionedTreeOp {
  {
    version: op.version,
    parents: op.parents.copy(),
    op: clone_prepared_tree_op(op.op),
  }
}

///|
fn clone_prepared_text_op(op : TextOp) -> TextOp {
  match op {
    Insert(insert) =>
      Insert({
        id: insert.id,
        content: insert.content,
        origin_left: insert.origin_left,
        origin_right: insert.origin_right,
        timestamp: insert.timestamp,
        agent: insert.agent,
      })
    Delete(delete) =>
      Delete({
        target: delete.target,
        timestamp: delete.timestamp,
        agent: delete.agent,
      })
    Undelete(undelete) =>
      Undelete({
        target: undelete.target,
        timestamp: undelete.timestamp,
        agent: undelete.agent,
      })
  }
}

///|
fn clone_prepared_versioned_text(
  op : VersionedBlockTextOp,
) -> VersionedBlockTextOp {
  {
    version: op.version,
    parents: op.parents.copy(),
    block: op.block,
    op: clone_prepared_text_op(op.op),
  }
}

///|
fn prepared_local_successor_message(
  source : Document,
  records : ArrayView[PreparedLocalTreeRecord],
) -> SyncMessage raise DocumentError {
  let current = source.sync().export_all()
  let tree_ops : Array[VersionedTreeOp] = []
  for op in current.tree_ops {
    tree_ops.push(clone_prepared_versioned_tree(op))
  }
  for record in records {
    tree_ops.push(clone_prepared_versioned_tree(record.sync))
  }
  let text_ops : Array[VersionedBlockTextOp] = []
  for op in current.text_ops {
    text_ops.push(clone_prepared_versioned_text(op))
  }
  SyncMessage::SyncMessage(
    tree_ops,
    text_ops,
    None,
    current.op_count() + records.length(),
  ) catch {
    failure => raise DocumentError::SyncFailed(failure)
  }
}

///|
fn PreparedLocalMutation::evidence(
  self : PreparedLocalMutation,
) -> PreparedLocalMutationEvidence {
  self.evidence
}

///|
fn Document::try_prepare_tree_property_append(
  self : Document,
  parent : TreeNodeId,
  properties : ArrayView[(String, String)],
) -> PreparedLocalPreparation raise DocumentError {
  if self.txn_depth != 0 ||
    !self.txn_buffer.is_empty() ||
    !self.tracking_enabled ||
    self.undo_execution_mode {
    return PreparationRejected(SourceNotIdle)
  }
  if !self.pending_sync_ops.is_empty() {
    return PreparationRejected(SourceHasSyncPending)
  }
  if !self.pending_text_ops.is_empty() {
    return PreparationRejected(SourceHasTextPending)
  }
  let parent_inner = parent.to_inner()
  if !self.is_local_parent_valid(parent_inner) {
    return PreparationRejected(ParentUnavailable)
  }
  let node : @mt.TreeNodeId = {
    agent: self.agent_id,
    counter: self.next_counter,
  }
  let position = self.position_after_last_child(parent_inner)
  let records : Array[PreparedLocalTreeRecord] = []
  let mut writer = DetachedLocalWriter::from_document(self)
  let (create_stamp, after_create) = writer.advance()
  writer = after_create
  let create_op : @mt.TreeMoveOp = {
    timestamp: create_stamp.timestamp,
    target: node,
    new_parent: parent_inner,
    position,
    agent: self.agent_id,
  }
  records.push({
    lv: create_stamp.lv,
    sync: {
      version: create_stamp.version,
      parents: create_stamp.parents,
      op: @mt.Move(create_op),
    },
    undo: TreeCreate(target=node, parent=parent_inner, pos=position),
  })
  let prepared_values : Map[String, String] = Map::default()
  for property in properties {
    let (key, value) = property
    let (stamp, next) = writer.advance()
    writer = next
    let property_op : @mt.TreePropertyOp = {
      timestamp: stamp.timestamp,
      target: node,
      key,
      value,
      agent: self.agent_id,
    }
    let old_value = prepared_values.get(key)
    prepared_values.set(key, value)
    records.push({
      lv: stamp.lv,
      sync: {
        version: stamp.version,
        parents: stamp.parents,
        op: @mt.SetProperty(property_op),
      },
      undo: PropertySet(target=node, key~, old_value~, new_value=value),
    })
  }
  let successor = prepared_local_successor_message(self, records)
  let successor_json = successor.to_json_string()
  PreparationReady({
    source: self,
    fence: prepared_local_source_snapshot(self),
    records,
    evidence: {
      delta_operation_count: records.length(),
      successor_json,
      successor_json_bytes: @utf8.encode(successor_json).length(),
      successor_canonical_bytes: successor.to_canonical_bytes(),
    },
    consumed: false,
    fail_before: None,
  })
}

///|
fn Document::prepare_tree_property_append(
  self : Document,
  parent : TreeNodeId,
  properties : ArrayView[(String, String)],
) -> PreparedLocalMutation raise {
  match self.try_prepare_tree_property_append(parent, properties) {
    PreparationReady(capability) => capability
    PreparationRejected(_) => fail("expected prepared tree/property append")
  }
}

///|
fn PreparedLocalMutation::begin(
  self : PreparedLocalMutation,
) -> PreparedLocalMutationBegin raise DocumentError {
  if self.consumed {
    return BeginConsumed
  }
  if prepared_local_source_snapshot(self.source) != self.fence {
    return BeginStale
  }
  self.consumed = true
  BeginReady(self.source)
}

///|
fn PreparedLocalMutation::inject_failure_before(
  self : PreparedLocalMutation,
  operation_index : Int,
) -> Bool {
  if operation_index < 0 || operation_index > self.records.length() {
    return false
  }
  self.fail_before = Some(operation_index)
  true
}

///|
fn PreparedLocalMutation::commit(
  self : PreparedLocalMutation,
) -> PreparedLocalCommitResult raise DocumentError {
  let document = match self.begin() {
    BeginConsumed => return CommitConsumed
    BeginStale => return CommitStale
    BeginReady(document) => document
  }
  if self.fail_before == Some(0) {
    return CommitInterruptedBeforeMutation
  }
  document.txn_open()
  let mut committed = 0
  for record in self.records {
    if self.fail_before == Some(committed) {
      document.txn_close()
      document.clear_undo()
      return CommitPartial(committed)
    }
    let committed_sync = clone_prepared_versioned_tree(record.sync)
    let raw = committed_sync.version
    if document.graph.raw_to_lv(raw) is Some(_) ||
      document.seen_sync_versions.get(raw_version_key(raw)) == Some(true) ||
      document.graph.op_count() != record.lv ||
      !document.try_apply_versioned_tree_op(committed_sync) {
      document.txn_close()
      document.clear_undo()
      return CommitPartial(committed)
    }
    if !document.record_sync_tree_op(committed_sync) {
      // The exact precheck above ruled out this identity before the graph and
      // tree changed. Reaching this branch means the per-operation commit is
      // already internally inconsistent; returning a recoverable error would
      // let callers continue with shared state missing its sync record.
      abort("prepared local commit lost exclusive sync-record ownership")
    }
    document.record_undo_item(record.undo)
    committed = committed + 1
  }
  if self.fail_before == Some(committed) {
    document.txn_close()
    document.clear_undo()
    return CommitPartial(committed)
  }
  document.txn_close()
  CommitAll(committed)
}
