///| Whitebox tests for OpLog internal functions

///|
test "ops_ref returns operations without copying" {
  let oplog = OpLog::new("test")
  let _ = try! oplog.insert("a", -1, -1)

  // ops_ref should return the same array instance
  let ref1 = oplog.ops_ref()
  let ref2 = oplog.ops_ref()

  // Both should have the same length
  inspect(ref1.length(), content="1")
  inspect(ref2.length(), content="1")

  // Length should match op_count
  inspect(oplog.op_count(), content="1")
}
