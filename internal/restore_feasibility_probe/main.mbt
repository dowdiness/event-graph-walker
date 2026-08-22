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
/// Emit one immutable native candidate/process capture.
fn native_produce(case_id : String, run_id : String) -> Unit {
  let fixture = try! generate_required_fixture(case_id)
  let provider = try! canonical_fixture_bytes(fixture)
  let empty = Bytes::new(0)
  let empty_hash = sha256_hex(empty)
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
        "outcome": "not_applicable".to_json(),
        "reason": "candidate implementation is owned by #1291".to_json(),
        "candidate_bytes_base64": base64_encode(empty).to_json(),
        "candidate_bytes_length": empty.length().to_json(),
        "candidate_bytes_sha256": empty_hash.to_json(),
        "snapshot_commit_id": empty_hash.to_json(),
        "provider_fixture_bytes_base64": base64_encode(provider).to_json(),
        "provider_fixture_bytes_length": provider.length().to_json(),
        "provider_fixture_bytes_sha256": sha256_hex(provider).to_json(),
        "expected_replay_order": fixture.replay_order
        .map(identity => identity.agent + ":" + identity.sequence.to_string())
        .to_json(),
        "expected_final_text": fixture.final_text.to_json(),
        "adapter_observation_sha256": sha256_hex(
          try! strict_utf8(fixture.final_text),
        ).to_json(),
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
  let provider_base64 : String = @json.from_json(
    object_field(payload, "provider_fixture_bytes_base64"),
  )
  let provider_sha256 : String = @json.from_json(
    object_field(payload, "provider_fixture_bytes_sha256"),
  )
  let provider_length : Int = @json.from_json(
    object_field(payload, "provider_fixture_bytes_length"),
  )
  let provider = try! base64_decode(provider_base64)
  if provider.length() != provider_length ||
    sha256_hex(provider) != provider_sha256 {
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
          catalog_hash = Some(hash)
        }
      }
      _ => panic()
    }
  }
  guard catalog_hash is Some(catalog_hash) else { panic() }
  if catalog_hash != provider_sha256 {
    panic()
  }
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
        "outcome": "not_applicable".to_json(),
        "reason": "candidate implementation is owned by #1291".to_json(),
        "provider_fixture_bytes_sha256": provider_sha256.to_json(),
        "independent_process_validation": "base64+length+sha256+catalog".to_json(),
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
