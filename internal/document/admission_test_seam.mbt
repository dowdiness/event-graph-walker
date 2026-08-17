///|
/// Package-local hooks for specifying Document admission boundaries in white-box tests.
///
/// These hooks observe boundary calls without adding counters to OpLog or
/// Document state. The optional lifecycle and recovery hooks are consumed only
/// by the future typed batch shell's injectable test seam.
#warnings("-struct_never_constructed")
priv struct AdmissionBoundaryHooks {
  on_prepare_remote : () -> Unit
  on_commit_admission : () -> Unit
  on_projection_finalization : (ArrayView[@core.Op]) -> Unit
  prepare_override : ((Array[@core.Op]) -> @oplog.PreparedAdmission raise @oplog.OpLogError)?
  commit_failure : ((@core.Op) -> @causal_graph.CausalGraphError?)?
  projection_failure : ((ArrayView[@core.Op]) -> DocumentError?)?
  recovery_checkout : ((@core.Frontier) -> @branch.Branch raise @branch.BranchError)?
}

///|
#warnings("-unused_value")
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

///|
fn Document::admission_prepare_override(
  self : Document,
) -> ((Array[@core.Op]) -> @oplog.PreparedAdmission raise @oplog.OpLogError)? {
  match self.admission_hooks {
    Some(hooks) => hooks.prepare_override
    None => None
  }
}

///|
fn Document::admission_projection_failure(
  self : Document,
) -> ((ArrayView[@core.Op]) -> DocumentError?)? {
  match self.admission_hooks {
    Some(hooks) => hooks.projection_failure
    None => None
  }
}

///|
fn Document::admission_recovery_checkout(
  self : Document,
) -> ((@core.Frontier) -> @branch.Branch raise @branch.BranchError)? {
  match self.admission_hooks {
    Some(hooks) => hooks.recovery_checkout
    None => None
  }
}

///|
fn Document::prepare_remote_for_admission(
  self : Document,
  incoming : Array[@core.Op],
  max_pending : Int?,
  max_pending_after_complete : Int?,
) -> @oplog.PreparedAdmission raise @oplog.OpLogError {
  match self.admission_prepare_override() {
    Some(replacement) => replacement(incoming)
    None =>
      match (max_pending, max_pending_after_complete) {
        (Some(during), Some(after)) =>
          self.oplog.prepare_remote(
            incoming,
            max_pending=during,
            max_pending_after_complete=after,
          )
        (Some(during), None) =>
          self.oplog.prepare_remote(incoming, max_pending=during)
        (None, Some(after)) =>
          self.oplog.prepare_remote(incoming, max_pending_after_complete=after)
        (None, None) => self.oplog.prepare_remote(incoming)
      }
  }
}
