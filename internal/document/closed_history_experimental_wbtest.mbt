///|
test "direct Document matches canonical Fugue topology winner tuples and indexed ranks" {
  let source = Document::new("source")
  ignore(source.insert(0, "a😀漢bc"))
  ignore(source.insert(2, "Z"))
  ignore(source.delete(1))
  ignore(source.undelete(1))
  let ops = source.get_all_ops()
  let ordinary = Document::new("fresh")
  ignore(ordinary.apply_changes(ops))
  let direct = Document::from_closed_history_experimental(
    "fresh",
    @oplog.ClosedHistory::prepare_experimental(ops),
  )
  assert_eq(direct.to_text(), ordinary.to_text())
  assert_eq(direct.get_all_runs(), ordinary.get_all_runs())
  assert_eq(direct.tree.get_all_items(), ordinary.tree.get_all_items())
  assert_indexed_state_matches_tree(direct)
  ignore(direct.insert(1, "Q"))
  ignore(ordinary.insert(1, "Q"))
  ignore(direct.delete(0))
  ignore(ordinary.delete(0))
  assert_eq(direct.tree.get_all_items(), ordinary.tree.get_all_items())
  assert_eq(direct.get_all_runs(), ordinary.get_all_runs())
  assert_indexed_state_matches_tree(direct)
}

///|
test "direct late construction failure consumes proof but yields no Document" {
  let ops = [@core.Op::insert(-1, [], "source", 0, "x", None, None)]
  let proof = @oplog.ClosedHistory::prepare_experimental(ops)
  assert_true(
    try Document::from_closed_history_internal("fresh", proof, true) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try Document::from_closed_history_experimental("another", proof) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}
