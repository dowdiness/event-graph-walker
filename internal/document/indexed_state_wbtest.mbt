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
  assert_true(doc.indexed_state.is_ready())

  ignore(try! doc.insert(2, "XY"))
  assert_true(doc.indexed_state.is_ready())
  assert_indexed_state_matches_tree(doc)

  try! doc.delete_range(1, 4)
  // Large local batches invalidate rather than maintaining many index edits.
  assert_true(!doc.indexed_state.is_ready())
  assert_indexed_state_matches_tree(doc)
  assert_true(doc.indexed_state.is_ready())

  let _ = try! doc.undelete(1)
  // Local undelete remains a conservative invalidation path.
  assert_true(!doc.indexed_state.is_ready())
  assert_indexed_state_matches_tree(doc)
  assert_true(doc.indexed_state.is_ready())
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
  assert_true(bob.indexed_state.is_ready())

  let delete_op = try! alice.delete(1)
  try! bob.apply_remote(delete_op)
  // Successful detached publication installs the matching warm generation.
  assert_true(bob.indexed_state.is_ready())
  assert_indexed_state_matches_tree(bob)

  let undelete_op = try! alice.undelete(1)
  try! bob.apply_remote(undelete_op)
  assert_true(bob.indexed_state.is_ready())
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
  // Merge atomically publishes the matching warm projection generation.
  assert_true(destination.indexed_state.is_ready())

  // The indexed projection must match Fugue's visible order after the merge.
  assert_indexed_state_matches_tree(destination)
  assert_true(destination.indexed_state.is_ready())
  assert_true(destination.to_text() == remote.to_text())
}

///|
test "property: published LV locator agrees with Fugue after randomized structural mutation" {
  let seeds : Array[Int] = @quickcheck.samples(24)
  for raw_seed in seeds {
    let doc = Document::new("locator-property")
    let deleted : Array[Int] = []
    let mut state = raw_seed % 997
    if state < 0 {
      state = -state
    }
    for step = 0; step < 80; step = step + 1 {
      state = (state * 37 + 17) % 997
      let action = state % 5
      if action < 3 || doc.tree.visible_count() == 0 {
        let position = state % (doc.tree.visible_count() + 1)
        let text = if state % 3 == 0 { "😀" } else { "x" }
        ignore(try! doc.insert(position, text))
      } else if action == 3 {
        let position = state % doc.tree.visible_count()
        match doc.lv_at_position(position) {
          Some(lv) => {
            ignore(try! doc.delete(position))
            deleted.push(lv)
          }
          None => ()
        }
      } else if deleted.length() > 0 {
        let index = state % deleted.length()
        ignore(try! doc.undelete(deleted[index]))
        ignore(deleted.remove(index))
      }
      assert_indexed_state_matches_tree(doc)
    }
  }
}
