///| P1 red tests for typed admission ownership, limits, recovery, and errors.

///|
fn p1_receipt_has_raw(
  raws : ArrayView[@core.RawVersion],
  expected : @core.RawVersion,
) -> Bool {
  let mut found = false
  for raw in raws {
    if raw == expected {
      found = true
    }
  }
  found
}

///|
fn p1_receipt_has_op(
  ops : ArrayView[@core.Op],
  expected : @core.RawVersion,
) -> Bool {
  let mut found = false
  for op in ops {
    if remote_admission_raw(op) == expected {
      found = true
    }
  }
  found
}

///|
test "P1 receipt owns defensive identity and operation snapshots" {
  let committed_source = [p0_insert("receipt-committed", 0, [], "a", None)]
  let already_admitted_source = [@core.RawVersion("receipt-admitted", 0)]
  let pending_source = [@core.RawVersion("receipt-pending", 0)]
  let pending_retained_source = [@core.RawVersion("receipt-retained", 0)]
  let pending_staged_source = [@core.RawVersion("receipt-staged", 0)]
  let discarded_pending_source = [
    @core.RawVersion("receipt-discarded-pending", 0),
  ]
  let discarded_staged_source = [
    @core.RawVersion("receipt-discarded-staged", 0),
  ]
  let receipt = AdmissionReceipt::from_parts(
    committed_source,
    already_admitted_source,
    pending_source,
    pending_retained_source,
    pending_staged_source,
    discarded_pending_source,
    discarded_staged_source,
    0,
    4,
    2,
    @core.Frontier::from_array([1]),
    @core.Frontier::from_array([2]),
  )

  committed_source[0] = p0_insert("receipt-mutated", 0, [], "x", None)
  already_admitted_source[0] = @core.RawVersion("mutated", 0)
  pending_source[0] = @core.RawVersion("mutated", 1)
  pending_retained_source[0] = @core.RawVersion("mutated", 4)
  pending_staged_source[0] = @core.RawVersion("mutated", 5)
  discarded_pending_source[0] = @core.RawVersion("mutated", 2)
  discarded_staged_source[0] = @core.RawVersion("mutated", 3)

  assert_true(
    p1_receipt_has_op(
      receipt.committed(),
      @core.RawVersion("receipt-committed", 0),
    ),
  )
  assert_true(
    p1_receipt_has_raw(
      receipt.already_admitted(),
      @core.RawVersion("receipt-admitted", 0),
    ),
  )
  assert_true(
    p1_receipt_has_raw(
      receipt.pending_from_transition(),
      @core.RawVersion("receipt-pending", 0),
    ),
  )
  assert_true(
    p1_receipt_has_raw(
      receipt.pending_retained(),
      @core.RawVersion("receipt-retained", 0),
    ),
  )
  assert_true(
    p1_receipt_has_raw(
      receipt.pending_staged(),
      @core.RawVersion("receipt-staged", 0),
    ),
  )
  assert_true(
    p1_receipt_has_raw(
      receipt.discarded_pending(),
      @core.RawVersion("receipt-discarded-pending", 0),
    ),
  )
  assert_true(
    p1_receipt_has_raw(
      receipt.discarded_staged(),
      @core.RawVersion("receipt-discarded-staged", 0),
    ),
  )
  assert_eq(receipt.pending_before_count(), 4)
  assert_eq(receipt.pending_after_count(), 2)
}

///|
test "P1 hard pending precondition counts unresolved staged identities" {
  let receiver = OpLog("p1-limit")
  let missing = p0_raw("p1-limit-missing", 0)
  let ready = p0_insert("p1-limit-ready", 0, [], "ready", None)
  let unresolved = p0_insert(
    "p1-limit-unresolved",
    0,
    [missing],
    "unresolved",
    Some(missing),
  )
  let generation_before = receiver.planner.generation()
  let pending_before = receiver.planner.pending_operations()
  let result : Result[PreparedAdmission, OpLogError] = Ok(
    receiver.prepare_remote([ready, unresolved], max_pending=1),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::PendingLimitExceeded(limit~, required~)) => {
      assert_eq(limit, 1)
      assert_eq(required, 2)
    }
    _ => fail("expected hard pending-limit rejection")
  }
  assert_eq(receiver.op_count(), 0)
  assert_eq(receiver.get_frontier_raw(), [])
  assert_eq(receiver.planner.generation(), generation_before)
  assert_true(
    planner_lifecycle_same_ops(
      receiver.planner.pending_operations(),
      pending_before,
    ),
  )
  assert_eq(receiver.has_pending(), false)
}

///|
test "P1 receipt preserves touched retained pending provenance" {
  let receiver = OpLog("p1-touched-retained")
  let dependency_a = p0_insert("p1-touched-a", 0, [], "A", None)
  let dependency_b = p0_insert("p1-touched-b", 0, [], "B", None)
  let retained = p0_insert(
    "p1-touched-retained",
    0,
    [remote_admission_raw(dependency_a), remote_admission_raw(dependency_b)],
    "R",
    None,
  )
  ignore(try! receiver.commit_remote(try! receiver.prepare_remote([retained])))

  let outcome = try! receiver.commit_admission(
    try! receiver.prepare_remote([dependency_a]),
  )
  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      let retained_raw = remote_admission_raw(retained)
      assert_true(
        p1_receipt_has_raw(receipt.pending_from_transition(), retained_raw),
      )
      assert_true(p1_receipt_has_raw(receipt.pending_retained(), retained_raw))
      assert_true(!p1_receipt_has_raw(receipt.pending_staged(), retained_raw))
      assert_eq(receipt.pending_after_count(), 1)
    }
    AdmissionOutcome::Partial(..) => fail("one dependency should complete")
  }
}

///|
test "P1 receipt includes unresolved staged pending identities" {
  let receiver = OpLog("p1-unresolved-receipt")
  let missing = p0_raw("p1-unresolved-missing", 0)
  let unresolved = p0_insert(
    "p1-unresolved",
    0,
    [missing],
    "unresolved",
    Some(missing),
  )
  let plan = try! receiver.prepare_remote([unresolved], max_pending=1)
  match (try! receiver.commit_admission(plan)) {
    AdmissionOutcome::Complete(receipt) => {
      assert_true(
        p1_receipt_has_raw(
          receipt.pending_from_transition(),
          remote_admission_raw(unresolved),
        ),
      )
      assert_eq(receipt.pending_after_count(), 1)
    }
    AdmissionOutcome::Partial(..) =>
      fail("unresolved staged work is not partial")
  }
}

///|
test "P1 pending duplicate remains pending when not awakened" {
  let receiver = OpLog("p1-pending-duplicate")
  let missing = p0_raw("p1-pending-dependency", 0)
  let pending = p0_insert("p1-pending-duplicate", 0, [missing], "pending", None)
  ignore(try! receiver.commit_remote(try! receiver.prepare_remote([pending])))
  let outcome = try! receiver.commit_admission(
    try! receiver.prepare_remote([pending]),
  )
  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_true(
        p1_receipt_has_raw(
          receipt.pending_from_transition(),
          remote_admission_raw(pending),
        ),
      )
      assert_true(
        !p1_receipt_has_op(receipt.committed(), remote_admission_raw(pending)),
      )
    }
    AdmissionOutcome::Partial(..) =>
      fail("duplicate-only admission is complete")
  }
}

///|
test "P1 pending duplicate wakes and becomes committed" {
  let receiver = OpLog("p1-pending-wake")
  let dependency = p0_insert("p1-wake-dependency", 0, [], "D", None)
  let pending = p0_insert(
    "p1-wake-duplicate",
    0,
    [remote_admission_raw(dependency)],
    "X",
    None,
  )
  ignore(try! receiver.commit_remote(try! receiver.prepare_remote([pending])))
  let outcome = try! receiver.commit_admission(
    try! receiver.prepare_remote([dependency, pending]),
  )
  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_true(
        p1_receipt_has_op(receipt.committed(), remote_admission_raw(pending)),
      )
      assert_true(
        !p1_receipt_has_raw(
          receipt.pending_from_transition(),
          remote_admission_raw(pending),
        ),
      )
    }
    AdmissionOutcome::Partial(..) => fail("dependency wake should complete")
  }
}

///|
test "P1 pending duplicate enters rejection closure and is discarded" {
  let receiver = OpLog("p1-pending-discard")
  let missing_target = p0_raw("p1-discard-target", 1)
  let pending_invalid = p0_insert(
    "p1-pending-invalid",
    0,
    [missing_target],
    "invalid",
    Some(missing_target),
  )
  ignore(
    try! receiver.commit_remote(try! receiver.prepare_remote([pending_invalid])),
  )
  let root = p0_insert("p1-discard-target", 0, [], "A", None)
  let target = p0_delete(
    "p1-discard-target",
    1,
    [remote_admission_raw(root)],
    remote_admission_raw(root),
  )
  let outcome = try! receiver.commit_admission(
    try! receiver.prepare_remote([root, target, pending_invalid]),
  )
  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_true(
        p1_receipt_has_raw(
          receipt.discarded_pending(),
          remote_admission_raw(pending_invalid),
        ),
      )
      assert_true(
        !p1_receipt_has_op(
          receipt.committed(),
          remote_admission_raw(pending_invalid),
        ),
      )
      assert_true(
        !p1_receipt_has_raw(
          receipt.pending_from_transition(),
          remote_admission_raw(pending_invalid),
        ),
      )
    }
    AdmissionOutcome::Partial(..) => fail("rejection closure should complete")
  }
}

///|
test "P1 partial receipt separates retained and staged pending provenance" {
  let receiver = OpLog("p1-partial-provenance")
  let retained_predecessor = p0_insert(
    "p1-partial-dependency",
    0,
    [],
    "P",
    None,
  )
  let retained = p0_insert(
    "p1-partial-retained",
    0,
    [remote_admission_raw(retained_predecessor)],
    "R",
    None,
  )
  let staged = p0_insert("p1-partial-staged", 0, [], "S", None)
  ignore(try! receiver.commit_remote(try! receiver.prepare_remote([retained])))
  let plan = try! receiver.prepare_remote([retained_predecessor, staged])
  assert_true(plan.operations().length() > 0)
  let failure_raw = remote_admission_raw(plan.operations()[0])
  let outcome = try! receiver.commit_admission_with(plan, op => {
    if remote_admission_raw(op) == failure_raw {
      raise @causal_graph.CausalGraphError::MissingParent(lv=-102)
    }
    receiver.commit_one_remote_for_admission(op)
  })
  match outcome {
    AdmissionOutcome::Partial(receipt~, error~) => {
      let retained_raw = remote_admission_raw(retained)
      let staged_raw = remote_admission_raw(staged)
      assert_true(
        p1_receipt_has_raw(receipt.pending_from_transition(), retained_raw),
      )
      assert_true(
        p1_receipt_has_raw(receipt.pending_from_transition(), staged_raw),
      )
      assert_true(p1_receipt_has_raw(receipt.pending_retained(), retained_raw))
      assert_true(!p1_receipt_has_raw(receipt.pending_staged(), retained_raw))
      assert_true(p1_receipt_has_raw(receipt.pending_staged(), staged_raw))
      assert_true(!p1_receipt_has_raw(receipt.pending_retained(), staged_raw))
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) =>
          assert_eq(lv, -102)
        _ => fail("expected provenance test causal failure")
      }
    }
    AdmissionOutcome::Complete(_) => fail("injected failure must be partial")
  }
}

///|
test "P1 partial recovery re-plans core-owned suffix" {
  let receiver = OpLog("p1-recovery")
  let first = p0_insert("p1-recovery-first", 0, [], "a", None)
  let failed = p0_insert("p1-recovery-failed", 0, [], "b", None)
  let suffix = p0_insert("p1-recovery-suffix", 0, [], "c", None)
  let failed_raw = remote_admission_raw(failed)
  let plan = try! receiver.prepare_remote([first, failed, suffix])
  let outcome = try! receiver.commit_admission_with(plan, op => {
    if remote_admission_raw(op) == failed_raw {
      raise @causal_graph.CausalGraphError::MissingParent(lv=-99)
    }
    receiver.commit_one_remote_for_admission(op)
  })
  match outcome {
    AdmissionOutcome::Partial(receipt~, error~) => {
      assert_true(
        p1_receipt_has_op(receipt.committed(), remote_admission_raw(first)),
      )
      assert_true(
        p1_receipt_has_raw(receipt.pending_from_transition(), failed_raw),
      )
      assert_true(
        p1_receipt_has_raw(
          receipt.pending_from_transition(),
          remote_admission_raw(suffix),
        ),
      )
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) => assert_eq(lv, -99)
        _ => fail("expected causal partial cause")
      }
    }
    AdmissionOutcome::Complete(_) => fail("injected failure must be partial")
  }
  let recovery = try! receiver.commit_admission(
    try! receiver.prepare_remote([]),
  )
  match recovery {
    AdmissionOutcome::Complete(receipt) => {
      assert_true(p1_receipt_has_op(receipt.committed(), failed_raw))
      assert_true(
        p1_receipt_has_op(receipt.committed(), remote_admission_raw(suffix)),
      )
      assert_eq(receiver.op_count(), 3)
    }
    AdmissionOutcome::Partial(..) => fail("core-owned suffix should recover")
  }
}

///|
test "P1 post-begin causal failure is an outcome not a recoverable error" {
  let receiver = OpLog("p1-error-algebra")
  let incoming = p0_insert("p1-error-algebra-op", 0, [], "x", None)
  let plan = try! receiver.prepare_remote([incoming])
  let outcome = try! receiver.commit_admission_with(plan, _op => {
    raise @causal_graph.CausalGraphError::MissingParent(lv=-101)
  })
  match outcome {
    AdmissionOutcome::Partial(receipt~, error~) => {
      assert_eq(receipt.committed().length(), 0)
      assert_eq(receipt.pending_after_count(), 1)
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) =>
          assert_eq(lv, -101)
        _ => fail("expected causal graph failure")
      }
    }
    AdmissionOutcome::Complete(_) => fail("causal failure must not complete")
  }
}
