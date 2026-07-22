/// EGW-specific test edges. These are the only adapters between façade
/// reports/errors and the shared public policy vocabulary.

///|
fn text_observation(
  report : @egw_text.SyncReport,
) -> @peer_sync.ApplyDisposition {
  @peer_sync_text.apply_disposition(report)
}

///|
fn container_observation(
  report : @egw_container.SyncReport,
) -> @peer_sync.ApplyDisposition {
  @peer_sync_container.apply_disposition(report)
}

///|
fn assert_text_observation(
  report : @egw_text.SyncReport,
  applied : Int,
  duplicates : Int,
  pending : Int,
) -> Unit raise {
  @debug.assert_eq(report.applied_operations(), applied)
  @debug.assert_eq(report.duplicate_operations(), duplicates)
  @debug.assert_eq(report.pending_operations(), pending)
}

///|
fn assert_container_observation(
  report : @egw_container.SyncReport,
  applied : Int,
  duplicates : Int,
  pending : Int,
) -> Unit raise {
  @debug.assert_eq(
    report.applied_tree_operations() + report.applied_text_operations(),
    applied,
  )
  @debug.assert_eq(report.duplicate_operations(), duplicates)
  @debug.assert_eq(report.pending_operations(), pending)
}

///|
fn text_failure(error : @egw_text.TextError) -> @peer_sync.FailureDisposition? {
  @peer_sync_text.classify_error(error)
}

///|
fn container_failure(
  error : @egw_container.DocumentError,
) -> @peer_sync.FailureDisposition? {
  @peer_sync_container.classify_error(error)
}

///|
fn failure_disposition(
  failure : @sync.Failure,
) -> @peer_sync.FailureDisposition {
  @peer_sync.FailureDisposition(failure)
}
