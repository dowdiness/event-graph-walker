///| Operation log error types

///|
pub(all) suberror OpLogError {
  /// A local version (LV) was not found in the graph during operation creation
  MissingLocalVersion(lv~ : Int)
  /// A remote delete operation was received without origin_left set.
  /// This indicates a malformed operation (protocol error), not missing graph state.
  /// Contrast with BranchError::MissingOrigin and DocumentError::MissingOrigin
  /// which carry the RawVersion and indicate missing graph entries.
  MissingOrigin
  /// A non-initial replica operation does not causally descend from its
  /// same-agent predecessor through declared parents.
  SequenceAncestryViolation(raw~ : @core.RawVersion)
  /// An operation origin or delete/undelete target names a non-Insert.
  OriginTargetNotInsert(
    operation~ : @core.RawVersion,
    target~ : @core.RawVersion
  )
  /// A delete or undelete carries the insert-only right-origin field.
  InvalidOriginShape(raw~ : @core.RawVersion)
  /// The complete prepared transition would retain more pending operations
  /// than the requested forecast allows. A partial commit suffix may exceed
  /// this forecast until the suffix is retried or discarded.
  PendingForecastExceeded(limit~ : Int, predicted~ : Int)
  /// Remote op refers to a parent not present locally or in the batch.
  MissingRemoteParent(raw~ : @core.RawVersion)
  /// Remote frontier references an op not present locally or in the batch.
  MissingRemoteFrontier(raw~ : @core.RawVersion)
  /// Remote batch contains duplicate operations (same agent:seq appears twice).
  DuplicateOperation(raw~ : @core.RawVersion)
  /// A RawVersion was reused for a different logical operation payload.
  ConflictingIdentity(raw~ : @core.RawVersion)
  /// A prepared admission was invalidated by another admission.
  StaleAdmission
  /// A prepared admission was committed or rejected already.
  ConsumedAdmission
  /// A prepared admission failed its internal consistency checks.
  InvalidAdmission
  /// A remote admission committed a prefix before a causal graph failure.
  PartialRemoteAdmission(
    committed~ : Array[@core.Op],
    error~ : @causal_graph.CausalGraphError
  )
  /// A causal graph error occurred during operation creation or application
  CausalGraphError(error~ : @causal_graph.CausalGraphError)
}
