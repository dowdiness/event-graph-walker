///| Typed result of one Document-owned remote change application.

///|
pub enum ProjectionStatus {
  Skipped
  Projected
  Recovered
  RecoveryRequired(error~ : @branch.BranchError)
}

///|
/// Package-internal scalar effect produced by Document projection.
pub(all) enum ProjectionEffect {
  Insert(position~ : Int, text~ : String)
  Delete(start~ : Int, end~ : Int)
}

///|
/// Whether Document can prove an exact ordered projection effect.
pub(all) enum ProjectionEffectAvailability {
  Exact(ArrayView[ProjectionEffect])
  SnapshotRequired
  Unavailable
}

///|
pub struct DocumentChanges {
  outcome : @oplog.ApplyChangesOutcome
  projection : ProjectionStatus
  effects : Array[ProjectionEffect]
  effect_availability : ProjectionEffectAvailability
}

///|
fn DocumentChanges::DocumentChanges(
  outcome : @oplog.ApplyChangesOutcome,
  projection : ProjectionStatus,
  effects : Array[ProjectionEffect],
  effect_availability : ProjectionEffectAvailability,
) -> DocumentChanges {
  { outcome, projection, effects, effect_availability, }
}

///|
priv enum ApplyChangesInput {
  RawOperations(Array[@core.Op])
  StructuralOperations(ArrayView[@core.StructuralOp])
}

///|
/// Stable graph-known origin requirements are distinct from current tree
/// divergence observations: a required origin may be present now and missing
/// in a later recovery candidate.
priv struct RemoteTargetCheck {
  required : Array[ProjectionRecoveryTarget]
  divergences : Array[ProjectionRecoveryTarget]
  invalid : DocumentError?
}

///|
/// Merge target evidence from the prepared and incoming views without exposing
/// a caller-owned array to the recovery state.
fn merge_projection_recovery_targets(
  prepared : Array[ProjectionRecoveryTarget],
  incoming : Array[ProjectionRecoveryTarget],
) -> Array[ProjectionRecoveryTarget] {
  let targets = prepared.copy()
  let seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for target in targets {
    ignore(seen.add_and_check(target.origin))
  }
  for target in incoming {
    if seen.add_and_check(target.origin) {
      targets.push(target)
    }
  }
  targets
}

///|
/// Check remote Fugue origins without changing the pending-change owner or tree.
/// Every graph-known origin enters `required`; only tree-missing origins enter
/// `divergences`.
fn Document::check_remote_targets(
  self : Document,
  ops : ArrayView[@core.Op],
) -> RemoteTargetCheck {
  let planned_inserts : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let planned_noninserts : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([],
  )
  for op in ops {
    let raw = @core.RawVersion(op.agent(), op.seq())
    match op.content() {
      @core.Insert(_) => planned_inserts.add(raw)
      @core.Delete | @core.Undelete => planned_noninserts.add(raw)
    }
  }
  let required : Array[ProjectionRecoveryTarget] = []
  let required_origins : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let divergences : Array[ProjectionRecoveryTarget] = []
  let divergence_origins : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([],
  )
  let mut invalid : DocumentError? = None
  for op in ops {
    for origin in [op.origin_left(), op.origin_right()] {
      match origin {
        None => ()
        Some(origin) => {
          match self.oplog.causal_graph().raw_to_lv(origin) {
            Some(lv) =>
              if required_origins.add_and_check(origin) {
                required.push({
                  origin,
                  error: @branch.BranchError::Fugue(
                    @fugue.FugueError::MissingItem(id=@fugue.Lv(lv)),
                  ),
                })
              }
            None => ()
          }
          match
            self.preflight_remote_origin(
              self.oplog.causal_graph(),
              origin,
              planned_inserts,
              planned_noninserts,
            ) {
            None => ()
            Some(error) =>
              match error {
                DocumentError::Fugue(fugue_error) =>
                  if divergence_origins.add_and_check(origin) {
                    divergences.push({
                      origin,
                      error: @branch.BranchError::Fugue(fugue_error),
                    })
                  }
                error => if invalid is None { invalid = Some(error) }
              }
          }
        }
      }
    }
  }
  { required, divergences, invalid, }
}

///|
/// Repair a graph-known/tree-missing origin before the prepared transition can
/// enter the pending-change owner. The prepared capability remains unchanged across
/// recovery; only pure target checks are repeated.
fn Document::ensure_apply_changes_targets(
  self : Document,
  prepared : ArrayView[@core.Op],
  incoming : ArrayView[@core.Op],
  recover : (@core.Frontier) -> Unit raise DocumentError,
) -> Bool raise DocumentError {
  let prepared_check = self.check_remote_targets(prepared)
  let incoming_check = self.check_remote_targets(incoming)
  let initial_divergences = merge_projection_recovery_targets(
    prepared_check.divergences,
    incoming_check.divergences,
  )
  let initial_targets = merge_projection_recovery_targets(
    prepared_check.required,
    incoming_check.required,
  )
  let initial_invalid = match prepared_check.invalid {
    Some(error) => Some(error)
    None => incoming_check.invalid
  }
  if initial_divergences.length() > 0 {
    self.projection_verification = Some(
      ProjectionRecoveryVerification::from_targets(initial_targets),
    )
    recover(self.get_frontier())
    let prepared_after = self.check_remote_targets(prepared)
    let incoming_after = self.check_remote_targets(incoming)
    let remaining_divergences = merge_projection_recovery_targets(
      prepared_after.divergences,
      incoming_after.divergences,
    )
    if remaining_divergences.length() > 0 {
      let error = remaining_divergences[0].error
      self.mark_apply_changes_recovery_required(
        self.get_frontier(),
        error,
        initial_targets,
      )
      false
    } else {
      let after_invalid = match prepared_after.invalid {
        Some(error) => Some(error)
        None => incoming_after.invalid
      }
      match after_invalid {
        Some(error) => raise error
        None => true
      }
    }
  } else {
    match initial_invalid {
      Some(error) => raise error
      None => false
    }
  }
}

///|
/// Keep the derived projection fail-closed when a successful checkout still
/// cannot satisfy a graph-known origin check.
fn Document::mark_apply_changes_recovery_required(
  self : Document,
  frontier : @core.Frontier,
  error : @branch.BranchError,
  targets : Array[ProjectionRecoveryTarget],
) -> Unit raise DocumentError {
  self.indexed_state.invalidate()
  self.cursor = None
  self.projection_verification = Some(
    ProjectionRecoveryVerification::from_targets(targets),
  )
  match self.apply_changes_recovery_checkout() {
    Some(checkout) => {
      let recovery_checkout = (_oplog, next_frontier) => checkout(next_frontier)
      self.projection_health = ProjectionHealth::RecoveryRequired(
        frontier~,
        checkout=recovery_checkout,
      )
    }
    None => {
      let recovery_checkout = (oplog, next_frontier) => {
        @branch.Branch::checkout(oplog, next_frontier)
      }
      self.projection_health = ProjectionHealth::RecoveryRequired(
        frontier~,
        checkout=recovery_checkout,
      )
    }
  }
  raise DocumentError::ProjectionRecoveryRequired(frontier~, error~)
}

///|
/// Use the production checkout or the package-local recovery capability.
fn Document::recover_projection_for_apply_changes(
  self : Document,
  frontier : @core.Frontier,
) -> Unit raise DocumentError {
  match self.apply_changes_recovery_checkout() {
    Some(checkout) =>
      self.recover_projection_with(frontier, (_oplog, frontier) => {
        checkout(frontier)
      })
    None => self.recover_projection(frontier)
  }
}

///|
/// Commit through the normal typed transition, or through the package-local
/// failure capability used by white-box change application tests.
fn Document::apply_changes_for_document(
  self : Document,
  action : @oplog.ApplyChanges,
) -> @oplog.ApplyChangesOutcome raise @oplog.OpLogError {
  match self.apply_changes_commit_failure() {
    Some(failure) => self.oplog.apply_changes_with_failure(action, failure)
    None => self.oplog.apply_changes(action)
  }
}

///|
fn DocumentChanges::frontier_after(self : DocumentChanges) -> @core.Frontier {
  match self.outcome {
    @oplog.ApplyChangesOutcome::Succeeded(report) => report.frontier_after()
    @oplog.ApplyChangesOutcome::Failed(report~, ..) => report.frontier_after()
  }
}

///|
/// Recovery failure takes precedence: committed changes may not yet be visible.
pub fn DocumentChanges::report(
  self : DocumentChanges,
) -> @oplog.ApplyChangesReport raise DocumentError {
  match self.projection {
    ProjectionStatus::RecoveryRequired(error~) =>
      raise DocumentError::ProjectionRecoveryRequired(
        frontier=self.frontier_after(),
        error~,
      )
    ProjectionStatus::Skipped
    | ProjectionStatus::Projected
    | ProjectionStatus::Recovered =>
      match self.outcome {
        @oplog.ApplyChangesOutcome::Succeeded(report) => report
        @oplog.ApplyChangesOutcome::Failed(report~, error~) =>
          raise DocumentError::OpLog(
            @oplog.OpLogError::PartialApplyChanges(
              committed=report.committed().to_owned(),
              error~,
            ),
          )
      }
  }
}

///|
/// Complete-frontier closure belongs to `merge_remote`, not here.
pub fn Document::apply_changes(
  self : Document,
  incoming : Array[@core.Op],
  max_pending? : Int,
  max_pending_after_complete? : Int,
) -> DocumentChanges raise DocumentError {
  self.apply_changes_with_input(
    ApplyChangesInput::RawOperations(incoming),
    max_pending,
    max_pending_after_complete,
  )
}

///|
pub fn Document::apply_structural_changes(
  self : Document,
  incoming : ArrayView[@core.StructuralOp],
  max_pending? : Int,
  max_pending_after_complete? : Int,
) -> DocumentChanges raise DocumentError {
  self.apply_changes_with_input(
    ApplyChangesInput::StructuralOperations(incoming),
    max_pending,
    max_pending_after_complete,
  )
}

///|
fn Document::apply_changes_with_input(
  self : Document,
  input : ApplyChangesInput,
  max_pending : Int?,
  max_pending_after_complete : Int?,
) -> DocumentChanges raise DocumentError {
  let entry_recovered = self.ensure_projection_ready_for_apply_changes()
  // Remote ingress ends the local sequential-insert fast path at entry,
  // including pending-only, duplicate-only, and pre-commit rejection paths.
  self.cursor = None
  let incoming = match input {
    RawOperations(operations) => {
      validate_remote_ops(operations[:])
      operations
    }
    StructuralOperations(operations) => operations.map(op => op.raw())
  }
  self.observe_action()
  let action = self.action_for_apply_changes(
    incoming, max_pending, max_pending_after_complete,
  ) catch {
    error => raise DocumentError::OpLog(error)
  }
  let preflight_recovered = self.ensure_apply_changes_targets(
    action.operations(),
    incoming[:],
    frontier => self.recover_projection_for_apply_changes(frontier),
  )
  ProjectionWorkspace::commit_and_project(
    self,
    action,
    entry_recovered || preflight_recovered,
  )
}
