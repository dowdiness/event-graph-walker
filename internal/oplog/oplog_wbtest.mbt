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

///|
test "get_ops_rle expands a middle slice from a compressed run" {
  let oplog = OpLog::new("test")
  let mut prev = -1
  for ch in ["a", "b", "c", "d"] {
    let op = try! oplog.insert(ch, prev, -1)
    prev = op.lv()
  }
  inspect(oplog.operations.length(), content="1")

  let ranges : @rle.Rle[@core.LvRange] = @rle.Rle::from_array([
    @core.LvRange::{ start: 1, count: 2 },
  ])
  let ops = oplog.get_ops_rle(ranges)
  inspect(ops.length(), content="2")
  inspect(ops[0].lv(), content="1")
  inspect(ops[0].content(), content="Insert(\"b\")")
  inspect(ops[1].lv(), content="2")
  inspect(ops[1].content(), content="Insert(\"c\")")
}

///|
test "get_ops_rle preserves range order for retreat-style ranges" {
  let oplog = OpLog::new("test")
  let mut prev = -1
  for ch in ["a", "b", "c"] {
    let op = try! oplog.insert(ch, prev, -1)
    prev = op.lv()
  }
  let ranges : @rle.Rle[@core.LvRange] = @rle.Rle::from_array([
    @core.LvRange::{ start: 2, count: 1 },
    @core.LvRange::{ start: 0, count: 1 },
  ])
  let ops = oplog.get_ops_rle(ranges)
  inspect(ops.length(), content="2")
  inspect(ops[0].lv(), content="2")
  inspect(ops[1].lv(), content="0")
}

///|
test "get_ops_rle keeps clamped invalid-LV behavior" {
  let oplog = OpLog::new("test")
  let _ = try! oplog.insert("a", -1, -1)
  let _ = try! oplog.insert("b", 0, -1)
  let ranges : @rle.Rle[@core.LvRange] = @rle.Rle::from_array([
    @core.LvRange::{ start: -1, count: 4 },
  ])
  let ops = oplog.get_ops_rle(ranges)
  inspect(ops.length(), content="2")
  inspect(ops[0].lv(), content="0")
  inspect(ops[1].lv(), content="1")
}
