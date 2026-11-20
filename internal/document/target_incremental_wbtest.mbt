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
test "committed target failure remains unavailable until explicit integration" {
  let doc = Document::new("recover-target")
  ignore(try! doc.insert(0, "abc"))
  doc.tree = @fugue.FugueTree::new()
  try doc.commit_delete_by_lv(0) catch {
    _ => ()
  } noraise {
    _ => fail("expected committed target projection to raise")
  }
  assert_eq(doc.get_all_ops().length(), 4)
  try doc.to_text() catch {
    _ => ()
  } noraise {
    _ => fail("read must not repair projection")
  }
  try doc.insert(0, "x") catch {
    _ => ()
  } noraise {
    _ => fail("mutation must not repair projection")
  }
  assert_eq(doc.get_all_ops().length(), 4)
  doc.integrate_projection()
  assert_eq(doc.to_text(), "bc")
  assert_indexed_state_matches_tree(doc)
}

///|
test "range post-commit failure preserves history without implicit repair" {
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
  try doc.to_text() catch {
    _ => ()
  } noraise {
    _ => fail("read must not repair projection")
  }
  doc.integrate_projection()
  assert_eq(doc.to_text(), "bcd")
  assert_indexed_state_matches_tree(doc)
}

///|
test "single delete failure preserves committed history and blocks readers" {
  let doc = Document::new("failed-single-delete")
  ignore(doc.insert(0, "abc"))
  assert_eq(doc.to_text(), "abc")
  doc.tree = @fugue.FugueTree::new()
  let deletion = Ok(doc.delete(0)) catch { error => Err(error) }
  assert_true(deletion is Err(DocumentError::Fugue(_)))
  assert_eq(doc.get_all_ops().length(), 4)
  let read = Ok(doc.visible_count()) catch { error => Err(error) }
  assert_true(read is Err(DocumentError::Fugue(_)))
  let mutation = Ok(doc.delete(0)) catch { error => Err(error) }
  assert_true(mutation is Err(DocumentError::Fugue(_)))
  assert_eq(doc.get_all_ops().length(), 4)
  assert_true(!doc.indexed_state.is_ready())
  doc.integrate_projection()
  assert_eq(doc.to_text(), "bc")
  assert_indexed_state_matches_tree(doc)
}

///|
test "cold valid projection publishes snapshot and lazily builds paired index" {
  let source = Document::new("cold-publication-source")
  ignore(source.insert(0, "😀a"))
  let doc = Document::new("cold-publication-receiver")
  doc.invalidate_cache()
  let change = doc.apply_changes(source.get_all_ops())
  assert_true(change.outcome is @oplog.ApplyChangesOutcome::Succeeded(_))
  assert_true(change.publication is SnapshotRequired)
  assert_true(doc.projection_health is Ready)
  assert_true(!doc.indexed_state.is_ready())
  assert_eq(doc.to_text(), "😀a")
  assert_true(doc.indexed_state.is_ready())
  assert_indexed_state_matches_tree(doc)
  let duplicate = doc.apply_changes(source.get_all_ops())
  match duplicate.publication {
    Exact(edits) => assert_eq(edits.length(), 0)
    _ => fail("duplicate publication must own exact empty edits")
  }
}
