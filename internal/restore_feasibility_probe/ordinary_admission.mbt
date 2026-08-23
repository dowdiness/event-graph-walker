///|
/// Provider bytes copied before they cross into the deterministic verifier.
struct OrdinaryOwnedMetadataResponse {
  meta_bytes : Bytes
  proof_bytes : Bytes
}

///|
enum OrdinaryAdmissionResponse {
  Authenticated(OrdinaryOwnedMetadataResponse)
  MissingInAuthenticatedRange
  Unavailable
  Corrupt
}

///|
#warnings("-unused_field")
struct OrdinaryAdmissionCounterDelta {
  logical_query_count : Int
  metadata_query_count : Int
  payload_query_count : Int
  full_history_query_count : Int
  physical_read_calls : Int
  requested_id_count : Int
  returned_record_count : Int
  metadata_records : Int
  payload_events : Int
  physical_bytes : Int
  framing_bytes : Int
  metadata_bytes : Int
  proof_bytes : Int
  payload_bytes : Int
  index_nodes_read : Int
  planner_metadata_nodes_visited : Int
  resident_records_visited : Int
  resident_text_code_units_visited : Int
  resident_text_scalars_visited : Int
  scan_records_visited : Int
  full_history_events : Int
  full_history_bytes : Int
}

///|
enum OrdinaryAdmissionConflict {
  BodyDigest
  DeclaredParents
  ImplicitPredecessor
  SemanticReferences
  RankOrEventDigest
} derive(Eq, Debug)

///|
enum OrdinaryAdmissionDecision {
  Tier0Nonmembership
  Duplicate
  Conflict(OrdinaryAdmissionConflict)
  Fallback(String)
} derive(Eq, Debug)

///|
#warnings("-unused_field")
struct OrdinaryAdmissionResult {
  decision : OrdinaryAdmissionDecision
  counter_delta : OrdinaryAdmissionCounterDelta
}

///|
fn ordinary_copy_provider_counters(
  counters : OrdinaryProviderCounters,
) -> OrdinaryProviderCounters {
  {
    logical_query_count: counters.logical_query_count,
    metadata_query_count: counters.metadata_query_count,
    payload_query_count: counters.payload_query_count,
    full_history_query_count: counters.full_history_query_count,
    physical_read_calls: counters.physical_read_calls,
    requested_id_count: counters.requested_id_count,
    returned_record_count: counters.returned_record_count,
    metadata_records: counters.metadata_records,
    payload_events: counters.payload_events,
    physical_bytes: counters.physical_bytes,
    framing_bytes: counters.framing_bytes,
    metadata_bytes: counters.metadata_bytes,
    proof_bytes: counters.proof_bytes,
    payload_bytes: counters.payload_bytes,
    index_nodes_read: counters.index_nodes_read,
    planner_metadata_nodes_visited: counters.planner_metadata_nodes_visited,
    resident_records_visited: counters.resident_records_visited,
    resident_text_code_units_visited: counters.resident_text_code_units_visited,
    resident_text_scalars_visited: counters.resident_text_scalars_visited,
    scan_records_visited: counters.scan_records_visited,
    full_history_events: counters.full_history_events,
    full_history_bytes: counters.full_history_bytes,
  }
}

///|
fn ordinary_counter_delta(
  before : OrdinaryProviderCounters,
  after : OrdinaryProviderCounters,
) -> OrdinaryAdmissionCounterDelta {
  {
    logical_query_count: after.logical_query_count - before.logical_query_count,
    metadata_query_count: after.metadata_query_count -
    before.metadata_query_count,
    payload_query_count: after.payload_query_count - before.payload_query_count,
    full_history_query_count: after.full_history_query_count -
    before.full_history_query_count,
    physical_read_calls: after.physical_read_calls - before.physical_read_calls,
    requested_id_count: after.requested_id_count - before.requested_id_count,
    returned_record_count: after.returned_record_count -
    before.returned_record_count,
    metadata_records: after.metadata_records - before.metadata_records,
    payload_events: after.payload_events - before.payload_events,
    physical_bytes: after.physical_bytes - before.physical_bytes,
    framing_bytes: after.framing_bytes - before.framing_bytes,
    metadata_bytes: after.metadata_bytes - before.metadata_bytes,
    proof_bytes: after.proof_bytes - before.proof_bytes,
    payload_bytes: after.payload_bytes - before.payload_bytes,
    index_nodes_read: after.index_nodes_read - before.index_nodes_read,
    planner_metadata_nodes_visited: after.planner_metadata_nodes_visited -
    before.planner_metadata_nodes_visited,
    resident_records_visited: after.resident_records_visited -
    before.resident_records_visited,
    resident_text_code_units_visited: after.resident_text_code_units_visited -
    before.resident_text_code_units_visited,
    resident_text_scalars_visited: after.resident_text_scalars_visited -
    before.resident_text_scalars_visited,
    scan_records_visited: after.scan_records_visited -
    before.scan_records_visited,
    full_history_events: after.full_history_events - before.full_history_events,
    full_history_bytes: after.full_history_bytes - before.full_history_bytes,
  }
}

///|
fn ordinary_provider_response(
  result : MetaLookupResult,
) -> OrdinaryAdmissionResponse {
  match result {
    MetaLookupResult::Found(meta_bytes, proof_bytes) =>
      OrdinaryAdmissionResponse::Authenticated({
        meta_bytes: meta_bytes.view().to_owned(),
        proof_bytes: proof_bytes.view().to_owned(),
      })
    MetaLookupResult::MissingInAuthenticatedRange =>
      OrdinaryAdmissionResponse::MissingInAuthenticatedRange
    MetaLookupResult::Unavailable => OrdinaryAdmissionResponse::Unavailable
    MetaLookupResult::Corrupt => OrdinaryAdmissionResponse::Corrupt
  }
}

///|
#warnings("-unused_error_type")
fn _ordinary_compare_metadata(
  snapshot : OrdinarySnapshot,
  incoming : OrdinaryEventMetaV2,
  response : OrdinaryAdmissionResponse,
) -> OrdinaryAdmissionDecision raise R0CodecError {
  match response {
    OrdinaryAdmissionResponse::MissingInAuthenticatedRange =>
      OrdinaryAdmissionDecision::Fallback(
        "provider_missing_in_authenticated_range",
      )
    OrdinaryAdmissionResponse::Unavailable =>
      OrdinaryAdmissionDecision::Fallback("provider_unavailable")
    OrdinaryAdmissionResponse::Corrupt =>
      OrdinaryAdmissionDecision::Fallback("provider_corrupt")
    OrdinaryAdmissionResponse::Authenticated(bytes) => {
      let resident = try! decode_event_meta_v2(bytes.meta_bytes)
      if resident.identity != incoming.identity {
        return OrdinaryAdmissionDecision::Fallback("metadata_identity_mismatch")
      }
      let writer = try! resident_writer_for(snapshot, incoming.identity)
      let proof = try! decode_mmr_proof(bytes.proof_bytes)
      if proof.leaf_position != incoming.identity.sequence {
        return OrdinaryAdmissionDecision::Fallback("provider_corrupt")
      }
      let leaf_hash = try! meta_leaf_hash_v2(resident)
      let proof_check : Result[Unit, R0ProofError] = Ok(
        _verify_mmr_inclusion(
          agent=writer.agent,
          leaf_count=writer.leaf_count,
          leaf_hash~,
          expected_root=writer.event_meta_mmr_root_v2,
          proof~,
        ),
      ) catch {
        error => Err(error)
      }
      match proof_check {
        Err(_) => return OrdinaryAdmissionDecision::Fallback("provider_corrupt")
        Ok(_) => ()
      }
      if resident.body_digest != incoming.body_digest {
        return OrdinaryAdmissionDecision::Conflict(
          OrdinaryAdmissionConflict::BodyDigest,
        )
      }
      if resident.declared_parents != incoming.declared_parents {
        return OrdinaryAdmissionDecision::Conflict(
          OrdinaryAdmissionConflict::DeclaredParents,
        )
      }
      if resident.implicit_predecessor != incoming.implicit_predecessor {
        return OrdinaryAdmissionDecision::Conflict(
          OrdinaryAdmissionConflict::ImplicitPredecessor,
        )
      }
      if resident.semantic_references != incoming.semantic_references {
        return OrdinaryAdmissionDecision::Conflict(
          OrdinaryAdmissionConflict::SemanticReferences,
        )
      }
      if resident.causal_rank_timestamp != incoming.causal_rank_timestamp ||
        resident.event_digest_v2 != incoming.event_digest_v2 {
        return OrdinaryAdmissionDecision::Conflict(
          OrdinaryAdmissionConflict::RankOrEventDigest,
        )
      }
      if resident.kind != incoming.kind ||
        resident.payload_byte_length != incoming.payload_byte_length {
        return OrdinaryAdmissionDecision::Conflict(
          OrdinaryAdmissionConflict::BodyDigest,
        )
      }
      OrdinaryAdmissionDecision::Duplicate
    }
  }
}

///|
fn ordinary_compare_metadata(
  snapshot : OrdinarySnapshot,
  incoming : OrdinaryEventMetaV2,
  response : OrdinaryAdmissionResponse,
) -> OrdinaryAdmissionDecision {
  let checked : Result[OrdinaryAdmissionDecision, R0CodecError] = Ok(
    _ordinary_compare_metadata(snapshot, incoming, response),
  ) catch {
    error => Err(error)
  }
  match checked {
    Ok(decision) => decision
    Err(_) => OrdinaryAdmissionDecision::Fallback("provider_corrupt")
  }
}

///|
/// Pure D-01--D-03 verifier. It performs no provider or history I/O.
fn verify_ordinary_admission(
  snapshot : OrdinarySnapshot,
  incoming : OrdinaryEventMetaV2,
  response : OrdinaryAdmissionResponse,
) -> OrdinaryAdmissionDecision {
  ordinary_compare_metadata(snapshot, incoming, response)
}

///|
/// The imperative shell performs the one sorted authenticated metadata call.
#warnings("-unused_value")
fn ordinary_admit_event(
  snapshot : OrdinarySnapshot,
  provider : OrdinaryProvider,
  incoming : OrdinaryEventMetaV2,
) -> OrdinaryAdmissionResult raise R0CodecError {
  let before = ordinary_copy_provider_counters(provider.counters)
  let mut resident_records_visited = 0
  let mut resident_writer : OrdinaryWriterCommitment? = None
  for writer in snapshot.writer_commitments {
    resident_records_visited += 1
    if writer.agent == incoming.identity.agent &&
      incoming.identity.sequence >= 0 &&
      incoming.identity.sequence < writer.leaf_count {
      resident_writer = Some(writer)
    }
  }
  let decision = match resident_writer {
    None => OrdinaryAdmissionDecision::Tier0Nonmembership
    Some(_) => {
      let results = provider.lookup_event_meta_batch(
        snapshot.snapshot_commit_id,
        [incoming.identity],
      )
      let response = match results.get(0) {
        Some(result) => ordinary_provider_response(result)
        None => OrdinaryAdmissionResponse::Corrupt
      }
      verify_ordinary_admission(snapshot, incoming, response)
    }
  }
  let provider_delta = ordinary_counter_delta(before, provider.counters)
  {
    decision,
    counter_delta: {
      ..provider_delta,
      resident_records_visited: provider_delta.resident_records_visited +
      resident_records_visited,
    },
  }
}
