///|
/// Direct Fugue tests use their explicit operation ID as the stable sequence.
fn insert_with_test_sequence(
  tree : @fugue.FugueTree[String],
  op : @fugue.InsertOp[String],
) -> Unit {
  tree.insert(op, sequence=op.id.0)
}
