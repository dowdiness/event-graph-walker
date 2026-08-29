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
struct ObservedIdentity {
  agent : String
  sequence : Int
} derive(Eq, Hash, @debug.Debug)

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
fn optional_field(value : Json, name : String) -> Json? {
  match value {
    Object(fields) => fields.get(name)
    _ => None
  }
}

///|
fn field(value : Json, name : String) -> Json raise Failure {
  match optional_field(value, name) {
    Some(value) => value
    None => raise Failure::Failure("missing JSON field \{name}")
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
fn decode_itf_identity(value : Json) -> ObservedIdentity raise Failure {
  {
    agent: string_field(value, "agent"),
    sequence: int_field(value, "sequence"),
  }
}

///|
fn decode_itf_identity_set(value : Json) -> Set[ObservedIdentity] raise Failure {
  let entries = match field(value, "#set") {
    Array(entries) => entries
    _ => raise Failure::Failure("ITF identity set payload must be an array")
  }
  let result : Set[ObservedIdentity] = Set([])
  for entry in entries {
    result.add(decode_itf_identity(entry))
  }
  result
}

///|
fn decode_itf_string_set(value : Json) -> Set[String] raise Failure {
  let entries = match field(value, "#set") {
    Array(entries) => entries
    _ => raise Failure::Failure("ITF set payload must be an array")
  }
  let result : Set[String] = Set([])
  for entry in entries {
    match entry {
      String(value) => result.add(value)
      _ => raise Failure::Failure("ITF schedule ID must be a string")
    }
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
fn observed_identity_json(identity : ObservedIdentity) -> Json {
  Json::object({
    "replica_id": identity.agent.to_json(),
    "sequence": identity.sequence.to_json(),
  })
}

///|
fn identity_json(sequence : Int) -> Json {
  observed_identity_json({ agent: "shared-agent", sequence })
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
fn optional_identity_json(value : Json) -> Json raise Failure {
  match string_field(value, "tag") {
    "NoIdentity" => Json::null()
    "SomeIdentity" =>
      observed_identity_json(decode_itf_identity(field(value, "value")))
    tag => raise Failure::Failure("unknown optional identity tag \{tag}")
  }
}

///|
fn exact_operation_json(value : Json) -> Json raise Failure {
  let id = observed_identity_json(decode_itf_identity(field(value, "id")))
  let parent_values = match field(field(value, "parents"), "#set") {
    Array(entries) => entries
    _ => raise Failure::Failure("operation parents must be an ITF set")
  }
  let parents : Array[Json] = []
  for parent in parent_values {
    parents.push(observed_identity_json(decode_itf_identity(parent)))
  }
  let kind = string_field(value, "kind")
  let has_content = match field(value, "hasContent") {
    True => true
    False => false
    _ => raise Failure::Failure("operation hasContent must be boolean")
  }
  let content = if has_content {
    string_field(value, "content").to_json()
  } else {
    Json::null()
  }
  if (kind == "insert") != has_content ||
    (kind != "insert" && kind != "delete" && kind != "undelete") {
    raise Failure::Failure("operation kind/content shape is invalid")
  }
  Json::object({
    "id": id,
    "parents": parents.to_json(),
    "kind": kind.to_json(),
    "content": content,
    "origin_left": optional_identity_json(field(value, "originLeft")),
    "origin_right": optional_identity_json(field(value, "originRight")),
  })
}

///|
fn exact_fixture_json(event : Json) -> String raise Failure {
  let operation_values = match field(field(event, "exactOperations"), "#set") {
    Array(entries) => entries
    _ => raise Failure::Failure("exact operations must be an ITF set")
  }
  let head_values = match field(field(event, "exactHeads"), "#set") {
    Array(entries) => entries
    _ => raise Failure::Failure("exact heads must be an ITF set")
  }
  let operations : Array[Json] = []
  for operation in operation_values {
    operations.push(exact_operation_json(operation))
  }
  let heads : Array[Json] = []
  for head in head_values {
    heads.push(observed_identity_json(decode_itf_identity(head)))
  }
  Json::object({
    "schema": (2).to_json(),
    "format": "event-graph-walker/text-sync".to_json(),
    "operations": operations.to_json(),
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
fn exact_version_observation(
  version : @text.Version,
) -> (Set[ObservedIdentity], Set[ObservedIdentity]) raise {
  let wire : WireVersion = @json.from_json(
    @json.parse(version.to_json_string()),
  )
  let knowledge : Set[ObservedIdentity] = Set([])
  for agent in wire.ranges {
    for range in agent.ranges {
      for sequence in range.start..<range.end {
        knowledge.add({ agent: agent.replica_id, sequence })
      }
    }
  }
  let frontier : Set[ObservedIdentity] = Set([])
  for identity in wire.frontier {
    frontier.add({ agent: identity.replica_id, sequence: identity.sequence })
  }
  (knowledge, frontier)
}

///|
fn identity_key(identity : WireIdentity) -> String {
  observed_identity_json({
    agent: identity.replica_id,
    sequence: identity.sequence,
  }).stringify()
}

///|
fn optional_wire_identity_key(value : Json) -> Json raise {
  match value {
    Null => Json::null()
    _ => {
      let identity : WireIdentity = @json.from_json(value)
      identity_key(identity).to_json()
    }
  }
}

///|
fn normalized_wire_operation(operation : WireOperation) -> String raise {
  let parents = operation.parents.map(identity_key)
  parents.sort()
  Json::object({
    "id": identity_key(operation.id).to_json(),
    "parents": parents.to_json(),
    "kind": operation.kind.to_json(),
    "content": operation.content,
    "origin_left": optional_wire_identity_key(operation.origin_left),
    "origin_right": optional_wire_identity_key(operation.origin_right),
  }).stringify()
}

///|
fn normalized_exact_operation(value : Json) -> String raise {
  let operation : WireOperation = @json.from_json(exact_operation_json(value))
  normalized_wire_operation(operation)
}

///|
fn expected_exact_operations(event : Json) -> Set[String] raise {
  let values = match field(field(event, "exactOperations"), "#set") {
    Array(entries) => entries
    _ => raise Failure::Failure("expected exact operations must be an ITF set")
  }
  let result : Set[String] = Set([])
  for operation in values {
    result.add(normalized_exact_operation(operation))
  }
  result
}

///|
fn message_exact_operations(message : @text.SyncMessage) -> Set[String] raise {
  let wire : WireSync = @json.from_json(@json.parse(message.to_json_string()))
  if wire.schema != 2 || wire.format != "event-graph-walker/text-sync" {
    raise Failure::Failure("exported message left the schema-2 domain")
  }
  let result : Set[String] = Set([])
  for operation in wire.operations {
    result.add(normalized_wire_operation(operation))
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
fn version_claim_json(event : Json) -> String raise Failure {
  let knowledge = decode_itf_identity_set(field(event, "claimKnowledge"))
  let frontier = decode_itf_identity_set(field(event, "claimFrontier"))
  let sequences : Map[String, Int] = Map([])
  for identity in knowledge {
    if sequences.contains(identity.agent) {
      raise Failure::Failure(
        "Gate V2 claim fixture supports one sequence per agent",
      )
    }
    sequences[identity.agent] = identity.sequence
  }
  let agents = sequences.keys().to_array()
  agents.sort()
  let ranges : Array[Json] = []
  for agent in agents {
    let sequence = sequences[agent]
    ranges.push(
      Json::object({
        "replica_id": agent.to_json(),
        "ranges": [
          Json::object({
            "start": sequence.to_json(),
            "end": (sequence + 1).to_json(),
          }),
        ].to_json(),
      }),
    )
  }
  let frontier_values = frontier.to_array()
  frontier_values.sort_by((left, right) => {
    let by_agent = left.agent.compare(right.agent)
    if by_agent == 0 {
      left.sequence.compare(right.sequence)
    } else {
      by_agent
    }
  })
  let frontier_json = frontier_values.map(observed_identity_json)
  Json::object({
    "schema": (2).to_json(),
    "format": "event-graph-walker/text-version".to_json(),
    "frontier": frontier_json.to_json(),
    "ranges": ranges.to_json(),
  }).stringify()
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
fn Driver::apply_event(
  self : Driver,
  event : Json,
  state : Json,
  step : Int,
) -> Unit raise {
  let name = string_field(event, "name")
  let message_id = string_field(event, "messageId")
  match name {
    "Init" => ()
    "BuildFixture" => {
      let operations = decode_itf_set(field(event, "operations"))
      let parent_sequence = int_field(event, "parentSequence")
      let content = string_field(event, "content")
      let exact_values = match field(field(event, "exactOperations"), "#set") {
        Array(entries) => entries
        _ => raise Failure::Failure("exact operations must be an ITF set")
      }
      let encoded = if exact_values.is_empty() {
        fixture_json(operations, parent_sequence, content)
      } else {
        exact_fixture_json(event)
      }
      self.messages[message_id] = @text.SyncMessage::from_json_string(encoded)
    }
    "DuplicateMessage" => {
      let new_message_id = string_field(event, "newMessageId")
      self.messages[new_message_id] = self.message(message_id)
    }
    "Deliver" => {
      let receiver = string_field(event, "receiver")
      let expected_outcome = string_field(event, "expectedOutcome")
      let exact_field = if receiver == "source" {
        "sourceIdentities"
      } else {
        "peerIdentities"
      }
      let before_count = match optional_field(state, exact_field) {
        Some(_) =>
          exact_version_observation(self.document(receiver).version()).0.length()
        None =>
          version_observation(self.document(receiver).version()).0.length()
      }
      let expected_count = match optional_field(state, exact_field) {
        Some(value) => decode_itf_identity_set(value).length()
        None => decode_itf_set(field(event, "versionKnowledge")).length()
      }
      let delivered_operations = self.message(message_id).op_count()
      let pending_field = if receiver == "source" {
        "sourcePending"
      } else {
        "peerPending"
      }
      let expected_pending = int_field(state, pending_field)
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
            report.pending_operations() != expected_pending {
            raise Failure::Failure(
              "step \{step}: pending SyncReport counts diverged",
            )
          }
        ("Duplicate", Ok(report)) =>
          if report.applied_operations() != 0 ||
            report.duplicate_operations() != delivered_operations ||
            report.pending_operations() != expected_pending {
            raise Failure::Failure(
              "step \{step}: duplicate SyncReport counts diverged",
            )
          }
        ("Success" | "AppliedPending", Ok(report)) => {
          let expected_applied = expected_count - before_count
          if report.applied_operations() != expected_applied ||
            report.duplicate_operations() != 0 ||
            report.pending_operations() != expected_pending {
            raise Failure::Failure(
              "step \{step}: applied SyncReport expected applied=" +
              "\{expected_applied}, duplicate=0, pending=\{expected_pending}; " +
              "observed applied=" +
              "\{report.applied_operations()}, duplicate=" +
              "\{report.duplicate_operations()}, pending=" +
              "\{report.pending_operations()}",
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
      let message = self
        .document(sender)
        .sync()
        .export_since(self.checkpoint(checkpoint_id))
      if optional_field(state, "sourceIdentities") is Some(_) {
        let expected = expected_exact_operations(event)
        let actual = message_exact_operations(message)
        if !actual.equal(expected) {
          raise Failure::Failure(
            "step \{step}: exact delta operation set diverged",
          )
        }
      } else {
        let expected = decode_itf_set(field(event, "operations"))
        let actual = message_operations(message)
        if !actual.equal(expected) {
          raise Failure::Failure(
            "step \{step}: delta operations expected " +
            "\{describe_set(expected)}, observed \{describe_set(actual)}",
          )
        }
      }
      self.messages[message_id] = message
    }
    "RequestDeltaClaim" => {
      let sender = string_field(event, "sender")
      let claim = @text.Version::from_json_string(version_claim_json(event))
      let message = self.document(sender).sync().export_since(claim)
      let expected = expected_exact_operations(event)
      let actual = message_exact_operations(message)
      if !actual.equal(expected) {
        raise Failure::Failure(
          "step \{step}: external claim delta operation set diverged",
        )
      }
      self.messages[message_id] = message
    }
    "Checkout" => {
      let replica = string_field(event, "receiver")
      let checkpoint_id = string_field(event, "checkpointId")
      let expected = string_field(event, "expectedText")
      let actual = self
        .document(replica)
        .checkout(self.checkpoint(checkpoint_id))
        .text()
      if actual != expected {
        raise Failure::Failure(
          "step \{step}: checkout expected \{expected}, observed \{actual}",
        )
      }
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
  let frontier_field = if replica == "source" {
    "sourceFrontier"
  } else {
    "peerFrontier"
  }
  let identities_field = if replica == "source" {
    "sourceIdentities"
  } else {
    "peerIdentities"
  }
  let frontier_identities_field = if replica == "source" {
    "sourceFrontierIdentities"
  } else {
    "peerFrontierIdentities"
  }
  let text_field = if replica == "source" { "sourceText" } else { "peerText" }
  let pending_field = if replica == "source" {
    "sourcePending"
  } else {
    "peerPending"
  }
  let document = self.document(replica)
  match optional_field(state, identities_field) {
    Some(identity_values) => {
      let expected = decode_itf_identity_set(identity_values)
      let expected_frontier = decode_itf_identity_set(
        field(state, frontier_identities_field),
      )
      let (knowledge, frontier) = exact_version_observation(document.version())
      if !knowledge.equal(expected) {
        raise Failure::Failure(
          "step \{step}: \{replica} exact knowledge diverged",
        )
      }
      if !frontier.equal(expected_frontier) {
        raise Failure::Failure(
          "step \{step}: \{replica} exact frontier diverged",
        )
      }
      let expected_text = string_field(state, text_field)
      if document.text() != expected_text {
        raise Failure::Failure(
          "step \{step}: \{replica} text expected \{expected_text}, " +
          "observed \{document.text()}",
        )
      }
    }
    None => {
      let expected = decode_itf_set(field(state, state_field))
      let expected_frontier = decode_itf_set(field(state, frontier_field))
      if self.broken && replica == "source" {
        expected.remove(2)
      }
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
          "\{describe_set(expected_frontier)}, observed " +
          describe_set(frontier),
        )
      }
      let expected_text = "x".repeat(expected.length())
      if document.text() != expected_text {
        raise Failure::Failure(
          "step \{step}: \{replica} text expected \{expected_text}, " +
          "observed \{document.text()}",
        )
      }
    }
  }
  let expected_pending = int_field(state, pending_field)
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
    self.apply_event(field(state, "lastEvent"), state, step)
    self.assert_replica(state, "source", "sourceKnowledge", step)
    self.assert_replica(state, "peer", "peerKnowledge", step)
  }
}

///|
fn trace_schedule_metadata(
  trace : ItfTrace,
) -> (String, Set[String])? raise Failure {
  guard trace.states is [first, ..] else { return None }
  let state = field(first, "s")
  match
    (
      optional_field(state, "scheduleId"),
      optional_field(state, "requiredScheduleIds"),
    ) {
    (Some(String(id)), Some(required)) =>
      Some((id, decode_itf_string_set(required)))
    (None, None) => None
    _ => raise Failure::Failure("incomplete schedule coverage metadata")
  }
}

///|
fn describe_string_set(values : Set[String]) -> String {
  let sorted = values.to_array()
  sorted.sort()
  @debug.to_string(sorted)
}

///|
async fn main {
  let args = @env.args()
  guard args is [_, .. rest] else {
    raise Failure::Failure("usage: replay TRACE... [--broken]")
  }
  let broken = rest.any(argument => argument == "--broken")
  let trace_paths = rest.filter(argument => argument != "--broken")
  if trace_paths.is_empty() {
    raise Failure::Failure("usage: replay TRACE... [--broken]")
  }
  let observed_schedule_ids : Set[String] = Set([])
  let required_schedule_ids : Set[String] = Set([])
  let mut total_states = 0
  for trace_path in trace_paths {
    let trace : ItfTrace = @json.from_json(
      @json.parse(@fs.read_file(trace_path).text()),
    )
    let driver = Driver(broken)
    driver.replay(trace)
    total_states += trace.states.length()
    match trace_schedule_metadata(trace) {
      Some((id, required)) => {
        observed_schedule_ids.add(id)
        for required_id in required {
          required_schedule_ids.add(required_id)
        }
      }
      None => ()
    }
  }
  if !observed_schedule_ids.equal(required_schedule_ids) {
    raise Failure::Failure(
      "schedule coverage expected " +
      "\{describe_string_set(required_schedule_ids)}, observed " +
      describe_string_set(observed_schedule_ids),
    )
  }
  let coverage = if required_schedule_ids.is_empty() {
    ""
  } else {
    " across \{required_schedule_ids.length()} required schedules"
  }
  println("PASS: \{total_states} ITF states matched public text API" + coverage)
}
