///| P2.1 red tests for the typed Document batch-admission boundary.

///|
fn p2_remote_insert(
  agent : String,
  sequence : Int,
  parents : Array[@core.RawVersion],
  origin_left : @core.RawVersion?,
) -> @core.Op {
  @core.Op::insert(
    -1,
    parents,
    agent,
    sequence,
    "p2-\{sequence}",
    origin_left,
    None,
  )
}

///|
fn p2_ready_batch(agent : String, count : Int) -> Array[@core.Op] {
  let operations : Array[@core.Op] = []
  for sequence = 0; sequence < count; sequence = sequence + 1 {
    let previous = if sequence == 0 {
      None
    } else {
      Some(@core.RawVersion(agent, sequence - 1))
    }
    let parents = match previous {
      Some(raw) => [raw]
      None => []
    }
    operations.push(p2_remote_insert(agent, sequence, parents, previous))
  }
  operations
}

///|
fn p2_pending_batch(agent : String) -> Array[@core.Op] {
  let missing = @core.RawVersion(agent + "-missing", 0)
  [p2_remote_insert(agent, 0, [missing], None)]
}

///|
fn p2_assert_operation_prefix(
  actual : ArrayView[@core.Op],
  expected : Array[@core.Op],
  count : Int,
) -> Unit raise {
  assert_eq(actual.length(), count)
  for index = 0; index < count; index = index + 1 {
    assert_eq(
      @core.RawVersion(actual[index].agent(), actual[index].seq()),
      @core.RawVersion(expected[index].agent(), expected[index].seq()),
    )
  }
}

///|
fn p2_assert_identity_prefix(
  actual : ArrayView[@core.RawVersion],
  expected : Array[@core.Op],
  count : Int,
) -> Unit raise {
  assert_eq(actual.length(), count)
  for index = 0; index < count; index = index + 1 {
    assert_eq(
      actual[index],
      @core.RawVersion(expected[index].agent(), expected[index].seq()),
    )
  }
}

///|
test "P2 red complete batch has one typed transition and one projection" {
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  let projected_ops : Array[@core.Op] = []
  let doc = Document::new("p2-complete")
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: committed => {
      projection_count = projection_count + 1
      for op in committed {
        projected_ops.push(op)
      }
    },
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: None,
  })
  let incoming = p2_ready_batch("p2-complete-peer", 3)

  let admission = try! doc.admit_remote(incoming)
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 1)
  p2_assert_operation_prefix(projected_ops, incoming, 3)
  match admission.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => {
      p2_assert_operation_prefix(receipt.committed(), incoming, 3)
      assert_eq(receipt.pending_from_transition().length(), 0)
    }
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("complete batch must not be partial")
  }
  match admission.projection {
    ProjectionStatus::Projected => ()
    ProjectionStatus::Skipped
    | ProjectionStatus::Recovered
    | ProjectionStatus::RecoveryRequired(..) =>
      fail("complete committed batch must be projected")
  }
  let fresh = try! @branch.Branch::checkout(doc.oplog, doc.get_frontier())
  assert_eq(doc.to_text(), fresh.to_text())
}

///|
test "P2 red duplicate-only and pending-only batches skip projection" {
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  let duplicate_doc = Document::new("p2-duplicate")
  duplicate_doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: None,
  })
  let incoming = p2_ready_batch("p2-duplicate-peer", 2)
  ignore(try! duplicate_doc.admit_remote(incoming))
  let duplicate = try! duplicate_doc.admit_remote(incoming)

  assert_eq(prepare_count, 2)
  assert_eq(commit_count, 2)
  assert_eq(projection_count, 1)
  match duplicate.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.committed().length(), 0)
      p2_assert_identity_prefix(receipt.already_admitted(), incoming, 2)
    }
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("duplicate-only batch must be complete")
  }
  match duplicate.projection {
    ProjectionStatus::Skipped => ()
    ProjectionStatus::Projected
    | ProjectionStatus::Recovered
    | ProjectionStatus::RecoveryRequired(..) =>
      fail("duplicate-only batch must skip projection")
  }

  let mut pending_prepare_count = 0
  let mut pending_commit_count = 0
  let mut pending_projection_count = 0
  let pending_doc = Document::new("p2-pending")
  pending_doc.set_admission_hooks({
    on_prepare_remote: () => pending_prepare_count = pending_prepare_count + 1,
    on_commit_admission: () => pending_commit_count = pending_commit_count + 1,
    on_projection_finalization: _ => {
      pending_projection_count = pending_projection_count + 1
    },
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: None,
  })
  let pending_incoming = p2_pending_batch("p2-pending-peer")
  let pending = try! pending_doc.admit_remote(pending_incoming)

  assert_eq(pending_prepare_count, 1)
  assert_eq(pending_commit_count, 1)
  assert_eq(pending_projection_count, 0)
  match pending.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.committed().length(), 0)
      p2_assert_identity_prefix(
        receipt.pending_from_transition(),
        pending_incoming,
        1,
      )
    }
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("pending-only batch must be complete")
  }
  match pending.projection {
    ProjectionStatus::Skipped => ()
    ProjectionStatus::Projected
    | ProjectionStatus::Recovered
    | ProjectionStatus::RecoveryRequired(..) =>
      fail("pending-only batch must skip projection")
  }
}

///|
test "P2 red partial prefixes project only the committed receipt prefix" {
  for failed_index in [0, 1, 2] {
    let mut prepare_count = 0
    let mut commit_count = 0
    let mut projection_count = 0
    let projected_ops : Array[@core.Op] = []
    let agent = "p2-partial-peer-" + failed_index.to_string()
    let doc = Document::new("p2-partial-" + failed_index.to_string())
    doc.set_admission_hooks({
      on_prepare_remote: () => prepare_count = prepare_count + 1,
      on_commit_admission: () => commit_count = commit_count + 1,
      on_projection_finalization: committed => {
        projection_count = projection_count + 1
        for op in committed {
          projected_ops.push(op)
        }
      },
      prepare_override: None,
      commit_failure: Some(op => {
        if op.seq() == failed_index {
          Some(@causal_graph.CausalGraphError::MissingParent(lv=-201))
        } else {
          None
        }
      }),
      projection_failure: None,
      recovery_checkout: None,
    })
    assert_true(doc.admission_commit_failure() is Some(_))

    let incoming = p2_ready_batch(agent, 3)
    let admission = try! doc.admit_remote(incoming)
    assert_eq(prepare_count, 1)
    assert_eq(commit_count, 1)
    assert_eq(projection_count, if failed_index == 0 { 0 } else { 1 })
    p2_assert_operation_prefix(projected_ops, incoming, failed_index)
    match admission.outcome {
      @oplog.AdmissionOutcome::Partial(receipt~, error~) => {
        p2_assert_operation_prefix(receipt.committed(), incoming, failed_index)
        assert_eq(receipt.pending_from_transition().length(), 3 - failed_index)
        match error {
          @causal_graph.CausalGraphError::MissingParent(lv~) =>
            assert_eq(lv, -201)
          _ => fail("partial cause must be preserved")
        }
      }
      @oplog.AdmissionOutcome::Complete(_) =>
        fail("injected partial boundary must remain partial")
    }
    match admission.projection {
      ProjectionStatus::Skipped if failed_index == 0 => ()
      ProjectionStatus::Projected if failed_index > 0 => ()
      ProjectionStatus::Skipped
      | ProjectionStatus::Projected
      | ProjectionStatus::Recovered
      | ProjectionStatus::RecoveryRequired(..) =>
        fail("partial projection status must follow committed prefix")
    }
  }
}
