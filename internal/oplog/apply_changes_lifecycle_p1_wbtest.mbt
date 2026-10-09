///| P1 typed-change application lifecycle closure tests.

///|
fn p1_assert_raw_sets_disjoint(
  left : ArrayView[@core.RawVersion],
  right : ArrayView[@core.RawVersion],
) -> Unit raise {
  for raw in left {
    assert_true(!p1_receipt_has_raw(right, raw))
  }
}

///|
fn p1_apply_success(
  oplog : OpLog,
  action : ApplyChanges,
) -> ApplyChangesReport raise OpLogError {
  match oplog.apply_changes(action) {
    ApplyChangesOutcome::Succeeded(report) => report
    ApplyChangesOutcome::Failed(..) =>
      abort("expected change application to succeed")
  }
}

///|
test "P1 typed zero-prefix partial owns the complete staged suffix" {
  let receiver = OpLog("p1-zero-prefix")
  let first = p0_insert("p1-zero-first", 0, [], "a", None)
  let second = p0_insert("p1-zero-second", 0, [], "b", None)
  let plan = try! ApplyChanges(receiver, [first, second])
  let outcome = try! receiver.apply_changes_with(plan, _op => {
    raise @causal_graph.CausalGraphError::MissingParent(lv=-103)
  })
  match outcome {
    ApplyChangesOutcome::Failed(report~, error~) => {
      assert_eq(report.committed().length(), 0)
      assert_eq(report.pending_before_count(), 0)
      assert_eq(report.pending_after_count(), 2)
      assert_true(
        p1_receipt_has_raw(
          report.pending_from_transition(),
          apply_changes_raw(first),
        ),
      )
      assert_true(
        p1_receipt_has_raw(
          report.pending_from_transition(),
          apply_changes_raw(second),
        ),
      )
      assert_true(
        p1_receipt_has_raw(report.pending_staged(), apply_changes_raw(first)),
      )
      assert_true(
        p1_receipt_has_raw(report.pending_staged(), apply_changes_raw(second)),
      )
      assert_eq(report.pending_retained().length(), 0)
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) =>
          assert_eq(lv, -103)
        _ => fail("expected zero-prefix causal failure")
      }
    }
    ApplyChangesOutcome::Succeeded(_) =>
      fail("injected failure must be partial")
  }
}

///|
test "P1 typed n-minus-one partial leaves only the final staged identity" {
  let receiver = OpLog("p1-n-minus-one")
  let first = p0_insert("p1-n-first", 0, [], "a", None)
  let second = p0_insert("p1-n-second", 0, [], "b", None)
  let last = p0_insert("p1-n-last", 0, [], "c", None)
  let last_raw = apply_changes_raw(last)
  let plan = try! ApplyChanges(receiver, [first, second, last])
  let outcome = try! receiver.apply_changes_with(plan, op => {
    if apply_changes_raw(op) == last_raw {
      raise @causal_graph.CausalGraphError::MissingParent(lv=-104)
    }
    receiver.commit_one_remote_for_apply_changes(op)
  })
  match outcome {
    ApplyChangesOutcome::Failed(report~, error~) => {
      assert_eq(report.committed().length(), 2)
      assert_true(
        p1_receipt_has_op(report.committed(), apply_changes_raw(first)),
      )
      assert_true(
        p1_receipt_has_op(report.committed(), apply_changes_raw(second)),
      )
      assert_eq(report.pending_after_count(), 1)
      assert_true(
        p1_receipt_has_raw(report.pending_from_transition(), last_raw),
      )
      assert_true(p1_receipt_has_raw(report.pending_staged(), last_raw))
      assert_eq(report.pending_retained().length(), 0)
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) =>
          assert_eq(lv, -104)
        _ => fail("expected n-minus-one causal failure")
      }
    }
    ApplyChangesOutcome::Succeeded(_) =>
      fail("injected failure must be partial")
  }
}

///|
test "P1 typed stale change application rejects without changing authority" {
  let receiver = OpLog("p1-stale-typed")
  let incoming = p0_insert("p1-stale-incoming", 0, [], "r", None)
  let plan = try! ApplyChanges(receiver, [incoming])
  ignore(try! receiver.insert("local", -1, -1))
  let count_before = receiver.op_count()
  let frontier_before = try! receiver.get_frontier_raw()
  let pending_before = receiver.pending_changes.pending_operations()
  let result : Result[ApplyChangesOutcome, OpLogError] = Ok(
    receiver.apply_changes(plan),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::StaleApplyChanges) => ()
    _ => fail("expected typed stale change application rejection")
  }
  assert_eq(receiver.op_count(), count_before)
  assert_eq(try! receiver.get_frontier_raw(), frontier_before)
  assert_true(
    pending_changes_lifecycle_same_ops(
      receiver.pending_changes.pending_operations(),
      pending_before,
    ),
  )
}

///|
test "P1 typed consumed change application rejects without a second transition" {
  let receiver = OpLog("p1-consumed-typed")
  let incoming = p0_insert("p1-consumed-incoming", 0, [], "r", None)
  let plan = try! ApplyChanges(receiver, [incoming])
  match (try! receiver.apply_changes(plan)) {
    ApplyChangesOutcome::Succeeded(receipt) =>
      assert_eq(receipt.committed().length(), 1)
    ApplyChangesOutcome::Failed(..) =>
      fail("ready change application should complete")
  }
  let count_after = receiver.op_count()
  let frontier_after = try! receiver.get_frontier_raw()
  let result : Result[ApplyChangesOutcome, OpLogError] = Ok(
    receiver.apply_changes(plan),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::ConsumedApplyChanges) => ()
    _ => fail("expected typed consumed change application rejection")
  }
  assert_eq(receiver.op_count(), count_after)
  assert_eq(try! receiver.get_frontier_raw(), frontier_after)
}

///|
test "P1 typed invalid change application rejects before pending-changes owner mutation" {
  let receiver = OpLog("p1-invalid-typed")
  let first = p0_insert("p1-invalid-first", 0, [], "a", None)
  let second = p0_insert("p1-invalid-second", 0, [], "b", None)
  let plan = try! ApplyChanges(receiver, [first, second])
  plan.planned[1] = plan.planned[0]
  let result : Result[ApplyChangesOutcome, OpLogError] = Ok(
    receiver.apply_changes(plan),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::InvalidApplyChanges) => ()
    _ => fail("expected typed invalid change application rejection")
  }
  assert_eq(receiver.op_count(), 0)
  assert_eq(receiver.pending_changes.generation(), 0)
  assert_eq(receiver.pending_changes.pending_operations().length(), 0)
}

///|
test "P1 typed begin rejects an absent pending discard identity" {
  let receiver = OpLog("p1-absent-discard")
  let missing = p0_raw("p1-absent-discard-missing", 0)
  let pending = p0_insert("p1-absent-discard-pending", 0, [missing], "P", None)
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [pending])),
  )
  let ready = p0_insert("p1-absent-discard-ready", 0, [], "R", None)
  let plan = try! ApplyChanges(receiver, [ready])
  plan.discarded_pending.add(@core.RawVersion("absent-discard", 0))
  let pending_before = receiver.pending_changes.pending_operations()
  let result : Result[ApplyChangesOutcome, OpLogError] = Ok(
    receiver.apply_changes(plan),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::InvalidApplyChanges) => ()
    _ => fail("expected absent discard identity rejection")
  }
  assert_eq(receiver.op_count(), 0)
  assert_true(
    pending_changes_lifecycle_same_ops(
      receiver.pending_changes.pending_operations(),
      pending_before,
    ),
  )
}

///|
test "P1 typed begin rechecks the hard pending limit" {
  let receiver = OpLog("p1-limit-recheck")
  let incoming = p0_insert("p1-limit-recheck-incoming", 0, [], "r", None)
  let plan = ApplyChanges::{
    planned: [incoming],
    storage: DeferredFast,
    discard_roots: [],
    discarded_pending: @hashset.HashSet([]),
    discarded_staged: @hashset.HashSet([]),
    next_arrival: 1,
    generation: 0,
    pending_before_count: 0,
    new_staged_count: 1,
    required_pending: 1,
    max_pending: Some(0),
    max_pending_after_complete: None,
    already_applied: [],
    duplicate_of_pending: [],
    retained_pending: [],
    touched_retained_pending: [],
    consumed: false,
  }
  let result : Result[ApplyChangesOutcome, OpLogError] = Ok(
    receiver.apply_changes(plan),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::PendingLimitExceeded(limit~, required~)) => {
      assert_eq(limit, 0)
      assert_eq(required, 1)
    }
    _ => fail("expected begin-time pending limit rejection")
  }
  assert_eq(receiver.op_count(), 0)
  assert_eq(receiver.pending_changes.generation(), 0)
  assert_eq(receiver.pending_changes.pending_operations().length(), 0)
}

///|
test "P1 typed ownership categories remain disjoint" {
  let receiver = OpLog("p1-ownership-partition")
  let applied = p0_insert("p1-ownership-admitted", 0, [], "A", None)
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [applied])),
  )
  let missing = p0_raw("p1-ownership-missing", 0)
  let pending = p0_insert("p1-ownership-pending", 0, [missing], "P", None)
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [pending])),
  )
  let committed = p0_insert("p1-ownership-committed", 0, [], "C", None)
  let outcome = try! receiver.apply_changes(
    try! ApplyChanges(receiver, [applied, pending, committed]),
  )
  match outcome {
    ApplyChangesOutcome::Succeeded(receipt) => {
      assert_true(
        p1_receipt_has_raw(
          receipt.already_applied(),
          apply_changes_raw(applied),
        ),
      )
      assert_true(
        p1_receipt_has_op(receipt.committed(), apply_changes_raw(committed)),
      )
      assert_true(
        p1_receipt_has_raw(
          receipt.pending_from_transition(),
          apply_changes_raw(pending),
        ),
      )
      p1_assert_raw_sets_disjoint(
        receipt.already_applied(),
        receipt.pending_from_transition(),
      )
      p1_assert_raw_sets_disjoint(
        receipt.pending_from_transition(),
        receipt.discarded_pending(),
      )
      assert_eq(receipt.pending_after_count(), 1)
    }
    ApplyChangesOutcome::Failed(..) =>
      fail("ownership partition change application should complete")
  }
}

///|
test "P1 discarded touched retained pending is absent from receipt ownership" {
  let receiver = OpLog("p1-touched-discarded")
  let missing_target = p0_raw("p1-touched-discard-target", 1)
  let invalid_pending = p0_insert(
    "p1-touched-discard-invalid",
    0,
    [missing_target],
    "I",
    Some(missing_target),
  )
  ignore(
    try! p1_apply_success(
      receiver,
      try! ApplyChanges(receiver, [invalid_pending]),
    ),
  )
  let dependency_a = p0_insert("p1-touched-discard-a", 0, [], "A", None)
  let touched_discarded = p0_insert(
    "p1-touched-discarded",
    0,
    [apply_changes_raw(dependency_a), apply_changes_raw(invalid_pending)],
    "X",
    None,
  )
  ignore(
    try! p1_apply_success(
      receiver,
      try! ApplyChanges(receiver, [touched_discarded]),
    ),
  )
  let root = p0_insert("p1-touched-discard-target", 0, [], "A", None)
  let target = p0_delete(
    "p1-touched-discard-target",
    1,
    [apply_changes_raw(root)],
    apply_changes_raw(root),
  )
  let plan = try! ApplyChanges(receiver, [dependency_a, root, target])
  assert_eq(
    plan.required_pending,
    receiver.pending_changes.required_pending_set_oracle(plan),
  )
  let outcome = try! receiver.apply_changes(plan)
  match outcome {
    ApplyChangesOutcome::Succeeded(receipt) => {
      let touched_raw = apply_changes_raw(touched_discarded)
      assert_true(p1_receipt_has_raw(receipt.discarded_pending(), touched_raw))
      assert_true(
        !p1_receipt_has_raw(receipt.pending_from_transition(), touched_raw),
      )
      assert_true(!p1_receipt_has_raw(receipt.pending_retained(), touched_raw))
      assert_true(!p1_receipt_has_raw(receipt.pending_staged(), touched_raw))
    }
    ApplyChangesOutcome::Failed(..) =>
      fail("discarded touched pending should complete")
  }
}

///|
test "P1 unrelated retained pending remains outside the receipt transition" {
  let receiver = OpLog("p1-unrelated-retained")
  let unrelated_missing = p0_raw("p1-unrelated-missing", 0)
  let unrelated = p0_insert("p1-unrelated", 0, [unrelated_missing], "U", None)
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [unrelated])),
  )

  let missing_target = p0_raw("p1-unrelated-discard-target", 1)
  let invalid_pending = p0_insert(
    "p1-unrelated-invalid",
    0,
    [missing_target],
    "I",
    Some(missing_target),
  )
  ignore(
    try! p1_apply_success(
      receiver,
      try! ApplyChanges(receiver, [invalid_pending]),
    ),
  )
  let root = p0_insert("p1-unrelated-discard-target", 0, [], "A", None)
  let target = p0_delete(
    "p1-unrelated-discard-target",
    1,
    [apply_changes_raw(root)],
    apply_changes_raw(root),
  )
  let plan = try! ApplyChanges(receiver, [root, target])
  assert_eq(
    plan.required_pending,
    receiver.pending_changes.required_pending_set_oracle(plan),
  )
  let outcome = try! receiver.apply_changes(plan)
  match outcome {
    ApplyChangesOutcome::Succeeded(receipt) => {
      assert_true(
        p1_receipt_has_raw(
          receipt.discarded_pending(),
          apply_changes_raw(invalid_pending),
        ),
      )
      assert_true(
        !p1_receipt_has_raw(
          receipt.pending_from_transition(),
          apply_changes_raw(unrelated),
        ),
      )
      assert_eq(receipt.pending_after_count(), 1)
      assert_true(receiver.pending_changes.has_pending())
      assert_true(
        p1_receipt_has_raw(
          receiver.pending_changes.pending_raws(),
          apply_changes_raw(unrelated),
        ),
      )
    }
    ApplyChangesOutcome::Failed(..) => fail("discard closure should complete")
  }
}

///|
test "P1 network resend commits only the core-owned suffix" {
  let receiver = OpLog("p1-network-resend")
  let first = p0_insert("p1-resend-first", 0, [], "a", None)
  let failed = p0_insert("p1-resend-failed", 0, [], "b", None)
  let suffix = p0_insert("p1-resend-suffix", 0, [], "c", None)
  let failed_raw = apply_changes_raw(failed)
  let plan = try! ApplyChanges(receiver, [first, failed, suffix])
  match
    (try! receiver.apply_changes_with(plan, op => {
      if apply_changes_raw(op) == failed_raw {
        raise @causal_graph.CausalGraphError::MissingParent(lv=-105)
      }
      receiver.commit_one_remote_for_apply_changes(op)
    })) {
    ApplyChangesOutcome::Failed(report~, error~) => {
      ignore(error)
      assert_eq(report.committed().length(), 1)
    }
    ApplyChangesOutcome::Succeeded(_) =>
      fail("injected failure must be partial")
  }
  let resend = try! receiver.apply_changes(
    try! ApplyChanges(receiver, [first, failed, suffix]),
  )
  match resend {
    ApplyChangesOutcome::Succeeded(receipt) => {
      assert_eq(receipt.committed().length(), 2)
      assert_true(
        p1_receipt_has_raw(receipt.already_applied(), apply_changes_raw(first)),
      )
      assert_true(
        !p1_receipt_has_op(receipt.committed(), apply_changes_raw(first)),
      )
      assert_eq(receiver.op_count(), 3)
      assert_eq(receiver.pending_changes.pending_operations().length(), 0)
    }
    ApplyChangesOutcome::Failed(..) => fail("resend should recover the suffix")
  }
}

///|
test "P1 matching duplicate is authority-owned and conflict is atomic" {
  let receiver = OpLog("p1-identity-boundary")
  let applied = p0_insert("p1-identity", 0, [], "A", None)
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [applied])),
  )
  let duplicate = try! receiver.apply_changes(
    try! ApplyChanges(receiver, [applied]),
  )
  match duplicate {
    ApplyChangesOutcome::Succeeded(receipt) => {
      assert_eq(receipt.committed().length(), 0)
      assert_true(
        p1_receipt_has_raw(
          receipt.already_applied(),
          apply_changes_raw(applied),
        ),
      )
    }
    ApplyChangesOutcome::Failed(..) =>
      fail("matching duplicate should complete")
  }
  let conflict = p0_insert("p1-identity", 0, [], "different", None)
  let result : Result[ApplyChanges, OpLogError] = Ok(
    ApplyChanges(receiver, [conflict]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::ConflictingIdentity(raw~)) => {
      assert_eq(raw.agent, "p1-identity")
      assert_eq(raw.seq, 0)
    }
    _ => fail("expected conflicting identity rejection")
  }
  assert_eq(receiver.op_count(), 1)
  assert_eq(receiver.pending_changes.pending_operations().length(), 0)
}
