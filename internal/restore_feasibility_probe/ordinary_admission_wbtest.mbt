///|
fn ordinary_admission_fixture() -> (
  OrdinarySnapshot,
  OrdinaryProvider,
  Array[OrdinaryEventMetaV2],
) {
  let fixture = try! generate_fixture("S-linear", 4)
  let overlay = try! build_ordinary_capture_overlay(fixture)
  let provider_overlay = {
    ..overlay,
    full_history_bytes: legacy_oracle_history_bytes(fixture),
  }
  let provider = try! OrdinaryProvider::new(
    try! encode_provider_fixture(provider_overlay),
  )
  (overlay.snapshot, provider, overlay.metas)
}

///|
fn assert_no_admission_reads(
  before : OrdinaryProviderCounters,
  after : OrdinaryProviderCounters,
) -> Unit raise {
  assert_eq(after.logical_query_count - before.logical_query_count, 0)
  assert_eq(after.physical_read_calls - before.physical_read_calls, 0)
  assert_eq(after.metadata_records - before.metadata_records, 0)
  assert_eq(after.payload_events - before.payload_events, 0)
  assert_eq(after.full_history_events - before.full_history_events, 0)
  assert_eq(after.scan_records_visited - before.scan_records_visited, 0)
}

///|
test "D-01 Tier-0 nonmembership never invokes the provider" {
  let (snapshot, provider, _) = ordinary_admission_fixture()
  let before = provider.counters
  let absent_writer : OrdinaryEventMetaV2 = {
    identity: RawIdentity(agent="missing", sequence=0),
    body: None,
    kind: 1,
    event_digest_v2: Bytes::new(32),
    body_digest: Bytes::new(32),
    causal_rank_timestamp: 0,
    declared_parents: [],
    implicit_predecessor: None,
    semantic_references: [],
    payload_byte_length: 0,
  }
  let absent_sequence = {
    ..absent_writer,
    identity: RawIdentity(agent="r0-a", sequence=4),
  }
  for incoming in [absent_writer, absent_sequence] {
    let result = try! ordinary_admit_event(snapshot, provider, incoming)
    assert_eq(result.decision, OrdinaryAdmissionDecision::Tier0Nonmembership)
    assert_eq(result.counter_delta.logical_query_count, 0)
    assert_eq(result.counter_delta.physical_read_calls, 0)
    assert_true(result.counter_delta.resident_records_visited > 0)
    assert_eq(result.counter_delta.scan_records_visited, 0)
    assert_no_admission_reads(before, provider.counters)
  }
}

///|
test "D-02 exact duplicate verifies one sorted authenticated metadata batch" {
  let (snapshot, provider, metas) = ordinary_admission_fixture()
  let incoming = metas[2]
  let before = ordinary_copy_provider_counters(provider.counters)
  let result = try! ordinary_admit_event(snapshot, provider, incoming)
  assert_eq(result.decision, OrdinaryAdmissionDecision::Duplicate)
  assert_eq(result.counter_delta.logical_query_count, 1)
  assert_eq(result.counter_delta.physical_read_calls, 1)
  assert_eq(result.counter_delta.requested_id_count, 1)
  assert_eq(result.counter_delta.returned_record_count, 1)
  assert_eq(result.counter_delta.payload_events, 0)
  assert_eq(result.counter_delta.full_history_events, 0)
  assert_eq(result.counter_delta.scan_records_visited, 0)
  assert_eq(
    provider.counters.logical_query_count - before.logical_query_count,
    1,
  )
  assert_eq(
    provider.counters.physical_read_calls - before.physical_read_calls,
    1,
  )
}

///|
test "D-03 conflicts are named before any payload or full-history read" {
  let (snapshot, provider, metas) = ordinary_admission_fixture()
  let resident = metas[2]
  let body_conflict = try! ordinary_event_meta(
    resident.identity,
    InsertScalar(0, "z"),
    resident.causal_rank_timestamp,
    resident.declared_parents.copy(),
    resident.implicit_predecessor,
    resident.semantic_references.copy(),
  )
  let parent_conflict = try! ordinary_event_meta(
    resident.identity,
    resident.body.unwrap(),
    resident.causal_rank_timestamp,
    [],
    resident.implicit_predecessor,
    resident.semantic_references.copy(),
  )
  let predecessor_conflict = try! ordinary_event_meta(
    resident.identity,
    resident.body.unwrap(),
    resident.causal_rank_timestamp,
    resident.declared_parents.copy(),
    None,
    resident.semantic_references.copy(),
  )
  let reference_conflict = try! ordinary_event_meta(
    resident.identity,
    resident.body.unwrap(),
    resident.causal_rank_timestamp,
    resident.declared_parents.copy(),
    resident.implicit_predecessor,
    [(1, RawIdentity(agent="r0-a", sequence=0), Bytes::new(32), 1)],
  )
  let rank_conflict = try! ordinary_event_meta(
    resident.identity,
    resident.body.unwrap(),
    resident.causal_rank_timestamp + 1,
    resident.declared_parents.copy(),
    resident.implicit_predecessor,
    resident.semantic_references.copy(),
  )
  let cases = [
    (body_conflict, OrdinaryAdmissionConflict::BodyDigest),
    (parent_conflict, OrdinaryAdmissionConflict::DeclaredParents),
    (predecessor_conflict, OrdinaryAdmissionConflict::ImplicitPredecessor),
    (reference_conflict, OrdinaryAdmissionConflict::SemanticReferences),
    (rank_conflict, OrdinaryAdmissionConflict::RankOrEventDigest),
  ]
  for item in cases {
    let (incoming, expected) = item
    let before = ordinary_copy_provider_counters(provider.counters)
    let result = try! ordinary_admit_event(snapshot, provider, incoming)
    assert_eq(result.decision, OrdinaryAdmissionDecision::Conflict(expected))
    assert_eq(result.counter_delta.payload_events, 0)
    assert_eq(result.counter_delta.full_history_events, 0)
    assert_eq(result.counter_delta.scan_records_visited, 0)
    assert_eq(provider.counters.payload_events - before.payload_events, 0)
    assert_eq(
      provider.counters.full_history_events - before.full_history_events,
      0,
    )
  }
}

///|
test "D metadata failures fallback and never become permission" {
  let (snapshot, provider, metas) = ordinary_admission_fixture()
  let incoming = metas[2]
  let stale_snapshot = { ..snapshot, snapshot_commit_id: Bytes::new(32) }
  let stale = try! ordinary_admit_event(stale_snapshot, provider, incoming)
  assert_eq(
    stale.decision,
    OrdinaryAdmissionDecision::Fallback("provider_corrupt"),
  )
  let records = provider.meta_records.copy()
  let index = 2
  let proof = try! decode_mmr_proof(records[index].proof_bytes)
  let siblings = proof.siblings.copy()
  siblings[0] = { ..siblings[0], digest: Bytes::new(32) }
  let corrupt_proof = try! encode_mmr_proof(proof.copy_with(siblings~))
  let corrupt_record = { ..records[index], proof_bytes: corrupt_proof }
  records[index] = corrupt_record
  let meta_index = provider.meta_index
  meta_index[raw_identity_key(incoming.identity)] = corrupt_record
  let corrupt_provider = { ..provider, meta_records: records, meta_index }
  let corrupt = try! ordinary_admit_event(snapshot, corrupt_provider, incoming)
  assert_eq(
    corrupt.decision,
    OrdinaryAdmissionDecision::Fallback("provider_corrupt"),
  )
  let unavailable_provider = { ..provider, metadata_unavailable: true }
  let unavailable = try! ordinary_admit_event(
    snapshot, unavailable_provider, incoming,
  )
  assert_eq(
    unavailable.decision,
    OrdinaryAdmissionDecision::Fallback("provider_unavailable"),
  )
  assert_eq(
    verify_ordinary_admission(
      snapshot,
      incoming,
      OrdinaryAdmissionResponse::MissingInAuthenticatedRange,
    ),
    OrdinaryAdmissionDecision::Fallback(
      "provider_missing_in_authenticated_range",
    ),
  )
}
