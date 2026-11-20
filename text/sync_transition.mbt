///|
/// One authority-owned visible-text effect in Unicode-scalar coordinates.
#derive(Debug, Eq)
pub(all) enum TextEffect {
  Insert(Pos, String)
  Delete(Range)
}

///|
pub(all) enum TextPublication {
  Exact(Array[TextEffect])
  SnapshotRequired
  Unavailable(TextError)
}

///|
pub struct TextSyncTransition {
  priv version_before : Version
  priv version_after : Version
  priv publication : TextPublication
  priv result : Result[SyncReport, TextError]
}

///|
fn TextSyncTransition::TextSyncTransition(
  version_before : Version,
  version_after : Version,
  publication : TextPublication,
  result : Result[SyncReport, TextError],
) -> TextSyncTransition {
  { version_before, version_after, publication, result, }
}

///|
pub fn TextSyncTransition::version_before(self : TextSyncTransition) -> Version {
  self.version_before
}

///|
pub fn TextSyncTransition::version_after(self : TextSyncTransition) -> Version {
  self.version_after
}

///|
pub fn TextSyncTransition::publication(
  self : TextSyncTransition,
) -> TextPublication {
  self.publication
}

///|
/// Admission is independent of whether the editing projection can be published.
/// Return data so callers can inspect admission and publication independently.
#warnings("-result_error_return")
pub fn TextSyncTransition::admission_result(
  self : TextSyncTransition,
) -> Result[SyncReport, TextError] {
  self.result
}

///|
/// Failure can follow committed changes; reconcile effects before propagating it.
pub fn TextSyncTransition::report(
  self : TextSyncTransition,
) -> SyncReport raise TextError {
  if self.publication is Unavailable(error) {
    raise error
  }
  match self.result {
    Ok(report) => report
    Err(error) => raise error
  }
}

// --- Explicit trait-method promotions (E0079) ---

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend TextEffect with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend TextEffect with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend TextEffect with Eq::{not_equal}
