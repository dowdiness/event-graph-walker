///|
/// Test-first conformance rows F-01, F-02, D-04, and D-05.
test "F-01 self-contained Fast-forward regions cover heads and match EGW" {
  for count in [1, 10, 100] {
    let (fixture, state, region) = try! working_state_scaled_case(count)
    let result = working_state_admit_region(state, region)
    match result.outcome {
      WorkingStateAdmissionOutcome::Complete => ()
      _ => fail("F-01 did not complete")
    }
    assert_eq(result.committed.length(), count)
    assert_eq(result.state.pending.length(), 0)
    assert_true(result.state.capture_enabled)
    assert_eq(result.reads.metadata_queries, 0)
    assert_eq(result.reads.payload_queries, 0)
    assert_eq(result.reads.full_history_queries, 0)
    assert_eq(result.reads.scan_records_visited, 0)
    assert_eq(result.state.document_text, fixture.final_text)
    let candidate = try! working_state_capture(result.state)
    let authority = try! validate_capture_against_egw_authority(
      fixture, candidate,
    )
    assert_eq(authority.authority_text, result.state.document_text)
    assert_eq(authority.exact_heads, working_state_frontier(result.state))
    assert_eq(authority.committed_events, count + 1)
    assert_eq(authority.pending_after_count, 0)
    assert_true(authority.used_typed_admission_receipts)
    assert_eq(authority.full_history_walks, 0)
    assert_eq(
      result.state.snapshot.document_text_sha256,
      try! sha256(strict_utf8(fixture.final_text)),
    )
    assert_eq(
      result.state.snapshot.document_text_scalar_length,
      try! unicode_scalar_length(fixture.final_text),
    )
  }
}

///|
test "F-02 delete and insert of the same scalar advances only causal state" {
  let (fixture, state, region) = try! working_state_source_equal_case()
  let before_text = state.document_text
  let before_hash = state.snapshot.document_text_sha256
  let before_projection = working_state_visible_projection(before_text)
  let before_commit = state.snapshot.snapshot_commit_id
  let result = working_state_admit_region(state, region)
  assert_eq(result.outcome, WorkingStateAdmissionOutcome::Complete)
  assert_eq(result.state.document_text, before_text)
  assert_eq(result.state.snapshot.document_text_sha256, before_hash)
  assert_true(result.state.snapshot.snapshot_commit_id != before_commit)
  assert_eq(
    working_state_visible_projection(result.state.document_text),
    before_projection,
  )
  assert_eq(result.state.committed_event_count, 2)
  assert_eq(result.state.pending.length(), 0)
  assert_eq(result.reads.metadata_queries, 0)
  assert_eq(result.reads.payload_queries, 0)
  assert_eq(result.reads.full_history_queries, 0)
  let authority = try! validate_capture_against_egw_authority(
    fixture,
    try! working_state_capture(result.state),
  )
  assert_eq(authority.authority_text, before_text)
  assert_eq(authority.committed_events, 3)
}

///|
test "D-04 child before parent retains exact pending identity then drains" {
  let (fixture, state, region) = try! working_state_pending_case()
  let child = region[1]
  let pending = working_state_admit_one(state, child)
  assert_eq(
    pending.outcome,
    WorkingStateAdmissionOutcome::Pending(missing=region[0].identity),
  )
  assert_eq(working_state_pending_identities(pending.state), [
    region[1].identity,
  ])
  assert_eq(pending.state.document_text, state.document_text)
  assert_eq(
    pending.state.snapshot.snapshot_commit_id,
    state.snapshot.snapshot_commit_id,
  )
  assert_eq(pending.state.committed_event_count, 0)
  assert_true(!pending.state.capture_enabled)
  let drained = working_state_admit_one(pending.state, region[0])
  assert_eq(drained.outcome, WorkingStateAdmissionOutcome::Complete)
  assert_eq(drained.state.pending.length(), 0)
  assert_true(drained.state.capture_enabled)
  assert_eq(drained.state.committed_event_count, 2)
  assert_eq(drained.committed.length(), 2)
  assert_eq(drained.state.document_text, fixture.final_text)
  assert_eq(drained.state.snapshot.exact_raw_heads, [region[1].identity])
  assert_eq(drained.reads.metadata_queries, 0)
  assert_eq(drained.reads.payload_queries, 0)
  assert_eq(drained.reads.full_history_queries, 0)
  assert_eq(drained.reads.scan_records_visited, 0)
}

///|
test "D-04 invalid pending child cannot become complete after parent arrival" {
  let (_, state, region) = try! working_state_pending_case()
  let parent = region[0]
  let child = region[1]
  let wrong_digest = Bytes::new(32)
  let invalid_child = try! ordinary_event_meta(
    child.identity,
    child.body.unwrap(),
    child.causal_rank_timestamp,
    [(parent.identity, wrong_digest)],
    Some((parent.identity, wrong_digest)),
    [],
  )
  let pending = working_state_admit_one(state, invalid_child)
  assert_eq(
    pending.outcome,
    WorkingStateAdmissionOutcome::Pending(missing=parent.identity),
  )
  let drained = working_state_admit_one(pending.state, parent)
  match drained.outcome {
    WorkingStateAdmissionOutcome::Partial(reason~, ..) =>
      assert_eq(reason, "parent_digest_mismatch")
    _ => fail("invalid pending child was certified complete")
  }
  assert_eq(drained.state.committed_event_count, 1)
  assert_eq(working_state_pending_identities(drained.state), [child.identity])
  assert_true(!drained.state.capture_enabled)
  try working_state_capture(drained.state) catch {
    R0CodecError::InvalidValue(detail="capture_disabled") => ()
    _ => fail("invalid pending state raised the wrong capture error")
  } noraise {
    _ => fail("invalid pending state remained recapturable")
  }
}

///|
test "F-01 every entry point covers every resident exact head" {
  let builder = FixtureBuilder::new()
  let base = builder.insert("r0-base", [], 0, "a")
  builder.insert("r0-left", [base.identity], 1, "l") |> ignore
  builder.insert("r0-right", [base.identity], 1, "r") |> ignore
  let fixture : GeneratedFixture = {
    fixture_id: "F-01-two-head-coverage",
    document_id: "loomark-r0-fixture-F-01-two-head-coverage",
    events: builder.events,
    replay_order: stable_topological_order(builder.events),
    final_text: visible_text(builder.visible),
  }
  let overlay = try! build_nonempty_overlay(fixture)
  assert_eq(overlay.snapshot.exact_head_records.length(), 2)
  let left = overlay.snapshot.exact_head_records[0]
  let right = overlay.snapshot.exact_head_records[1]
  let first = try! ordinary_event_meta(
    RawIdentity(agent="r0-entry-a", sequence=0),
    InsertScalar(0, "x"),
    left.causal_rank_timestamp + 1,
    [(left.identity, left.event_digest_v2)],
    None,
    [],
  )
  let second = try! ordinary_event_meta(
    RawIdentity(agent="r0-entry-b", sequence=0),
    InsertScalar(0, "y"),
    right.causal_rank_timestamp + 1,
    [(right.identity, right.event_digest_v2)],
    None,
    [],
  )
  let state = working_state_begin_from_snapshot(
    overlay.snapshot,
    fixture.final_text,
  )
  let single = working_state_admit_one(state, first)
  assert_eq(
    single.outcome,
    WorkingStateAdmissionOutcome::Rejected(
      reason="entry_point_does_not_cover_heads",
    ),
  )
  let batch = working_state_admit_batch(state, [first])
  assert_eq(
    batch.outcome,
    WorkingStateAdmissionOutcome::Rejected(
      reason="entry_point_does_not_cover_heads",
    ),
  )
  let result = working_state_admit_region(state, [first, second])
  assert_eq(
    result.outcome,
    WorkingStateAdmissionOutcome::Rejected(
      reason="entry_point_does_not_cover_heads",
    ),
  )
  assert_eq(
    result.state.snapshot.snapshot_commit_id,
    state.snapshot.snapshot_commit_id,
  )
}

///|
test "D-05 valid prefix commits sidecar while unresolved suffix disables capture" {
  let result = try! working_state_partial_case()
  match result.outcome {
    WorkingStateAdmissionOutcome::Partial(missing~, reason~) => {
      assert_eq(missing, RawIdentity(agent="r0-missing", sequence=0))
      assert_eq(reason, "pending")
    }
    _ => fail("expected partial admission")
  }
  assert_eq(result.state.committed_event_count, 1)
  assert_eq(result.committed.length(), 1)
  assert_eq(result.state.document_text, "p")
  assert_eq(result.state.snapshot.exact_raw_heads, [
    RawIdentity(agent="r0-fast-forward", sequence=0),
  ])
  assert_eq(working_state_pending_identities(result.state), [
    RawIdentity(agent="r0-suffix", sequence=0),
  ])
  assert_true(!result.state.capture_enabled)
  assert_eq(result.reads.metadata_queries, 0)
  assert_eq(result.reads.payload_queries, 0)
  assert_eq(result.reads.full_history_queries, 0)
  assert_eq(result.reads.scan_records_visited, 0)
}

///|
test "Working State validation rejects malformed metadata without mutation" {
  let (_, state, region) = try! working_state_pending_case()
  let valid = region[0]
  let malformed = { ..valid, body: None }
  let result = working_state_admit_one(state, malformed)
  assert_eq(
    result.outcome,
    WorkingStateAdmissionOutcome::Rejected(reason="body_missing"),
  )
  assert_eq(result.state.document_text, state.document_text)
  assert_eq(
    result.state.snapshot.snapshot_commit_id,
    state.snapshot.snapshot_commit_id,
  )
  assert_eq(result.state.committed_event_count, 0)
  let bad_length = {
    ..valid,
    payload_byte_length: valid.payload_byte_length + 1,
  }
  let length_result = working_state_admit_one(state, bad_length)
  assert_eq(
    length_result.outcome,
    WorkingStateAdmissionOutcome::Rejected(reason="payload_length_mismatch"),
  )
  let bad_rank = { ..valid, causal_rank_timestamp: 1 }
  let rank_result = working_state_admit_one(state, bad_rank)
  assert_eq(
    rank_result.outcome,
    WorkingStateAdmissionOutcome::Rejected(reason="event_digest_mismatch"),
  )
}

///|
test "Working State rejects unsorted parents, undelete, and non-contiguous identity" {
  let (_, state, region) = try! working_state_pending_case()
  let root = region[0]
  let unsorted = try! ordinary_event_meta(
    RawIdentity(agent="r0-other", sequence=0),
    InsertScalar(0, "u"),
    1,
    [
      (RawIdentity(agent="z", sequence=0), Bytes::new(32)),
      (RawIdentity(agent="a", sequence=0), Bytes::new(32)),
    ],
    None,
    [],
  )
  assert_eq(
    working_state_admit_one(state, unsorted).outcome,
    WorkingStateAdmissionOutcome::Rejected(reason="parents_not_sorted_unique"),
  )
  let undelete = try! ordinary_event_meta(
    RawIdentity(agent="r0-other", sequence=0),
    Undelete(root.identity),
    0,
    [],
    None,
    [],
  )
  assert_eq(
    working_state_admit_one(state, undelete).outcome,
    WorkingStateAdmissionOutcome::Rejected(reason="undelete_unsupported"),
  )
  let non_contiguous = try! ordinary_event_meta(
    RawIdentity(agent="r0-fast-forward", sequence=1),
    InsertScalar(0, "n"),
    0,
    [],
    None,
    [],
  )
  assert_eq(
    working_state_admit_one(state, non_contiguous).outcome,
    WorkingStateAdmissionOutcome::Rejected(reason="predecessor_missing"),
  )
}

///|
test "Working State conflict never mutates the committed sidecar" {
  let (_, state, region) = try! working_state_pending_case()
  let first = working_state_admit_one(state, region[0])
  let conflict = try! ordinary_event_meta(
    region[0].identity,
    InsertScalar(0, "d"),
    region[0].causal_rank_timestamp,
    region[0].declared_parents.copy(),
    region[0].implicit_predecessor,
    [],
  )
  let result = working_state_admit_one(first.state, conflict)
  assert_eq(
    result.outcome,
    WorkingStateAdmissionOutcome::Rejected(reason="conflicting_identity"),
  )
  assert_eq(result.state.document_text, first.state.document_text)
  assert_eq(
    result.state.snapshot.snapshot_commit_id,
    first.state.snapshot.snapshot_commit_id,
  )
  assert_eq(result.state.committed_event_count, 1)
}
