///| Document error types

///|
pub(all) suberror DocumentError {
  /// replica_id must be non-empty
  EmptyReplicaId
  /// Target node does not exist locally
  TargetNotFound
  /// Parent node does not exist locally or is not alive
  ParentNotFound
  /// Move would create a cycle in the tree
  CycleDetected
  /// Internal invariant violation
  Internal(detail~ : String)
}
