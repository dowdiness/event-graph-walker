///|
/// Package-local hooks for specifying Document admission boundaries in white-box tests.
///
/// These hooks observe boundary calls without adding counters to OpLog or
/// Document state. The optional causal failure hook is consumed only by the
/// future typed batch shell's injectable commit seam.
priv struct AdmissionBoundaryHooks {
  on_prepare_remote : () -> Unit
  on_commit_admission : () -> Unit
  on_projection_finalization : (ArrayView[@core.Op]) -> Unit
  commit_failure : ((@core.Op) -> @causal_graph.CausalGraphError?)?
}

///|
fn Document::set_admission_hooks(
  self : Document,
  hooks : AdmissionBoundaryHooks,
) -> Unit {
  self.admission_hooks = Some(hooks)
}

///|
fn Document::observe_prepare_remote(self : Document) -> Unit {
  match self.admission_hooks {
    Some(hooks) => (hooks.on_prepare_remote)()
    None => ()
  }
}

///|
fn Document::observe_commit_admission(self : Document) -> Unit {
  match self.admission_hooks {
    Some(hooks) => (hooks.on_commit_admission)()
    None => ()
  }
}

///|
fn Document::observe_projection_finalization(
  self : Document,
  committed : ArrayView[@core.Op],
) -> Unit {
  match self.admission_hooks {
    Some(hooks) => (hooks.on_projection_finalization)(committed)
    None => ()
  }
}

///|
fn Document::admission_commit_failure(
  self : Document,
) -> ((@core.Op) -> @causal_graph.CausalGraphError?)? {
  match self.admission_hooks {
    Some(hooks) => hooks.commit_failure
    None => None
  }
}
