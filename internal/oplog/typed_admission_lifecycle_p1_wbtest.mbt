///| P1 typed-admission lifecycle closure tests.

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
test "P1 typed zero-prefix partial owns the complete staged suffix" {
  let receiver = OpLog("p1-zero-prefix")
  let first = p0_insert("p1-zero-first", 0, [], "a", None)
  let second = p0_insert("p1-zero-second", 0, [], "b", None)
  let plan = try! receiver.prepare_remote([first, second])
  let outcome = try! receiver.commit_admission_with(plan, _op => {
    raise @causal_graph.CausalGraphError::MissingParent(lv=-103)
  })
  match outcome {
    AdmissionOutcome::Partial(receipt~, error~) => {
      assert_eq(receipt.committed().length(), 0)
      assert_eq(receipt.pending_before_count(), 0)
      assert_eq(receipt.pending_after_count(), 2)
      assert_true(
        p1_receipt_has_raw(
          receipt.pending_from_transition(),
          remote_admission_raw(first),
        ),
      )
      assert_true(
        p1_receipt_has_raw(
          receipt.pending_from_transition(),
          remote_admission_raw(second),
        ),
      )
      assert_true(
        p1_receipt_has_raw(
          receipt.pending_staged(),
          remote_admission_raw(first),
        ),
      )
      assert_true(
        p1_receipt_has_raw(
          receipt.pending_staged(),
          remote_admission_raw(second),
        ),
      )
      assert_eq(receipt.pending_retained().length(), 0)
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) =>
          assert_eq(lv, -103)
        _ => fail("expected zero-prefix causal failure")
      }
    }
    AdmissionOutcome::Complete(_) => fail("injected failure must be partial")
  }
}

///|
test "P1 typed n-minus-one partial leaves only the final staged identity" {
  let receiver = OpLog("p1-n-minus-one")
  let first = p0_insert("p1-n-first", 0, [], "a", None)
  let second = p0_insert("p1-n-second", 0, [], "b", None)
  let last = p0_insert("p1-n-last", 0, [], "c", None)
  let last_raw = remote_admission_raw(last)
  let plan = try! receiver.prepare_remote([first, second, last])
  let outcome = try! receiver.commit_admission_with(plan, op => {
    if remote_admission_raw(op) == last_raw {
      raise @causal_graph.CausalGraphError::MissingParent(lv=-104)
    }
    receiver.commit_one_remote_for_admission(op)
  })
  match outcome {
    AdmissionOutcome::Partial(receipt~, error~) => {
      assert_eq(receipt.committed().length(), 2)
      assert_true(
        p1_receipt_has_op(receipt.committed(), remote_admission_raw(first)),
      )
      assert_true(
        p1_receipt_has_op(receipt.committed(), remote_admission_raw(second)),
      )
      assert_eq(receipt.pending_after_count(), 1)
      assert_true(
        p1_receipt_has_raw(receipt.pending_from_transition(), last_raw),
      )
      assert_true(p1_receipt_has_raw(receipt.pending_staged(), last_raw))
      assert_eq(receipt.pending_retained().length(), 0)
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) =>
          assert_eq(lv, -104)
        _ => fail("expected n-minus-one causal failure")
      }
    }
    AdmissionOutcome::Complete(_) => fail("injected failure must be partial")
  }
}

///|
test "P1 typed stale admission rejects without changing authority" {
  let receiver = OpLog("p1-stale-typed")
  let incoming = p0_insert("p1-stale-incoming", 0, [], "r", None)
  let plan = try! receiver.prepare_remote([incoming])
  ignore(try! receiver.insert("local", -1, -1))
  let count_before = receiver.op_count()
  let frontier_before = try! receiver.get_frontier_raw()
  let pending_before = receiver.planner.pending_operations()
  let result : Result[AdmissionOutcome, OpLogError] = Ok(
    receiver.commit_admission(plan),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::StaleAdmission) => ()
    _ => fail("expected typed stale admission rejection")
  }
  assert_eq(receiver.op_count(), count_before)
  assert_eq(try! receiver.get_frontier_raw(), frontier_before)
  assert_true(
    planner_lifecycle_same_ops(
      receiver.planner.pending_operations(),
      pending_before,
    ),
  )
}

///|
test "P1 typed consumed admission rejects without a second transition" {
  let receiver = OpLog("p1-consumed-typed")
  let incoming = p0_insert("p1-consumed-incoming", 0, [], "r", None)
  let plan = try! receiver.prepare_remote([incoming])
  match (try! receiver.commit_admission(plan)) {
    AdmissionOutcome::Complete(receipt) =>
      assert_eq(receipt.committed().length(), 1)
    AdmissionOutcome::Partial(..) => fail("ready admission should complete")
  }
  let count_after = receiver.op_count()
  let frontier_after = try! receiver.get_frontier_raw()
  let result : Result[AdmissionOutcome, OpLogError] = Ok(
    receiver.commit_admission(plan),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::ConsumedAdmission) => ()
    _ => fail("expected typed consumed admission rejection")
  }
  assert_eq(receiver.op_count(), count_after)
  assert_eq(try! receiver.get_frontier_raw(), frontier_after)
}

///|
test "P1 typed invalid admission rejects before planner mutation" {
  let receiver = OpLog("p1-invalid-typed")
  let first = p0_insert("p1-invalid-first", 0, [], "a", None)
  let second = p0_insert("p1-invalid-second", 0, [], "b", None)
  let plan = try! receiver.prepare_remote([first, second])
  plan.planned[1] = plan.planned[0]
  let result : Result[AdmissionOutcome, OpLogError] = Ok(
    receiver.commit_admission(plan),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::InvalidAdmission) => ()
    _ => fail("expected typed invalid admission rejection")
  }
  assert_eq(receiver.op_count(), 0)
  assert_eq(receiver.planner.generation(), 0)
  assert_eq(receiver.planner.pending_operations().length(), 0)
}

///|
test "P1 typed begin rechecks the hard pending limit" {
  let receiver = OpLog("p1-limit-recheck")
  let incoming = p0_insert("p1-limit-recheck-incoming", 0, [], "r", None)
  let plan = PreparedAdmission::{
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
    already_admitted: [],
    duplicate_of_pending: [],
    retained_pending: [],
    touched_retained_pending: [],
    consumed: false,
  }
  let result : Result[AdmissionOutcome, OpLogError] = Ok(
    receiver.commit_admission(plan),
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
  assert_eq(receiver.planner.generation(), 0)
  assert_eq(receiver.planner.pending_operations().length(), 0)
}

///|
test "P1 typed ownership categories remain disjoint" {
  let receiver = OpLog("p1-ownership-partition")
  let admitted = p0_insert("p1-ownership-admitted", 0, [], "A", None)
  ignore(try! receiver.commit_remote(try! receiver.prepare_remote([admitted])))
  let missing = p0_raw("p1-ownership-missing", 0)
  let pending = p0_insert("p1-ownership-pending", 0, [missing], "P", None)
  ignore(try! receiver.commit_remote(try! receiver.prepare_remote([pending])))
  let committed = p0_insert("p1-ownership-committed", 0, [], "C", None)
  let outcome = try! receiver.commit_admission(
    try! receiver.prepare_remote([admitted, pending, committed]),
  )
  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_true(
        p1_receipt_has_raw(
          receipt.already_admitted(),
          remote_admission_raw(admitted),
        ),
      )
      assert_true(
        p1_receipt_has_op(receipt.committed(), remote_admission_raw(committed)),
      )
      assert_true(
        p1_receipt_has_raw(
          receipt.pending_from_transition(),
          remote_admission_raw(pending),
        ),
      )
      p1_assert_raw_sets_disjoint(
        receipt.already_admitted(),
        receipt.pending_from_transition(),
      )
      p1_assert_raw_sets_disjoint(
        receipt.pending_from_transition(),
        receipt.discarded_pending(),
      )
      assert_eq(receipt.pending_after_count(), 1)
    }
    AdmissionOutcome::Partial(..) =>
      fail("ownership partition admission should complete")
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
    try! receiver.commit_remote(try! receiver.prepare_remote([invalid_pending])),
  )
  let dependency_a = p0_insert("p1-touched-discard-a", 0, [], "A", None)
  let touched_discarded = p0_insert(
    "p1-touched-discarded",
    0,
    [remote_admission_raw(dependency_a), remote_admission_raw(invalid_pending)],
    "X",
    None,
  )
  ignore(
    try! receiver.commit_remote(
      try! receiver.prepare_remote([touched_discarded]),
    ),
  )
  let root = p0_insert("p1-touched-discard-target", 0, [], "A", None)
  let target = p0_delete(
    "p1-touched-discard-target",
    1,
    [remote_admission_raw(root)],
    remote_admission_raw(root),
  )
  let outcome = try! receiver.commit_admission(
    try! receiver.prepare_remote([dependency_a, root, target]),
  )
  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      let touched_raw = remote_admission_raw(touched_discarded)
      assert_true(p1_receipt_has_raw(receipt.discarded_pending(), touched_raw))
      assert_true(
        !p1_receipt_has_raw(receipt.pending_from_transition(), touched_raw),
      )
      assert_true(!p1_receipt_has_raw(receipt.pending_retained(), touched_raw))
      assert_true(!p1_receipt_has_raw(receipt.pending_staged(), touched_raw))
    }
    AdmissionOutcome::Partial(..) =>
      fail("discarded touched pending should complete")
  }
}

///|
test "P1 unrelated retained pending remains outside the receipt transition" {
  let receiver = OpLog("p1-unrelated-retained")
  let unrelated_missing = p0_raw("p1-unrelated-missing", 0)
  let unrelated = p0_insert("p1-unrelated", 0, [unrelated_missing], "U", None)
  ignore(try! receiver.commit_remote(try! receiver.prepare_remote([unrelated])))

  let missing_target = p0_raw("p1-unrelated-discard-target", 1)
  let invalid_pending = p0_insert(
    "p1-unrelated-invalid",
    0,
    [missing_target],
    "I",
    Some(missing_target),
  )
  ignore(
    try! receiver.commit_remote(try! receiver.prepare_remote([invalid_pending])),
  )
  let root = p0_insert("p1-unrelated-discard-target", 0, [], "A", None)
  let target = p0_delete(
    "p1-unrelated-discard-target",
    1,
    [remote_admission_raw(root)],
    remote_admission_raw(root),
  )
  let outcome = try! receiver.commit_admission(
    try! receiver.prepare_remote([root, target]),
  )
  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_true(
        p1_receipt_has_raw(
          receipt.discarded_pending(),
          remote_admission_raw(invalid_pending),
        ),
      )
      assert_true(
        !p1_receipt_has_raw(
          receipt.pending_from_transition(),
          remote_admission_raw(unrelated),
        ),
      )
      assert_eq(receipt.pending_after_count(), 1)
      assert_true(receiver.planner.has_pending())
      assert_true(
        p1_receipt_has_raw(
          receiver.planner.pending_raws(),
          remote_admission_raw(unrelated),
        ),
      )
    }
    AdmissionOutcome::Partial(..) => fail("discard closure should complete")
  }
}

///|
test "P1 network resend commits only the core-owned suffix" {
  let receiver = OpLog("p1-network-resend")
  let first = p0_insert("p1-resend-first", 0, [], "a", None)
  let failed = p0_insert("p1-resend-failed", 0, [], "b", None)
  let suffix = p0_insert("p1-resend-suffix", 0, [], "c", None)
  let failed_raw = remote_admission_raw(failed)
  let plan = try! receiver.prepare_remote([first, failed, suffix])
  match
    (try! receiver.commit_admission_with(plan, op => {
      if remote_admission_raw(op) == failed_raw {
        raise @causal_graph.CausalGraphError::MissingParent(lv=-105)
      }
      receiver.commit_one_remote_for_admission(op)
    })) {
    AdmissionOutcome::Partial(receipt~, error~) => {
      ignore(error)
      assert_eq(receipt.committed().length(), 1)
    }
    AdmissionOutcome::Complete(_) => fail("injected failure must be partial")
  }
  let resend = try! receiver.commit_admission(
    try! receiver.prepare_remote([first, failed, suffix]),
  )
  match resend {
    AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.committed().length(), 2)
      assert_true(
        p1_receipt_has_raw(
          receipt.already_admitted(),
          remote_admission_raw(first),
        ),
      )
      assert_true(
        !p1_receipt_has_op(receipt.committed(), remote_admission_raw(first)),
      )
      assert_eq(receiver.op_count(), 3)
      assert_eq(receiver.planner.pending_operations().length(), 0)
    }
    AdmissionOutcome::Partial(..) => fail("resend should recover the suffix")
  }
}

///|
test "P1 matching duplicate is authority-owned and conflict is atomic" {
  let receiver = OpLog("p1-identity-boundary")
  let admitted = p0_insert("p1-identity", 0, [], "A", None)
  ignore(try! receiver.commit_remote(try! receiver.prepare_remote([admitted])))
  let duplicate = try! receiver.commit_admission(
    try! receiver.prepare_remote([admitted]),
  )
  match duplicate {
    AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.committed().length(), 0)
      assert_true(
        p1_receipt_has_raw(
          receipt.already_admitted(),
          remote_admission_raw(admitted),
        ),
      )
    }
    AdmissionOutcome::Partial(..) => fail("matching duplicate should complete")
  }
  let conflict = p0_insert("p1-identity", 0, [], "different", None)
  let result : Result[PreparedAdmission, OpLogError] = Ok(
    receiver.prepare_remote([conflict]),
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
  assert_eq(receiver.planner.pending_operations().length(), 0)
}
