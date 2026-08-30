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
struct ObservedMessage {
  operations : Set[String]
  heads : Set[ObservedIdentity]
}

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
fn observed_identity_json(identity : ObservedIdentity) -> Json {
  Json::object({
    "replica_id": identity.agent.to_json(),
    "sequence": identity.sequence.to_json(),
  })
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
fn expected_exact_heads(event : Json) -> Set[ObservedIdentity] raise {
  decode_itf_identity_set(field(event, "exactHeads"))
}

///|
fn expected_conflict_identity(event : Json) -> ObservedIdentity raise {
  let value = field(event, "expectedConflictIdentity")
  match string_field(value, "tag") {
    "SomeIdentity" => decode_itf_identity(field(value, "value"))
    "NoIdentity" =>
      raise Failure::Failure("conflict event omitted its expected identity")
    tag => raise Failure::Failure("unknown conflict identity tag \{tag}")
  }
}

///|
fn message_observation(message : @text.SyncMessage) -> ObservedMessage raise {
  let wire : WireSync = @json.from_json(@json.parse(message.to_json_string()))
  if wire.schema != 2 || wire.format != "event-graph-walker/text-sync" {
    raise Failure::Failure("exported message left the schema-2 domain")
  }
  let operations : Set[String] = Set([])
  for operation in wire.operations {
    operations.add(normalized_wire_operation(operation))
  }
  let heads : Set[ObservedIdentity] = Set([])
  for head in wire.heads {
    heads.add({ agent: head.replica_id, sequence: head.sequence })
  }
  let canonical = message.to_canonical_bytes()
  let roundtrip = @text.SyncMessage::from_json_string(message.to_json_string())
  if canonical != roundtrip.to_canonical_bytes() {
    raise Failure::Failure(
      "exported message canonical bytes changed on round-trip",
    )
  }
  { operations, heads }
}

///|
fn assert_message_observation(
  message : @text.SyncMessage,
  event : Json,
  step : Int,
  broken_head : Bool,
) -> Unit raise {
  let expected_operations = expected_exact_operations(event)
  let expected_heads = expected_exact_heads(event)
  if broken_head && string_field(event, "name") == "RequestDelta" {
    expected_heads.remove({ agent: "erin", sequence: 0 })
  }
  let actual = message_observation(message)
  if !actual.operations.equal(expected_operations) {
    raise Failure::Failure("step \{step}: exact message operation set diverged")
  }
  if !actual.heads.equal(expected_heads) {
    raise Failure::Failure("step \{step}: exact message heads diverged")
  }
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
  broken_head : Bool
}

///|
fn Driver::Driver(broken : Bool, broken_head : Bool) -> Driver raise {
  {
    documents: Map([
      ("source", @text.TextState::new("source-replay")),
      ("peer", @text.TextState::new("peer-replay")),
    ]),
    messages: Map([]),
    checkpoints: Map([]),
    broken,
    broken_head,
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
      let message = @text.SyncMessage::from_json_string(
        exact_fixture_json(event),
      )
      assert_message_observation(message, event, step, self.broken_head)
      self.messages[message_id] = message
    }
    "DuplicateMessage" => {
      let new_message_id = string_field(event, "newMessageId")
      self.messages[new_message_id] = self.message(message_id)
    }
    "Deliver" => {
      let receiver = string_field(event, "receiver")
      let expected_outcome = string_field(event, "expectedOutcome")
      let expected_applied = int_field(event, "expectedApplied")
      let expected_duplicate = int_field(event, "expectedDuplicate")
      let expected_pending = int_field(event, "expectedPending")
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
                replica_id=actual_agent,
                sequence=actual_sequence
              )
            )
          ),
        ) => {
          let expected = expected_conflict_identity(event)
          if actual_agent != expected.agent ||
            actual_sequence != expected.sequence {
            raise Failure::Failure(
              "step \{step}: conflicting identity payload diverged",
            )
          }
        }
        ("Conflict", _) =>
          raise Failure::Failure(
            "step \{step}: expected conflicting identity rejection",
          )
        (_, Err(_)) =>
          raise Failure::Failure("step \{step}: unexpected delivery failure")
        (_, Ok(report)) =>
          if report.applied_operations() != expected_applied ||
            report.duplicate_operations() != expected_duplicate ||
            report.pending_operations() != expected_pending {
            raise Failure::Failure(
              "step \{step}: SyncReport expected applied=" +
              "\{expected_applied}, duplicate=\{expected_duplicate}, " +
              "pending=\{expected_pending}; observed applied=" +
              "\{report.applied_operations()}, duplicate=" +
              "\{report.duplicate_operations()}, pending=" +
              "\{report.pending_operations()}",
            )
          }
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
      assert_message_observation(message, event, step, self.broken_head)
      self.messages[message_id] = message
    }
    "RequestDeltaClaim" => {
      let sender = string_field(event, "sender")
      let claim = @text.Version::from_json_string(version_claim_json(event))
      let message = self.document(sender).sync().export_since(claim)
      assert_message_observation(message, event, step, self.broken_head)
      self.messages[message_id] = message
    }
    "RequestAll" => {
      let sender = string_field(event, "sender")
      let message = self.document(sender).sync().export_all()
      assert_message_observation(message, event, step, self.broken_head)
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
  event : Json,
  replica : String,
  step : Int,
) -> Unit raise {
  let knowledge_field = if replica == "source" {
    "sourceKnowledge"
  } else {
    "peerKnowledge"
  }
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
  let expected = decode_itf_identity_set(field(event, knowledge_field))
  let expected_frontier = decode_itf_identity_set(field(event, frontier_field))
  if self.broken && replica == "source" {
    expected.remove({ agent: "erin", sequence: 0 })
  }
  let document = self.document(replica)
  let (knowledge, frontier) = exact_version_observation(document.version())
  if !knowledge.equal(expected) {
    raise Failure::Failure("step \{step}: \{replica} exact knowledge diverged")
  }
  if !frontier.equal(expected_frontier) {
    raise Failure::Failure("step \{step}: \{replica} exact frontier diverged")
  }
  let expected_pending = int_field(event, pending_field)
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
    let event = field(state, "lastEvent")
    self.apply_event(event, step)
    self.assert_replica(event, "source", step)
    self.assert_replica(event, "peer", step)
  }
}

///|
fn trace_schedule_metadata(trace : ItfTrace) -> (Int, Set[Int])? raise Failure {
  guard trace.states is [first, ..] else { return None }
  let state = field(first, "s")
  match
    (
      optional_field(state, "scheduleId"),
      optional_field(state, "requiredScheduleIds"),
    ) {
    (Some(id), Some(required)) => {
      let decoded = decode_itf_set(required)
      if decoded.is_empty() {
        None
      } else {
        Some((decode_itf_int(id), decoded))
      }
    }
    (None, None) => None
    _ => raise Failure::Failure("incomplete schedule coverage metadata")
  }
}

///|
fn describe_schedule_set(values : Set[Int]) -> String {
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
  let broken_head = rest.any(argument => argument == "--broken-head")
  let trace_paths = rest.filter(argument => {
    argument != "--broken" && argument != "--broken-head"
  })
  if trace_paths.is_empty() {
    raise Failure::Failure("usage: replay TRACE... [--broken]")
  }
  let observed_schedule_ids : Set[Int] = Set([])
  let required_schedule_ids : Set[Int] = Set([])
  let mut total_states = 0
  for trace_path in trace_paths {
    let trace : ItfTrace = @json.from_json(
      @json.parse(@fs.read_file(trace_path).text()),
    )
    let driver = Driver(broken, broken_head)
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
      "\{describe_schedule_set(required_schedule_ids)}, observed " +
      describe_schedule_set(observed_schedule_ids),
    )
  }
  let coverage = if required_schedule_ids.is_empty() {
    ""
  } else {
    " across \{required_schedule_ids.length()} required schedules"
  }
  println("PASS: \{total_states} ITF states matched public text API" + coverage)
  println(
    "COVERAGE: observed=\{observed_schedule_ids.length()} " +
    "required=\{required_schedule_ids.length()}",
  )
}
