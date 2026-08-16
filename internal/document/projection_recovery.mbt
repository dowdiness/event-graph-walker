///| Document-owned projection lifecycle and canonical recovery.

///|
priv enum ProjectionHealth {
  Ready
  RecoveryRequired(
    frontier~ : @core.Frontier,
    checkout~ : (@oplog.OpLog, @core.Frontier) -> @branch.Branch raise @branch.BranchError
  )
}

///|
/// Install a freshly checked-out tree without exposing a replacement operation
/// outside the document package.
fn Document::replace_projection_tree(
  self : Document,
  replacement : @fugue.FugueTree[String],
) -> Unit {
  self.tree = replacement
}

///|
/// Rebuild the derived projection through a supplied checkout seam.
///
/// The callback is private and exists so white-box tests can exercise failed
/// checkout while the production entry point always uses Branch::checkout.
fn Document::recover_projection_with(
  self : Document,
  frontier : @core.Frontier,
  checkout : (@oplog.OpLog, @core.Frontier) -> @branch.Branch raise @branch.BranchError,
) -> Unit raise DocumentError {
  self.indexed_state.invalidate()
  self.cursor = None
  self.projection_health = ProjectionHealth::RecoveryRequired(
    frontier~,
    checkout~,
  )
  let branch = checkout(self.oplog, frontier) catch {
    error => raise DocumentError::ProjectionRecoveryRequired(frontier~, error~)
  }
  self.replace_projection_tree(branch.inner_tree())
  self.indexed_state.invalidate()
  self.cursor = None
  self.projection_health = ProjectionHealth::Ready
}

///|
/// Rebuild the projection from the authoritative operation log.
fn Document::recover_projection(
  self : Document,
  frontier : @core.Frontier,
) -> Unit raise DocumentError {
  self.recover_projection_with(frontier, (oplog, frontier) => {
    @branch.Branch::checkout(oplog, frontier)
  })
}

///|
/// Ensure the derived projection is canonical before a dependent mutation.
///
/// This narrow direct-dependent guard lets facades validate their own input
/// without reading a failed non-fallible projection first.
pub fn Document::prepare_for_mutation(
  self : Document,
) -> Unit raise DocumentError {
  self.ensure_projection_ready()
}

///|
/// Retry canonical recovery before a fallible document mutation.
fn Document::ensure_projection_ready(
  self : Document,
) -> Unit raise DocumentError {
  match self.projection_health {
    ProjectionHealth::Ready => ()
    ProjectionHealth::RecoveryRequired(frontier~, checkout~) =>
      self.recover_projection_with(frontier, checkout)
  }
}

///|
/// Recover the derived projection before preserving the original failure.
fn Document::recover_after_projection_failure(
  self : Document,
  error : DocumentError,
) -> Unit raise DocumentError {
  let frontier = self.oplog.get_frontier()
  match self.admission_recovery_checkout() {
    Some(checkout) =>
      self.recover_projection_with(frontier, (_oplog, frontier) => {
        checkout(frontier)
      })
    None => self.recover_projection(frontier)
  }
  raise error
}

///|
/// Derived readers retain their non-fallible signatures but never expose a
/// projection that failed canonical recovery.
fn Document::ensure_projection_ready_for_read(self : Document) -> Unit {
  self.ensure_projection_ready() catch {
    _ => abort("document projection recovery required")
  }
}
