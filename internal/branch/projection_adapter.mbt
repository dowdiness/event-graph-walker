///|
/// Apply one operation through the shared Fugue projection seam.
fn apply_projection(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise BranchError {
  @fugue_projection.apply(tree, op, causal_graph) catch {
    @fugue_projection.FugueProjectionError::MissingOrigin(raw~) =>
      raise BranchError::MissingOrigin(raw~)
    @fugue_projection.FugueProjectionError::MissingCausalEntry(lv~) =>
      raise BranchError::MissingOp(lv~)
    @fugue_projection.FugueProjectionError::Fugue(error~) =>
      raise BranchError::Fugue(error)
  }
}
