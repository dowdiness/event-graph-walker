///|
test "DeleteIndex - build and lookup" {
  let oplog = @oplog.OpLog::new("agent_a")

  // Insert "AB"
  let op_a = try! oplog.insert("A", -1, -1)
  let op_b = try! oplog.insert("B", op_a.lv(), -1)

  // Delete "A" (target = op_a's LV)
  let del_op = try! oplog.delete(op_a.lv())
  let _ = del_op
  let _ = op_b

  let index = @branch.DeleteIndex::build(oplog)
  let raw_a = @core.RawVersion::new(op_a.agent(), op_a.seq())
  let raw_b = @core.RawVersion::new(op_b.agent(), op_b.seq())

  // op_a should have 1 delete op targeting it
  let ops = index.get_delete_ops(raw_a)
  inspect(ops.length(), content="1")

  // op_b should have 0 delete ops
  let ops_b = index.get_delete_ops(raw_b)
  inspect(ops_b.length(), content="0")
}

///|
test "DeleteIndex - recompute_winner" {
  let oplog = @oplog.OpLog::new("agent_a")
  let op_a = try! oplog.insert("A", -1, -1)
  let _ = try! oplog.delete(op_a.lv())

  let index = @branch.DeleteIndex::build(oplog)
  let raw_a = @core.RawVersion::new(op_a.agent(), op_a.seq())

  // Recompute winner excluding nothing (empty retreat set)
  let empty_retreat : @rle.Rle[@core.LvRange] = @rle.Rle::new()
  let winner = index.recompute_winner(raw_a, oplog, empty_retreat)
  // Should find the delete as winner
  inspect(winner.deleted, content="true")
}
