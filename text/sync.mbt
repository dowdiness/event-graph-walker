///| Stable v0.4 synchronization for `TextState`.

///|
/// Façade-specific wire format identifiers.
let text_version_format : String = "event-graph-walker/text-version"

///|
let text_sync_format : String = "event-graph-walker/text-sync"

///|
let text_schema : Int = 2

///|
let text_sync_canonical_domain : Bytes = b"event-graph-walker:text-sync:v2"

///|
fn stable_id_key(replica_id : String, sequence : Int) -> String {
  replica_id.length().to_string() +
  ":" +
  replica_id +
  ":" +
  sequence.to_string()
}

///|
fn raw_key(raw : @core.RawVersion) -> String {
  stable_id_key(raw.agent, raw.seq)
}

///|
fn compare_raw(a : @core.RawVersion, b : @core.RawVersion) -> Int {
  match a.agent.compare(b.agent) {
    0 => a.seq.compare(b.seq)
    other => other
  }
}

///|
fn sorted_raw(values : Array[@core.RawVersion]) -> Array[@core.RawVersion] {
  let result = values.copy()
  result.sort_by(compare_raw)
  result
}

///|
fn option_raw_key(value : @core.RawVersion?) -> String {
  match value {
    Some(raw) => "1:" + raw_key(raw)
    None => "0"
  }
}

///|
/// Collision-safe logical payload key. Local LVs are deliberately omitted.
fn op_payload_key(op : @core.Op) -> String {
  let parents = sorted_raw(op.parents())
  let parent_parts : Array[String] = []
  for parent in parents {
    parent_parts.push(raw_key(parent))
  }
  let content = match op.content() {
    @core.Insert(text) => "i:" + text.length().to_string() + ":" + text
    @core.Delete => "d"
    @core.Undelete => "u"
  }
  content +
  "|p:" +
  parent_parts.join(",") +
  "|l:" +
  option_raw_key(op.origin_left()) +
  "|r:" +
  option_raw_key(op.origin_right())
}

///|
fn op_identity(op : @core.Op) -> @core.RawVersion {
  @core.RawVersion(op.agent(), op.seq())
}

///|
fn op_dependencies(op : @core.Op) -> Array[@core.RawVersion] {
  let deps = op.parents()
  match op.origin_left() {
    Some(raw) => deps.push(raw)
    None => ()
  }
  match op.origin_right() {
    Some(raw) => deps.push(raw)
    None => ()
  }
  let by_key : Map[String, @core.RawVersion] = Map([])
  for dep in deps {
    by_key[raw_key(dep)] = dep
  }
  let result = by_key.values().to_array()
  result.sort_by(compare_raw)
  result
}

///|
fn validate_insert_scalar(text : String) -> Unit raise @sync.Failure {
  let len = text.length()
  if len == 0 {
    raise @sync.Failure::InvalidContent(
      detail="insert content must not be empty",
    )
  }
  let first = text[0].to_int()
  let consumed = if first >= 0xD800 && first <= 0xDBFF {
    if len < 2 {
      raise @sync.Failure::InvalidContent(
        detail="insert content contains malformed UTF-16",
      )
    }
    let second = text[1].to_int()
    if second < 0xDC00 || second > 0xDFFF {
      raise @sync.Failure::InvalidContent(
        detail="insert content contains malformed UTF-16",
      )
    }
    2
  } else if first >= 0xDC00 && first <= 0xDFFF {
    raise @sync.Failure::InvalidContent(
      detail="insert content contains malformed UTF-16",
    )
  } else {
    1
  }
  if consumed != len {
    raise @sync.Failure::InvalidContent(
      detail="insert content must contain exactly one Unicode scalar value",
    )
  }
}

///|
fn is_well_formed_utf16(text : String) -> Bool {
  let mut index = 0
  while index < text.length() {
    let code_unit = text[index].to_int()
    if code_unit >= 0xD800 && code_unit <= 0xDBFF {
      if index + 1 >= text.length() {
        return false
      }
      let low = text[index + 1].to_int()
      if low < 0xDC00 || low > 0xDFFF {
        return false
      }
      index = index + 2
    } else if code_unit >= 0xDC00 && code_unit <= 0xDFFF {
      return false
    } else {
      index = index + 1
    }
  }
  true
}

///|
/// State-independent proof for a text operation.
priv struct StructuralOp {
  op : @core.Op
}

///|
fn StructuralOp::StructuralOp(
  op : @core.Op,
) -> StructuralOp raise @sync.Failure {
  validate_op_structure(op)
  { op, }
}

///|
fn StructuralOp::raw(self : StructuralOp) -> @core.Op {
  self.op
}

///|
fn validate_op_structure(op : @core.Op) -> Unit raise @sync.Failure {
  if op.agent() == "" {
    raise @sync.Failure::MalformedMessage(
      detail="operation replica_id must not be empty",
    )
  }
  if op.seq() < 0 {
    raise @sync.Failure::MalformedMessage(
      detail="operation sequence must not be negative",
    )
  }
  let seen_parents : Map[String, Bool] = Map([])
  for parent in op.parents() {
    if parent.agent == "" || parent.seq < 0 {
      raise @sync.Failure::MalformedMessage(
        detail="operation parent identity is invalid",
      )
    }
    let key = raw_key(parent)
    if key == raw_key(op_identity(op)) || seen_parents.get(key) is Some(_) {
      raise @sync.Failure::MalformedMessage(
        detail="operation contains a self or duplicate parent",
      )
    }
    seen_parents[key] = true
  }
  match op.content() {
    @core.Insert(text) => {
      validate_insert_scalar(text)
      match op.origin_left() {
        Some(origin) =>
          if origin.agent == "" || origin.seq < 0 {
            raise @sync.Failure::MalformedMessage(
              detail="operation origin identity is invalid",
            )
          }
        None => ()
      }
      match op.origin_right() {
        Some(origin) =>
          if origin.agent == "" || origin.seq < 0 {
            raise @sync.Failure::MalformedMessage(
              detail="operation origin identity is invalid",
            )
          }
        None => ()
      }
    }
    @core.Delete | @core.Undelete => {
      if op.origin_left() is None {
        raise @sync.Failure::MalformedMessage(
          detail="delete and undelete operations require a target",
        )
      }
      if op.origin_right() is Some(_) {
        raise @sync.Failure::MalformedMessage(
          detail="delete and undelete operations cannot have a right target",
        )
      }
      match op.origin_left() {
        Some(origin) =>
          if origin.agent == "" || origin.seq < 0 {
            raise @sync.Failure::MalformedMessage(
              detail="operation origin identity is invalid",
            )
          }
        None => ()
      }
    }
  }
}

///|
/// Receiver policy, deliberately checked only while preparing an apply.
fn validate_op_limits(
  op : @core.Op,
  limits : @sync.Limits,
) -> Unit raise @sync.Failure {
  if op.parents().length() > limits.max_parents_per_operation() {
    raise @sync.Failure::LimitExceeded(
      kind=@sync.LimitKind::ParentsPerOperation,
      limit=limits.max_parents_per_operation(),
      actual=op.parents().length(),
    )
  }
}

///|
/// Translate the shared protocol error at the façade boundary.
fn[T] map_sync_failure(
  action : () -> T raise @sync.Failure,
) -> T raise TextError {
  action() catch {
    @sync.Failure::MalformedMessage(detail~) =>
      raise TextError::SyncFailed(@sync.Failure::MalformedMessage(detail~))
    @sync.Failure::InvalidContent(detail~) =>
      raise TextError::SyncFailed(@sync.Failure::InvalidContent(detail~))
    @sync.Failure::MissingDependency(replica_id~, sequence~) =>
      raise TextError::SyncFailed(
        @sync.Failure::MissingDependency(replica_id~, sequence~),
      )
    @sync.Failure::ConflictingIdentity(replica_id~, sequence~) =>
      raise TextError::SyncFailed(
        @sync.Failure::ConflictingIdentity(replica_id~, sequence~),
      )
    @sync.Failure::LimitExceeded(kind~, limit~, actual~) =>
      raise TextError::SyncFailed(
        @sync.Failure::LimitExceeded(kind~, limit~, actual~),
      )
  }
}

///|
/// Sort a batch topologically, breaking ties by stable identity.
fn canonical_order(
  ops : Array[@core.Op],
) -> Array[@core.Op] raise @sync.Failure {
  canonical_order_counted(ops).0
}

///|
/// Dependency-indexed Kahn ordering with a deterministic comparison count.
fn canonical_order_counted(
  ops : Array[@core.Op],
) -> (Array[@core.Op], Int) raise @sync.Failure {
  let candidates : Map[String, @core.Op] = Map([])
  for op in ops {
    let key = raw_key(op_identity(op))
    match candidates.get(key) {
      Some(previous) =>
        if op_payload_key(previous) != op_payload_key(op) {
          let id = op_identity(op)
          raise @sync.Failure::ConflictingIdentity(
            replica_id=id.agent,
            sequence=id.seq,
          )
        }
      None => candidates[key] = op
    }
  }
  let missing_counts : Map[String, Int] = Map([])
  let dependency_waiters : Map[String, Array[String]] = Map([])
  candidates.each(fn(key, op) {
    let mut count = 0
    for dependency in op_dependencies(op) {
      let dependency_key = raw_key(dependency)
      if candidates.get(dependency_key) is Some(_) {
        count = count + 1
        let waiters = dependency_waiters
          .get(dependency_key)
          .unwrap_or([])
          .copy()
        waiters.push(key)
        dependency_waiters[dependency_key] = waiters
      }
    }
    missing_counts[key] = count
  })
  let mut comparisons = 0
  let ready : Array[@core.Op] = []
  candidates.each(fn(key, op) {
    if missing_counts.get(key) == Some(0) {
      ready.push(op)
    }
  })
  ready.sort_by(fn(a, b) {
    comparisons = comparisons + 1
    compare_raw(op_identity(a), op_identity(b))
  })
  let ordered : Array[@core.Op] = []
  let mut ready_index = 0
  while ready_index < ready.length() {
    let next = ready[ready_index]
    ready_index = ready_index + 1
    ordered.push(next)
    let next_key = raw_key(op_identity(next))
    for waiter_key in dependency_waiters.get(next_key).unwrap_or([]) {
      let count = missing_counts.get(waiter_key).unwrap() - 1
      missing_counts[waiter_key] = count
      if count == 0 {
        let waiter = candidates.get(waiter_key).unwrap()
        let mut low = ready_index
        let mut high = ready.length()
        while low < high {
          let middle = low + (high - low) / 2
          comparisons = comparisons + 1
          if compare_raw(op_identity(waiter), op_identity(ready[middle])) < 0 {
            high = middle
          } else {
            low = middle + 1
          }
        }
        ready.insert(low, waiter)
      }
    }
  }
  if ordered.length() != candidates.length() {
    raise @sync.Failure::MalformedMessage(
      detail="operation dependency cycle detected",
    )
  }
  (ordered, comparisons)
}

///|
/// A schema-2 text synchronization message.
pub(all) struct SyncMessage {
  // Raw storage is private; the structural array carries the parse proof.
  priv operations : Array[@core.Op]
  priv structural_operations : Array[StructuralOp]
  priv heads : Array[@core.RawVersion]
  priv encoded_size : Int?
  priv decoded_operation_count : Int
}

///|
/// Validating custom constructor used by decode and export paths.
fn SyncMessage::SyncMessage(
  operations : Array[@core.Op],
  heads : Array[@core.RawVersion],
  encoded_size : Int?,
) -> SyncMessage raise @sync.Failure {
  let structural_operations : Array[StructuralOp] = []
  let structural_by_key : Map[String, StructuralOp] = Map([])
  for op in operations {
    let structural = StructuralOp::StructuralOp(op)
    structural_operations.push(structural)
    structural_by_key[raw_key(op_identity(op))] = structural
  }
  let ordered = canonical_order(operations)
  let ordered_structural : Array[StructuralOp] = []
  for op in ordered {
    ordered_structural.push(
      structural_by_key.get(raw_key(op_identity(op))).unwrap(),
    )
  }
  let seen_heads : Map[String, Bool] = Map([])
  for head in heads {
    if head.agent == "" ||
      head.seq < 0 ||
      seen_heads.get(raw_key(head)) is Some(_) {
      raise @sync.Failure::MalformedMessage(
        detail="message contains an invalid or duplicate head",
      )
    }
    seen_heads[raw_key(head)] = true
  }
  {
    operations: ordered,
    structural_operations: ordered_structural,
    heads: sorted_raw(heads),
    encoded_size,
    decoded_operation_count: operations.length(),
  }
}

///|
pub fn SyncMessage::is_empty(self : SyncMessage) -> Bool {
  self.operations.is_empty()
}

///|
pub fn SyncMessage::op_count(self : SyncMessage) -> Int {
  self.operations.length()
}

///|
/// Result of applying a text synchronization message.
pub(all) struct SyncReport {
  priv applied_operations : Int
  priv duplicate_operations : Int
  priv pending_operations : Int
} derive(Debug, Eq)

///|
pub fn SyncReport::applied_operations(self : SyncReport) -> Int {
  self.applied_operations
}

///|
pub fn SyncReport::duplicate_operations(self : SyncReport) -> Int {
  self.duplicate_operations
}

///|
pub fn SyncReport::pending_operations(self : SyncReport) -> Int {
  self.pending_operations
}

///|
/// A sync session bound to a `TextState`.
pub(all) struct SyncSession {
  priv doc : TextState
  // White-box seam for proving admission-guard ordering; production uses None.
  priv prepare_for_mutation_override : (() -> Unit raise TextError)?
  // White-box seam for counting the single Text-to-Document admission call.
  priv admit_remote_override : ((@document.Document, Array[@core.Op], Int) -> @document.DocumentAdmission raise @document.DocumentError)?
}

///|
fn version_frontier_json(frontier : Array[@core.RawVersion]) -> Json {
  let values : Array[Json] = []
  for raw in frontier {
    values.push(identity_json(raw))
  }
  values.to_json()
}

///|
fn version_ranges_json(ranges : Array[(String, Array[(UInt, UInt)])]) -> Json {
  let values : Array[Json] = []
  for entry in ranges {
    let agent = entry.0
    let entry_ranges = entry.1
    let parts : Array[Json] = []
    for range in entry_ranges {
      parts.push(
        Json::object({ "start": range.0.to_json(), "end": range.1.to_json() }),
      )
    }
    values.push(
      Json::object({ "replica_id": agent.to_json(), "ranges": parts.to_json() }),
    )
  }
  values.to_json()
}

///|
pub fn Version::to_json_string(self : Version) -> String {
  Json::object({
    "schema": text_schema.to_json(),
    "format": text_version_format.to_json(),
    "frontier": version_frontier_json(self.graph_version.frontier()),
    "ranges": version_ranges_json(self.graph_version.ranges()),
  }).stringify()
}

///|
fn exact_object_fields(
  object : Map[String, Json],
  expected : Array[String],
) -> Bool {
  if object.length() != expected.length() {
    return false
  }
  for key in object.keys() {
    let mut found = false
    for allowed in expected {
      if key == allowed {
        found = true
      }
    }
    if !found {
      return false
    }
  }
  true
}

///|
/// Typed wire representations used only after the strict exact-field gate.
///
/// Derived `FromJson` intentionally handles field type conversion, while the
/// surrounding decoders retain responsibility for rejecting unknown fields
/// and enforcing protocol semantics and resource limits.
priv struct WireIdentity {
  replica_id : String
  sequence : Int
} derive(FromJson)

///|
priv struct WireVersionEnvelope {
  schema : Int
  format : String
  frontier : Array[Json]
  ranges : Array[Json]
} derive(FromJson)

///|
priv struct WireOperation {
  id : Json
  parents : Array[Json]
  kind : String
  content : Json
  origin_left : Json
  origin_right : Json
} derive(FromJson)

///|
priv struct WireSyncEnvelope {
  schema : Int
  format : String
  operations : Array[Json]
  heads : Array[Json]
} derive(FromJson)

///|
fn decode_identity(json : Json) -> @core.RawVersion raise {
  let object = match json {
    Json::Object(value) => value
    _ => fail("identity must be an object")
  }
  guard exact_object_fields(object, ["replica_id", "sequence"]) else {
    fail("identity contains missing or unknown fields")
  }
  let wire : WireIdentity = @json.from_json(json)
  guard wire.replica_id != "" && wire.sequence >= 0 else {
    fail("identity is invalid")
  }
  @core.RawVersion(wire.replica_id, wire.sequence)
}

///|
pub fn Version::from_json_string(json_str : String) -> Version raise TextError {
  if !is_well_formed_utf16(json_str) {
    raise TextError::SyncFailed(
      @sync.Failure::MalformedMessage(detail="invalid text version JSON"),
    )
  }
  if @utf8.encode(json_str).length() >
    @sync.Limits::default().max_encoded_bytes() {
    raise TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=@sync.Limits::default().max_encoded_bytes(),
        actual=@utf8.encode(json_str).length(),
      ),
    )
  }
  try {
    let root = @json.parse(json_str)
    let object = match root {
      Json::Object(value) => value
      _ => fail("version envelope must be an object")
    }
    guard exact_object_fields(object, ["schema", "format", "frontier", "ranges"]) else {
      fail("version envelope contains missing or unknown fields")
    }
    let envelope : WireVersionEnvelope = @json.from_json(root)
    guard envelope.schema == text_schema &&
      envelope.format == text_version_format else {
      fail("unsupported version envelope")
    }
    let frontier : Array[@core.RawVersion] = []
    for value in envelope.frontier {
      frontier.push(decode_identity(value))
    }
    let ranges : Array[(String, Array[(UInt, UInt)])] = []
    for value in envelope.ranges {
      let obj = match value {
        Json::Object(fields) => fields
        _ => fail("range entry must be an object")
      }
      guard exact_object_fields(obj, ["replica_id", "ranges"]) else {
        fail("range entry contains missing or unknown fields")
      }
      let agent : String = @json.from_json(obj["replica_id"])
      let encoded_ranges : Array[Json] = @json.from_json(obj["ranges"])
      let agent_ranges : Array[(UInt, UInt)] = []
      for value in encoded_ranges {
        let fields = match value {
          Json::Object(fields) => fields
          _ => fail("range must be an object")
        }
        guard exact_object_fields(fields, ["start", "end"]) else {
          fail("range contains missing or unknown fields")
        }
        let start : UInt = @json.from_json(fields["start"])
        let end : UInt = @json.from_json(fields["end"])
        agent_ranges.push((start, end))
      }
      ranges.push((agent, agent_ranges))
    }
    Version::from_graph_version(
      @causal_graph.GraphVersion::from_parts(frontier, ranges) catch {
        _ => fail("invalid version")
      },
    )
  } catch {
    _ =>
      raise TextError::SyncFailed(
        @sync.Failure::MalformedMessage(detail="invalid text version JSON"),
      )
  }
}

///|
fn identity_json(raw : @core.RawVersion) -> Json {
  Json::object({
    "replica_id": raw.agent.to_json(),
    "sequence": raw.seq.to_json(),
  })
}

///|
fn optional_identity_json(raw : @core.RawVersion?) -> Json {
  match raw {
    Some(value) => identity_json(value)
    None => Json::null()
  }
}

///|
fn op_json(op : @core.Op) -> Json {
  let parents : Array[Json] = []
  for parent in sorted_raw(op.parents()) {
    parents.push(identity_json(parent))
  }
  let (kind, content) = match op.content() {
    @core.Insert(text) => ("insert", text.to_json())
    @core.Delete => ("delete", Json::null())
    @core.Undelete => ("undelete", Json::null())
  }
  Json::object({
    "id": identity_json(op_identity(op)),
    "parents": parents.to_json(),
    "kind": kind.to_json(),
    "content": content,
    "origin_left": optional_identity_json(op.origin_left()),
    "origin_right": optional_identity_json(op.origin_right()),
  })
}

///|
pub fn SyncMessage::to_json_string(self : SyncMessage) -> String {
  let operations : Array[Json] = []
  for op in self.structural_operations {
    operations.push(op_json(op.raw()))
  }
  let heads : Array[Json] = []
  for head in self.heads {
    heads.push(identity_json(head))
  }
  Json::object({
    "schema": text_schema.to_json(),
    "format": text_sync_format.to_json(),
    "operations": operations.to_json(),
    "heads": heads.to_json(),
  }).stringify()
}

///|
fn decode_optional_identity(json : Json) -> @core.RawVersion? raise {
  match json {
    Json::Null => None
    value => Some(decode_identity(value))
  }
}

///|
fn decode_op(json : Json) -> @core.Op raise {
  let object = match json {
    Json::Object(value) => value
    _ => fail("operation must be an object")
  }
  guard exact_object_fields(object, [
    "id", "parents", "kind", "content", "origin_left", "origin_right",
  ]) else {
    fail("operation contains missing or unknown fields")
  }
  let wire : WireOperation = @json.from_json(json)
  let id = decode_identity(wire.id)
  let parents : Array[@core.RawVersion] = []
  let seen_parents : Map[String, Bool] = Map([])
  for value in wire.parents {
    let parent = decode_identity(value)
    guard seen_parents.get(raw_key(parent)) is None else {
      fail("duplicate parent")
    }
    seen_parents[raw_key(parent)] = true
    parents.push(parent)
  }
  let origin_left = decode_optional_identity(wire.origin_left)
  let origin_right = decode_optional_identity(wire.origin_right)
  match wire.kind {
    "insert" => {
      let content : String = @json.from_json(wire.content)
      @core.Op::insert(
        0,
        parents,
        id.agent,
        id.seq,
        content,
        origin_left,
        origin_right,
      )
    }
    "delete" => {
      guard wire.content is Json::Null && origin_right is None else {
        fail("delete fields are invalid")
      }
      @core.Op::delete(0, parents, id.agent, id.seq, origin_left)
    }
    "undelete" => {
      guard wire.content is Json::Null && origin_right is None else {
        fail("undelete fields are invalid")
      }
      @core.Op::undelete(0, parents, id.agent, id.seq, origin_left)
    }
    _ => fail("unknown operation kind")
  }
}

///|
fn decode_sync_json(
  json_str : String,
  _limits : @sync.Limits,
) -> SyncMessage raise TextError {
  if !is_well_formed_utf16(json_str) {
    raise TextError::SyncFailed(
      @sync.Failure::MalformedMessage(detail="invalid text sync JSON"),
    )
  }
  let encoded_size = @utf8.encode(json_str).length()
  try {
    let root = @json.parse(json_str)
    let object = match root {
      Json::Object(value) => value
      _ => fail("sync envelope must be an object")
    }
    guard exact_object_fields(object, [
      "schema", "format", "operations", "heads",
    ]) else {
      fail("sync envelope contains missing or unknown fields")
    }
    let envelope : WireSyncEnvelope = @json.from_json(root)
    guard envelope.schema == text_schema && envelope.format == text_sync_format else {
      fail("unsupported sync envelope")
    }
    let operations : Array[@core.Op] = []
    for value in envelope.operations {
      operations.push(decode_op(value))
    }
    let heads : Array[@core.RawVersion] = []
    for value in envelope.heads {
      heads.push(decode_identity(value))
    }
    SyncMessage::SyncMessage(operations, heads, Some(encoded_size))
  } catch {
    @sync.Failure::MalformedMessage(detail~) =>
      raise TextError::SyncFailed(@sync.Failure::MalformedMessage(detail~))
    @sync.Failure::InvalidContent(detail~) =>
      raise TextError::SyncFailed(@sync.Failure::InvalidContent(detail~))
    @sync.Failure::MissingDependency(replica_id~, sequence~) =>
      raise TextError::SyncFailed(
        @sync.Failure::MissingDependency(replica_id~, sequence~),
      )
    @sync.Failure::ConflictingIdentity(replica_id~, sequence~) =>
      raise TextError::SyncFailed(
        @sync.Failure::ConflictingIdentity(replica_id~, sequence~),
      )
    @sync.Failure::LimitExceeded(kind~, limit~, actual~) =>
      raise TextError::SyncFailed(
        @sync.Failure::LimitExceeded(kind~, limit~, actual~),
      )
    _ =>
      raise TextError::SyncFailed(
        @sync.Failure::MalformedMessage(detail="invalid text sync JSON"),
      )
  }
}

///|
/// Decode a synchronization message and establish structural proofs.
///
/// Resource limits are receiver policy and are enforced by `apply`, not by
/// this structural decoder.
pub fn SyncMessage::from_json_string(
  json_str : String,
) -> SyncMessage raise TextError {
  decode_sync_json(json_str, @sync.Limits::default())
}

///|
fn current_heads(doc : TextState) -> Array[@core.RawVersion] raise TextError {
  doc.inner.get_frontier_raw() catch {
    error => raise TextError::from_document_error(error, () => doc.len())
  }
}

///|
/// Decode synchronization JSON structurally. Receiver limits are enforced
/// atomically by `apply`.
pub fn SyncSession::decode_json(
  _self : SyncSession,
  json_str : String,
) -> SyncMessage raise TextError {
  decode_sync_json(json_str, @sync.Limits::default())
}

///|
pub fn SyncSession::export_all(
  self : SyncSession,
) -> SyncMessage raise TextError {
  let heads = current_heads(self.doc)
  map_sync_failure(fn() raise @sync.Failure {
    SyncMessage::SyncMessage(self.doc.inner.get_all_ops(), heads, None)
  })
}

///|
pub fn SyncSession::export_since(
  self : SyncSession,
  peer_version : Version,
) -> SyncMessage raise TextError {
  let operations : Array[@core.Op] = []
  for op in self.doc.inner.get_all_ops() {
    if !peer_version.graph().contains(@core.RawVersion(op.agent(), op.seq())) {
      operations.push(op)
    }
  }
  let heads = current_heads(self.doc)
  map_sync_failure(fn() raise @sync.Failure {
    SyncMessage::SyncMessage(operations, heads, None)
  })
}

///|
/// Validate receiver policy at the wire-facing Text boundary. Causal
/// applicability and pending ownership belong to Document/OpLog.
fn validate_message_limits(
  message : SyncMessage,
  limits : @sync.Limits,
) -> Unit raise @sync.Failure {
  let encoded_size = match message.encoded_size {
    Some(size) => size
    None => @utf8.encode(message.to_json_string()).length()
  }
  if encoded_size > limits.max_encoded_bytes() {
    raise @sync.Failure::LimitExceeded(
      kind=@sync.LimitKind::EncodedBytes,
      limit=limits.max_encoded_bytes(),
      actual=encoded_size,
    )
  }
  if message.decoded_operation_count > limits.max_decoded_operations() {
    raise @sync.Failure::LimitExceeded(
      kind=@sync.LimitKind::DecodedOperations,
      limit=limits.max_decoded_operations(),
      actual=message.decoded_operation_count,
    )
  }
  for structural in message.structural_operations {
    validate_op_limits(structural.raw(), limits)
  }
}

///|
/// Run the Document-owned recovery transition before sync preflight.
fn SyncSession::prepare_for_admission(
  self : SyncSession,
) -> Unit raise TextError {
  match self.prepare_for_mutation_override {
    Some(prepare) => prepare()
    None => self.doc.prepare_for_mutation()
  }
}

///|
fn SyncSession::admit_remote(
  self : SyncSession,
  operations : Array[@core.Op],
  max_pending_after_complete : Int,
) -> @document.DocumentAdmission raise @document.DocumentError {
  match self.admit_remote_override {
    Some(admit) => admit(self.doc.inner, operations, max_pending_after_complete)
    None => self.doc.inner.admit_remote(operations, max_pending_after_complete~)
  }
}

///|
/// Apply one canonical message and retain its authority-owned settlement.
pub fn SyncSession::apply_transition_with_limits(
  self : SyncSession,
  message : SyncMessage,
  limits : @sync.Limits,
) -> TextAdmissionTransition raise TextError {
  let version_before = self.doc.transition_version()
  self.prepare_for_admission()
  map_sync_failure(fn() raise @sync.Failure {
    validate_message_limits(message, limits)
  })
  let admission = self.admit_remote(
    message.operations.copy(),
    limits.max_pending_operations(),
  ) catch {
    error => raise TextError::from_document_error(error, () => self.doc.len())
  }
  let outcome = admission.outcome
  let projection = admission.projection
  let effects : Array[TextEffect] = []
  let availability = match admission.effect_availability {
    @document.ProjectionEffectAvailability::Exact(projected) => {
      for effect in projected {
        match effect {
          @document.ProjectionEffect::Insert(position~, text~) =>
            effects.push(TextEffect::Insert(Pos::at(position), text))
          @document.ProjectionEffect::Delete(start~, end~) =>
            effects.push(TextEffect::Delete(Range::from_ints(start, end)))
        }
      }
      TextEffectAvailability::Exact(effects[:])
    }
    @document.ProjectionEffectAvailability::SnapshotRequired =>
      TextEffectAvailability::SnapshotRequired
    @document.ProjectionEffectAvailability::Unavailable =>
      TextEffectAvailability::Unavailable
  }
  let result : Result[SyncReport, TextError] = match projection {
    @document.ProjectionStatus::RecoveryRequired(..) =>
      Err(TextError::ProjectionRecoveryRequired)
    @document.ProjectionStatus::Skipped
    | @document.ProjectionStatus::Projected
    | @document.ProjectionStatus::Recovered =>
      match outcome {
        @oplog.AdmissionOutcome::Complete(receipt) =>
          Ok({
            applied_operations: receipt.committed().length(),
            duplicate_operations: receipt.redelivery_count(),
            pending_operations: receipt.pending_after_count(),
          })
        @oplog.AdmissionOutcome::Partial(receipt~, error~) => {
          let _ = receipt
          Err(
            TextError::from_oplog_error(
              @oplog.OpLogError::CausalGraphError(error~),
            ),
          )
        }
      }
  }
  TextAdmissionTransition::new(
    version_before,
    self.doc.transition_version(),
    effects,
    availability,
    result,
  )
}

///|
/// Apply one canonical message through the Document-owned authority boundary.
pub fn SyncSession::apply_with_limits(
  self : SyncSession,
  message : SyncMessage,
  limits : @sync.Limits,
) -> SyncReport raise TextError {
  self.apply_transition_with_limits(message, limits).finish()
}

///|
/// Apply a message and retain its authority-owned settlement.
pub fn SyncSession::apply_transition(
  self : SyncSession,
  message : SyncMessage,
) -> TextAdmissionTransition raise TextError {
  self.apply_transition_with_limits(message, self.doc.sync_limits)
}

///|
/// Apply a message using the limits configured when the document was created.
pub fn SyncSession::apply(
  self : SyncSession,
  message : SyncMessage,
) -> SyncReport raise TextError {
  self.apply_with_limits(message, self.doc.sync_limits)
}

///|
pub fn SyncSession::current_version(self : SyncSession) -> Version {
  self.doc.version()
}

///|
pub fn SyncSession::pending_sync_count(self : SyncSession) -> Int {
  self.doc.inner.pending_count()
}

///|
pub fn SyncSession::clear_pending_sync(self : SyncSession) -> Unit {
  self.doc.inner.clear_pending()
}

///|
/// Private canonical byte helpers.
fn write_uvarint(buf : Buffer, value : Int) -> Unit {
  let mut remaining = value
  while remaining >= 0x80 {
    buf.write_byte(((remaining & 0x7F) | 0x80).to_byte())
    remaining = remaining >> 7
  }
  buf.write_byte(remaining.to_byte())
}

///|
fn write_string_utf8(buf : Buffer, value : String) -> Unit {
  let bytes = @utf8.encode(value)
  write_uvarint(buf, bytes.length())
  buf.write_bytes(bytes)
}

///|
fn write_raw(buf : Buffer, raw : @core.RawVersion) -> Unit {
  write_string_utf8(buf, raw.agent)
  write_uvarint(buf, raw.seq)
}

///|
fn write_optional_raw(buf : Buffer, raw : @core.RawVersion?) -> Unit {
  match raw {
    Some(value) => {
      buf.write_byte(b'\x01')
      write_raw(buf, value)
    }
    None => buf.write_byte(b'\x00')
  }
}

///|
/// Domain-separated canonical logical bytes for hashing and signing.
pub fn SyncMessage::to_canonical_bytes(self : SyncMessage) -> Bytes {
  let buffer = Buffer()
  buffer.write_bytes(text_sync_canonical_domain)
  write_uvarint(buffer, self.operations.length())
  for structural in self.structural_operations {
    let op = structural.raw()
    write_raw(buffer, op_identity(op))
    let parents = sorted_raw(op.parents())
    write_uvarint(buffer, parents.length())
    for parent in parents {
      write_raw(buffer, parent)
    }
    match op.content() {
      @core.Insert(text) => {
        buffer.write_byte(b'\x00')
        write_string_utf8(buffer, text)
      }
      @core.Delete => buffer.write_byte(b'\x01')
      @core.Undelete => buffer.write_byte(b'\x02')
    }
    write_optional_raw(buffer, op.origin_left())
    write_optional_raw(buffer, op.origin_right())
  }
  write_uvarint(buffer, self.heads.length())
  for head in self.heads {
    write_raw(buffer, head)
  }
  buffer.to_bytes()
}
