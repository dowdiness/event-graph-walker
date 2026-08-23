///|
test "ProviderFixtureEnvelopeV1 empty fixture is exact and decodes" {
  let fixture : GeneratedFixture = {
    fixture_id: "R-01-empty-provider",
    document_id: "r0-empty-provider",
    events: [],
    replay_order: [],
    final_text: "",
  }
  let capture_overlay = try! build_ordinary_capture_overlay(fixture)
  let overlay = {
    ..capture_overlay,
    full_history_bytes: legacy_oracle_history_bytes(fixture),
  }
  let encoded = try! encode_provider_fixture(overlay)
  assert_eq(encoded.length(), 99)
  assert_eq(
    sha256_hex(encoded),
    "b8e290719e5838e7ffe714cd9f14950fb11e39a17ff92ab19b32afabf8ff7a4a",
  )
  let decoded = try! OrdinaryProvider::new(encoded)
  assert_eq(decoded.snapshot_commit_id, overlay.snapshot.snapshot_commit_id)
  assert_eq(decoded.meta_records.length(), 0)
  assert_eq(decoded.payload_records.length(), 0)
  assert_true(decoded.full_history_bytes.length() > 0)
  assert_eq(decoded.counters.logical_query_count, 0)
  assert_eq(decoded.counters.physical_read_calls, 0)
}

///|
test "ProviderFixtureEnvelopeV1 S-linear-4 verifies metadata proofs and payloads" {
  let fixture = try! generate_fixture("S-linear", 4)
  let capture_overlay = try! build_ordinary_capture_overlay(fixture)
  let overlay = {
    ..capture_overlay,
    full_history_bytes: legacy_oracle_history_bytes(fixture),
  }
  let encoded = try! encode_provider_fixture(overlay)
  assert_eq(encoded.length(), 1088)
  assert_eq(
    sha256_hex(encoded),
    "fbb3504d3607c7d8f2ec96e168fdfee6a5d1574d470a00324348b6399087555a",
  )
  let provider = try! OrdinaryProvider::new(encoded)
  assert_eq(provider.meta_records.length(), 4)
  assert_eq(provider.payload_records.length(), 4)
  let ids = provider.meta_records.map(record => record.identity)
  let found = try! provider.lookup_event_meta_batch(
    overlay.snapshot.snapshot_commit_id,
    ids,
  )
  assert_eq(found.length(), 4)
  for index, result in found {
    match result {
      MetaLookupResult::Found(meta_bytes, proof_bytes) => {
        let meta = try! decode_event_meta_v2(meta_bytes)
        let proof = try! decode_mmr_proof(proof_bytes)
        let writer = try! resident_writer_for(overlay.snapshot, ids[index])
        try! _verify_mmr_inclusion(
          agent=writer.agent,
          leaf_count=writer.leaf_count,
          leaf_hash=meta_leaf_hash_v2(meta),
          expected_root=writer.event_meta_mmr_root_v2,
          proof~,
        )
        assert_eq(meta.identity, ids[index])
        assert_eq(
          meta.payload_byte_length,
          overlay.metas[index].payload_byte_length,
        )
      }
      _ => fail("in-range metadata was not found")
    }
  }
  let payloads = try! provider.read_event_payload_batch(
    overlay.snapshot.snapshot_commit_id,
    ids,
  )
  for index, result in payloads {
    match result {
      PayloadReadResult::Found(body) => {
        assert_eq(
          body,
          try! encode_canonical_body(overlay.metas[index].body.unwrap()),
        )
        assert_eq(body.length(), overlay.metas[index].payload_byte_length)
        assert_eq(
          _canonical_body_digest(overlay.metas[index].body.unwrap()),
          overlay.metas[index].body_digest,
        )
      }
      _ => fail("in-range payload was not found")
    }
  }
  assert_eq(provider.counters.logical_query_count, 2)
  assert_eq(provider.counters.physical_read_calls, 2)
  assert_eq(provider.counters.requested_id_count, 8)
  assert_eq(provider.counters.returned_record_count, 8)
  assert_eq(provider.counters.metadata_records, 4)
  assert_eq(provider.counters.payload_events, 4)
  assert_eq(
    provider.counters.physical_bytes,
    provider.counters.framing_bytes +
    provider.counters.metadata_bytes +
    provider.counters.proof_bytes +
    provider.counters.payload_bytes,
  )
  assert_eq(provider.counters.scan_records_visited, 0)
  assert_true(provider.counters.metadata_bytes > 0)
  assert_true(provider.counters.proof_bytes > 0)
  assert_true(provider.counters.payload_bytes > 0)
}

///|
test "provider Tier-0 non-membership and explicit history fallback are separately counted" {
  let fixture = try! generate_fixture("S-linear", 4)
  let capture_overlay = try! build_ordinary_capture_overlay(fixture)
  let overlay = {
    ..capture_overlay,
    full_history_bytes: legacy_oracle_history_bytes(fixture),
  }
  let provider = try! OrdinaryProvider::new(
    try! encode_provider_fixture(overlay),
  )
  let absent = [RawIdentity(agent="missing", sequence=0)]
  let physical_reads_before = provider.counters.physical_read_calls
  let logical_queries_before = provider.counters.logical_query_count
  let resident_records_before = provider.counters.resident_records_visited
  let result = try! lookup_event_meta_tier0_then_provider(
    overlay.snapshot,
    provider,
    absent,
  )
  match result[0] {
    MetaLookupResult::MissingInAuthenticatedRange => ()
    _ => fail("absent writer was not answered by Tier 0")
  }
  assert_eq(provider.counters.physical_read_calls - physical_reads_before, 0)
  assert_eq(provider.counters.logical_query_count - logical_queries_before, 0)
  assert_true(
    provider.counters.resident_records_visited - resident_records_before > 0,
  )
  assert_eq(provider.counters.scan_records_visited, 0)
  let history = try! provider.read_full_history(
    overlay.snapshot.snapshot_commit_id,
  )
  assert_eq(history, overlay.full_history_bytes)
  assert_eq(provider.counters.full_history_events, 4)
  assert_eq(provider.counters.full_history_bytes, history.length())
  assert_eq(provider.counters.logical_query_count, 1)
  assert_eq(provider.counters.physical_read_calls, 1)
}
