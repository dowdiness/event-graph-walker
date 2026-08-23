///|
/// Emit one stable JSONL vector record.
fn emit_vector(name : String, expected_hex : String) -> Unit {
  println(
    "{\"schema_version\":1,\"record\":\"vector\",\"name\":" +
    name.to_json().stringify() +
    ",\"expected_hex\":" +
    expected_hex.to_json().stringify() +
    "}",
  )
}

///|
/// Emit the primitive oracle output consumed by the independent harness.
fn self_test() -> Unit {
  emit_vector("uvarint-0", bytes_hex(try! encode_uvarint(0)))
  emit_vector("uvarint-1", bytes_hex(try! encode_uvarint(1)))
  emit_vector("uvarint-127", bytes_hex(try! encode_uvarint(127)))
  emit_vector("uvarint-128", bytes_hex(try! encode_uvarint(128)))
  emit_vector("uvarint-0x7ffffffe", bytes_hex(try! encode_uvarint(0x7fff_fffe)))
  emit_vector("lp_bytes-ab", bytes_hex(try! lp_bytes(@utf8.encode("ab"))))
  emit_vector("lp_utf8-é", bytes_hex(try! lp_utf8("é")))
  emit_vector("domain-é", bytes_hex(try! domain("é")))
  emit_vector(
    "raw_version-a-128",
    bytes_hex(try! encode_raw_version(@core.RawVersion("a", 128))),
  )
  emit_vector("sha256-empty", sha256_hex(Bytes::new(0)))
  println(
    "{\"schema_version\":1,\"record\":\"summary\",\"vector_count\":10,\"passed\":true}",
  )
}

///|
fn ordinary_admission_decision_json(
  decision : OrdinaryAdmissionDecision,
) -> Json {
  match decision {
    OrdinaryAdmissionDecision::Tier0Nonmembership =>
      Json::object({ "outcome": "tier0_nonmembership".to_json() })
    OrdinaryAdmissionDecision::Duplicate =>
      Json::object({ "outcome": "duplicate".to_json() })
    OrdinaryAdmissionDecision::Conflict(conflict) => {
      let name = match conflict {
        OrdinaryAdmissionConflict::BodyDigest => "body_digest"
        OrdinaryAdmissionConflict::DeclaredParents => "declared_parents"
        OrdinaryAdmissionConflict::ImplicitPredecessor => "implicit_predecessor"
        OrdinaryAdmissionConflict::SemanticReferences => "semantic_references"
        OrdinaryAdmissionConflict::RankOrEventDigest => "rank_or_event_digest"
      }
      Json::object({
        "outcome": "conflict".to_json(),
        "conflict": name.to_json(),
      })
    }
    OrdinaryAdmissionDecision::Fallback(reason) =>
      Json::object({
        "outcome": "fallback".to_json(),
        "reason": reason.to_json(),
      })
  }
}

///|
fn ordinary_admission_observation_json(
  run_id : String,
  case_id : String,
  phase : String,
  operation : String,
  result : OrdinaryAdmissionResult,
) -> Json {
  let counters = result.counter_delta
  Json::object({
    "schema_version": (1).to_json(),
    "run_id": run_id.to_json(),
    "case_id": case_id.to_json(),
    "producer": "egw_candidate_js".to_json(),
    "status": "pass".to_json(),
    "payload": Json::object({
      "record": "ordinary_admission_observation".to_json(),
      "candidate": "A".to_json(),
      "phase": phase.to_json(),
      "operation": operation.to_json(),
      "decision": ordinary_admission_decision_json(result.decision),
      "counter_delta": Json::object({
        "logical_query_count": counters.logical_query_count.to_json(),
        "physical_read_calls": counters.physical_read_calls.to_json(),
        "requested_id_count": counters.requested_id_count.to_json(),
        "returned_record_count": counters.returned_record_count.to_json(),
        "metadata_records": counters.metadata_records.to_json(),
        "payload_events": counters.payload_events.to_json(),
        "metadata_bytes": counters.metadata_bytes.to_json(),
        "proof_bytes": counters.proof_bytes.to_json(),
        "payload_bytes": counters.payload_bytes.to_json(),
        "index_nodes_read": counters.index_nodes_read.to_json(),
        "resident_records_visited": counters.resident_records_visited.to_json(),
        "scan_records_visited": counters.scan_records_visited.to_json(),
        "full_history_events": counters.full_history_events.to_json(),
        "full_history_bytes": counters.full_history_bytes.to_json(),
      }),
    }),
  })
}

///|
fn emit_ordinary_admission_observation(observation : Json) -> Unit {
  println(observation.stringify())
}

///|
fn run_ordinary_admission_probe(
  run_id : String,
  case_id : String,
  snapshot : OrdinarySnapshot,
  provider : OrdinaryProvider,
) -> Array[Json] raise R0CodecError {
  guard provider.meta_records.get(0) is Some(first_record) else {
    raise R0CodecError::InvalidValue(detail="provider metadata is empty")
  }
  let resident = decode_event_meta_v2(first_record.meta_bytes)
  let tier0 : OrdinaryEventMetaV2 = {
    ..resident,
    identity: RawIdentity(agent="r0-tier0-absent", sequence=0),
  }
  let conflict : OrdinaryEventMetaV2 = {
    ..resident,
    body_digest: Bytes::new(32),
  }
  let cases = [
    (
      "admission-tier0",
      "absent-writer",
      ordinary_admit_event(snapshot, provider, tier0),
    ),
    (
      "admission-duplicate",
      "exact-duplicate",
      ordinary_admit_event(snapshot, provider, resident),
    ),
    (
      "admission-conflict",
      "body-digest-conflict",
      ordinary_admit_event(snapshot, provider, conflict),
    ),
  ]
  let observations : Array[Json] = []
  for item in cases {
    let (phase, operation, result) = item
    let observation = ordinary_admission_observation_json(
      run_id, case_id, phase, operation, result,
    )
    emit_ordinary_admission_observation(observation)
    observations.push(observation)
  }
  observations
}

///|
/// Emit one immutable native candidate/process capture.
fn native_produce(case_id : String, run_id : String) -> Unit {
  let fixture = try! generate_required_fixture(case_id)
  let capture_overlay = try! build_ordinary_capture_overlay(fixture)
  let capture = try! capture_paper_branch_candidate_from_overlay(
    fixture, capture_overlay,
  )
  let provider_overlay = {
    ..capture_overlay,
    full_history_bytes: legacy_oracle_history_bytes(fixture),
  }
  let provider = try! encode_provider_fixture(provider_overlay)
  let fixture_catalog_sha256 = sha256_hex(try! canonical_fixture_bytes(fixture))
  let authority = try! validate_capture_against_egw_authority(
    fixture,
    capture.candidate_bytes,
  )
  let working_state_observations = try! working_state_observations(
    run_id,
    "egw_authority_native",
    capture_overlay.snapshot,
    fixture.final_text,
  )
  println(
    Json::object({
      "schema_version": (1).to_json(),
      "run_id": run_id.to_json(),
      "producer": "egw_authority_native".to_json(),
      "case_id": case_id.to_json(),
      "status": "pass".to_json(),
      "payload": Json::object({
        "record": "candidate_capture".to_json(),
        "candidate": "A".to_json(),
        "phase": "capture".to_json(),
        "outcome": "pass".to_json(),
        "candidate_bytes_base64": base64_encode(capture.candidate_bytes).to_json(),
        "candidate_bytes_length": capture.candidate_bytes.length().to_json(),
        "candidate_bytes_sha256": sha256_hex(capture.candidate_bytes).to_json(),
        "snapshot_commit_id": bytes_hex(capture.snapshot_commit_id).to_json(),
        "verification_projection": capture.verification_projection,
        "provider_fixture_bytes_base64": base64_encode(provider).to_json(),
        "provider_fixture_bytes_length": provider.length().to_json(),
        "provider_fixture_bytes_sha256": sha256_hex(provider).to_json(),
        "fixture_catalog_sha256": fixture_catalog_sha256.to_json(),
        "expected_replay_order": fixture.replay_order
        .map(identity => identity.agent + ":" + identity.sequence.to_string())
        .to_json(),
        "expected_final_text": fixture.final_text.to_json(),
        "adapter_observation_sha256": sha256_hex(
          try! strict_utf8(fixture.final_text),
        ).to_json(),
        "authority_capture": Json::object({
          "committed_events": authority.committed_events.to_json(),
          "pending_after_count": authority.pending_after_count.to_json(),
          "authority_text_sha256": sha256_hex(
            try! strict_utf8(authority.authority_text),
          ).to_json(),
          "exact_heads": authority.exact_heads
          .map(identity => identity.agent + ":" + identity.sequence.to_string())
          .to_json(),
          "head_ranks": authority.head_ranks.to_json(),
          "used_typed_admission_receipts": authority.used_typed_admission_receipts.to_json(),
          "full_history_walks": authority.full_history_walks.to_json(),
        }),
        "working_state_observations": working_state_observations.to_json(),
      }),
    }).stringify(),
  )
}

///|
/// Require a JSON object and expose one typed field.
fn object_field(object : Map[String, Json], key : String) -> Json {
  object.get(key).unwrap_or(Json::null())
}

///|
/// Consume native bytes in a separately compiled JS process.
fn js_consume(capture_path : String, catalog_path : String) -> Unit raise {
  let capture_source = @fs.read_file_to_string(capture_path)
  let mut capture : Map[String, Json]? = None
  for line in capture_source.split("\n") {
    let trimmed = line.trim().to_owned()
    if trimmed != "" {
      match @json.parse(trimmed) {
        Json::Object(object) => {
          let payload = match object_field(object, "payload") {
            Json::Object(payload) => payload
            _ => panic()
          }
          let record : String = @json.from_json(object_field(payload, "record"))
          if record == "candidate_capture" && capture is None {
            capture = Some(object)
          }
        }
        _ => panic()
      }
    }
  }
  guard capture is Some(capture) else { panic() }
  let payload = match object_field(capture, "payload") {
    Json::Object(payload) => payload
    _ => panic()
  }
  let case_id : String = @json.from_json(object_field(capture, "case_id"))
  let run_id : String = @json.from_json(object_field(capture, "run_id"))
  let candidate_base64 : String = @json.from_json(
    object_field(payload, "candidate_bytes_base64"),
  )
  let candidate_sha256 : String = @json.from_json(
    object_field(payload, "candidate_bytes_sha256"),
  )
  let candidate_length : Int = @json.from_json(
    object_field(payload, "candidate_bytes_length"),
  )
  let expected_snapshot_commit_id : String = @json.from_json(
    object_field(payload, "snapshot_commit_id"),
  )
  let candidate = try! base64_decode(candidate_base64)
  if candidate.length() != candidate_length ||
    sha256_hex(candidate) != candidate_sha256 {
    panic()
  }
  let restored = try! validate_published_paper_branch_candidate(
    candidate,
    expected_snapshot_commit_id_hex=expected_snapshot_commit_id,
  )
  let provider_base64 : String = @json.from_json(
    object_field(payload, "provider_fixture_bytes_base64"),
  )
  let provider_sha256 : String = @json.from_json(
    object_field(payload, "provider_fixture_bytes_sha256"),
  )
  let provider_length : Int = @json.from_json(
    object_field(payload, "provider_fixture_bytes_length"),
  )
  let fixture_catalog_sha256 : String = @json.from_json(
    object_field(payload, "fixture_catalog_sha256"),
  )
  let provider = try! base64_decode(provider_base64)
  if provider.length() != provider_length ||
    sha256_hex(provider) != provider_sha256 {
    panic()
  }
  let decoded_provider = try! OrdinaryProvider::new(provider)
  if decoded_provider.snapshot_commit_id != restored.snapshot.snapshot_commit_id {
    panic()
  }
  let catalog_source = @fs.read_file_to_string(catalog_path)
  let catalog = match @json.parse(catalog_source) {
    Json::Object(object) => object
    _ => panic()
  }
  let fixtures : Array[Json] = @json.from_json(
    object_field(catalog, "fixtures"),
  )
  let mut catalog_hash : String? = None
  let mut catalog_text : String? = None
  let mut catalog_event_count : Int? = None
  for entry in fixtures {
    match entry {
      Json::Object(object) => {
        let fixture_id : String = @json.from_json(
          object_field(object, "fixture_id"),
        )
        if fixture_id == case_id {
          let hash : String = @json.from_json(
            object_field(object, "canonical_sha256"),
          )
          let final_text : String = @json.from_json(
            object_field(object, "final_text"),
          )
          let event_count : Int = @json.from_json(
            object_field(object, "event_count"),
          )
          catalog_hash = Some(hash)
          catalog_text = Some(final_text)
          catalog_event_count = Some(event_count)
        }
      }
      _ => panic()
    }
  }
  guard catalog_hash is Some(catalog_hash) else { panic() }
  guard catalog_text is Some(catalog_text) else { panic() }
  guard catalog_event_count is Some(catalog_event_count) else { panic() }
  if catalog_hash != fixture_catalog_sha256 ||
    restored.document_text != catalog_text ||
    decoded_provider.meta_records.length() != catalog_event_count ||
    decoded_provider.payload_records.length() != catalog_event_count {
    panic()
  }
  let first_branch = try! begin_ordinary_paper_branch(
    restored,
    fresh_writer="r0-gate-fresh-a",
  )
  let second_branch = try! begin_ordinary_paper_branch(
    restored,
    fresh_writer="r0-gate-fresh-b",
  )
  let end_position = try! unicode_scalar_length(restored.document_text)
  let inserted = try! apply_local_insert(
    first_branch,
    position=end_position,
    scalar="Z",
  )
  let deleted = if end_position == 0 {
    None
  } else {
    Some(try! apply_local_delete(second_branch, position=0))
  }
  let sequential = try! apply_local_delete(inserted.state, position=0)
  let undo = request_pre_capture_undo(first_branch)
  let ordinary_admission_observations = try! run_ordinary_admission_probe(
    run_id,
    case_id,
    restored.snapshot,
    decoded_provider,
  )
  let working_state_observations = try! working_state_observations(
    run_id,
    "egw_candidate_js",
    restored.snapshot,
    restored.document_text,
  )
  println(
    Json::object({
      "schema_version": (1).to_json(),
      "run_id": run_id.to_json(),
      "producer": "egw_candidate_js".to_json(),
      "case_id": case_id.to_json(),
      "status": "pass".to_json(),
      "payload": Json::object({
        "record": "candidate_result".to_json(),
        "candidate": "A".to_json(),
        "phase": "consume".to_json(),
        "outcome": "pass".to_json(),
        "snapshot_commit_id": expected_snapshot_commit_id.to_json(),
        "candidate_bytes_sha256": candidate_sha256.to_json(),
        "restored_text_sha256": sha256_hex(
          try! strict_utf8(restored.document_text),
        ).to_json(),
        "read_accounting": Json::object({
          "metadata_queries": (restored.reads.metadata_queries +
          inserted.reads.metadata_queries +
          deleted.map_or(0, result => result.reads.metadata_queries) +
          sequential.reads.metadata_queries +
          undo.reads.metadata_queries).to_json(),
          "payload_queries": (restored.reads.payload_queries +
          inserted.reads.payload_queries +
          deleted.map_or(0, result => result.reads.payload_queries) +
          sequential.reads.payload_queries +
          undo.reads.payload_queries).to_json(),
          "full_history_queries": (restored.reads.full_history_queries +
          inserted.reads.full_history_queries +
          deleted.map_or(0, result => result.reads.full_history_queries) +
          sequential.reads.full_history_queries +
          undo.reads.full_history_queries).to_json(),
          "scan_records_visited": (restored.reads.scan_records_visited +
          inserted.reads.scan_records_visited +
          deleted.map_or(0, result => result.reads.scan_records_visited) +
          sequential.reads.scan_records_visited +
          undo.reads.scan_records_visited).to_json(),
        }),
        "local_edit_observations": Json::object({
          "fresh_writer_a": first_branch.fresh_writer.to_json(),
          "fresh_writer_b": second_branch.fresh_writer.to_json(),
          "content_commit_equal_before_edit": (first_branch.snapshot.snapshot_commit_id ==
          second_branch.snapshot.snapshot_commit_id).to_json(),
          "insert_body_hex": bytes_hex(
            try! encode_canonical_body(inserted.event.body.unwrap()),
          ).to_json(),
          "insert_text_sha256": sha256_hex(
            try! strict_utf8(inserted.state.document_text),
          ).to_json(),
          "delete_body_hex": deleted
          .map(result => {
            bytes_hex(try! encode_canonical_body(result.event.body.unwrap()))
          })
          .to_json(),
          "delete_text_sha256": deleted
          .map(result => {
            sha256_hex(try! strict_utf8(result.state.document_text))
          })
          .to_json(),
          "sequential_sequence": sequential.event.identity.sequence.to_json(),
          "sequential_predecessor_present": (sequential.event.implicit_predecessor
          is Some(_)).to_json(),
          "undo_outcome": undo.reason.to_json(),
          "undo_text_unchanged": (undo.state.document_text ==
          first_branch.document_text).to_json(),
        }),
        "provider_fixture_bytes_sha256": provider_sha256.to_json(),
        "ordinary_admission_observations": ordinary_admission_observations.to_json(),
        "working_state_observations": working_state_observations.to_json(),
        "independent_process_validation": "candidate base64+length+sha256+snapshot+catalog".to_json(),
      }),
    }).stringify(),
  )
}

///|
fn argument_value(args : Array[String], flag : String) -> String? {
  for index = 0; index + 1 < args.length(); index = index + 1 {
    if args[index] == flag {
      return args.get(index + 1)
    }
  }
  None
}

///|
fn main {
  let args = @env.args()
  let mut command_index = -1
  for index = 0; index < args.length(); index = index + 1 {
    match args.get(index) {
      Some(
        "self-test"
        | "generate-catalog"
        | "catalog-one"
        | "produce"
        | "consume"
        | "legacy-history"
        | "oracle"
      ) => command_index = index
      _ => ()
    }
  }
  match args.get(command_index) {
    Some("self-test") => self_test()
    Some("generate-catalog") => {
      guard argument_value(args, "--output") is Some(output_path) else {
        panic()
      }
      try! @fs.write_string_to_file(
        output_path,
        generate_full_catalog_json() + "\n",
      )
    }
    Some("catalog-one") => {
      guard args.get(command_index + 1) is Some(case_id) else { panic() }
      println(try! generate_single_catalog_json(case_id))
    }
    Some("produce") => {
      guard argument_value(args, "--catalog") is Some(catalog_path) else {
        panic()
      }
      guard argument_value(args, "--case-id") is Some(case_id) else { panic() }
      ignore(try! @fs.read_file_to_string(catalog_path))
      native_produce(case_id, "gate-r0-v1")
    }
    Some("consume") => {
      guard argument_value(args, "--capture-jsonl") is Some(capture_path) else {
        panic()
      }
      guard argument_value(args, "--catalog") is Some(catalog_path) else {
        panic()
      }
      guard argument_value(args, "--case-id") is Some(_case_id) else { panic() }
      try! js_consume(capture_path, catalog_path)
    }
    Some("legacy-history") => {
      guard argument_value(args, "--case-id") is Some(case_id) else { panic() }
      guard argument_value(args, "--output") is Some(output_path) else {
        panic()
      }
      try! @fs.write_string_to_file(
        output_path,
        generate_legacy_oracle_history(case_id) + "\n",
      )
    }
    Some("oracle") | None => emit_authority_oracle()
    _ => panic()
  }
}
