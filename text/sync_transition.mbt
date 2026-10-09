///|
/// One authority-owned visible-text effect in Unicode-scalar coordinates.
pub(all) enum TextEffect {
  Insert(Pos, String)
  Delete(Range)
} derive(Debug, Eq)

///|
pub(all) enum TextEffectAvailability {
  Exact(ArrayView[TextEffect])
  SnapshotRequired
  Unavailable
}

///|
pub struct TextSyncTransition {
  priv version_before : Version
  priv version_after : Version
  priv effects : Array[TextEffect]
  priv availability : TextEffectAvailability
  priv result : Result[SyncReport, TextError]
}

///|
fn TextSyncTransition::TextSyncTransition(
  version_before : Version,
  version_after : Version,
  effects : Array[TextEffect],
  availability : TextEffectAvailability,
  result : Result[SyncReport, TextError],
) -> TextSyncTransition {
  { version_before, version_after, effects, availability, result, }
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
pub fn TextSyncTransition::effect_availability(
  self : TextSyncTransition,
) -> TextEffectAvailability {
  // Keep the transition-owned backing storage live for the returned view.
  ignore(self.effects)
  self.availability
}

///|
/// Failure can follow committed changes; reconcile effects before propagating it.
pub fn TextSyncTransition::report(
  self : TextSyncTransition,
) -> SyncReport raise TextError {
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
