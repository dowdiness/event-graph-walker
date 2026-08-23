///|
test "F-04 MetadataBacked Fast-forward applies without retaining cold metadata" {
  let (fixture, state, incoming, provider, provider_bytes) = try! metadata_backed_fast_forward_case()
  let before = working_state_copy_state(state)
  ignore(
    working_state_admit_metadata_backed_one(
      state,
      incoming[0],
      try! OrdinaryProvider::new(provider_bytes),
    ),
  )
  ignore(
    working_state_admit_metadata_backed_batch(
      state,
      incoming,
      try! OrdinaryProvider::new(provider_bytes),
    ),
  )
  ignore(
    working_state_admit_metadata_backed_region(
      state,
      incoming,
      try! OrdinaryProvider::new(provider_bytes),
    ),
  )
  let result = working_state_admit_metadata_backed(state, incoming, provider)
  assert_eq(result.outcome, WorkingStateAdmissionOutcome::Complete)
  assert_eq(result.evidence_source, WorkingStateEvidenceSource::MetadataBacked)
  assert_eq(result.state.document_text, fixture.final_text)
  assert_true(
    result.state.snapshot.snapshot_commit_id !=
    before.snapshot.snapshot_commit_id,
  )
  assert_eq(result.reads.metadata_queries, 1)
  assert_eq(provider.counters.requested_id_count, 2)
  assert_eq(provider.counters.metadata_records, 2)
  assert_eq(result.reads.payload_queries, 0)
  assert_eq(result.reads.full_history_queries, 0)
  assert_eq(result.reads.scan_records_visited, 0)
  let authority = try! validate_capture_against_egw_authority(
    fixture,
    try! working_state_capture(result.state),
  )
  assert_eq(authority.authority_text, result.state.document_text)
  assert_eq(authority.exact_heads, working_state_frontier(result.state))
  assert_eq(authority.committed_events, 4)
  let cold = RawIdentity(agent="r0-metadata-backed-history", sequence=1)
  assert_true(result.state.committed.get(raw_identity_key(cold)) is None)
  assert_true(result.state.text_by_identity.get(raw_identity_key(cold)) is None)
  let writer_metas = result.state.writer_metas.get(cold.agent).unwrap_or([])
  assert_eq(writer_metas.length(), 1)
  assert_eq(writer_metas[0].identity, incoming[0].identity)
}

///|
test "Metadata authentication rejects a valid proof bound to the wrong sequence" {
  let (_, state, incoming, provider, _) = try! metadata_backed_fast_forward_case()
  let wrong_identity = RawIdentity(
    agent="r0-metadata-backed-history",
    sequence=0,
  )
  let wrong_proof = provider.meta_index
    .get(raw_identity_key(wrong_identity))
    .unwrap().proof_bytes
  let parent_identity = incoming[0].implicit_predecessor.unwrap().0
  let index : Map[String, OrdinaryProviderMetaRecord] = Map::from_array(
    provider.meta_index.to_array(),
  )
  let parent_record = index[raw_identity_key(parent_identity)]
  index[raw_identity_key(parent_identity)] = {
    ..parent_record,
    proof_bytes: wrong_proof,
  }
  let result = working_state_admit_metadata_backed(state, incoming, {
    ..provider,
    meta_index: index,
  })
  assert_eq(
    result.outcome,
    WorkingStateAdmissionOutcome::Fallback(reason="provider_corrupt"),
  )
}

///|
test "MetadataBacked missing unavailable corrupt digest and rank evidence falls back closed" {
  let (_, state, incoming, provider, _) = try! metadata_backed_fast_forward_case()
  let unavailable = working_state_admit_metadata_backed(state, incoming, {
    ..provider,
    metadata_unavailable: true,
  })
  assert_eq(
    unavailable.outcome,
    WorkingStateAdmissionOutcome::Fallback(reason="provider_unavailable"),
  )
  let missing_index : Map[String, OrdinaryProviderMetaRecord] = Map::from_array(
    provider.meta_index.to_array(),
  )
  missing_index.remove(raw_identity_key(incoming[0].declared_parents[0].0))
  let missing = working_state_admit_metadata_backed(state, incoming, {
    ..provider,
    meta_index: missing_index,
  })
  assert_eq(
    missing.outcome,
    WorkingStateAdmissionOutcome::Fallback(
      reason="provider_missing_in_authenticated_range",
    ),
  )
  let corrupt_index : Map[String, OrdinaryProviderMetaRecord] = Map::from_array(
    provider.meta_index.to_array(),
  )
  let parent = incoming[0].declared_parents[0].0
  let parent_record = corrupt_index.get(raw_identity_key(parent)).unwrap()
  corrupt_index[raw_identity_key(parent)] = {
    ..parent_record,
    meta_bytes: Bytes::new(0),
  }
  let corrupt = working_state_admit_metadata_backed(state, incoming, {
    ..provider,
    meta_index: corrupt_index,
  })
  assert_eq(
    corrupt.outcome,
    WorkingStateAdmissionOutcome::Fallback(reason="provider_corrupt"),
  )
  let bad_parent = try! ordinary_event_meta(
    incoming[0].identity,
    incoming[0].body.unwrap(),
    incoming[0].causal_rank_timestamp,
    [(parent, Bytes::new(32))],
    incoming[0].implicit_predecessor,
    [],
  )
  let bad_digest = working_state_admit_metadata_backed(
    state,
    [bad_parent],
    provider,
  )
  assert_eq(
    bad_digest.outcome,
    WorkingStateAdmissionOutcome::Fallback(reason="parent_digest_mismatch"),
  )
  let bad_rank = try! ordinary_event_meta(
    incoming[0].identity,
    incoming[0].body.unwrap(),
    incoming[0].causal_rank_timestamp - 1,
    incoming[0].declared_parents.copy(),
    incoming[0].implicit_predecessor,
    [],
  )
  let rank = working_state_admit_metadata_backed(state, [bad_rank], provider)
  assert_eq(
    rank.outcome,
    WorkingStateAdmissionOutcome::Fallback(reason="rank_not_decreasing"),
  )
  let predecessor = incoming[0].implicit_predecessor.unwrap()
  let bad_predecessor = try! ordinary_event_meta(
    incoming[0].identity,
    incoming[0].body.unwrap(),
    incoming[0].causal_rank_timestamp,
    incoming[0].declared_parents.copy(),
    Some((predecessor.0, Bytes::new(32))),
    [],
  )
  let predecessor_digest = working_state_admit_metadata_backed(
    state,
    [bad_predecessor],
    provider,
  )
  assert_eq(
    predecessor_digest.outcome,
    WorkingStateAdmissionOutcome::Fallback(reason="predecessor_digest_mismatch"),
  )
  for
    result in [
      unavailable, missing, corrupt, bad_digest, rank, predecessor_digest,
    ] {
    assert_eq(result.state.document_text, state.document_text)
    assert_eq(
      result.state.snapshot.snapshot_commit_id,
      state.snapshot.snapshot_commit_id,
    )
    assert_eq(result.state.committed_event_count, 0)
    assert_eq(result.reads.payload_queries, 0)
    assert_eq(result.reads.full_history_queries, 0)
    assert_eq(result.reads.scan_records_visited, 0)
  }
}

///|
test "MetadataBacked append supports multiple historical events from one writer" {
  let builder = FixtureBuilder::new()
  let first = builder.insert("r0-metadata-backed-history", [], 0, "a")
  let second = builder.insert(
    "r0-metadata-backed-history",
    builder.chain_parents(),
    1,
    "b",
  )
  let resident = builder.insert(
    "r0-metadata-backed-resident",
    builder.chain_parents(),
    2,
    "c",
  )
  builder.insert("r0-metadata-backed-history", builder.chain_parents(), 3, "d")
  |> ignore
  builder.insert("r0-metadata-backed-history", builder.chain_parents(), 4, "e")
  |> ignore
  let fixture : GeneratedFixture = {
    fixture_id: "F-04-metadata-backed-multi",
    document_id: "r0-metadata-backed-multi",
    events: builder.events,
    replay_order: stable_topological_order(builder.events),
    final_text: visible_text(builder.visible),
  }
  let full = build_nonempty_overlay(fixture)
  let prefix : GeneratedFixture = {
    ..fixture,
    events: [first, second, resident],
    replay_order: [first.identity, second.identity, resident.identity],
    final_text: "abc",
  }
  let base = build_nonempty_overlay(prefix)
  let provider_bytes = try! encode_provider_fixture({
    ..base,
    full_history_bytes: Bytes::new(0),
  })
  let provider = try! OrdinaryProvider::new(provider_bytes)
  let state = working_state_begin_from_snapshot(base.snapshot, "abc")
  let incoming = [full.metas[3], full.metas[4]]
  let result = working_state_admit_metadata_backed(state, incoming, provider)
  assert_eq(result.outcome, WorkingStateAdmissionOutcome::Complete)
  assert_eq(result.state.document_text, fixture.final_text)
  let expected_writer = full.snapshot.writer_commitments
    .filter(writer => writer.agent == "r0-metadata-backed-history")
    .get(0)
    .unwrap()
  let actual_writer = result.state.snapshot.writer_commitments
    .filter(writer => writer.agent == "r0-metadata-backed-history")
    .get(0)
    .unwrap()
  assert_eq(actual_writer.agent, expected_writer.agent)
  assert_eq(actual_writer.leaf_count, expected_writer.leaf_count)
  assert_eq(
    actual_writer.tip_event_digest_v2,
    expected_writer.tip_event_digest_v2,
  )
  assert_eq(
    actual_writer.event_meta_mmr_root_v2,
    expected_writer.event_meta_mmr_root_v2,
  )
  assert_eq(
    result.state.writer_metas
    .get("r0-metadata-backed-history")
    .unwrap()
    .length(),
    2,
  )
  assert_eq(
    result.state.snapshot.exact_raw_heads,
    full.snapshot.exact_raw_heads,
  )
}

///|
test "MetadataBacked derived retention and mutation evidence are exact" {
  let (_, state, incoming, provider, _) = try! metadata_backed_fast_forward_case()
  let result = working_state_admit_metadata_backed(state, incoming, provider)
  let observation = metadata_backed_observation_json(
    "test-run", "test", "F-04", state, result,
  )
  let object = match observation {
    Json::Object(object) => object
    _ => panic()
  }
  assert_eq(
    @json.from_json(object_field(object, "cold_metadata_retained")),
    false,
  )
  assert_eq(@json.from_json(object_field(object, "state_mutated")), true)
  let (_, unreachable_state, unreachable_incoming, unreachable_provider, _) = try! metadata_backed_unreachable_case()
  let unreachable_result = working_state_admit_metadata_backed(
    unreachable_state, unreachable_incoming, unreachable_provider,
  )
  let unreachable_observation = metadata_backed_observation_json(
    "test-run", "test", "D-06", unreachable_state, unreachable_result,
  )
  let unreachable_object = match unreachable_observation {
    Json::Object(object) => object
    _ => panic()
  }
  assert_eq(
    @json.from_json(object_field(unreachable_object, "cold_metadata_retained")),
    false,
  )
  assert_eq(
    @json.from_json(object_field(unreachable_object, "state_mutated")),
    false,
  )
}

///|
test "D-06 unreachable implicit predecessor is explicit and non-mutating" {
  let (_, state, incoming, provider, _) = try! metadata_backed_unreachable_case()
  let before = working_state_copy_state(state)
  let result = working_state_admit_metadata_backed(state, incoming, provider)
  assert_eq(
    result.outcome,
    WorkingStateAdmissionOutcome::Rejected(reason="predecessor_not_reachable"),
  )
  assert_eq(result.state.document_text, before.document_text)
  assert_eq(
    result.state.snapshot.snapshot_commit_id,
    before.snapshot.snapshot_commit_id,
  )
  assert_eq(result.state.committed_event_count, before.committed_event_count)
  assert_eq(result.state.committed.length(), before.committed.length())
  assert_eq(result.state.pending.length(), before.pending.length())
  assert_eq(result.state.capture_enabled, before.capture_enabled)
  assert_eq(result.reads.metadata_queries, 2)
  assert_eq(result.reads.payload_queries, 0)
  assert_eq(result.reads.full_history_queries, 0)
  assert_eq(result.reads.scan_records_visited, 0)
}
