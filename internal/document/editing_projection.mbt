///|
/// Only the editing cut's membership is retained, never a second operation log
/// or Fugue tree. Hidden admissions leave the projection and its indexes alone.
priv struct EditingProjection {
  mut frontier : @core.Frontier
  version : @causal_graph.ViewVersion
}

///|
fn Document::local_parents(self : Document) -> @core.Frontier {
  self.view.frontier
}

///|
fn Document::advance_local_view(self : Document, op : @core.Op) -> Unit {
  self.view.frontier = @core.Frontier::from_array([op.lv()])
  self.view.version.append(@core.RawVersion(op.agent(), op.seq()))
}

///|
pub fn Document::view_graph_version(
  self : Document,
) -> @causal_graph.GraphVersion {
  self.view.version.snapshot()
}

///|
/// Admission uses only graph/log semantics. In particular a known target absent
/// from the retained tree is not evidence of projection corruption here.
pub fn Document::admit_structural_changes(
  self : Document,
  incoming : ArrayView[@core.StructuralOp],
  max_pending : Int32,
) -> @oplog.ApplyChangesOutcome raise DocumentError {
  let action = @oplog.ApplyChanges(
    self.oplog,
    incoming.map(op => op.raw()),
    max_pending_after_complete=max_pending,
  ) catch {
    error => raise DocumentError::OpLog(error)
  }
  self.apply_changes_for_document(action) catch {
    error => raise DocumentError::OpLog(error)
  }
}

///|
/// Publish the missing accepted operations without ending local undo history.
pub fn Document::advance_projection(
  self : Document,
) -> Unit raise DocumentError {
  self.ensure_projection_ready()
  match self.project_accepted() {
    Unavailable(error) => raise error
    Exact(_) | SnapshotRequired => ()
  }
}

///|
/// Explicit session boundary. A complete accepted cut includes noncausal origin
/// dependencies too. No arbitrary editable historical cut is exposed.
pub fn Document::integrate_projection(
  self : Document,
) -> Unit raise DocumentError {
  self.recover_projection()
}
