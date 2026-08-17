/// P2.3 differential gate: typed batch admission is checked against the
/// legacy wrappers and a fresh Branch checkout at every meaningful boundary.

///|
fn p2_diff_assert_state(control : Document, legacy : Document) -> Unit raise {
  assert_eq(control.get_frontier(), legacy.get_frontier())
  p2_assert_same_operations(control.get_all_ops(), legacy.get_all_ops())
  assert_eq(control.oplog.has_pending(), legacy.oplog.has_pending())
  assert_eq(control.tree.to_text(), legacy.tree.to_text())
  let control_fresh = try! @branch.Branch::checkout(
    control.oplog,
    control.get_frontier(),
  )
  let legacy_fresh = try! @branch.Branch::checkout(
    legacy.oplog,
    legacy.get_frontier(),
  )
  assert_eq(control.tree.to_text(), control_fresh.to_text())
  assert_eq(control.get_frontier(), control_fresh.get_frontier())
  assert_eq(legacy.tree.to_text(), legacy_fresh.to_text())
  assert_eq(legacy.get_frontier(), legacy_fresh.get_frontier())
}

///|
fn p2_diff_hooks(
  doc : Document,
  failed_index : Int?,
  projection_error : DocumentError?,
  recovery_error : @branch.BranchError?,
) -> Unit {
  doc.set_admission_hooks({
    on_prepare_remote: () => (),
    on_commit_admission: () => (),
    on_projection_finalization: _ => (),
    prepare_override: None,
    commit_failure: Some(op => {
      match failed_index {
        Some(index) if op.seq() == index =>
          Some(@causal_graph.CausalGraphError::MissingParent(lv=-311))
        _ => None
      }
    }),
    projection_failure: Some(_ => projection_error),
    recovery_checkout: match recovery_error {
      Some(error) => Some(_frontier => raise error)
      None => None
    },
  })
}

///|
test "P2.3 differential gate covers complete duplicate pending and prefixes" {
  let complete = p2_ready_batch("p2-diff-complete", 3)
  let typed_complete = Document::new("p2-diff-typed-complete")
  let legacy_complete = Document::new("p2-diff-legacy-complete")
  let typed = try! typed_complete.admit_remote(complete)
  try! legacy_complete.merge_remote(
    complete,
    try! typed_complete.get_frontier_raw(),
  )
  match typed.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => {
      p2_assert_operation_prefix(receipt.committed(), complete, 3)
      assert_eq(receipt.frontier_after(), typed_complete.get_frontier())
    }
    @oplog.AdmissionOutcome::Partial(..) => fail("complete differential case")
  }
  match typed.projection {
    ProjectionStatus::Projected => ()
    _ => fail("complete differential projection status")
  }
  p2_diff_assert_state(typed_complete, legacy_complete)

  let typed_duplicate = try! typed_complete.admit_remote(complete)
  let legacy_duplicate : Result[Unit, DocumentError] = Ok(
    legacy_complete.merge_remote(
      complete,
      try! typed_complete.get_frontier_raw(),
    ),
  ) catch {
    error => Err(error)
  }
  match legacy_duplicate {
    Ok(_) => ()
    Err(_) => fail("duplicate wrapper must not fail")
  }
  match typed_duplicate.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) =>
      assert_eq(receipt.committed().length(), 0)
    @oplog.AdmissionOutcome::Partial(..) => fail("duplicate differential case")
  }
  match typed_duplicate.projection {
    ProjectionStatus::Skipped => ()
    _ => fail("duplicate differential projection status")
  }
  p2_diff_assert_state(typed_complete, legacy_complete)

  let pending = p2_pending_batch("p2-diff-pending")
  let typed_pending_doc = Document::new("p2-diff-typed-pending")
  let legacy_pending_doc = Document::new("p2-diff-legacy-pending")
  let typed_pending = try! typed_pending_doc.admit_remote(pending)
  let legacy_pending : Result[Unit, DocumentError] = Ok(
    legacy_pending_doc.apply_remote(pending[0]),
  ) catch {
    error => Err(error)
  }
  match legacy_pending {
    Ok(_) => ()
    Err(DocumentError::OpLog(@oplog.OpLogError::PartialRemoteAdmission(..))) =>
      ()
    Err(_) => fail("pending wrapper error shape changed")
  }
  match typed_pending.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) =>
      p2_assert_identity_prefix(receipt.pending_from_transition(), pending, 1)
    @oplog.AdmissionOutcome::Partial(..) => fail("pending differential case")
  }
  match typed_pending.projection {
    ProjectionStatus::Skipped => ()
    _ => fail("pending differential projection status")
  }
  p2_diff_assert_state(typed_pending_doc, legacy_pending_doc)

  for failed_index in [0, 1, 2] {
    let incoming = p2_ready_batch(
      "p2-diff-prefix-" + failed_index.to_string(),
      3,
    )
    let remote_frontier = [
      @core.RawVersion(incoming[2].agent(), incoming[2].seq()),
    ]
    let typed_doc = Document::new(
      "p2-diff-typed-prefix-" + failed_index.to_string(),
    )
    let legacy_doc = Document::new(
      "p2-diff-legacy-prefix-" + failed_index.to_string(),
    )
    p2_diff_hooks(typed_doc, Some(failed_index), None, None)
    p2_diff_hooks(legacy_doc, Some(failed_index), None, None)
    let typed_result = try! typed_doc.admit_remote(incoming)
    let legacy_result : Result[Unit, DocumentError] = Ok(
      legacy_doc.merge_remote(incoming, remote_frontier),
    ) catch {
      error => Err(error)
    }
    match typed_result.outcome {
      @oplog.AdmissionOutcome::Partial(receipt~, error~) => {
        p2_assert_operation_prefix(receipt.committed(), incoming, failed_index)
        match error {
          @causal_graph.CausalGraphError::MissingParent(lv~) =>
            assert_eq(lv, -311)
          _ => fail("typed prefix cause changed")
        }
      }
      @oplog.AdmissionOutcome::Complete(_) => fail("prefix must be partial")
    }
    match typed_result.projection {
      ProjectionStatus::Skipped if failed_index == 0 => ()
      ProjectionStatus::Projected if failed_index > 0 => ()
      _ => fail("prefix projection status changed")
    }
    match legacy_result {
      Err(
        DocumentError::OpLog(
          @oplog.OpLogError::PartialRemoteAdmission(committed~, error~)
        )
      ) => {
        assert_eq(committed.length(), failed_index)
        p2_assert_operation_prefix(committed, incoming, failed_index)
        match error {
          @causal_graph.CausalGraphError::MissingParent(lv~) =>
            assert_eq(lv, -311)
          _ => fail("legacy prefix cause changed")
        }
      }
      Ok(_) => fail("legacy prefix must expose partial error")
      Err(_) => fail("legacy prefix error shape changed")
    }
    p2_diff_assert_state(typed_doc, legacy_doc)
  }
}

///|
test "P2.3 differential gate covers divergence recovery required and retry" {
  let typed_doc = Document::new("p2-diff-divergence-document")
  let legacy_doc = Document::new("p2-diff-divergence-document")
  let known_t = try! typed_doc.insert(0, "Y")
  let known_l = try! legacy_doc.insert(0, "Y")
  ignore(known_l)
  let known = @core.RawVersion(known_t.agent(), known_t.seq())
  let missing = @core.RawVersion("p2-diff-divergence-missing", 0)
  let incoming = [
    p2_remote_insert("p2-diff-divergence", 0, [missing], Some(known)),
  ]
  typed_doc.replace_projection_tree(@fugue.FugueTree::new())
  legacy_doc.replace_projection_tree(@fugue.FugueTree::new())
  p2_diff_hooks(typed_doc, None, None, None)
  p2_diff_hooks(legacy_doc, None, None, None)
  let typed = try! typed_doc.admit_remote(incoming)
  try! legacy_doc.apply_remote(incoming[0])
  match typed.projection {
    ProjectionStatus::Recovered => ()
    _ => fail("preflight recovery status changed")
  }
  assert_true(typed_doc.oplog.has_pending())
  p2_diff_assert_state(typed_doc, legacy_doc)

  let recovery_t = Document::new("p2-diff-typed-recovery")
  let recovery_l = Document::new("p2-diff-legacy-recovery")
  let batch = p2_ready_batch("p2-diff-recovery", 2)
  let projection_error = DocumentError::Fugue(
    @fugue.FugueError::MissingItem(id=@fugue.Lv(991)),
  )
  p2_diff_hooks(recovery_t, None, Some(projection_error), None)
  p2_diff_hooks(recovery_l, None, Some(projection_error), None)
  let recovered = try! recovery_t.admit_remote(batch)
  let legacy_recovery : Result[Unit, DocumentError] = Ok(
    recovery_l.merge_remote(batch, [@core.RawVersion("p2-diff-recovery", 1)]),
  ) catch {
    error => Err(error)
  }
  match recovered.projection {
    ProjectionStatus::Recovered => ()
    _ => fail("post-commit recovery status changed")
  }
  match legacy_recovery {
    Ok(_) => ()
    Err(_) => fail("successful recovery must remain transparent to wrapper")
  }
  p2_diff_assert_state(recovery_t, recovery_l)

  let required = Document::new("p2-diff-required")
  let required_legacy = Document::new("p2-diff-required")
  p2_diff_hooks(
    required,
    None,
    Some(projection_error),
    Some(@branch.BranchError::MissingOp(lv=992)),
  )
  p2_diff_hooks(
    required_legacy,
    None,
    Some(projection_error),
    Some(@branch.BranchError::MissingOp(lv=992)),
  )
  let required_admission = try! required.admit_remote(batch)
  let required_error : Result[Unit, DocumentError] = Ok(
    required_legacy.merge_remote(batch, [
      @core.RawVersion("p2-diff-recovery", 1),
    ]),
  ) catch {
    error => Err(error)
  }
  match required_admission.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) =>
      p2_assert_operation_prefix(receipt.committed(), batch, 2)
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("recovery control must retain receipt")
  }
  match required_error {
    Err(DocumentError::ProjectionRecoveryRequired(frontier~, error~)) => {
      assert_eq(frontier, required.get_frontier())
      match error {
        @branch.BranchError::MissingOp(lv~) => assert_eq(lv, 992)
        _ => fail("legacy recovery cause changed")
      }
    }
    _ => fail("wrapper must prioritize recovery failure")
  }
  assert_eq(required.get_frontier(), required_legacy.get_frontier())
  p2_assert_same_operations(
    required.get_all_ops(),
    required_legacy.get_all_ops(),
  )
  match required_admission.projection {
    ProjectionStatus::RecoveryRequired(error~) =>
      match error {
        @branch.BranchError::MissingOp(lv~) => assert_eq(lv, 992)
        _ => fail("unexpected recovery cause")
      }
    _ => fail("RecoveryRequired evidence was lost")
  }
  assert_eq(required.tree.to_text(), required_legacy.tree.to_text())
  assert_eq(required.oplog.has_pending(), required_legacy.oplog.has_pending())
  let required_fresh = try! @branch.Branch::checkout(
    required.oplog,
    required.get_frontier(),
  )
  let required_legacy_fresh = try! @branch.Branch::checkout(
    required_legacy.oplog,
    required_legacy.get_frontier(),
  )
  assert_eq(required.get_frontier(), required_fresh.get_frontier())
  assert_eq(
    required_legacy.get_frontier(),
    required_legacy_fresh.get_frontier(),
  )
  assert_eq(required_fresh.to_text(), required_legacy_fresh.to_text())
  assert_true(required.tree.to_text() != required_fresh.to_text())
  assert_true(required_legacy.tree.to_text() != required_legacy_fresh.to_text())
  assert_true(!required.indexed_state.is_ready())
  assert_true(!required_legacy.indexed_state.is_ready())
  assert_true(required.cursor is None)
  assert_true(required_legacy.cursor is None)
  let typed_mutation : Result[Unit, DocumentError] = Ok(
    required.prepare_for_mutation(),
  ) catch {
    error => Err(error)
  }
  let legacy_mutation : Result[Unit, DocumentError] = Ok(
    required_legacy.prepare_for_mutation(),
  ) catch {
    error => Err(error)
  }
  match (typed_mutation, legacy_mutation) {
    (
      Err(DocumentError::ProjectionRecoveryRequired(..)),
      Err(DocumentError::ProjectionRecoveryRequired(..)),
    ) => ()
    _ => fail("RecoveryRequired must keep both wrappers fail-closed")
  }

  let retry_batch = p2_ready_batch("p2-diff-retry", 3)
  let retry_t = Document::new("p2-diff-retry-typed")
  let retry_l = Document::new("p2-diff-retry-legacy")
  let mut typed_fail = true
  let mut legacy_fail = true
  retry_t.set_admission_hooks({
    on_prepare_remote: () => (),
    on_commit_admission: () => (),
    on_projection_finalization: _ => (),
    prepare_override: None,
    commit_failure: Some(op => {
      if typed_fail && op.seq() == 1 {
        Some(@causal_graph.CausalGraphError::MissingParent(lv=-312))
      } else {
        None
      }
    }),
    projection_failure: None,
    recovery_checkout: None,
  })
  retry_l.set_admission_hooks({
    on_prepare_remote: () => (),
    on_commit_admission: () => (),
    on_projection_finalization: _ => (),
    prepare_override: None,
    commit_failure: Some(op => {
      if legacy_fail && op.seq() == 1 {
        Some(@causal_graph.CausalGraphError::MissingParent(lv=-312))
      } else {
        None
      }
    }),
    projection_failure: None,
    recovery_checkout: None,
  })
  let first = try! retry_t.admit_remote(retry_batch)
  let legacy_first : Result[Unit, DocumentError] = Ok(
    retry_l.merge_remote(retry_batch, [
      @core.RawVersion(retry_batch[2].agent(), retry_batch[2].seq()),
    ]),
  ) catch {
    error => Err(error)
  }
  match first.outcome {
    @oplog.AdmissionOutcome::Partial(receipt~, ..) =>
      p2_assert_operation_prefix(receipt.committed(), retry_batch, 1)
    _ => fail("retry first typed transition changed")
  }
  match first.projection {
    ProjectionStatus::Projected => ()
    _ => fail("retry first projection status changed")
  }
  match legacy_first {
    Err(DocumentError::OpLog(@oplog.OpLogError::PartialRemoteAdmission(..))) =>
      ()
    _ => fail("retry first legacy prefix should expose partial error")
  }
  p2_diff_assert_state(retry_t, retry_l)
  typed_fail = false
  legacy_fail = false
  let retry = try! retry_t.admit_remote([])
  try! retry_l.merge_remote([], [])
  match retry.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) =>
      p2_assert_operation_prefix(
        receipt.committed(),
        [retry_batch[1], retry_batch[2]],
        2,
      )
    _ => fail("typed retry must drain only core suffix")
  }
  match retry.projection {
    ProjectionStatus::Projected => ()
    _ => fail("typed retry projection status changed")
  }
  p2_diff_assert_state(retry_t, retry_l)
}

///|
test "P2.3 differential gate covers wrapper errors and merge closure" {
  let op = p2_ready_batch("p2-diff-wrapper", 1)[0]
  let typed_doc = Document::new("p2-diff-wrapper-typed")
  let legacy_doc = Document::new("p2-diff-wrapper-legacy")
  p2_diff_hooks(typed_doc, Some(0), None, None)
  p2_diff_hooks(legacy_doc, Some(0), None, None)
  let typed = try! typed_doc.admit_remote([op])
  let legacy : Result[Unit, DocumentError] = Ok(legacy_doc.apply_remote(op)) catch {
    error => Err(error)
  }
  match typed.projection {
    ProjectionStatus::Skipped => ()
    _ => fail("wrapper partial projection status changed")
  }
  match legacy {
    Err(
      DocumentError::OpLog(
        @oplog.OpLogError::PartialRemoteAdmission(committed~, error~)
      )
    ) => {
      assert_eq(committed.length(), 0)
      ignore(error)
    }
    _ => fail("apply_remote legacy conversion shape changed")
  }
  p2_diff_assert_state(typed_doc, legacy_doc)

  let source = Document::new("p2-diff-merge-source")
  ignore(try! source.insert(0, "a"))
  ignore(try! source.insert(1, "b"))
  let ops = source.get_all_ops()
  let frontier = try! source.get_frontier_raw()
  let merged = Document::new("p2-diff-merge-wrapper")
  let control = try! merged.admit_remote(ops)
  let closure : Result[Unit, DocumentError] = Ok(
    Document::new("p2-diff-merge-closure").merge_remote([ops[1]], frontier),
  ) catch {
    error => Err(error)
  }
  match control.projection {
    ProjectionStatus::Projected => ()
    _ => fail("merge control projection status changed")
  }
  match closure {
    Err(DocumentError::OpLog(@oplog.OpLogError::MissingRemoteParent(..))) => ()
    _ => fail("merge closure validation changed")
  }
  assert_eq(merged.tree.to_text(), source.tree.to_text())
  assert_eq(merged.get_frontier(), source.get_frontier())
}
