///|
/// Translate shared projection failures into Document's existing error surface.
fn translate_projection_error(
  error : @fugue_projection.FugueProjectionError,
) -> DocumentError {
  match error {
    @fugue_projection.FugueProjectionError::MissingOrigin(raw~) =>
      DocumentError::MissingOrigin(raw~)
    @fugue_projection.FugueProjectionError::MissingCausalEntry(lv~) =>
      DocumentError::OpLog(@oplog.OpLogError::MissingLocalVersion(lv~))
    @fugue_projection.FugueProjectionError::Fugue(error~) =>
      DocumentError::Fugue(error)
  }
}

///|
/// Apply one operation through the shared Fugue projection seam.
fn apply_projection(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise DocumentError {
  @fugue_projection.apply(tree, op, causal_graph) catch {
    error => raise translate_projection_error(error)
  }
}

///|
/// Apply one operation and retain its semantic visibility outcome.
fn apply_projection_with_visible_change(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> @fugue_projection.VisibilityChange raise DocumentError {
  @fugue_projection.apply_with_visible_change(tree, op, causal_graph) catch {
    error => raise translate_projection_error(error)
  }
}
