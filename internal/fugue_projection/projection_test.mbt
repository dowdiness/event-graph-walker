///|
fn target_raw() -> @core.RawVersion {
  @core.RawVersion::new("target", 0)
}

///|
fn target_fixture() -> (@causal_graph.CausalGraph, @core.Op) {
  let graph = @causal_graph.CausalGraph::new()
  let lv = try! graph.add_version_with_seq([], "target", 0)
  let op = @core.Op::new_insert(lv, [], "target", 0, "A", None, None)
  (graph, op)
}

///|
fn assert_visible(
  change : VisibilityChange,
  expected : @fugue.Lv,
) -> Unit raise {
  match change {
    VisibilityChange::BecameVisible(lv) => assert_eq(lv, expected)
    _ => fail("expected visible change")
  }
}

///|
fn assert_hidden(change : VisibilityChange, expected : @fugue.Lv) -> Unit raise {
  match change {
    VisibilityChange::BecameHidden(lv) => assert_eq(lv, expected)
    _ => fail("expected hidden change")
  }
}

///|
fn assert_unchanged(change : VisibilityChange) -> Unit raise {
  match change {
    VisibilityChange::Unchanged => ()
    _ => fail("expected unchanged")
  }
}

///|
fn capture_apply(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  graph : @causal_graph.CausalGraph,
) -> Result[Unit, FugueProjectionError] {
  Ok(apply(tree, op, graph)) catch {
    error => Err(error)
  }
}

///|
fn capture_observed(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  graph : @causal_graph.CausalGraph,
) -> Result[VisibilityChange, FugueProjectionError] {
  Ok(apply_with_visible_change(tree, op, graph)) catch {
    error => Err(error)
  }
}

///|
test "insert returns visible change" {
  let graph = @causal_graph.CausalGraph::new()
  let lv = try! graph.add_version_with_seq([], "agent", 0)
  let op = @core.Op::new_insert(lv, [], "agent", 0, "A", None, None)
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  let change = try! apply_with_visible_change(tree, op, graph)
  assert_visible(change, @fugue.Lv(lv))
  assert_eq(tree.to_text(), "A")
}

///|
test "insert resolves a present origin before mutation" {
  let (graph, first) = target_fixture()
  let second_lv = try! graph.add_version_with_seq([0], "second", 0)
  let second = @core.Op::new_insert(
    second_lv,
    [target_raw()],
    "second",
    0,
    "B",
    Some(target_raw()),
    None,
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply(tree, first, graph)

  let change = try! apply_with_visible_change(tree, second, graph)
  assert_visible(change, @fugue.Lv(second_lv))
  assert_eq(tree.to_text(), "AB")
}

///|
test "apply and observed insert have identical tree effects" {
  let (graph, op) = target_fixture()
  let direct : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  let observed : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  try! apply(direct, op, graph)
  let change = try! apply_with_visible_change(observed, op, graph)
  assert_visible(change, @fugue.Lv(0))
  assert_eq(direct.to_text(), observed.to_text())
  assert_eq(direct.visible_count(), observed.visible_count())
}

///|
test "apply and observed preserve delete and undelete effects" {
  let (graph, insert) = target_fixture()
  let delete_lv = try! graph.add_version_with_seq([0], "deleter", 0)
  let delete = @core.Op::new_delete(
    delete_lv,
    [target_raw()],
    "deleter",
    0,
    Some(target_raw()),
  )
  let undelete_lv = try! graph.add_version_with_seq([delete_lv], "reviver", 0)
  let undelete = @core.Op::new_undelete(
    undelete_lv,
    [target_raw()],
    "reviver",
    0,
    Some(target_raw()),
  )
  let direct : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  let observed : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply(direct, insert, graph)
  try! apply(observed, insert, graph)

  try! apply(direct, delete, graph)
  let _ = try! apply_with_visible_change(observed, delete, graph)
  assert_eq(direct.to_text(), observed.to_text())
  assert_eq(direct.visible_count(), observed.visible_count())

  try! apply(direct, undelete, graph)
  let _ = try! apply_with_visible_change(observed, undelete, graph)
  assert_eq(direct.to_text(), observed.to_text())
  assert_eq(direct.visible_count(), observed.visible_count())
}

///|
test "delete of visible target becomes hidden" {
  let (graph, insert) = target_fixture()
  let delete_lv = try! graph.add_version_with_seq([0], "deleter", 0)
  let delete = @core.Op::new_delete(
    delete_lv,
    [target_raw()],
    "deleter",
    0,
    Some(target_raw()),
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply(tree, insert, graph)

  let change = try! apply_with_visible_change(tree, delete, graph)
  assert_hidden(change, @fugue.Lv(0))
  assert_eq(tree.to_text(), "")
}

///|
test "winning delete of invisible target is unchanged" {
  let (graph, insert) = target_fixture()
  let first_lv = try! graph.add_version_with_seq([0], "deleter", 0)
  let first = @core.Op::new_delete(
    first_lv,
    [target_raw()],
    "deleter",
    0,
    Some(target_raw()),
  )
  let second_lv = try! graph.add_version_with_seq([first_lv], "deleter", 1)
  let second = @core.Op::new_delete(
    second_lv,
    [target_raw()],
    "deleter",
    1,
    Some(target_raw()),
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply(tree, insert, graph)
  try! apply(tree, first, graph)

  let change = try! apply_with_visible_change(tree, second, graph)
  assert_unchanged(change)
  assert_eq(tree.to_text(), "")
}

///|
test "losing delete leaves visibility unchanged" {
  let (graph, insert) = target_fixture()
  let winner_lv = try! graph.add_version_with_seq([0], "winner", 0)
  let winner = @core.Op::new_delete(
    winner_lv,
    [target_raw()],
    "winner",
    0,
    Some(target_raw()),
  )
  let loser_lv = try! graph.add_version_with_seq([0], "loser", 0)
  let loser = @core.Op::new_delete(
    loser_lv,
    [target_raw()],
    "loser",
    0,
    Some(target_raw()),
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply(tree, insert, graph)
  try! apply(tree, winner, graph)

  let change = try! apply_with_visible_change(tree, loser, graph)
  assert_unchanged(change)
  assert_eq(tree.to_text(), "")
}

///|
test "winning undelete of invisible target becomes visible with content" {
  let (graph, insert) = target_fixture()
  let delete_lv = try! graph.add_version_with_seq([0], "deleter", 0)
  let delete = @core.Op::new_delete(
    delete_lv,
    [target_raw()],
    "deleter",
    0,
    Some(target_raw()),
  )
  let undelete_lv = try! graph.add_version_with_seq([delete_lv], "reviver", 0)
  let undelete = @core.Op::new_undelete(
    undelete_lv,
    [target_raw()],
    "reviver",
    0,
    Some(target_raw()),
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply(tree, insert, graph)
  try! apply(tree, delete, graph)

  let change = try! apply_with_visible_change(tree, undelete, graph)
  assert_visible(change, @fugue.Lv(0))
  assert_eq(tree.to_text(), "A")
}

///|
test "equal-timestamp undelete wins when delete arrives first" {
  let (graph, insert) = target_fixture()
  let delete_lv = try! graph.add_version_with_seq([0], "deleter", 0)
  let delete = @core.Op::new_delete(
    delete_lv,
    [target_raw()],
    "deleter",
    0,
    Some(target_raw()),
  )
  let undelete_lv = try! graph.add_version_with_seq([0], "reviver", 0)
  let undelete = @core.Op::new_undelete(
    undelete_lv,
    [target_raw()],
    "reviver",
    0,
    Some(target_raw()),
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  try! apply(tree, insert, graph)
  try! apply(tree, delete, graph)
  try! apply(tree, undelete, graph)
  assert_eq(tree.to_text(), "A")
  assert_eq(tree.visible_count(), 1)
}

///|
test "equal-timestamp undelete wins when undelete arrives first" {
  let (graph, insert) = target_fixture()
  let delete_lv = try! graph.add_version_with_seq([0], "deleter", 0)
  let delete = @core.Op::new_delete(
    delete_lv,
    [target_raw()],
    "deleter",
    0,
    Some(target_raw()),
  )
  let undelete_lv = try! graph.add_version_with_seq([0], "reviver", 0)
  let undelete = @core.Op::new_undelete(
    undelete_lv,
    [target_raw()],
    "reviver",
    0,
    Some(target_raw()),
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  try! apply(tree, insert, graph)
  try! apply(tree, undelete, graph)
  try! apply(tree, delete, graph)
  assert_eq(tree.to_text(), "A")
  assert_eq(tree.visible_count(), 1)
}

///|
test "undelete of visible target and losing undelete are unchanged" {
  let (graph, insert) = target_fixture()
  let visible_lv = try! graph.add_version_with_seq([0], "reviver", 0)
  let visible = @core.Op::new_undelete(
    visible_lv,
    [target_raw()],
    "reviver",
    0,
    Some(target_raw()),
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply(tree, insert, graph)
  let visible_change = try! apply_with_visible_change(tree, visible, graph)
  assert_unchanged(visible_change)

  let winner_lv = try! graph.add_version_with_seq([0], "winner", 1)
  let winner = @core.Op::new_undelete(
    winner_lv,
    [target_raw()],
    "winner",
    1,
    Some(target_raw()),
  )
  let loser_lv = try! graph.add_version_with_seq([0], "loser", 1)
  let loser = @core.Op::new_undelete(
    loser_lv,
    [target_raw()],
    "loser",
    1,
    Some(target_raw()),
  )
  try! apply(tree, winner, graph)
  let loser_change = try! apply_with_visible_change(tree, loser, graph)
  assert_unchanged(loser_change)
  assert_eq(tree.to_text(), "A")
}

///|
test "targetless delete and undelete are no-ops without causal entries" {
  let graph = @causal_graph.CausalGraph::new()
  let delete = @core.Op::new_delete(99, [], "missing", 0, None)
  let undelete = @core.Op::new_undelete(100, [], "missing", 1, None)
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  try! apply(tree, delete, graph)
  let delete_change = try! apply_with_visible_change(tree, delete, graph)
  assert_unchanged(delete_change)
  try! apply(tree, undelete, graph)
  let undelete_change = try! apply_with_visible_change(tree, undelete, graph)
  assert_unchanged(undelete_change)
  assert_eq(tree.visible_count(), 0)
}

///|
test "missing right insert origin is reported before mutation" {
  let graph = @causal_graph.CausalGraph::new()
  let lv = try! graph.add_version_with_seq([], "agent", 0)
  let missing = @core.RawVersion::new("missing", 0)
  let op = @core.Op::new_insert(lv, [], "agent", 0, "A", None, Some(missing))
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  match capture_apply(tree, op, graph) {
    Err(FugueProjectionError::MissingOrigin(raw~)) => assert_eq(raw, missing)
    _ => fail("expected MissingOrigin")
  }
  assert_eq(tree.to_text(), "")
}

///|
test "missing causal entry is reported before insert or targeted mutation" {
  let graph = @causal_graph.CausalGraph::new()
  let insert = @core.Op::new_insert(0, [], "agent", 0, "A", None, None)
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  match capture_observed(tree, insert, graph) {
    Err(FugueProjectionError::MissingCausalEntry(lv~)) => assert_eq(lv, 0)
    _ => fail("expected MissingCausalEntry for insert")
  }
  assert_eq(tree.to_text(), "")

  let (graph_with_target, target) = target_fixture()
  let target_tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply(target_tree, target, graph_with_target)
  let delete = @core.Op::new_delete(
    99,
    [target_raw()],
    "deleter",
    0,
    Some(target_raw()),
  )
  match capture_apply(target_tree, delete, graph_with_target) {
    Err(FugueProjectionError::MissingCausalEntry(lv~)) => assert_eq(lv, 99)
    _ => fail("expected MissingCausalEntry for delete")
  }
  assert_eq(target_tree.to_text(), "A")
}

///|
test "missing causal entry is reported before targeted undelete" {
  let (graph, _) = target_fixture()
  let undelete = @core.Op::new_undelete(
    99,
    [target_raw()],
    "reviver",
    0,
    Some(target_raw()),
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  match capture_apply(tree, undelete, graph) {
    Err(FugueProjectionError::MissingCausalEntry(lv~)) => assert_eq(lv, 99)
    _ => fail("expected MissingCausalEntry for undelete")
  }
  assert_eq(tree.to_text(), "")
}

///|
test "missing Fugue target is reported before mutation" {
  let (graph, _) = target_fixture()
  let delete_lv = try! graph.add_version_with_seq([0], "deleter", 0)
  let delete = @core.Op::new_delete(
    delete_lv,
    [target_raw()],
    "deleter",
    0,
    Some(target_raw()),
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  match capture_observed(tree, delete, graph) {
    Err(FugueProjectionError::Fugue(error~)) =>
      match error {
        @fugue.FugueError::MissingItem(id~) => assert_eq(id, @fugue.Lv(0))
      }
    _ => fail("expected Fugue missing target")
  }
  assert_eq(tree.to_text(), "")
}

///|
test "missing Fugue target is reported before undelete mutation" {
  let (graph, _) = target_fixture()
  let undelete_lv = try! graph.add_version_with_seq([0], "reviver", 0)
  let undelete = @core.Op::new_undelete(
    undelete_lv,
    [target_raw()],
    "reviver",
    0,
    Some(target_raw()),
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  match capture_apply(tree, undelete, graph) {
    Err(FugueProjectionError::Fugue(error~)) =>
      match error {
        @fugue.FugueError::MissingItem(id~) => assert_eq(id, @fugue.Lv(0))
      }
    _ => fail("expected Fugue missing undelete target")
  }
  assert_eq(tree.to_text(), "")
}

///|
test "a later projection failure preserves the earlier successful prefix" {
  let (graph, target) = target_fixture()
  let missing_lv = try! graph.add_version_with_seq([], "missing", 0)
  let bad_delete_lv = try! graph.add_version_with_seq(
    [missing_lv],
    "deleter",
    0,
  )
  let bad_delete = @core.Op::new_delete(
    bad_delete_lv,
    [@core.RawVersion::new("missing", 0)],
    "deleter",
    0,
    Some(@core.RawVersion::new("missing", 0)),
  )
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  let result : Result[Unit, FugueProjectionError] = try {
    apply_all(tree, [target, bad_delete][:], graph)
    Ok(())
  } catch {
    error => Err(error)
  }
  match result {
    Err(FugueProjectionError::Fugue(_)) => ()
    _ => fail("expected failed later projection")
  }
  assert_eq(tree.to_text(), "A")
  assert_eq(tree.visible_count(), 1)
}
