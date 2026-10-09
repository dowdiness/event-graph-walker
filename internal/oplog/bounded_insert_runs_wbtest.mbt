///|
test "bounded insert packing preserves boundary operations and snapshots" {
  for count in [255, 256, 257, 513, 1025, 2049] {
    let log = OpLog("bounded")
    let expected : Array[@core.Op] = []
    for i = 0; i < count; i = i + 1 {
      expected.push(
        try! log.insert(if i % 2 == 0 { "😀" } else { "x" }, i - 1, -1),
      )
    }
    let retained = log.get_all_runs()
    let retained_ops : Array[@core.Op] = []
    for run in retained {
      run.decompress_into(retained_ops)
    }
    ignore(try! log.insert("Z", count - 1, -1))
    let still_retained : Array[@core.Op] = []
    for run in retained {
      run.decompress_into(still_retained)
    }
    assert_eq(retained_ops.length(), count)
    assert_eq(still_retained.length(), count)
    for i = 0; i < count; i = i + 1 {
      assert_true(
        apply_changes_same_logical_operation(
          expected[i],
          log.get_op(i).unwrap(),
        ),
      )
      assert_true(
        apply_changes_same_logical_operation(expected[i], still_retained[i]),
      )
    }
    assert_true(log.get_op(count).unwrap().content() is @core.Insert("Z"))
    assert_eq(log.get_all_ops().length(), count + 1)
    assert_true(log.get_all_runs().length() > 1 || count < 256)
  }
}
