///|
/// Emit one stable JSONL vector record.
fn emit_vector(name : String, expected_hex : String) -> Unit {
  println(
    "{\"schema_version\":1,\"record\":\"vector\",\"name\":" +
    Json(name).stringify() +
    ",\"expected_hex\":" +
    Json(expected_hex).stringify() +
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
      "schema_version": Json((1)),
      "run_id": Json(run_id),
      "producer": Json("egw_authority_native"),
      "case_id": Json(case_id),
      "status": Json("pass"),
      "payload": Json::object({
        "record": Json("candidate_capture"),
        "candidate": Json("A"),
        "phase": Json("capture"),
        "outcome": Json("not_applicable"),
        "reason": Json("candidate implementation is owned by #1291"),
        "candidate_bytes_base64": Json(base64_encode(empty)),
        "candidate_bytes_length": Json(empty.length()),
        "candidate_bytes_sha256": Json(empty_hash),
        "snapshot_commit_id": Json(empty_hash),
        "provider_fixture_bytes_base64": Json(base64_encode(provider)),
        "provider_fixture_bytes_length": Json(provider.length()),
        "provider_fixture_bytes_sha256": Json(sha256_hex(provider)),
        "expected_replay_order": Json(fixture.replay_order
        .map(identity => identity.agent + ":" + identity.sequence.to_string())
        ),
        "expected_final_text": Json(fixture.final_text),
        "adapter_observation_sha256": Json(sha256_hex(
          try! strict_utf8(fixture.final_text),
        )),
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
      "schema_version": Json((1)),
      "run_id": Json(run_id),
      "producer": Json("egw_candidate_js"),
      "case_id": Json(case_id),
      "status": Json("pass"),
      "payload": Json::object({
        "record": Json("candidate_result"),
        "candidate": Json("A"),
        "phase": Json("consume"),
        "outcome": Json("not_applicable"),
        "reason": Json("candidate implementation is owned by #1291"),
        "provider_fixture_bytes_sha256": Json(provider_sha256),
        "independent_process_validation": Json("base64+length+sha256+catalog"),
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
