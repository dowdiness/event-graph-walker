///| One authority-owned visible-text effect in Unicode-scalar coordinates.
pub(all) enum TextEffect {
  Insert(Pos, String)
  Delete(Range)
} derive(Debug, Eq)

///| Availability of an exact incremental effect for one admission.
pub(all) enum TextEffectAvailability {
  Exact(ArrayView[TextEffect])
  SnapshotRequired
  Unavailable
}

///| Opaque settlement for one Text authority admission.
pub struct TextAdmissionTransition {
  version_before : Version
  version_after : Version
  effects : Array[TextEffect]
  availability : TextEffectAvailability
  result : Result[SyncReport, TextError]
}

///|
fn TextAdmissionTransition::new(
  version_before : Version,
  version_after : Version,
  effects : Array[TextEffect],
  availability : TextEffectAvailability,
  result : Result[SyncReport, TextError],
) -> TextAdmissionTransition {
  { version_before, version_after, effects, availability, result }
}

///|
pub fn TextAdmissionTransition::version_before(
  self : TextAdmissionTransition,
) -> Version {
  self.version_before
}

///|
pub fn TextAdmissionTransition::version_after(
  self : TextAdmissionTransition,
) -> Version {
  self.version_after
}

///|
pub fn TextAdmissionTransition::availability(
  self : TextAdmissionTransition,
) -> TextEffectAvailability {
  self.availability
}

///| Complete settlement after the consumer has reconciled derived state.
pub fn TextAdmissionTransition::finish(
  self : TextAdmissionTransition,
) -> SyncReport raise TextError {
  match self.result {
    Ok(report) => report
    Err(error) => raise error
  }
}
