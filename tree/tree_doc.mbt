///| Tree façade over the shared container replica engine.

///|
/// Stable façade-owned tree node identifier.
pub(all) struct TreeNodeId {
  priv inner : @container.TreeNodeId
} derive(Eq, Hash, Debug, Compare)

///|
/// Construct a validated non-sentinel node identifier.
pub fn TreeNodeId::TreeNodeId(
  replica_id : String,
  sequence : Int,
) -> TreeNodeId raise TreeError {
  { inner: @container.TreeNodeId::TreeNodeId(replica_id, sequence) } catch {
    _ => raise TreeError::Internal(detail="invalid tree node identity")
  }
}

///|
fn TreeNodeId::from_inner(inner : @container.TreeNodeId) -> TreeNodeId {
  { inner, }
}

///|
fn TreeNodeId::to_inner(self : TreeNodeId) -> @container.TreeNodeId {
  self.inner
}

///|
pub fn TreeNodeId::replica_id(self : TreeNodeId) -> String {
  self.inner.replica_id()
}

///|
pub fn TreeNodeId::sequence(self : TreeNodeId) -> Int {
  self.inner.sequence()
}

///|
pub fn TreeNodeId::key(self : TreeNodeId) -> String {
  self.inner.key()
}

///|
/// Virtual root node.
pub let root_id : TreeNodeId = TreeNodeId::from_inner(@container.root_id)

///|
/// Virtual trash node.
pub let trash_id : TreeNodeId = TreeNodeId::from_inner(@container.trash_id)

///|
/// Opaque tree version.
pub(all) struct Version {
  priv inner : @container.Version
} derive(Eq)

///|
fn Version::Version(inner : @container.Version) -> Version {
  { inner, }
}

///|
/// Empty tree version.
pub fn Version::empty() -> Version {
  Version(@container.Version::empty())
}

///|
/// Opaque tree sync message.
pub(all) struct SyncMessage {
  priv inner : @container.SyncMessage
  priv encoded_size : Int?
}

///|
fn SyncMessage::SyncMessage(
  inner : @container.SyncMessage,
  encoded_size : Int?,
) -> SyncMessage {
  { inner, encoded_size }
}

///|
/// Opaque tree sync report.
pub(all) struct SyncReport {
  priv inner : @container.SyncReport
}

///|
pub fn SyncReport::applied_operations(self : SyncReport) -> Int {
  self.inner.applied_tree_operations()
}

///|
pub fn SyncReport::duplicate_operations(self : SyncReport) -> Int {
  self.inner.duplicate_operations()
}

///|
pub fn SyncReport::pending_operations(self : SyncReport) -> Int {
  self.inner.pending_operations()
}

///|
/// A collaborative movable-tree replica.
pub struct TreeState {
  priv document : @container.Document
  priv sync_limits : @sync.Limits
}

///|
/// Create an empty replica.
pub fn TreeState::new(replica_id : String) -> TreeState raise TreeError {
  TreeState::new_with_sync_limits(replica_id, @sync.Limits::default())
}

///|
/// Create an empty replica with explicit sync limits.
pub fn TreeState::new_with_sync_limits(
  replica_id : String,
  limits : @sync.Limits,
) -> TreeState raise TreeError {
  {
    document: map_document_error(fn() raise @container.DocumentError {
      @container.Document::new_with_sync_limits(replica_id, limits)
    }),
    sync_limits: limits,
  }
}

///|
fn[T] map_document_error(
  action : () -> T raise @container.DocumentError,
) -> T raise TreeError {
  action() catch {
    @container.DocumentError::EmptyReplicaId => raise TreeError::EmptyReplicaId
    @container.DocumentError::TargetNotFound => raise TreeError::TargetNotFound
    @container.DocumentError::ParentNotFound => raise TreeError::ParentNotFound
    @container.DocumentError::CycleDetected => raise TreeError::CycleDetected
    @container.DocumentError::SyncFailed(failure) =>
      raise TreeError::SyncFailed(failure)
    @container.DocumentError::Internal(detail~) =>
      raise TreeError::Internal(detail~)
  }
}

///|
pub fn TreeState::create_node(
  self : TreeState,
  parent~ : TreeNodeId,
) -> TreeNodeId raise TreeError {
  TreeNodeId::from_inner(
    map_document_error(fn() raise @container.DocumentError {
      self.document.create_node(parent=parent.to_inner())
    }),
  )
}

///|
pub fn TreeState::create_node_after(
  self : TreeState,
  parent~ : TreeNodeId,
  after~ : TreeNodeId,
) -> TreeNodeId raise TreeError {
  TreeNodeId::from_inner(
    map_document_error(fn() raise @container.DocumentError {
      self.document.create_node_after(
        parent=parent.to_inner(),
        after=after.to_inner(),
      )
    }),
  )
}

///|
pub fn TreeState::move_node(
  self : TreeState,
  target~ : TreeNodeId,
  new_parent~ : TreeNodeId,
) -> Unit raise TreeError {
  map_document_error(fn() raise @container.DocumentError {
    self.document.move_node(
      target=target.to_inner(),
      new_parent=new_parent.to_inner(),
    )
  })
}

///|
pub fn TreeState::delete_node(
  self : TreeState,
  target : TreeNodeId,
) -> Unit raise TreeError {
  map_document_error(fn() raise @container.DocumentError {
    self.document.delete_node(target.to_inner())
  })
}

///|
pub fn TreeState::children(
  self : TreeState,
  parent : TreeNodeId,
) -> Array[TreeNodeId] {
  self.document
  .children(parent.to_inner())
  .map(fn(id) { TreeNodeId::from_inner(id) })
}

///|
pub fn TreeState::is_alive(self : TreeState, id : TreeNodeId) -> Bool {
  self.document.is_alive(id.to_inner())
}

///|
pub fn TreeState::set_property(
  self : TreeState,
  id : TreeNodeId,
  key : String,
  value : String,
) -> Unit {
  self.document.set_property(id.to_inner(), key, value)
}

///|
pub fn TreeState::get_property(
  self : TreeState,
  id : TreeNodeId,
  key : String,
) -> String? {
  self.document.get_property(id.to_inner(), key)
}

///|
/// Return an owning snapshot of a node's current properties, sorted by
/// MoonBit's deterministic shortlex `String` comparison.
/// Missing nodes return an empty snapshot. Nodes retained under the trash
/// sentinel keep their current properties.
pub fn TreeState::properties(
  self : TreeState,
  id : TreeNodeId,
) -> Array[(String, String)] {
  self.document.properties(id.to_inner())
}

///|
pub fn TreeState::version(self : TreeState) -> Version {
  Version(self.document.version())
}

///|
pub fn TreeState::sync(self : TreeState) -> SyncSession {
  { state: self }
}

///|
/// Tree synchronization session.
pub(all) struct SyncSession {
  priv state : TreeState
}

///|
pub fn SyncSession::export_all(
  self : SyncSession,
) -> SyncMessage raise TreeError {
  SyncMessage(
    map_document_error(fn() raise @container.DocumentError {
      self.state.document.sync().export_all()
    }),
    None,
  )
}

///|
pub fn SyncSession::export_since(
  self : SyncSession,
  version : Version,
) -> SyncMessage raise TreeError {
  SyncMessage(
    map_document_error(fn() raise @container.DocumentError {
      self.state.document.sync().export_since(version.inner)
    }),
    None,
  )
}

///|
pub fn SyncSession::apply(
  self : SyncSession,
  message : SyncMessage,
) -> SyncReport raise TreeError {
  let encoded_size = match message.encoded_size {
    Some(size) => size
    None => @utf8.encode(message.to_json_string()).length()
  }
  check_tree_encoded_size(encoded_size, self.state.sync_limits)
  {
    inner: map_document_error(fn() raise @container.DocumentError {
      self.state.document.sync().apply(message.inner)
    }),
  }
}

///|
pub fn SyncSession::pending_sync_count(self : SyncSession) -> Int {
  self.state.document.sync().pending_sync_count()
}

///|
pub fn SyncSession::clear_pending_sync(self : SyncSession) -> Unit {
  self.state.document.sync().clear_pending_sync()
}
