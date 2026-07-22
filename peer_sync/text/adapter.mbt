///|
/// Reduce a text apply report to the causal fact used by peer-sync policy.
pub fn apply_disposition(
  report : @egw_text.SyncReport,
) -> @peer_sync.ApplyDisposition {
  @peer_sync.ApplyDisposition(@egw_text.SyncReport::pending_operations(report))
}

///|
/// Classify a text error only when it belongs to peer synchronization.
/// Local construction and editing errors return `None`.
pub fn classify_error(
  error : @egw_text.TextError,
) -> @peer_sync.FailureDisposition? {
  match error {
    @egw_text.TextError::SyncFailed(failure) =>
      Some(@peer_sync.FailureDisposition(failure))
    @egw_text.TextError::VersionNotFound =>
      Some(@peer_sync.FailureDisposition::recoverable())
    @egw_text.TextError::EmptyReplicaId
    | @egw_text.TextError::InvalidPosition(_)
    | @egw_text.TextError::InvalidRange(_)
    | @egw_text.TextError::Internal(_) => None
  }
}
