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
  doc.projection_health = ProjectionHealth::RecoveryRequired(frontier~, checkout=(
    oplog,
    frontier,
  ) => @branch.Branch::checkout(oplog, frontier))

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
  doc.projection_health = ProjectionHealth::RecoveryRequired(frontier~, checkout=(
    oplog,
    frontier,
  ) => @branch.Branch::checkout(oplog, frontier))

  ignore(try! doc.insert(3, "!"))

  assert_eq(doc.to_text(), "abc!")
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  assert_true(doc.cursor is Some(_))
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
    Err(DocumentError::ProjectionRecoveryRequired(frontier~, error~)) => {
      assert_eq(frontier, before_frontier)
      match error {
        @branch.BranchError::MissingOp(lv~) => assert_eq(lv, 999)
        _ => fail("expected checkout cause")
      }
    }
    _ => fail("expected typed projection recovery failure")
  }
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  assert_eq(doc.get_frontier(), before_frontier)
  assert_eq(doc.tree.to_text(), "ac")
}

///|
test "panic derived reader fails closed after recovery failure" {
  let doc = Document::new("recovery-reader-failure")
  ignore(try! doc.insert(0, "abc"))
  let frontier = doc.get_frontier()
  let result : Result[Unit, DocumentError] = try {
    doc.recover_projection_with(frontier, (_, _) => {
      raise @branch.BranchError::MissingOp(lv=999)
    })
    Ok(())
  } catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("expected typed projection recovery failure")
  }
  ignore(doc.to_text())
}

///|
test "recovery failure blocks later mutation and remote admission" {
  let doc = Document::new("recovery-mutation-failure")
  ignore(try! doc.insert(0, "abc"))
  let frontier = doc.get_frontier()
  let before_frontier = doc.get_frontier()
  let before_count = doc.oplog.op_count()
  let before_pending = doc.oplog.has_pending()
  let before_tree = doc.tree.to_text()
  let result : Result[Unit, DocumentError] = try {
    doc.recover_projection_with(frontier, (_, _) => {
      raise @branch.BranchError::MissingOp(lv=999)
    })
    Ok(())
  } catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("expected typed projection recovery failure")
  }

  let insert_result : Result[@core.Op, DocumentError] = Ok(doc.insert(3, "!")) catch {
    error => Err(error)
  }
  match insert_result {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("expected mutation recovery failure")
  }

  let remote = @core.Op::insert(-1, [], "remote", 0, "r", None, None)
  let remote_result : Result[Unit, DocumentError] = try {
    doc.apply_remote(remote)
    Ok(())
  } catch {
    error => Err(error)
  }
  match remote_result {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("expected admission recovery failure")
  }
  assert_eq(doc.oplog.op_count(), before_count)
  assert_eq(doc.get_frontier(), before_frontier)
  assert_eq(doc.oplog.has_pending(), before_pending)
  assert_eq(doc.tree.to_text(), before_tree)
}
