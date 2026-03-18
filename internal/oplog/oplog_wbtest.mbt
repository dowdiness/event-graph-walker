///| Whitebox tests for OpLog internal functions

///|
test "add_op auto-merges contiguous insert ops" {
  let oplog = OpLog::new("test")
  let _ = try! oplog.insert("a", -1, -1)
  let _ = try! oplog.insert("b", 0, -1)

  // Two contiguous inserts from same agent should merge into 1 run
  inspect(oplog.op_count(), content="2")
  inspect(oplog.operations.length(), content="1")
}

///|
test "op_count returns total ops across all runs" {
  let oplog = OpLog::new("test")
  let _ = try! oplog.insert("a", -1, -1)
  inspect(oplog.op_count(), content="1")
}

///|
test "get_all_ops expands runs back to individual ops" {
  let oplog = OpLog::new("test")
  let _ = try! oplog.insert("h", -1, -1)
  let _ = try! oplog.insert("i", 0, -1)
  let all = oplog.get_all_ops()
  inspect(all.length(), content="2")
}
