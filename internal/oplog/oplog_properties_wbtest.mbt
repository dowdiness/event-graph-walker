///| Property-style tests: verify compressed OpLog produces identical get_op results

///|
fn verify_compression_equivalence(oplog : OpLog) -> Unit raise {
  let count = oplog.op_count()
  let all_ops = oplog.get_all_ops()
  assert_eq(all_ops.length(), count)
  for lv = 0; lv < count; lv = lv + 1 {
    let from_get = oplog.get_op(lv)
    guard from_get is Some(op) else {
      fail("get_op(\{lv}) returned None for valid LV")
    }
    let from_array = all_ops[lv]
    assert_eq(op.lv(), from_array.lv())
    assert_eq(op.agent(), from_array.agent())
    assert_eq(op.seq(), from_array.seq())
    assert_eq(op.content(), from_array.content())
    assert_eq(op.origin_left(), from_array.origin_left())
    assert_eq(op.origin_right(), from_array.origin_right())
    assert_eq(op.parents(), from_array.parents())
  }
  inspect(oplog.get_op(-1) is None, content="true")
  inspect(oplog.get_op(count) is None, content="true")
}

///|
test "property: single-user linear typing (maximum compression)" {
  let oplog = OpLog::new("alice")
  let _ = try! oplog.insert("h", -1, -1)
  let _ = try! oplog.insert("e", 0, -1)
  let _ = try! oplog.insert("l", 1, -1)
  let _ = try! oplog.insert("l", 2, -1)
  let _ = try! oplog.insert("o", 3, -1)
  inspect(oplog.op_count(), content="5")
  // Should be 1 run
  inspect(oplog.operations.length(), content="1")
  verify_compression_equivalence(oplog)
}

///|
test "property: insert then delete (2+ runs)" {
  let oplog = OpLog::new("alice")
  let _ = try! oplog.insert("a", -1, -1)
  let _ = try! oplog.insert("b", 0, -1)
  let _ = try! oplog.delete(0)
  inspect(oplog.op_count(), content="3")
  verify_compression_equivalence(oplog)
}

///|
test "property: interleaved agents (no compression)" {
  let oplog = OpLog::new("alice")
  let _ = try! oplog.insert("a", -1, -1)
  let bob_op = @core.Op::new_insert(-1, [], "bob", 0, "b", None, None)
  let _ = try! oplog.apply_remote(bob_op)
  inspect(oplog.op_count(), content="2")
  inspect(oplog.operations.length(), content="2")
  verify_compression_equivalence(oplog)
}

///|
test "property: longer typing session" {
  let oplog = OpLog::new("alice")
  let text = "the quick brown fox"
  let mut prev_lv = -1
  for ch in text {
    let _ = try! oplog.insert(ch.to_string(), prev_lv, -1)
    prev_lv = prev_lv + 1
  }
  inspect(oplog.op_count(), content="19")
  inspect(oplog.operations.length(), content="1")
  verify_compression_equivalence(oplog)
}
