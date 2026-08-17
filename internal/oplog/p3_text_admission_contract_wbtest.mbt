///| P3 red tests for delivery evidence versus terminal ownership.

///|
fn p3_receipt_has_raw(
  raws : ArrayView[@core.RawVersion],
  expected : @core.RawVersion,
) -> Bool {
  for raw in raws {
    if raw == expected {
      return true
    }
  }
  false
}

///|
fn p3_receipt_has_op(
  ops : ArrayView[@core.Op],
  expected : @core.RawVersion,
) -> Bool {
  for op in ops {
    if remote_admission_raw(op) == expected {
      return true
    }
  }
  false
}

///|
test "P3 redelivery evidence is independent of admitted ownership" {
  let receiver = OpLog("p3-admitted-redelivery")
  let admitted = p0_insert("p3-admitted-redelivery-peer", 0, [], "A", None)
  let admitted_plan = try! receiver.prepare_remote([admitted])
  ignore(try! receiver.commit_remote(admitted_plan))
  let duplicate_plan = try! receiver.prepare_remote([admitted])
  let outcome = try! receiver.commit_admission(duplicate_plan)

  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.redelivery_count(), 1)
      assert_eq(receipt.committed().length(), 0)
      assert_true(
        p3_receipt_has_raw(
          receipt.already_admitted(),
          remote_admission_raw(admitted),
        ),
      )
    }
    AdmissionOutcome::Partial(..) => fail("admitted redelivery must complete")
  }
}

///|
test "P3 redelivery evidence is independent of pending ownership" {
  let receiver = OpLog("p3-pending-redelivery")
  let missing = p0_raw("p3-pending-redelivery-missing", 0)
  let pending = p0_insert("p3-pending-redelivery-peer", 0, [missing], "P", None)
  let pending_plan = try! receiver.prepare_remote([pending])
  ignore(try! receiver.commit_remote(pending_plan))
  let duplicate_plan = try! receiver.prepare_remote([pending])
  let outcome = try! receiver.commit_admission(duplicate_plan)

  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.redelivery_count(), 1)
      assert_eq(receipt.committed().length(), 0)
      assert_eq(receipt.pending_after_count(), 1)
      assert_true(
        p3_receipt_has_raw(
          receipt.pending_from_transition(),
          remote_admission_raw(pending),
        ),
      )
    }
    AdmissionOutcome::Partial(..) => fail("pending redelivery must complete")
  }
}

///|
test "P3 pending redelivery contributes to delivery and committed evidence" {
  let receiver = OpLog("p3-wake-redelivery")
  let dependency = p0_insert("p3-wake-dependency", 0, [], "D", None)
  let pending = p0_insert(
    "p3-wake-redelivery-peer",
    0,
    [remote_admission_raw(dependency)],
    "P",
    None,
  )
  let pending_plan = try! receiver.prepare_remote([pending])
  ignore(try! receiver.commit_remote(pending_plan))
  let wake_plan = try! receiver.prepare_remote([dependency, pending])
  let outcome = try! receiver.commit_admission(wake_plan)

  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.redelivery_count(), 1)
      assert_eq(receipt.committed().length(), 2)
      assert_true(
        p3_receipt_has_op(receipt.committed(), remote_admission_raw(pending)),
      )
      assert_eq(receipt.pending_after_count(), 0)
    }
    AdmissionOutcome::Partial(..) => fail("dependency wake must complete")
  }
}

///|
test "P3 discarded pending redelivery preserves delivery evidence" {
  let receiver = OpLog("p3-discard-redelivery")
  let missing_target = p0_raw("p3-discard-target", 1)
  let pending_invalid = p0_insert(
    "p3-discard-redelivery-peer",
    0,
    [missing_target],
    "invalid",
    Some(missing_target),
  )
  let pending_plan = try! receiver.prepare_remote([pending_invalid])
  ignore(try! receiver.commit_remote(pending_plan))
  let root = p0_insert("p3-discard-target", 0, [], "A", None)
  let target = p0_delete(
    "p3-discard-target",
    1,
    [remote_admission_raw(root)],
    remote_admission_raw(root),
  )

  let discard_plan = try! receiver.prepare_remote([
    root, target, pending_invalid,
  ])
  let outcome = try! receiver.commit_admission(discard_plan)

  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.redelivery_count(), 1)
      assert_true(
        p3_receipt_has_raw(
          receipt.discarded_pending(),
          remote_admission_raw(pending_invalid),
        ),
      )
      assert_true(
        !p3_receipt_has_op(
          receipt.committed(),
          remote_admission_raw(pending_invalid),
        ),
      )
      assert_eq(receipt.pending_after_count(), 0)
    }
    AdmissionOutcome::Partial(..) =>
      fail("pending rejection closure must complete")
  }
}

///|
test "P3 complete-after limit accepts a ready operation at zero" {
  let receiver = OpLog("p3-after-ready-zero")
  let ready = p0_insert("p3-after-ready-zero-peer", 0, [], "A", None)
  let plan = try! receiver.prepare_remote([ready], max_pending_after_complete=0)
  let outcome = try! receiver.commit_admission(plan)
  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.committed().length(), 1)
      assert_eq(receipt.pending_after_count(), 0)
    }
    AdmissionOutcome::Partial(..) => fail("ready operation must complete")
  }
}

///|
test "P3 complete-after limit accepts mixed ready and unresolved batch" {
  let receiver = OpLog("p3-after-mixed")
  let ready = p0_insert("p3-after-mixed-ready", 0, [], "A", None)
  let unresolved = p0_insert(
    "p3-after-mixed-unresolved",
    0,
    [p0_raw("p3-after-mixed-missing", 0)],
    "B",
    None,
  )
  let plan = try! receiver.prepare_remote(
    [ready, unresolved],
    max_pending_after_complete=1,
  )
  let outcome = try! receiver.commit_admission(plan)
  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.committed().length(), 1)
      assert_eq(receipt.pending_after_count(), 1)
    }
    AdmissionOutcome::Partial(..) => fail("mixed batch must complete")
  }
}

///|
test "P3 complete-after limit accepts all-ready batch over the limit" {
  let receiver = OpLog("p3-after-all-ready")
  let first = p0_insert("p3-after-all-ready-first", 0, [], "A", None)
  let second = p0_insert("p3-after-all-ready-second", 0, [], "B", None)
  let plan = try! receiver.prepare_remote(
    [first, second],
    max_pending_after_complete=1,
  )
  let outcome = try! receiver.commit_admission(plan)
  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.committed().length(), 2)
      assert_eq(receipt.pending_after_count(), 0)
    }
    AdmissionOutcome::Partial(..) => fail("all-ready batch must complete")
  }
}

///|
test "P3 core admission does not count repeated raw identities as redelivery" {
  let receiver = OpLog("p3-core-raw-duplicate")
  let operation = p0_insert("p3-core-raw-duplicate-peer", 0, [], "A", None)
  let duplicate_plan = try! receiver.prepare_remote([operation, operation])
  let outcome = try! receiver.commit_admission(duplicate_plan)
  match outcome {
    AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.redelivery_count(), 0)
      assert_eq(receipt.committed().length(), 1)
      assert_eq(receipt.already_admitted().length(), 0)
    }
    AdmissionOutcome::Partial(..) =>
      fail("canonical raw duplicate must complete")
  }
}
