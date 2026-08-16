///| Projection health and canonical recovery tests for Document

///|
test "recover_projection replaces a divergent tree and resets derived state" {
  let doc = Document::new("recovery-preflight")
  ignore(try! doc.insert(0, "abc"))
  let frontier = doc.get_frontier()
  ignore(doc.to_text())
  assert_true(doc.indexed_state.is_ready())
  assert_true(doc.cursor is Some(_))

  try! doc.tree.delete(@fugue.Lv(1))
  assert_eq(doc.tree.to_text(), "ac")

  try! doc.recover_projection(frontier)

  assert_eq(doc.tree.to_text(), "abc")
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  assert_true(doc.cursor is None)
  assert_true(!doc.indexed_state.is_ready())
  assert_eq(doc.to_text(), "abc")
  let fresh = try! @branch.Branch::checkout(doc.oplog, frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}

///|
test "derived readers retry recovery before reading" {
  let doc = Document::new("recovery-reader")
  ignore(try! doc.insert(0, "abc"))
  let frontier = doc.get_frontier()
  try! doc.tree.delete(@fugue.Lv(1))
  doc.projection_health = ProjectionHealth::RecoveryRequired(frontier~)

  assert_eq(doc.to_text(), "abc")
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  assert_true(doc.cursor is None)
}

///|
test "fallible local mutation retries recovery before mutation" {
  let doc = Document::new("recovery-mutation")
  ignore(try! doc.insert(0, "abc"))
  let frontier = doc.get_frontier()
  try! doc.tree.delete(@fugue.Lv(1))
  doc.projection_health = ProjectionHealth::RecoveryRequired(frontier~)

  ignore(try! doc.insert(3, "!"))

  assert_eq(doc.to_text(), "abc!")
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  assert_true(doc.cursor is Some(_))
}

///|
test "post-commit projection failure recovers without authority rollback" {
  let doc = Document::new("recovery-post-commit")
  ignore(try! doc.insert(0, "base"))
  ignore(doc.to_text())
  let incoming = @core.Op::insert(-1, [], "remote", 0, "r", None, None)

  let result : Result[Unit, DocumentError] = try {
    doc.apply_remote_with(incoming, _ => {
      ignore(try! doc.oplog.insert("committed", -1, -1))
      [@core.Op::insert(999, [], "synthetic", 0, "x", None, None)]
    })
    Ok(())
  } catch {
    error => Err(error)
  }

  match result {
    Err(DocumentError::OpLog(@oplog.OpLogError::MissingLocalVersion(lv~))) =>
      assert_eq(lv, 999)
    _ => fail("expected post-commit projection failure")
  }
  assert_eq(doc.oplog.op_count(), 5)
  assert_eq(doc.tree.to_text(), "basecommitted")
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  assert_true(doc.cursor is None)
  assert_true(!doc.indexed_state.is_ready())
  let fresh = try! @branch.Branch::checkout(doc.oplog, doc.get_frontier())
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}

///|
test "recovery checkout failure keeps the document fail-closed" {
  let doc = Document::new("recovery-failure")
  ignore(try! doc.insert(0, "abc"))
  let frontier = doc.get_frontier()
  ignore(doc.to_text())
  try! doc.tree.delete(@fugue.Lv(1))
  let before_frontier = doc.get_frontier()

  let result : Result[Unit, DocumentError] = try {
    doc.recover_projection_with(frontier, (_, _) => {
      raise @branch.BranchError::MissingOp(lv=999)
    })
    Ok(())
  } catch {
    error => Err(error)
  }

  match result {
    Err(DocumentError::ProjectionRecoveryRequired(frontier~)) =>
      assert_eq(frontier, before_frontier)
    _ => fail("expected typed projection recovery failure")
  }
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  assert_eq(doc.get_frontier(), before_frontier)
  assert_eq(doc.tree.to_text(), "ac")
}
