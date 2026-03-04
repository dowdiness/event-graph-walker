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
  /// Remote op refers to a parent not present locally or in the batch.
  MissingRemoteParent(raw~ : @core.RawVersion)
  /// Remote frontier references an op not present locally or in the batch.
  MissingRemoteFrontier(raw~ : @core.RawVersion)
  /// Remote batch contains duplicate operations (same agent:seq appears twice).
  DuplicateOperation(raw~ : @core.RawVersion)
  /// A causal graph error occurred during operation creation or application
  CausalGraphError(error~ : @causal_graph.CausalGraphError)
}
