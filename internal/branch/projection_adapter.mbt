///|
/// Translate the shared projection error into Branch's existing surface.
#inline
fn translate_projection_error(
  error : @fugue_projection.FugueProjectionError,
) -> BranchError {
  match error {
    @fugue_projection.FugueProjectionError::MissingOrigin(raw~) =>
      BranchError::MissingOrigin(raw~)
    @fugue_projection.FugueProjectionError::MissingCausalEntry(lv~) =>
      BranchError::MissingOp(lv~)
    @fugue_projection.FugueProjectionError::Fugue(error~) =>
      BranchError::Fugue(error)
  }
}

///|
/// Apply one operation through the shared Fugue projection seam.
#inline
fn apply_projection(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise BranchError {
  @fugue_projection.apply(tree, op, causal_graph) catch {
    error => raise translate_projection_error(error)
  }
}

///|
/// Apply an already-collected causal sequence with one adapter error boundary.
/// A later failure preserves the successful prefix exactly as per-op calls do.
#inline
fn apply_projections(
  tree : @fugue.FugueTree[String],
  operations : ArrayView[@core.Op],
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise BranchError {
  @fugue_projection.apply_all(tree, operations, causal_graph) catch {
    error => raise translate_projection_error(error)
  }
}
