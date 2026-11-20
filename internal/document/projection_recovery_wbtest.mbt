///| Projection health and canonical recovery tests for Document

///|
fn Document::replace_projection_tree(
  self : Document,
  tree : @fugue.FugueTree[String],
) -> Unit {
  self.tree = tree
}

///|
test "failure remains unavailable across hidden admission until explicit reopening" {
  let doc = Document::new("retry-local")
  doc.set_apply_changes_hooks({
    on_action: () => (),
    on_apply_changes: () => (),
    on_projection_finalization: _ => (),
    action_override: None,
    commit_failure: None,
    projection_failure: Some(_ => {
      Some(
        DocumentError::Fugue(@fugue.FugueError::MissingItem(id=@fugue.Lv(999))),
      )
    }),
  })
  let first = try! doc.apply_changes(p2_ready_batch("retry-peer", 1))
  assert_true(first.publication is Unavailable(_))
  let expected_version = doc.current_graph_version()
  let hidden = p2_ready_batch("hidden-peer", 1).map(op => {
    try! @core.StructuralOp(op)
  })
  ignore(try! doc.admit_structural_changes(hidden[:], 100))
  // A failed retry must not recapture the newer history as its target.
  let retry : Result[Unit, DocumentError] = Ok(doc.prepare_for_mutation()) catch {
    error => Err(error)
  }
  assert_true(retry is Err(DocumentError::Fugue(_)))
  let still_unavailable = Ok(doc.to_text()) catch { error => Err(error) }
  assert_true(still_unavailable is Err(DocumentError::Fugue(_)))
  assert_true(doc.current_graph_version() != expected_version)
  doc.apply_changes_hooks = None
  try! doc.integrate_projection()
  assert_eq(doc.visible_count(), 2)
  ignore(try! doc.insert(2, "!"))
  try! doc.advance_projection()
  assert_eq(doc.view_graph_version(), doc.current_graph_version())
  assert_eq(doc.visible_count(), 3)
  let expected = (try! doc.checkout_branch(doc.get_frontier())).to_text()
  assert_eq(doc.to_text(), expected)
  try! doc.advance_projection()
  assert_eq(doc.to_text(), expected)
}

///|
test "reopening includes all accepted history instead of repairing an old cut" {
  let doc = Document::new("retained-local")
  ignore(try! doc.insert(0, "abc"))
  let version = doc.view_graph_version()
  let hidden = p2_ready_batch("hidden-peer", 1).map(op => {
    try! @core.StructuralOp(op)
  })
  ignore(try! doc.admit_structural_changes(hidden[:], 100))
  try! doc.tree.delete(@fugue.Lv(1))
  try! doc.integrate_projection()
  assert_eq(doc.visible_count(), 4)
  assert_eq(doc.view_graph_version(), doc.current_graph_version())
  assert_true(doc.current_graph_version() != version)
  ignore(try! doc.insert(4, "!"))
  try! doc.advance_projection()
  assert_eq(doc.visible_count(), 5)
  assert_eq(doc.view_graph_version(), doc.current_graph_version())
  assert_eq(
    doc.to_text(),
    (try! doc.checkout_branch(doc.get_frontier())).to_text(),
  )
}

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

  try! doc.recover_projection()

  assert_eq(doc.tree.to_text(), "abc")
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  assert_true(doc.cursor is None)
  assert_true(doc.indexed_state.is_ready())
  assert_eq(doc.to_text(), "abc")
  let fresh = try! @branch.Branch::checkout(doc.oplog, frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}

///|
test "derived readers reject invalid projection until explicit reopening" {
  let doc = Document::new("recovery-reader")
  ignore(try! doc.insert(0, "abc"))
  let frontier = doc.get_frontier()
  try! doc.tree.delete(@fugue.Lv(1))
  doc.invalidate_projection(
    DocumentError::ProjectionRecoveryRequired(
      frontier~,
      error=@branch.BranchError::MissingOp(lv=1),
    ),
  )
  let read = Ok(doc.to_text()) catch { error => Err(error) }
  assert_true(read is Err(DocumentError::ProjectionRecoveryRequired(..)))
  assert_eq(doc.tree.to_text(), "ac")
  doc.integrate_projection()

  assert_eq(doc.to_text(), "abc")
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  assert_true(doc.cursor is None)
}

///|
test "fallible local mutation does not retry recovery" {
  let doc = Document::new("recovery-mutation")
  ignore(try! doc.insert(0, "abc"))
  let frontier = doc.get_frontier()
  try! doc.tree.delete(@fugue.Lv(1))
  doc.invalidate_projection(
    DocumentError::ProjectionRecoveryRequired(
      frontier~,
      error=@branch.BranchError::MissingOp(lv=1),
    ),
  )
  let mutation = Ok(doc.insert(3, "!")) catch { error => Err(error) }
  assert_true(mutation is Err(DocumentError::ProjectionRecoveryRequired(..)))
  assert_eq(doc.get_frontier(), frontier)
  doc.integrate_projection()
  ignore(try! doc.insert(3, "!"))

  assert_eq(doc.to_text(), "abc!")
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  assert_true(doc.cursor is Some(_))
}

///|
test "recovery checkout failure keeps the document fail-closed" {
  let doc = Document::new("recovery-failure")
  ignore(try! doc.insert(0, "abc"))
  ignore(doc.to_text())
  try! doc.tree.delete(@fugue.Lv(1))
  let before_frontier = doc.get_frontier()

  let result : Result[Unit, DocumentError] = try {
    doc.recover_projection_with((_, _) => {
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
  assert_true(doc.projection_health is ProjectionHealth::Unavailable(_))
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  assert_eq(doc.get_frontier(), before_frontier)
  assert_eq(doc.tree.to_text(), "ac")
}

///|
test "derived reader returns typed error after recovery failure" {
  let doc = Document::new("recovery-reader-failure")
  ignore(try! doc.insert(0, "abc"))
  let result : Result[Unit, DocumentError] = try {
    doc.recover_projection_with((_, _) => {
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
  let read = Ok(doc.to_text()) catch { error => Err(error) }
  assert_true(read is Err(DocumentError::ProjectionRecoveryRequired(..)))
}

///|
test "recovery failure blocks later mutation and remote change application" {
  let doc = Document::new("recovery-mutation-failure")
  ignore(try! doc.insert(0, "abc"))
  let before_frontier = doc.get_frontier()
  let before_count = doc.oplog.op_count()
  let before_pending = doc.oplog.has_pending()
  let before_tree = doc.tree.to_text()
  let result : Result[Unit, DocumentError] = try {
    doc.recover_projection_with((_, _) => {
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
    _ => fail("expected change application recovery failure")
  }
  assert_eq(doc.oplog.op_count(), before_count)
  assert_eq(doc.get_frontier(), before_frontier)
  assert_eq(doc.oplog.has_pending(), before_pending)
  assert_eq(doc.tree.to_text(), before_tree)
}
