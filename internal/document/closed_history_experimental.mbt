///| Complete-history factory; no existing Document or prepared capability exists.

///|
fn Document::from_closed_history_internal(
  writer : String,
  proof : @oplog.ClosedHistory,
  fault_after_adoption : Bool,
) -> Document raise DocumentError {
  let (oplog, local_operations) = proof.consume_experimental(writer) catch {
    error => raise DocumentError::OpLog(error)
  }
  if fault_after_adoption {
    raise DocumentError::OpLog(@oplog.OpLogError::InvalidAdmission)
  }
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  for op in local_operations {
    apply_projection(tree, op, oplog.causal_graph())
  }
  let indexed = IndexedState::from_tree_bulk_experimental(tree)
  guard indexed is Some(indexed) else {
    raise DocumentError::OpLog(@oplog.OpLogError::InvalidAdmission)
  }
  {
    tree,
    oplog,
    agent_id: writer,
    indexed_state: indexed,
    cursor: None,
    projection_health: ProjectionHealth::Ready,
    projection_verification: None,
    admission_hooks: None,
  }
}

///|
pub fn Document::from_closed_history_experimental(
  writer : String,
  proof : @oplog.ClosedHistory,
) -> Document raise DocumentError {
  Document::from_closed_history_internal(writer, proof, false)
}
