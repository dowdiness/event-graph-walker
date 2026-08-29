///|
struct ItfTrace {
  states : Array[Json]
} derive(FromJson)

///|
struct WireIdentity {
  replica_id : String
  sequence : Int
} derive(FromJson)

///|
struct WireRange {
  start : Int
  end : Int
} derive(FromJson)

///|
struct WireAgentRanges {
  replica_id : String
  ranges : Array[WireRange]
} derive(FromJson)

///|
struct WireVersion {
  frontier : Array[WireIdentity]
  ranges : Array[WireAgentRanges]
} derive(FromJson)

///|
struct WireOperation {
  id : WireIdentity
  parents : Array[WireIdentity]
  kind : String
  content : Json
  origin_left : Json
  origin_right : Json
} derive(FromJson)

///|
struct WireSync {
  schema : Int
  format : String
  operations : Array[WireOperation]
  heads : Array[WireIdentity]
} derive(FromJson)

///|
fn field(value : Json, name : String) -> Json raise Failure {
  match value {
    Object(fields) =>
      match fields.get(name) {
        Some(value) => value
        None => raise Failure::Failure("missing JSON field \{name}")
      }
    _ => raise Failure::Failure("expected object containing \{name}")
  }
}

///|
fn string_field(value : Json, name : String) -> String raise Failure {
  match field(value, name) {
    String(value) => value
    _ => raise Failure::Failure("JSON field \{name} must be a string")
  }
}

///|
fn int_field(value : Json, name : String) -> Int raise Failure {
  decode_itf_int(field(value, name))
}

///|
fn decode_itf_int(value : Json) -> Int raise Failure {
  let encoded = string_field(value, "#bigint")
  @strconv.from_str(encoded) catch {
    _ => raise Failure::Failure("invalid ITF integer \{encoded}")
  }
}

///|
fn decode_itf_set(value : Json) -> Set[Int] raise Failure {
  let entries = match field(value, "#set") {
    Array(entries) => entries
    _ => raise Failure::Failure("ITF set payload must be an array")
  }
  let result : Set[Int] = Set([])
  for entry in entries {
    result.add(decode_itf_int(entry))
  }
  result
}

///|
fn sorted_values(values : Set[Int]) -> Array[Int] {
  let result = values.to_array()
  result.sort()
  result
}

///|
fn describe_set(values : Set[Int]) -> String {
  @debug.to_string(sorted_values(values))
}

///|
fn identity_json(sequence : Int) -> Json {
  Json::object({
    "replica_id": "shared-agent".to_json(),
    "sequence": sequence.to_json(),
  })
}

///|
fn fixture_json(
  operations : Set[Int],
  parent_sequence : Int,
  content : String,
) -> String {
  let sorted = sorted_values(operations)
  let encoded_operations : Array[Json] = []
  let heads : Array[Json] = []
  for sequence in sorted {
    let identity = identity_json(sequence)
    let parents = if parent_sequence < 0 {
      Json::array([])
    } else {
      [identity_json(parent_sequence)].to_json()
    }
    encoded_operations.push(
      Json::object({
        "id": identity,
        "parents": parents,
        "kind": "insert".to_json(),
        "content": content.to_json(),
        "origin_left": Json::null(),
        "origin_right": Json::null(),
      }),
    )
    heads.push(identity)
  }
  Json::object({
    "schema": (2).to_json(),
    "format": "event-graph-walker/text-sync".to_json(),
    "operations": encoded_operations.to_json(),
    "heads": heads.to_json(),
  }).stringify()
}

///|
fn version_observation(version : @text.Version) -> (Set[Int], Set[Int]) raise {
  let wire : WireVersion = @json.from_json(
    @json.parse(version.to_json_string()),
  )
  let knowledge : Set[Int] = Set([])
  for agent in wire.ranges {
    if agent.replica_id == "shared-agent" {
      for range in agent.ranges {
        for sequence in range.start..<range.end {
          knowledge.add(sequence)
        }
      }
    }
  }
  let frontier : Set[Int] = Set([])
  for identity in wire.frontier {
    if identity.replica_id == "shared-agent" {
      frontier.add(identity.sequence)
    }
  }
  (knowledge, frontier)
}

///|
fn message_operations(message : @text.SyncMessage) -> Set[Int] raise {
  let wire : WireSync = @json.from_json(@json.parse(message.to_json_string()))
  if wire.schema != 2 || wire.format != "event-graph-walker/text-sync" {
    raise Failure::Failure("exported message left the schema-2 domain")
  }
  let result : Set[Int] = Set([])
  for operation in wire.operations {
    if operation.kind != "insert" ||
      !(operation.content is String(_)) ||
      operation.parents.length() != 0 ||
      !(operation.origin_left is Null) ||
      !(operation.origin_right is Null) {
      raise Failure::Failure("exported sparse fixture operation changed shape")
    }
    if operation.id.replica_id == "shared-agent" {
      result.add(operation.id.sequence)
    }
  }
  for head in wire.heads {
    if head.replica_id != "shared-agent" {
      raise Failure::Failure("exported message contains an unexpected head")
    }
  }
  let canonical = message.to_canonical_bytes()
  let roundtrip = @text.SyncMessage::from_json_string(message.to_json_string())
  if canonical != roundtrip.to_canonical_bytes() {
    raise Failure::Failure(
      "exported message canonical bytes changed on round-trip",
    )
  }
  result
}

///|
struct Driver {
  documents : Map[String, @text.TextState]
  messages : Map[String, @text.SyncMessage]
  checkpoints : Map[String, @text.Version]
  broken : Bool
}

///|
fn Driver::Driver(broken : Bool) -> Driver raise {
  {
    documents: Map([
      ("source", @text.TextState::new("source-replay")),
      ("peer", @text.TextState::new("peer-replay")),
    ]),
    messages: Map([]),
    checkpoints: Map([]),
    broken,
  }
}

///|
fn Driver::document(
  self : Driver,
  name : String,
) -> @text.TextState raise Failure {
  match self.documents.get(name) {
    Some(document) => document
    None => raise Failure::Failure("unknown replica \{name}")
  }
}

///|
fn Driver::message(
  self : Driver,
  message_id : String,
) -> @text.SyncMessage raise Failure {
  match self.messages.get(message_id) {
    Some(message) => message
    None => raise Failure::Failure("unknown message \{message_id}")
  }
}

///|
fn Driver::checkpoint(
  self : Driver,
  checkpoint_id : String,
) -> @text.Version raise Failure {
  match self.checkpoints.get(checkpoint_id) {
    Some(version) => version
    None => raise Failure::Failure("unknown checkpoint \{checkpoint_id}")
  }
}

///|
fn Driver::apply_event(self : Driver, event : Json, step : Int) -> Unit raise {
  let name = string_field(event, "name")
  let message_id = string_field(event, "messageId")
  match name {
    "Init" => ()
    "BuildFixture" => {
      let operations = decode_itf_set(field(event, "operations"))
      let parent_sequence = int_field(event, "parentSequence")
      let content = string_field(event, "content")
      self.messages[message_id] = @text.SyncMessage::from_json_string(
        fixture_json(operations, parent_sequence, content),
      )
    }
    "DuplicateMessage" => {
      let new_message_id = string_field(event, "newMessageId")
      self.messages[new_message_id] = self.message(message_id)
    }
    "Deliver" => {
      let receiver = string_field(event, "receiver")
      let expected_outcome = string_field(event, "expectedOutcome")
      let before_knowledge = version_observation(
          self.document(receiver).version(),
        ).0
      let expected_knowledge = decode_itf_set(field(event, "versionKnowledge"))
      let delivered_operations = self.message(message_id).op_count()
      let result : Result[@text.SyncReport, Error] = Ok(
        self.document(receiver).sync().apply(self.message(message_id)),
      ) catch {
        error => Err(error)
      }
      match (expected_outcome, result) {
        (
          "Conflict",
          Err(
            @text.TextError::SyncFailed(
              @sync.Failure::ConflictingIdentity(
                replica_id="shared-agent",
                sequence=2
              )
            )
          ),
        ) => ()
        ("Conflict", _) =>
          raise Failure::Failure(
            "step \{step}: expected conflicting identity rejection",
          )
        (_, Err(_)) =>
          raise Failure::Failure("step \{step}: unexpected delivery failure")
        ("Pending", Ok(report)) =>
          if report.applied_operations() != 0 ||
            report.duplicate_operations() != 0 ||
            report.pending_operations() != 1 {
            raise Failure::Failure(
              "step \{step}: pending SyncReport counts diverged",
            )
          }
        ("Duplicate", Ok(report)) =>
          if report.applied_operations() != 0 ||
            report.duplicate_operations() != delivered_operations ||
            report.pending_operations() != 0 {
            raise Failure::Failure(
              "step \{step}: duplicate SyncReport counts diverged",
            )
          }
        ("Success" | "AppliedPending", Ok(report)) => {
          let expected_applied = expected_knowledge.length() -
            before_knowledge.length()
          if report.applied_operations() != expected_applied ||
            report.duplicate_operations() != 0 ||
            report.pending_operations() != 0 {
            raise Failure::Failure(
              "step \{step}: applied SyncReport counts diverged",
            )
          }
        }
        (_, Ok(_)) =>
          raise Failure::Failure(
            "step \{step}: unknown expected outcome \{expected_outcome}",
          )
      }
    }
    "CaptureCheckpoint" => {
      let replica = string_field(event, "receiver")
      let checkpoint_id = string_field(event, "checkpointId")
      self.checkpoints[checkpoint_id] = self.document(replica).version()
    }
    "RequestDelta" => {
      let sender = string_field(event, "sender")
      let checkpoint_id = string_field(event, "checkpointId")
      let expected = decode_itf_set(field(event, "operations"))
      let message = self
        .document(sender)
        .sync()
        .export_since(self.checkpoint(checkpoint_id))
      let actual = message_operations(message)
      if !actual.equal(expected) {
        raise Failure::Failure(
          "step \{step}: delta operations expected \{describe_set(expected)}, " +
          "observed \{describe_set(actual)}",
        )
      }
      self.messages[message_id] = message
    }
    _ => raise Failure::Failure("step \{step}: unknown event \{name}")
  }
}

///|
fn Driver::assert_replica(
  self : Driver,
  state : Json,
  replica : String,
  state_field : String,
  step : Int,
) -> Unit raise {
  let expected = decode_itf_set(field(state, state_field))
  let frontier_field = if replica == "source" {
    "sourceFrontier"
  } else {
    "peerFrontier"
  }
  let pending_field = if replica == "source" {
    "sourcePending"
  } else {
    "peerPending"
  }
  let expected_frontier = decode_itf_set(field(state, frontier_field))
  let expected_pending = int_field(state, pending_field)
  if self.broken && replica == "source" {
    expected.remove(2)
  }
  let document = self.document(replica)
  let (knowledge, frontier) = version_observation(document.version())
  if !knowledge.equal(expected) {
    raise Failure::Failure(
      "step \{step}: \{replica} knowledge expected " +
      "\{describe_set(expected)}, observed \{describe_set(knowledge)}",
    )
  }
  if !frontier.equal(expected_frontier) {
    raise Failure::Failure(
      "step \{step}: \{replica} frontier expected " +
      "\{describe_set(expected_frontier)}, observed \{describe_set(frontier)}",
    )
  }
  let expected_text = "x".repeat(expected.length())
  if document.text() != expected_text {
    raise Failure::Failure(
      "step \{step}: \{replica} text expected \{expected_text}, " +
      "observed \{document.text()}",
    )
  }
  let actual_pending = document.sync().pending_sync_count()
  if actual_pending != expected_pending {
    raise Failure::Failure(
      "step \{step}: \{replica} pending expected \{expected_pending}, " +
      "observed \{actual_pending}",
    )
  }
}

///|
fn Driver::replay(self : Driver, trace : ItfTrace) -> Unit raise {
  for step, raw_state in trace.states {
    let state = field(raw_state, "s")
    self.apply_event(field(state, "lastEvent"), step)
    self.assert_replica(state, "source", "sourceKnowledge", step)
    self.assert_replica(state, "peer", "peerKnowledge", step)
  }
}

///|
async fn main {
  let args = @env.args()
  guard args is [_, trace_path, .. rest] else {
    raise Failure::Failure("usage: replay TRACE.itf.json [--broken]")
  }
  let broken = rest.any(argument => argument == "--broken")
  let trace : ItfTrace = @json.from_json(
    @json.parse(@fs.read_file(trace_path).text()),
  )
  let driver = Driver(broken)
  driver.replay(trace)
  println("PASS: \{trace.states.length()} ITF states matched public text API")
}
