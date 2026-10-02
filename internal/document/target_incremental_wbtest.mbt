///|
test "compensation direct visibility obeys ItemState and delete count" {
  let doc = Document::new("target-state")
  ignore(try! doc.insert(0, "a😀b"))
  let item = doc.tree.get(@fugue.Lv(1)).unwrap()
  // Predicate follows the same two-count semantics as Fugue traversal.
  item.delete_count = 1
  assert_true(!(try! doc.target_is_visible(1)))
  item.delete_count = 0
  assert_true(try! doc.target_is_visible(1))
  assert_true((try! doc.delete_if_visible(1)) is Applied)
  assert_true(doc.indexed_state.is_ready())
  assert_indexed_state_matches_tree(doc)
  let before = doc.get_all_ops().length()
  assert_true((try! doc.delete_if_visible(1)) is Stale)
  assert_eq(doc.get_all_ops().length(), before)
  assert_true((try! doc.undelete_if_deleted(1)) is Applied)
  assert_true(doc.indexed_state.is_ready())
  assert_indexed_state_matches_tree(doc)
  assert_eq(doc.to_text(), "a😀b")
}

///|
test "cold compensation never constructs an index per target" {
  let doc = Document::new("cold-target")
  ignore(try! doc.insert(0, "abcdef"))
  doc.invalidate_cache()
  for lv = 0; lv < 6; lv = lv + 1 {
    assert_true((try! doc.delete_if_visible(lv)) is Applied)
    assert_true(!doc.indexed_state.is_ready())
  }
  assert_eq(doc.to_text(), "")
  for lv = 0; lv < 6; lv = lv + 1 {
    assert_true((try! doc.undelete_if_deleted(lv)) is Applied)
    assert_true(doc.indexed_state.is_ready())
  }
  assert_eq(doc.to_text(), "abcdef")
  assert_indexed_state_matches_tree(doc)
}

///|
test "committed target failure repairs canonical projection before propagation" {
  let doc = Document::new("recover-target")
  ignore(try! doc.insert(0, "abc"))
  doc.tree = @fugue.FugueTree::new()
  try doc.commit_delete_by_lv(0) catch {
    _ => ()
  } noraise {
    _ => fail("expected committed target projection to raise")
  }
  assert_eq(doc.get_all_ops().length(), 4)
  assert_eq(doc.to_text(), "bc")
  assert_indexed_state_matches_tree(doc)
}

///|
test "range post-commit failure repairs committed prefix without rollback" {
  let doc = Document::new("recover-range")
  ignore(try! doc.insert(0, "abcd"))
  assert_eq(doc.to_text(), "abcd")
  doc.tree = @fugue.FugueTree::new()
  try doc.delete_range(0, 3) catch {
    _ => ()
  } noraise {
    _ => fail("expected range projection to raise")
  }
  assert_eq(doc.get_all_ops().length(), 5)
  assert_eq(doc.to_text(), "bcd")
  assert_indexed_state_matches_tree(doc)
}
