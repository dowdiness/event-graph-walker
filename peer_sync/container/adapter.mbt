///|
/// Reduce a container apply report to the causal fact used by peer-sync policy.
pub fn apply_disposition(
  report : @egw_container.SyncReport,
) -> @peer_sync.ApplyDisposition {
  @peer_sync.ApplyDisposition(
    @egw_container.SyncReport::pending_operations(report),
  )
}

///|
/// Classify a container error only when it belongs to peer synchronization.
/// Local document errors return `None`.
pub fn classify_error(
  error : @egw_container.DocumentError,
) -> @peer_sync.FailureDisposition? {
  match error {
    @egw_container.DocumentError::SyncFailed(failure) =>
      Some(@peer_sync.FailureDisposition(failure))
    @egw_container.DocumentError::EmptyReplicaId
    | @egw_container.DocumentError::TargetNotFound
    | @egw_container.DocumentError::ParentNotFound
    | @egw_container.DocumentError::CycleDetected
    | @egw_container.DocumentError::Internal(_) => None
  }
}
