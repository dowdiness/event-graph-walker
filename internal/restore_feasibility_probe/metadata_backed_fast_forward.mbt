///|
/// Ephemeral verified metadata used only during one MetadataBacked Fast-forward.
fn working_state_known_record_with_metadata(
  state : WorkingState,
  identity : RawIdentity,
  metadata : Map[String, OrdinaryEventMetaV2],
) -> WorkingStateKnownRecord? {
  match metadata.get(raw_identity_key(identity)) {
    Some(meta) =>
      Some({
        event_digest_v2: meta.event_digest_v2,
        causal_rank_timestamp: meta.causal_rank_timestamp,
      })
    None => working_state_known_record(state, identity)
  }
}

///|
fn working_state_known_text_with_metadata(
  state : WorkingState,
  identity : RawIdentity,
  metadata : Map[String, OrdinaryEventMetaV2],
) -> String? {
  ignore(metadata)
  working_state_known_text(state, identity)
}

///|
fn working_state_missing_dependency_with_metadata(
  state : WorkingState,
  incoming : OrdinaryEventMetaV2,
  metadata : Map[String, OrdinaryEventMetaV2],
) -> RawIdentity? {
  for item in incoming.declared_parents {
    let (identity, _) = item
    if working_state_known_record_with_metadata(state, identity, metadata)
      is None {
      return Some(identity)
    }
  }
  match incoming.implicit_predecessor {
    Some((identity, _)) if working_state_known_record_with_metadata(
        state, identity, metadata,
      )
      is None => Some(identity)
    _ => None
  }
}

///|
fn working_state_closure_contains_with_metadata(
  state : WorkingState,
  parents : Array[(RawIdentity, Bytes)],
  target : RawIdentity,
  metadata : Map[String, OrdinaryEventMetaV2],
) -> Bool {
  let todo : Array[RawIdentity] = parents.map(item => item.0)
  let seen : Set[String] = Set([])
  while !todo.is_empty() {
    let identity = todo[0]
    todo.remove(0) |> ignore
    let key = raw_identity_key(identity)
    if seen.add_and_check(key) {
      if identity == target {
        return true
      }
      let record = match metadata.get(key) {
        Some(meta) => Some(meta)
        None => state.committed.get(key)
      }
      match record {
        Some(meta) =>
          for parent in meta.declared_parents {
            todo.push(parent.0)
          }
        None => ()
      }
    }
  }
  false
}

///|
fn metadata_backed_read_accounting(
  before : OrdinaryProviderCounters,
  after : OrdinaryProviderCounters,
) -> OrdinaryReadAccounting {
  {
    metadata_queries: after.metadata_query_count - before.metadata_query_count,
    payload_queries: after.payload_query_count - before.payload_query_count,
    full_history_queries: after.full_history_query_count -
    before.full_history_query_count,
    scan_records_visited: after.scan_records_visited -
    before.scan_records_visited,
  }
}

///|
fn metadata_backed_wave(
  snapshot : OrdinarySnapshot,
  provider : OrdinaryProvider,
  identities : Array[RawIdentity],
) -> (Map[String, OrdinaryEventMetaV2], Map[String, Array[MmrPeak]]) raise R0CodecError {
  let requested = identities.copy()
  requested.sort_by(compare_raw_identity)
  let unique : Array[RawIdentity] = []
  for identity in requested {
    if unique.is_empty() || unique[unique.length() - 1] != identity {
      unique.push(identity)
    }
  }
  let responses = provider.lookup_event_meta_batch(
    snapshot.snapshot_commit_id,
    unique,
  )
  let result : Map[String, OrdinaryEventMetaV2] = Default::default()
  let proof_peaks : Map[String, Array[MmrPeak]] = Default::default()
  for index, response in responses {
    let identity = unique[index]
    let (meta_bytes, proof_bytes) = match response {
      MetaLookupResult::Found(meta_bytes, proof_bytes) =>
        (meta_bytes, proof_bytes)
      MetaLookupResult::MissingInAuthenticatedRange =>
        raise R0CodecError::InvalidValue(
          detail="provider_missing_in_authenticated_range",
        )
      MetaLookupResult::Unavailable =>
        raise R0CodecError::InvalidValue(detail="provider_unavailable")
      MetaLookupResult::Corrupt =>
        raise R0CodecError::InvalidValue(detail="provider_corrupt")
    }
    let meta = decode_event_meta_v2(meta_bytes)
    if meta.identity != identity {
      raise R0CodecError::InvalidValue(detail="metadata_identity_mismatch")
    }
    let writer = resident_writer_for(snapshot, identity)
    let proof = decode_mmr_proof(proof_bytes)
    if proof.leaf_position != identity.sequence {
      raise R0CodecError::InvalidValue(detail="provider_corrupt")
    }
    let peaks : Result[Array[MmrPeak], R0ProofError] = Ok(
      _verify_mmr_inclusion_peaks(
        agent=writer.agent,
        leaf_count=writer.leaf_count,
        leaf_hash=meta_leaf_hash_v2(meta),
        expected_root=writer.event_meta_mmr_root_v2,
        proof~,
      ),
    ) catch {
      _ => Err(R0ProofError::InvalidProof(detail="provider_corrupt"))
    }
    match peaks {
      Err(_) => raise R0CodecError::InvalidValue(detail="provider_corrupt")
      Ok(peaks) => {
        result[raw_identity_key(identity)] = meta
        proof_peaks[raw_identity_key(identity)] = peaks
      }
    }
  }
  (result, proof_peaks)
}

///|
fn metadata_backed_needs_fetch(
  state : WorkingState,
  metadata : Map[String, OrdinaryEventMetaV2],
  identity : RawIdentity,
) -> Bool {
  let key = raw_identity_key(identity)
  if metadata.contains(key) {
    false
  } else {
    let is_frontier_head = state.snapshot.exact_raw_heads.any(head => {
      head == identity
    })
    if is_frontier_head {
      true
    } else {
      !state.committed.contains(key)
    }
  }
}

///|
struct MetadataBackedWriterAccumulator {
  commitment : OrdinaryWriterCommitment
  peaks : Array[MmrPeak]
}

///|
/// Reconstruct the resident writer peaks only from an authenticated tip proof.
fn metadata_backed_initial_accumulator(
  snapshot : OrdinarySnapshot,
  incoming : OrdinaryEventMetaV2,
  metadata : Map[String, OrdinaryEventMetaV2],
  proof_peaks : Map[String, Array[MmrPeak]],
) -> MetadataBackedWriterAccumulator raise R0CodecError {
  guard incoming.implicit_predecessor is Some(predecessor) else {
    raise R0CodecError::InvalidValue(detail="predecessor_missing")
  }
  let (predecessor_identity, predecessor_digest) = predecessor
  let writer = resident_writer_for(snapshot, predecessor_identity)
  guard metadata.get(raw_identity_key(predecessor_identity))
    is Some(predecessor_meta) else {
    raise R0CodecError::InvalidValue(detail="predecessor_proof_missing")
  }
  if predecessor_meta.event_digest_v2 != predecessor_digest {
    raise R0CodecError::InvalidValue(detail="predecessor_digest_mismatch")
  }
  if predecessor_identity.sequence != writer.leaf_count - 1 ||
    writer.tip_event_digest_v2 != predecessor_digest ||
    incoming.identity.agent != writer.agent ||
    incoming.identity.sequence != writer.leaf_count {
    raise R0CodecError::InvalidValue(detail="predecessor_not_committed_tip")
  }
  guard proof_peaks.get(raw_identity_key(predecessor_identity)) is Some(peaks) else {
    raise R0CodecError::InvalidValue(detail="predecessor_proof_missing")
  }
  { commitment: writer, peaks: peaks.copy() }
}

///|
/// Append one incoming meta leaf to an accumulator established by a tip proof.
fn metadata_backed_append_accumulator(
  accumulator : MetadataBackedWriterAccumulator,
  incoming : OrdinaryEventMetaV2,
) -> MetadataBackedWriterAccumulator raise R0CodecError {
  guard incoming.implicit_predecessor is Some(predecessor) else {
    raise R0CodecError::InvalidValue(detail="predecessor_missing")
  }
  let (predecessor_identity, predecessor_digest) = predecessor
  let commitment = accumulator.commitment
  if predecessor_identity.agent != commitment.agent ||
    predecessor_identity.sequence != commitment.leaf_count - 1 ||
    predecessor_digest != commitment.tip_event_digest_v2 ||
    incoming.identity.agent != commitment.agent ||
    incoming.identity.sequence != commitment.leaf_count {
    raise R0CodecError::InvalidValue(detail="predecessor_not_committed_tip")
  }
  let peaks = mmr_append_peaks(
    accumulator.peaks,
    commitment.leaf_count,
    meta_leaf_hash_v2(incoming),
  ) catch {
    R0ProofError::InvalidProof(detail~) =>
      raise R0CodecError::InvalidValue(detail~)
    _ => raise R0CodecError::InvalidValue(detail="provider_corrupt")
  }
  let next_count = commitment.leaf_count + 1
  {
    commitment: {
      agent: commitment.agent,
      leaf_count: next_count,
      tip_event_digest_v2: incoming.event_digest_v2,
      event_meta_mmr_root_v2: writer_root_from_peaks(
        commitment.agent,
        next_count,
        peaks,
      ),
    },
    peaks,
  }
}

///|
fn metadata_backed_targets_reachable(
  state : WorkingState,
  incoming : Array[OrdinaryEventMetaV2],
  metadata : Map[String, OrdinaryEventMetaV2],
) -> Bool {
  for meta in incoming {
    match meta.implicit_predecessor {
      Some((target, _)) =>
        if !working_state_closure_contains_with_metadata(
            state,
            meta.declared_parents,
            target,
            metadata,
          ) {
          return false
        }
      None => ()
    }
  }
  true
}

///|
fn metadata_backed_validate_edges(
  state : WorkingState,
  incoming : Array[OrdinaryEventMetaV2],
  metadata : Map[String, OrdinaryEventMetaV2],
  expanded : Set[String],
) -> String? {
  // Incoming declared-parent edges are always traversed by admission.
  for child in incoming {
    for item in child.declared_parents {
      let (identity, digest) = item
      guard working_state_known_record_with_metadata(state, identity, metadata)
        is Some(parent) else {
        return Some("provider_missing_in_authenticated_range")
      }
      if parent.event_digest_v2 != digest {
        return Some("parent_digest_mismatch")
      }
      if child.causal_rank_timestamp <= parent.causal_rank_timestamp {
        return Some("rank_not_decreasing")
      }
    }
  }
  // Only declared-parent closure nodes are expanded.  In particular, a cold
  // implicit predecessor is an authenticated target, not a traversal root.
  for key in expanded {
    guard metadata.get(key) is Some(child) else { continue }
    for item in child.declared_parents {
      let (identity, digest) = item
      guard working_state_known_record_with_metadata(state, identity, metadata)
        is Some(parent) else {
        // Successful reachability may stop before exploring an unrelated
        // branch. Such an edge was observed but was not part of the proof.
        continue
      }
      if parent.event_digest_v2 != digest {
        return Some("parent_digest_mismatch")
      }
      if child.causal_rank_timestamp <= parent.causal_rank_timestamp {
        return Some("rank_not_decreasing")
      }
    }
  }
  None
}

///|
fn metadata_backed_error_reason(error : R0CodecError) -> String {
  match error {
    R0CodecError::InvalidValue(detail~) => detail
    R0CodecError::MalformedEncoding(detail~) => detail
  }
}

///|
fn metadata_backed_provider_error_reason(error : R0CodecError) -> String {
  let reason = metadata_backed_error_reason(error)
  if reason == "provider_unavailable" ||
    reason == "provider_missing_in_authenticated_range" {
    reason
  } else {
    "provider_corrupt"
  }
}

///|
fn working_state_admit_metadata_backed(
  state : WorkingState,
  incoming : Array[OrdinaryEventMetaV2],
  provider : OrdinaryProvider,
) -> WorkingStateAdmissionResult {
  let before = ordinary_copy_provider_counters(provider.counters)
  let reads = fn() -> OrdinaryReadAccounting {
    metadata_backed_read_accounting(before, provider.counters)
  }
  let coverage = working_state_validate_entry_coverage(state, incoming)
  match coverage {
    Some(reason) =>
      return working_state_result(
        state,
        WorkingStateAdmissionOutcome::Rejected(reason~),
        [],
        reads=reads(),
        evidence_source=WorkingStateEvidenceSource::MetadataBacked,
      )
    None => ()
  }
  for meta in incoming {
    let shape : Result[Unit, String] = Ok(working_state_validate_shape(meta)) catch {
      R0CodecError::InvalidValue(detail~) => Err(detail)
      R0CodecError::MalformedEncoding(detail~) => Err(detail)
    }
    match shape {
      Err(reason) =>
        return working_state_result(
          state,
          WorkingStateAdmissionOutcome::Rejected(reason~),
          [],
          reads=reads(),
          evidence_source=WorkingStateEvidenceSource::MetadataBacked,
        )
      Ok(_) => ()
    }
  }
  let incoming_keys : Set[String] = Set([])
  let target_keys : Set[String] = Set([])
  for meta in incoming {
    incoming_keys.add(raw_identity_key(meta.identity)) |> ignore
    match meta.implicit_predecessor {
      Some((identity, _)) =>
        target_keys.add(raw_identity_key(identity)) |> ignore
      None => ()
    }
  }
  let verified : Map[String, OrdinaryEventMetaV2] = Default::default()
  for meta in incoming {
    verified[raw_identity_key(meta.identity)] = meta
  }
  let proof_peaks : Map[String, Array[MmrPeak]] = Default::default()
  let fetched_cold_keys : Set[String] = Set([])
  let fetched_cold_identities : Array[RawIdentity] = []
  let expanded : Set[String] = Set([])
  let mut wave : Array[RawIdentity] = []
  for meta in incoming {
    for item in meta.declared_parents {
      let key = raw_identity_key(item.0)
      if !incoming_keys.contains(key) &&
        metadata_backed_needs_fetch(state, verified, item.0) {
        wave.push(item.0)
      }
      if !target_keys.contains(key) {
        expanded.add(key) |> ignore
      }
    }
    match meta.implicit_predecessor {
      Some((identity, _)) if !incoming_keys.contains(raw_identity_key(identity)) &&
        metadata_backed_needs_fetch(state, verified, identity) =>
        wave.push(identity)
      _ => ()
    }
  }
  while !wave.is_empty() {
    let (fetched, fetched_peaks) = metadata_backed_wave(
      state.snapshot,
      provider,
      wave,
    ) catch {
      error =>
        return working_state_result(
          state,
          WorkingStateAdmissionOutcome::Fallback(
            reason=metadata_backed_provider_error_reason(error),
          ),
          [],
          reads=reads(),
          evidence_source=WorkingStateEvidenceSource::MetadataBacked,
        )
    }
    for key, meta in fetched {
      verified[key] = meta
      if !incoming_keys.contains(key) && fetched_cold_keys.add_and_check(key) {
        fetched_cold_identities.push(meta.identity)
      }
    }
    for key, peaks in fetched_peaks {
      proof_peaks[key] = peaks
    }
    if metadata_backed_targets_reachable(state, incoming, verified) {
      break
    }
    wave = []
    for key, meta in fetched {
      if expanded.contains(key) {
        for item in meta.declared_parents {
          let parent_key = raw_identity_key(item.0)
          if !incoming_keys.contains(parent_key) &&
            !target_keys.contains(parent_key) &&
            metadata_backed_needs_fetch(state, verified, item.0) {
            wave.push(item.0)
          }
          if !target_keys.contains(parent_key) {
            expanded.add(parent_key) |> ignore
          }
        }
      }
    }
  }
  let edge_reason = metadata_backed_validate_edges(
    state, incoming, verified, expanded,
  )
  match edge_reason {
    Some("predecessor_not_reachable") =>
      return working_state_result(
        state,
        WorkingStateAdmissionOutcome::Rejected(
          reason="predecessor_not_reachable",
        ),
        [],
        reads=reads(),
        evidence_source=WorkingStateEvidenceSource::MetadataBacked,
        fetched_cold_identities~,
      )
    Some(reason) =>
      return working_state_result(
        state,
        WorkingStateAdmissionOutcome::Fallback(reason~),
        [],
        reads=reads(),
        evidence_source=WorkingStateEvidenceSource::MetadataBacked,
        fetched_cold_identities~,
      )
    None => ()
  }
  let accumulators : Map[String, MetadataBackedWriterAccumulator] = Default::default()
  let mut next = working_state_copy_state(state)
  let committed : Array[OrdinaryEventMetaV2] = []
  for meta in incoming {
    if meta.implicit_predecessor is Some(_) {
      let accumulator = match accumulators.get(meta.identity.agent) {
        Some(accumulator) => accumulator
        None =>
          metadata_backed_initial_accumulator(
            state.snapshot,
            meta,
            verified,
            proof_peaks,
          ) catch {
            error =>
              return working_state_result(
                state,
                WorkingStateAdmissionOutcome::Fallback(
                  reason=metadata_backed_error_reason(error),
                ),
                [],
                reads=reads(),
                evidence_source=WorkingStateEvidenceSource::MetadataBacked,
                fetched_cold_identities~,
              )
          }
      }
      let updated_accumulator = metadata_backed_append_accumulator(
        accumulator, meta,
      ) catch {
        error =>
          return working_state_result(
            state,
            WorkingStateAdmissionOutcome::Fallback(
              reason=metadata_backed_error_reason(error),
            ),
            [],
            reads=reads(),
            evidence_source=WorkingStateEvidenceSource::MetadataBacked,
            fetched_cold_identities~,
          )
      }
      accumulators[meta.identity.agent] = updated_accumulator
    }
    let step_overrides : Map[String, OrdinaryWriterCommitment] = Default::default()
    match accumulators.get(meta.identity.agent) {
      Some(accumulator) =>
        step_overrides[meta.identity.agent] = accumulator.commitment
      None => ()
    }
    match
      working_state_try_commit_with_metadata(
        next, meta, verified, step_overrides,
      ) {
      WorkingStateTryCommit::Ready(updated, committed_meta) => {
        next = updated
        committed.push(committed_meta)
      }
      WorkingStateTryCommit::Missing(_) =>
        return working_state_result(
          state,
          WorkingStateAdmissionOutcome::Fallback(reason="metadata_missing"),
          [],
          reads=reads(),
          evidence_source=WorkingStateEvidenceSource::MetadataBacked,
          fetched_cold_identities~,
        )
      WorkingStateTryCommit::Invalid(reason) =>
        return working_state_result(
          state,
          WorkingStateAdmissionOutcome::Rejected(reason~),
          [],
          reads=reads(),
          evidence_source=WorkingStateEvidenceSource::MetadataBacked,
          fetched_cold_identities~,
        )
    }
  }
  working_state_result(
    next,
    WorkingStateAdmissionOutcome::Complete,
    committed,
    reads=reads(),
    evidence_source=WorkingStateEvidenceSource::MetadataBacked,
    fetched_cold_identities~,
  )
}

///|
fn metadata_backed_fast_forward_case() -> (
  GeneratedFixture,
  WorkingState,
  Array[OrdinaryEventMetaV2],
  OrdinaryProvider,
  Bytes,
) raise {
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
  let incoming_event = builder.insert(
    "r0-metadata-backed-history",
    builder.chain_parents(),
    3,
    "d",
  )
  let fixture : GeneratedFixture = {
    fixture_id: "F-04-metadata-backed-fast-forward",
    document_id: "loomark-r0-fixture-F-04-metadata-backed-fast-forward",
    events: builder.events,
    replay_order: stable_topological_order(builder.events),
    final_text: visible_text(builder.visible),
  }
  let prefix : GeneratedFixture = {
    fixture_id: "F-04-metadata-backed-prefix",
    document_id: fixture.document_id,
    events: [first, second, resident],
    replay_order: [first.identity, second.identity, resident.identity],
    final_text: "abc",
  }
  let overlay = build_nonempty_overlay(prefix)
  let provider_bytes = try! encode_provider_fixture({
    ..overlay,
    full_history_bytes: legacy_oracle_history_bytes(prefix),
  })
  let provider = OrdinaryProvider::new(provider_bytes)
  let incoming = overlay.metas[0:0].to_owned()
  let incoming_meta = ordinary_event_meta(
    incoming_event.identity,
    incoming_event.body,
    overlay.metas[2].causal_rank_timestamp + 1,
    [(overlay.metas[2].identity, overlay.metas[2].event_digest_v2)],
    Some((second.identity, overlay.metas[1].event_digest_v2)),
    [],
  )
  incoming.push(incoming_meta)
  (
    fixture,
    working_state_begin_from_snapshot(overlay.snapshot, prefix.final_text),
    incoming,
    provider,
    provider_bytes,
  )
}

///|
fn metadata_backed_unreachable_case() -> (
  GeneratedFixture,
  WorkingState,
  Array[OrdinaryEventMetaV2],
  OrdinaryProvider,
  Bytes,
) raise {
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
    [first.identity],
    1,
    "c",
  )
  let fixture : GeneratedFixture = {
    fixture_id: "D-06-metadata-backed-unreachable",
    document_id: "loomark-r0-fixture-D-06-metadata-backed-unreachable",
    events: [first, second, resident],
    replay_order: [first.identity, second.identity, resident.identity],
    final_text: visible_text(builder.visible),
  }
  let overlay = build_nonempty_overlay(fixture)
  let heads = [overlay.snapshot.exact_head_records[1]]
  let raw_heads = heads.map(record => record.identity)
  let invalid_frontier : OrdinarySnapshot = {
    ..overlay.snapshot,
    exact_raw_heads: raw_heads,
    exact_raw_heads_sha256: encode_exact_heads_hash(raw_heads),
    exact_head_records: heads,
    graph_root_v2: encode_graph_root(heads),
    snapshot_commit_id: Bytes::new(0),
  }
  let committed_frontier = {
    ..invalid_frontier,
    snapshot_commit_id: derive_snapshot_commit_id(invalid_frontier),
  }
  let provider_overlay = { ..overlay, snapshot: committed_frontier }
  let provider_bytes = try! encode_provider_fixture({
    ..provider_overlay,
    full_history_bytes: Bytes::new(0),
  })
  let provider = OrdinaryProvider::new(provider_bytes)
  let incoming_meta = ordinary_event_meta(
    RawIdentity(agent="r0-metadata-backed-history", sequence=2),
    InsertScalar(3, "d"),
    overlay.metas[2].causal_rank_timestamp + 1,
    [(resident.identity, overlay.metas[2].event_digest_v2)],
    Some((second.identity, overlay.metas[1].event_digest_v2)),
    [],
  )
  (
    fixture,
    working_state_begin_from_snapshot(committed_frontier, fixture.final_text),
    [incoming_meta],
    provider,
    provider_bytes,
  )
}

///|
#warnings("-unused_value")
fn working_state_admit_metadata_backed_one(
  state : WorkingState,
  incoming : OrdinaryEventMetaV2,
  provider : OrdinaryProvider,
) -> WorkingStateAdmissionResult {
  working_state_admit_metadata_backed(state, [incoming], provider)
}

///|
#warnings("-unused_value")
fn working_state_admit_metadata_backed_batch(
  state : WorkingState,
  incoming : Array[OrdinaryEventMetaV2],
  provider : OrdinaryProvider,
) -> WorkingStateAdmissionResult {
  working_state_admit_metadata_backed(state, incoming, provider)
}

///|
#warnings("-unused_value")
fn working_state_admit_metadata_backed_region(
  state : WorkingState,
  incoming : Array[OrdinaryEventMetaV2],
  provider : OrdinaryProvider,
) -> WorkingStateAdmissionResult {
  working_state_admit_metadata_backed(state, incoming, provider)
}

///|
struct MetadataBackedCaptureBundle {
  fast_forward_candidate : Bytes
  fast_forward_provider : Bytes
  unreachable_candidate : Bytes
  unreachable_provider : Bytes
}

///|
fn metadata_backed_bytes_json(bytes : Bytes) -> Json {
  Json::object({
    "length": bytes.length().to_json(),
    "sha256": sha256_hex(bytes).to_json(),
    "base64": base64_encode(bytes).to_json(),
  })
}

///|
fn metadata_backed_normalize_observations(
  observations : Array[Json],
) -> Array[Json] {
  observations.map(observation => {
    match observation {
      Json::Object(object) =>
        Json::object({
          "schema_version": object_field(object, "schema_version"),
          "run_id": object_field(object, "run_id"),
          "record": object_field(object, "record"),
          "candidate": object_field(object, "candidate"),
          "case_id": object_field(object, "case_id"),
          "outcome": object_field(object, "outcome"),
          "text": object_field(object, "text"),
          "frontier": object_field(object, "frontier"),
          "snapshot_commit_id": object_field(object, "snapshot_commit_id"),
          "cold_metadata_retained": object_field(
            object, "cold_metadata_retained",
          ),
          "state_mutated": object_field(object, "state_mutated"),
          "reads": object_field(object, "reads"),
        })
      _ => observation
    }
  })
}

///|
fn metadata_backed_bytes_from_json(value : Json) -> Bytes raise R0CodecError {
  let object = match value {
    Json::Object(object) => object
    _ =>
      raise R0CodecError::MalformedEncoding(
        detail="metadata capture bytes must be an object",
      )
  }
  let length : Int = @json.from_json(object_field(object, "length")) catch {
    _ =>
      raise R0CodecError::MalformedEncoding(
        detail="metadata capture length is invalid",
      )
  }
  let expected_sha256 : String = @json.from_json(object_field(object, "sha256")) catch {
    _ =>
      raise R0CodecError::MalformedEncoding(
        detail="metadata capture digest is invalid",
      )
  }
  let encoded : String = @json.from_json(object_field(object, "base64")) catch {
    _ =>
      raise R0CodecError::MalformedEncoding(
        detail="metadata capture base64 is invalid",
      )
  }
  let bytes = base64_decode(encoded)
  if bytes.length() != length || sha256_hex(bytes) != expected_sha256 {
    raise R0CodecError::InvalidValue(
      detail="metadata capture bytes integrity mismatch",
    )
  }
  bytes
}

///|
fn metadata_backed_capture_bundle() -> MetadataBackedCaptureBundle raise {
  let (fast_fixture, fast_state, _, _, fast_provider_bytes) = metadata_backed_fast_forward_case()
  let (unreachable_fixture, unreachable_state, _, _, unreachable_provider_bytes) = metadata_backed_unreachable_case()
  ignore(fast_fixture)
  ignore(unreachable_fixture)
  {
    fast_forward_candidate: encode_candidate(
      fast_state.snapshot,
      fast_state.document_text,
    ),
    fast_forward_provider: fast_provider_bytes,
    unreachable_candidate: encode_candidate(
      unreachable_state.snapshot,
      unreachable_state.document_text,
    ),
    unreachable_provider: unreachable_provider_bytes,
  }
}

///|
fn metadata_backed_incoming_from_provider(
  snapshot : OrdinarySnapshot,
  document_text : String,
  provider : OrdinaryProvider,
) -> Array[OrdinaryEventMetaV2] raise R0CodecError {
  let predecessor_record = provider.meta_index
    .get(
      raw_identity_key(
        RawIdentity(agent="r0-metadata-backed-history", sequence=1),
      ),
    )
    .unwrap()
  let predecessor = decode_event_meta_v2(predecessor_record.meta_bytes)
  let resident_head = snapshot.exact_head_records[0].identity
  let resident_record = provider.meta_index
    .get(raw_identity_key(resident_head))
    .unwrap()
  let resident = decode_event_meta_v2(resident_record.meta_bytes)
  [
    ordinary_event_meta(
      RawIdentity(agent="r0-metadata-backed-history", sequence=2),
      InsertScalar(unicode_scalar_length(document_text), "d"),
      resident.causal_rank_timestamp + 1,
      [(resident.identity, resident.event_digest_v2)],
      Some((predecessor.identity, predecessor.event_digest_v2)),
      [],
    ),
  ]
}

///|
fn metadata_backed_state_mutated(
  before : WorkingState,
  after : WorkingState,
) -> Bool {
  before.document_text != after.document_text ||
  before.snapshot.snapshot_commit_id != after.snapshot.snapshot_commit_id ||
  working_state_frontier(before) != working_state_frontier(after) ||
  before.committed_event_count != after.committed_event_count ||
  before.committed.length() != after.committed.length() ||
  before.pending.length() != after.pending.length() ||
  before.capture_enabled != after.capture_enabled
}

///|
fn metadata_backed_cold_metadata_retained(
  result : WorkingStateAdmissionResult,
) -> Bool {
  for identity in result.fetched_cold_identities {
    let key = raw_identity_key(identity)
    if result.state.committed.contains(key) ||
      result.state.text_by_identity.contains(key) {
      return true
    }
    for _, metas in result.state.writer_metas {
      if metas.any(meta => meta.identity == identity) {
        return true
      }
    }
  }
  false
}

///|
fn metadata_backed_observation_json(
  run_id : String,
  producer : String,
  case_id : String,
  before : WorkingState,
  result : WorkingStateAdmissionResult,
) -> Json {
  let outcome = match result.outcome {
    WorkingStateAdmissionOutcome::Complete =>
      match result.evidence_source {
        WorkingStateEvidenceSource::MetadataBacked =>
          Json::object({
            "kind": "fast_forward".to_json(),
            "evidence_source": "metadata_backed".to_json(),
          })
        WorkingStateEvidenceSource::SelfContained =>
          Json::object({ "kind": "complete".to_json() })
      }
    WorkingStateAdmissionOutcome::Rejected(reason~) =>
      Json::object({ "kind": "rejected".to_json(), "reason": reason.to_json() })
    WorkingStateAdmissionOutcome::Fallback(reason~) =>
      Json::object({ "kind": "fallback".to_json(), "reason": reason.to_json() })
    _ => Json::object({ "kind": "unexpected".to_json() })
  }
  Json::object({
    "schema_version": (1).to_json(),
    "run_id": run_id.to_json(),
    "producer": producer.to_json(),
    "record": "metadata_backed_observation".to_json(),
    "candidate": "A".to_json(),
    "case_id": case_id.to_json(),
    "outcome": outcome,
    "text": result.state.document_text.to_json(),
    "frontier": working_state_frontier(result.state)
    .map(item => item.agent + ":" + item.sequence.to_string())
    .to_json(),
    "snapshot_commit_id": bytes_hex(result.state.snapshot.snapshot_commit_id).to_json(),
    "cold_metadata_retained": metadata_backed_cold_metadata_retained(result).to_json(),
    "state_mutated": metadata_backed_state_mutated(before, result.state).to_json(),
    "reads": Json::object({
      "metadata_queries": result.reads.metadata_queries.to_json(),
      "payload_queries": result.reads.payload_queries.to_json(),
      "full_history_queries": result.reads.full_history_queries.to_json(),
      "scan_records_visited": result.reads.scan_records_visited.to_json(),
    }),
  })
}

///|
fn metadata_backed_observations_from_bytes(
  run_id : String,
  producer : String,
  fast_forward_candidate : Bytes,
  fast_forward_provider_bytes : Bytes,
  unreachable_candidate : Bytes,
  unreachable_provider_bytes : Bytes,
) -> Array[Json] raise {
  let fast = validate_paper_branch_candidate(fast_forward_candidate)
  let fast_provider = OrdinaryProvider::new(fast_forward_provider_bytes)
  let fast_incoming = metadata_backed_incoming_from_provider(
    fast.snapshot,
    fast.document_text,
    fast_provider,
  )
  let fast_before = working_state_begin_from_snapshot(
    fast.snapshot,
    fast.document_text,
  )
  let fast_result = working_state_admit_metadata_backed(
    fast_before, fast_incoming, fast_provider,
  )
  let unreachable_candidate_state = validate_paper_branch_candidate(
    unreachable_candidate,
  )
  let unreachable_provider = OrdinaryProvider::new(unreachable_provider_bytes)
  let unreachable_incoming = metadata_backed_incoming_from_provider(
    unreachable_candidate_state.snapshot,
    unreachable_candidate_state.document_text,
    unreachable_provider,
  )
  let unreachable_before = working_state_begin_from_snapshot(
    unreachable_candidate_state.snapshot,
    unreachable_candidate_state.document_text,
  )
  let unreachable_result = working_state_admit_metadata_backed(
    unreachable_before, unreachable_incoming, unreachable_provider,
  )
  [
    metadata_backed_observation_json(
      run_id, producer, "F-04-metadata-backed-fast-forward", fast_before, fast_result,
    ),
    metadata_backed_observation_json(
      run_id, producer, "D-06-metadata-backed-unreachable", unreachable_before, unreachable_result,
    ),
  ]
}
