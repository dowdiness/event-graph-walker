///|
/// Package-local hooks for specifying Document change application boundaries in white-box tests.
///
/// Hooks observe boundary calls without adding counters to OpLog or Document state.
#warnings("-struct_never_constructed")
priv struct ApplyChangesBoundaryHooks {
  on_action : () -> Unit
  on_apply_changes : () -> Unit
  on_projection_finalization : (ArrayView[@core.Op]) -> Unit
  action_override : ((Array[@core.Op]) -> @oplog.ApplyChanges raise @oplog.OpLogError)?
  commit_failure : ((@core.Op) -> @causal_graph.CausalGraphError?)?
  projection_failure : ((ArrayView[@core.Op]) -> DocumentError?)?
  recovery_checkout : ((@core.Frontier) -> @branch.Branch raise @branch.BranchError)?
}

///|
#warnings("-unused_value")
fn Document::set_apply_changes_hooks(
  self : Document,
  hooks : ApplyChangesBoundaryHooks,
) -> Unit {
  self.apply_changes_hooks = Some(hooks)
}

///|
fn Document::observe_action(self : Document) -> Unit {
  match self.apply_changes_hooks {
    Some(hooks) => (hooks.on_action)()
    None => ()
  }
}

///|
fn Document::observe_apply_changes(self : Document) -> Unit {
  match self.apply_changes_hooks {
    Some(hooks) => (hooks.on_apply_changes)()
    None => ()
  }
}

///|
fn Document::observe_projection_finalization(
  self : Document,
  committed : ArrayView[@core.Op],
) -> Unit {
  match self.apply_changes_hooks {
    Some(hooks) => (hooks.on_projection_finalization)(committed)
    None => ()
  }
}

///|
fn Document::apply_changes_commit_failure(
  self : Document,
) -> ((@core.Op) -> @causal_graph.CausalGraphError?)? {
  match self.apply_changes_hooks {
    Some(hooks) => hooks.commit_failure
    None => None
  }
}

///|
fn Document::apply_changes_action_override(
  self : Document,
) -> ((Array[@core.Op]) -> @oplog.ApplyChanges raise @oplog.OpLogError)? {
  match self.apply_changes_hooks {
    Some(hooks) => hooks.action_override
    None => None
  }
}

///|
fn Document::apply_changes_projection_failure(
  self : Document,
) -> ((ArrayView[@core.Op]) -> DocumentError?)? {
  match self.apply_changes_hooks {
    Some(hooks) => hooks.projection_failure
    None => None
  }
}

///|
fn Document::apply_changes_recovery_checkout(
  self : Document,
) -> ((@core.Frontier) -> @branch.Branch raise @branch.BranchError)? {
  match self.apply_changes_hooks {
    Some(hooks) => hooks.recovery_checkout
    None => None
  }
}

///|
fn Document::action_for_apply_changes(
  self : Document,
  incoming : Array[@core.Op],
  max_pending : Int?,
  max_pending_after_complete : Int?,
) -> @oplog.ApplyChanges raise @oplog.OpLogError {
  match self.apply_changes_action_override() {
    Some(replacement) => replacement(incoming)
    None =>
      match (max_pending, max_pending_after_complete) {
        (Some(during), Some(after)) =>
          @oplog.ApplyChanges(
            self.oplog,
            incoming,
            max_pending=during,
            max_pending_after_complete=after,
          )
        (Some(during), None) =>
          @oplog.ApplyChanges(self.oplog, incoming, max_pending=during)
        (None, Some(after)) =>
          @oplog.ApplyChanges(
            self.oplog,
            incoming,
            max_pending_after_complete=after,
          )
        (None, None) => @oplog.ApplyChanges(self.oplog, incoming)
      }
  }
}
