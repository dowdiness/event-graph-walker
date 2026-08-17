///| Typed result of one Document-owned remote admission.

///|
pub enum ProjectionStatus {
  Skipped
  Projected
  Recovered
  RecoveryRequired(error~ : @branch.BranchError)
}

///|
pub struct DocumentAdmission {
  outcome : @oplog.AdmissionOutcome
  projection : ProjectionStatus
}

///|
/// Construct admission evidence in one place so callers cannot accidentally
/// separate the authority outcome from its derived projection status.
fn DocumentAdmission::DocumentAdmission(
  outcome : @oplog.AdmissionOutcome,
  projection : ProjectionStatus,
) -> DocumentAdmission {
  { outcome, projection }
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
priv struct AdmissionCapabilities {
  prepare : (Array[@core.Op], Int?) -> @oplog.PreparedAdmission raise @oplog.OpLogError
  commit : (@oplog.PreparedAdmission) -> @oplog.AdmissionOutcome raise @oplog.OpLogError
  project : (ArrayView[@core.Op]) -> Unit raise DocumentError
  recover : (@core.Frontier) -> Unit raise DocumentError
}

///|
/// Check remote Fugue origins without changing the pending planner or tree.
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
  { required, divergences, invalid }
}

///|
/// Repair a graph-known/tree-missing origin before the prepared transition can
/// enter the pending planner. The prepared capability remains unchanged across
/// recovery; only pure target checks are repeated.
fn Document::ensure_admission_targets(
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
      self.mark_admission_recovery_required(
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
fn Document::mark_admission_recovery_required(
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
  match self.admission_recovery_checkout() {
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
fn Document::recover_projection_for_admission(
  self : Document,
  frontier : @core.Frontier,
) -> Unit raise DocumentError {
  match self.admission_recovery_checkout() {
    Some(checkout) =>
      self.recover_projection_with(frontier, (_oplog, frontier) => {
        checkout(frontier)
      })
    None => self.recover_projection(frontier)
  }
}

///|
/// Commit through the normal typed transition, or through the package-local
/// failure capability used by white-box admission tests.
fn Document::commit_admission_for_document(
  self : Document,
  prepared : @oplog.PreparedAdmission,
) -> @oplog.AdmissionOutcome raise @oplog.OpLogError {
  match self.admission_commit_failure() {
    Some(failure) => self.oplog.commit_admission_with_failure(prepared, failure)
    None => self.oplog.commit_admission(prepared)
  }
}

///|
/// Run one typed remote admission and one derived projection finalization.
fn Document::admit_remote_with(
  self : Document,
  incoming : Array[@core.Op],
  max_pending : Int?,
  capabilities : AdmissionCapabilities,
) -> DocumentAdmission raise DocumentError {
  let entry_recovered = self.ensure_projection_ready_for_admission()
  // Remote ingress ends the local sequential-insert fast path at entry,
  // including pending-only, duplicate-only, and pre-commit rejection paths.
  self.cursor = None
  validate_remote_ops(incoming[:])
  self.observe_prepare_remote()
  let prepared = (capabilities.prepare)(incoming, max_pending) catch {
    error => raise DocumentError::OpLog(error)
  }
  let preflight_recovered = self.ensure_admission_targets(
    prepared.operations(),
    incoming[:],
    capabilities.recover,
  )
  let recovered = entry_recovered || preflight_recovered

  let detached_cache = self.indexed_state.take_cache()
  self.observe_commit_admission()
  let outcome = (capabilities.commit)(prepared) catch {
    error => {
      self.indexed_state.restore_cache(detached_cache)
      raise DocumentError::OpLog(error)
    }
  }
  let receipt = match outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => receipt
    @oplog.AdmissionOutcome::Partial(receipt~, error~) => {
      let _ = error
      receipt
    }
  }
  let committed = receipt.committed()
  if committed.length() == 0 {
    self.indexed_state.restore_cache(detached_cache)
    self.cursor = None
    let status = if recovered {
      ProjectionStatus::Recovered
    } else {
      ProjectionStatus::Skipped
    }
    return DocumentAdmission::DocumentAdmission(outcome, status)
  }

  // Authority has advanced. Never restore the detached cache before projection;
  // a projection failure must remain visibly invalid until recovery succeeds.
  self.invalidate_cache()
  self.cursor = None
  let projection_result : Result[Unit, DocumentError] = Ok(
    (capabilities.project)(committed),
  ) catch {
    error => Err(error)
  }
  match projection_result {
    Ok(_) => {
      let status = if recovered {
        ProjectionStatus::Recovered
      } else {
        ProjectionStatus::Projected
      }
      DocumentAdmission::DocumentAdmission(outcome, status)
    }
    Err(_) => {
      self.invalidate_cache()
      self.cursor = None
      let status = try (capabilities.recover)(receipt.frontier_after()) catch {
        DocumentError::ProjectionRecoveryRequired(frontier~, error~) => {
          let _ = frontier
          ProjectionStatus::RecoveryRequired(error~)
        }
        error => raise error
      } noraise {
        _ => ProjectionStatus::Recovered
      }
      DocumentAdmission::DocumentAdmission(outcome, status)
    }
  }
}

///|
/// Return the authority frontier carried by either typed outcome variant.
fn DocumentAdmission::frontier_after(
  self : DocumentAdmission,
) -> @core.Frontier {
  match self.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => receipt.frontier_after()
    @oplog.AdmissionOutcome::Partial(receipt~, ..) => receipt.frontier_after()
  }
}

///|
/// Translate typed admission evidence for the legacy Unit-returning wrappers.
/// Recovery failure takes precedence over a partial authority outcome because
/// the committed Document is not safe for ordinary derived use until repaired.
fn DocumentAdmission::raise_legacy_remote_error(
  self : DocumentAdmission,
) -> Unit raise DocumentError {
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
        @oplog.AdmissionOutcome::Complete(_) => ()
        @oplog.AdmissionOutcome::Partial(receipt~, error~) =>
          raise DocumentError::OpLog(
            @oplog.OpLogError::PartialRemoteAdmission(
              committed=receipt.committed().to_owned(),
              error~,
            ),
          )
      }
  }
}

///|
/// Admit an incomplete remote batch through one typed authority/projection
/// boundary. Complete-frontier closure belongs to `merge_remote`, not here.
pub fn Document::admit_remote(
  self : Document,
  incoming : Array[@core.Op],
  max_pending? : Int,
) -> DocumentAdmission raise DocumentError {
  self.admit_remote_with(incoming, max_pending, {
    prepare: (operations, max_pending) => {
      self.prepare_remote_for_admission(operations, max_pending)
    },
    commit: prepared => self.commit_admission_for_document(prepared),
    project: committed => self.project_remote_ops(committed),
    recover: frontier => self.recover_projection_for_admission(frontier),
  })
}
