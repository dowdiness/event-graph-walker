///| Differential checks for the package-private indexed visible projection.

///|
fn assert_indexed_state_matches_tree(doc : Document) -> Unit raise {
  let items = doc.tree.get_visible_items()
  let state = doc.indexed_state
  assert_true(state.text(doc.tree) == doc.tree.to_text())
  assert_true(state.visible_span(doc.tree) == items.length())
  assert_true(state.position_to_lv(doc.tree, 0) == -1)
  for i = 0; i < items.length(); i = i + 1 {
    let (lv, _) = items[i]
    assert_true(state.lv_at_position(doc.tree, i) == Some(lv.0))
    assert_true(state.lv_to_position(doc.tree, lv.0) == Some(i))
    assert_true(state.position_to_lv(doc.tree, i + 1) == lv.0)
  }
  assert_true(state.lv_at_position(doc.tree, items.length()) is None)
}

///|
test "IndexedState agrees with Fugue after local insert and delete" {
  let doc = Document::new("local-index")
  ignore(try! doc.insert(0, "abc😀d"))
  assert_indexed_state_matches_tree(doc)

  ignore(try! doc.insert(2, "XY"))
  assert_indexed_state_matches_tree(doc)

  try! doc.delete_range(1, 4)
  assert_indexed_state_matches_tree(doc)

  let _ = try! doc.undelete(1)
  assert_indexed_state_matches_tree(doc)
}

///|
test "IndexedState agrees with Fugue after remote apply" {
  let alice = Document::new("alice-index")
  let bob = Document::new("bob-index")
  ignore(try! alice.insert(0, "abc"))
  for op in alice.get_all_ops() {
    try! bob.apply_remote(op)
  }
  assert_indexed_state_matches_tree(bob)

  let delete_op = try! alice.delete(1)
  try! bob.apply_remote(delete_op)
  assert_indexed_state_matches_tree(bob)

  let undelete_op = try! alice.undelete(1)
  try! bob.apply_remote(undelete_op)
  assert_indexed_state_matches_tree(bob)
}

///|
test "IndexedState agrees with Fugue after Document::merge_remote" {
  let destination = Document::new("destination-index")
  ignore(try! destination.insert(0, "abc"))

  // Build a realistic remote source from the destination's shared history.
  let remote = Document::new("remote-index")
  for op in destination.get_all_ops() {
    try! remote.apply_remote(op)
  }
  ignore(try! remote.insert(1, "XY"))
  ignore(try! remote.delete(0))

  // Warm the destination before production merge_remote mutates its Fugue tree.
  assert_indexed_state_matches_tree(destination)
  let remote_ops = remote.get_all_ops()
  let remote_frontier = try! remote.get_frontier_raw()
  try! destination.merge_remote(remote_ops, remote_frontier)

  // The indexed projection must match Fugue's visible order after the merge.
  assert_indexed_state_matches_tree(destination)
  assert_true(destination.to_text() == remote.to_text())
}
