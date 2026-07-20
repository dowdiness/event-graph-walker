///|
/// White-box compatibility helper for characterization tests.
fn Document::apply_remote_sync_message(
  self : Document,
  message : SyncMessage,
) -> SyncReport {
  self.sync().apply(message) catch {
    DocumentError::Internal(detail~) =>
      abort("legacy white-box sync helper: " + detail)
    _ => abort("legacy white-box sync helper received invalid input")
  }
}
