///| Admission and projection publication are independent results.

///|
pub(all) enum ProjectionEffect {
  Insert(position~ : Int32, text~ : String)
  Delete(start~ : Int32, end~ : Int32)
}

///|
/// Exact owns its sequential edits, including an empty no-op publication.
/// SnapshotRequired means a valid tree, but no proven incremental edit stream.
pub(all) enum ProjectionPublication {
  Exact(Array[ProjectionEffect])
  SnapshotRequired
  Unavailable(DocumentError)
}

///|
pub struct DocumentChanges {
  outcome : @oplog.ApplyChangesOutcome
  publication : ProjectionPublication
}

///|
priv enum ApplyChangesInput {
  RawOperations(Array[@core.Op])
  StructuralOperations(ArrayView[@core.StructuralOp])
}

///|
/// Detect divergence without attempting canonical checkout or consuming action.
fn Document::ensure_apply_changes_targets(
  self : Document,
  prepared : ArrayView[@core.Op],
  incoming : ArrayView[@core.Op],
) -> Unit raise DocumentError {
  for operations in [prepared, incoming] {
    let inserts : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
    let noninserts : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
    for op in operations {
      let raw = @core.RawVersion(op.agent(), op.seq())
      match op.content() {
        @core.Insert(_) => inserts.insert(raw)
        _ => noninserts.insert(raw)
      }
    }
    for op in operations {
      for origin in [op.origin_left(), op.origin_right()] {
        if origin is Some(origin) {
          match
            self.preflight_remote_origin(
              self.oplog.causal_graph(),
              origin,
              inserts,
              noninserts,
            ) {
            Some(DocumentError::Fugue(error)) =>
              if self.view.version.contains(origin) {
                let failure = DocumentError::ProjectionRecoveryRequired(
                  frontier=self.get_frontier(),
                  error=@branch.BranchError::Fugue(error),
                )
                self.invalidate_projection(failure)
                raise failure
              }
            Some(error) => raise error
            None => ()
          }
        }
      }
    }
  }
}

///|
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
/// Convenience for callers requiring both successful admission and projection.
/// The outcome field remains available even when projection is unavailable.
pub fn DocumentChanges::report(
  self : DocumentChanges,
) -> @oplog.ApplyChangesReport raise DocumentError {
  if self.publication is Unavailable(error) {
    raise error
  }
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

///|
pub fn Document::apply_changes(
  self : Document,
  incoming : Array[@core.Op],
  max_pending? : Int32,
  max_pending_after_complete? : Int32,
) -> DocumentChanges raise DocumentError {
  self.apply_changes_with_input(
    RawOperations(incoming),
    max_pending,
    max_pending_after_complete,
  )
}

///|
pub fn Document::apply_structural_changes(
  self : Document,
  incoming : ArrayView[@core.StructuralOp],
  max_pending? : Int32,
  max_pending_after_complete? : Int32,
) -> DocumentChanges raise DocumentError {
  self.apply_changes_with_input(
    StructuralOperations(incoming),
    max_pending,
    max_pending_after_complete,
  )
}

///|
fn Document::apply_changes_with_input(
  self : Document,
  input : ApplyChangesInput,
  max_pending : Int32?,
  max_pending_after_complete : Int32?,
) -> DocumentChanges raise DocumentError {
  self.ensure_projection_ready()
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
  self.ensure_apply_changes_targets(action.operations(), incoming[:])
  ProjectionWorkspace::commit_and_project(self, action)
}
