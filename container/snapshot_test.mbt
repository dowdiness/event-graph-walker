///|
test "container causal snapshot stays live across tree and text mutations" {
  let document = try! @container.Document::new("snapshot-replica")
  let snapshot = document.causal_snapshot()
  inspect(snapshot.op_count(), content="0")
  let block = try! document.create_node(parent=@container.root_id)
  inspect(snapshot.op_count(), content="1")
  try! document.insert_text(block, 0, "hello")
  inspect(snapshot.op_count(), content="6")
  let entry = snapshot.entry(1).unwrap()
  inspect(entry.agent(), content="snapshot-replica")
  inspect(entry.seq(), content="1")
  inspect(entry.parents().length(), content="1")
  let frontier = snapshot.frontier()
  frontier.clear()
  inspect(snapshot.frontier().length(), content="1")
}
