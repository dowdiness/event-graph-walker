///| Stable v0.4 synchronization for `TextState`.

///|
/// Façade-specific wire format identifiers.
let text_version_format : String = "event-graph-walker/text-version"

///|
let text_sync_format : String = "event-graph-walker/text-sync"

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
  @core.RawVersion::new(op.agent(), op.seq())
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
  if op.seq() > 0 {
    deps.push(@core.RawVersion::new(op.agent(), op.seq() - 1))
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
/// Return whether `target` is reachable through the declared causal parents.
///
/// Origins and the implicit replica predecessor are deliberately excluded:
/// they constrain applicability, but only `parents` define graph ancestry.
fn parents_reach_identity(
  parents : Array[@core.RawVersion],
  target : @core.RawVersion,
  known_ops : Map[String, @core.Op],
) -> Bool {
  let queue = parents.copy()
  let visited : Map[String, Bool] = Map([])
  let target_key = raw_key(target)
  let mut index = 0
  while index < queue.length() {
    let current = queue[index]
    index = index + 1
    let current_key = raw_key(current)
    if current_key == target_key {
      return true
    }
    if visited.get(current_key) is None {
      visited[current_key] = true
      match known_ops.get(current_key) {
        Some(parent_op) =>
          for ancestor in parent_op.parents() {
            queue.push(ancestor)
          }
        None => ()
      }
    }
  }
  false
}

///|
/// Require every non-initial replica operation to causally descend from its
/// predecessor, not merely wait for that predecessor to exist.
fn validate_sequence_descent(
  op : @core.Op,
  known_ops : Map[String, @core.Op],
) -> Unit raise @sync.Failure {
  if op.seq() == 0 {
    return
  }
  let predecessor = @core.RawVersion::new(op.agent(), op.seq() - 1)
  if !parents_reach_identity(op.parents(), predecessor, known_ops) {
    raise @sync.Failure::MalformedMessage(
      detail="operation does not causally descend from its replica predecessor",
    )
  }
}

///|
/// Require every Fugue origin to identify an Insert operation.
///
/// Dependency resolution only proves that an origin exists in the causal
/// graph. Delete and Undelete operations also have stable identities, but they
/// do not create Fugue items and therefore cannot be valid insertion anchors or
/// delete targets. Reject them during preflight so the commit shell cannot
/// mutate the oplog and then fail while updating the Fugue tree.
fn validate_origin_targets(
  op : @core.Op,
  known_ops : Map[String, @core.Op],
) -> Unit raise @sync.Failure {
  fn require_insert(
    origin : @core.RawVersion?,
    known_ops : Map[String, @core.Op],
  ) -> Unit raise @sync.Failure {
    match origin {
      None => ()
      Some(raw) =>
        match known_ops.get(raw_key(raw)) {
          Some(target) =>
            match target.content() {
              @core.Insert(_) => ()
              @core.Delete | @core.Undelete =>
                raise @sync.Failure::MalformedMessage(
                  detail="operation origin must identify an insert operation",
                )
            }
          None =>
            raise @sync.Failure::MissingDependency(
              replica_id=raw.agent,
              sequence=raw.seq,
            )
        }
    }
  }

  require_insert(op.origin_left(), known_ops)
  require_insert(op.origin_right(), known_ops)
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
fn validate_op(
  op : @core.Op,
  limits : @sync.Limits,
) -> Unit raise @sync.Failure {
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
  if op.parents().length() > limits.max_parents_per_operation() {
    raise @sync.Failure::LimitExceeded(
      kind=@sync.LimitKind::ParentsPerOperation,
      limit=limits.max_parents_per_operation(),
      actual=op.parents().length(),
    )
  }
  for parent in op.parents() {
    if parent.agent == "" || parent.seq < 0 {
      raise @sync.Failure::MalformedMessage(
        detail="operation parent identity is invalid",
      )
    }
  }
  match op.content() {
    @core.Insert(text) => validate_insert_scalar(text)
    @core.Delete | @core.Undelete =>
      if op.origin_left() is None {
        raise @sync.Failure::MalformedMessage(
          detail="delete and undelete operations require a target",
        )
      }
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
/// A version-1 text synchronization message.
pub(all) struct SyncMessage {
  priv operations : Array[@core.Op]
  priv heads : Array[@core.RawVersion]
  priv encoded_size : Int?
}

///|
/// Validating custom constructor used by decode and export paths.
fn SyncMessage::SyncMessage(
  operations : Array[@core.Op],
  heads : Array[@core.RawVersion],
  encoded_size : Int?,
  limits? : @sync.Limits = @sync.Limits::default(),
) -> SyncMessage raise @sync.Failure {
  if operations.length() > limits.max_decoded_operations() {
    raise @sync.Failure::LimitExceeded(
      kind=@sync.LimitKind::DecodedOperations,
      limit=limits.max_decoded_operations(),
      actual=operations.length(),
    )
  }
  for op in operations {
    validate_op(op, limits)
  }
  let ordered = canonical_order(operations)
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
  { operations: ordered, heads: sorted_raw(heads), encoded_size }
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
/// An operation parsed for the receiver's current causal context.
///
/// The raw operation stays behind this private wrapper so the commit shell
/// cannot accidentally consume an operation that has only passed wire-level
/// decoding. Construction also proves replica sequence ancestry and that every
/// Fugue origin names an Insert operation.
priv struct ApplicableOp {
  op : @core.Op
}

///|
/// Provenance of an operation considered during synchronization preparation.
///
/// A malformed operation seen only in the current message rejects that
/// message. A previously deferred operation retains that provenance even when
/// resent, and is discarded once its dependencies make the malformation
/// decidable, preventing one pending record from poisoning later attempts.
priv enum SyncCandidate {
  FromPending(@core.Op)
  FromMessage(@core.Op)
  FromPendingAndMessage(@core.Op)
}

///|
fn SyncCandidate::raw(self : SyncCandidate) -> @core.Op {
  match self {
    FromPending(op) | FromMessage(op) | FromPendingAndMessage(op) => op
  }
}

///|
/// Record an identical observation from the current message without losing
/// whether the operation was already present in the pending queue.
fn SyncCandidate::observe_message(
  self : SyncCandidate,
  op : @core.Op,
) -> SyncCandidate {
  match self {
    FromPending(_) | FromPendingAndMessage(_) => FromPendingAndMessage(op)
    FromMessage(_) => FromMessage(op)
  }
}

///|
/// Parse a dependency-resolved operation into the representation accepted by
/// the commit shell.
fn ApplicableOp::ApplicableOp(
  op : @core.Op,
  known_ops : Map[String, @core.Op],
) -> ApplicableOp raise @sync.Failure {
  validate_sequence_descent(op, known_ops)
  validate_origin_targets(op, known_ops)
  { op, }
}

///|
fn ApplicableOp::raw(self : ApplicableOp) -> @core.Op {
  self.op
}

///|
/// The receiver-specific result of parsing one synchronization candidate.
///
/// This sum type preserves the dependency decision instead of collapsing it to
/// a Boolean. Only `Apply` can carry an `ApplicableOp`; `Defer` retains the
/// decoded operation for the bounded pending queue.
priv enum ParsedCandidate {
  Apply(ApplicableOp)
  Defer(@core.Op)
  DiscardInvalidPending
}

///|
/// Parse one canonically ordered candidate against the receiver snapshot and
/// operations already proved applicable earlier in the same transition.
fn parse_candidate(
  op : @core.Op,
  local_payloads : Map[String, String],
  resolved : Map[String, Unit],
  known_ops : Map[String, @core.Op],
) -> ParsedCandidate raise @sync.Failure {
  for dependency in op_dependencies(op) {
    let key = raw_key(dependency)
    if local_payloads.get(key) is None && resolved.get(key) is None {
      return Defer(op)
    }
  }
  Apply(ApplicableOp::ApplicableOp(op, known_ops))
}

///|
/// Parse a candidate according to its provenance.
///
/// New current-message failures remain atomic message failures. A pending
/// record that only becomes provably malformed after its dependencies arrive
/// is discarded from the next prepared queue, including when the peer resends
/// it, while valid current-message operations remain applicable.
fn parse_sync_candidate(
  candidate : SyncCandidate,
  local_payloads : Map[String, String],
  resolved : Map[String, Unit],
  known_ops : Map[String, @core.Op],
) -> ParsedCandidate raise @sync.Failure {
  match candidate {
    FromMessage(op) => parse_candidate(op, local_payloads, resolved, known_ops)
    FromPending(op) | FromPendingAndMessage(op) =>
      parse_candidate(op, local_payloads, resolved, known_ops) catch {
        _ => DiscardInvalidPending
      }
  }
}

///|
/// A fully parsed, receiver-specific synchronization transition.
///
/// This type is private so the imperative commit shell can only receive plans
/// produced by `prepare_sync`. Its operations have passed identity, resource,
/// dependency, causal-ancestry, and Fugue-origin checks.
priv struct PreparedSync {
  applicable : Array[ApplicableOp]
  pending : Array[@core.Op]
  duplicate_operations : Int
}

///|
/// Derive the public report from the parsed transition without observing or
/// mutating document state.
fn PreparedSync::report(self : PreparedSync) -> SyncReport {
  {
    applied_operations: self.applicable.length(),
    duplicate_operations: self.duplicate_operations,
    pending_operations: self.pending.length(),
  }
}

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
}

///|
fn version_entries_json(entries : Array[VersionEntry]) -> Json {
  let values : Array[Json] = []
  for entry in entries {
    values.push(
      Json::object({
        "replica_id": entry.replica_id.to_json(),
        "sequence": entry.sequence.to_json(),
      }),
    )
  }
  values.to_json()
}

///|
pub fn Version::to_json_string(self : Version) -> String {
  Json::object({
    "schema": (1).to_json(),
    "format": text_version_format.to_json(),
    "entries": version_entries_json(self.entries),
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
  entries : Array[Json]
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
  @core.RawVersion::new(wire.replica_id, wire.sequence)
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
    guard exact_object_fields(object, ["schema", "format", "entries"]) else {
      fail("version envelope contains missing or unknown fields")
    }
    let envelope : WireVersionEnvelope = @json.from_json(root)
    guard envelope.schema == 1 && envelope.format == text_version_format else {
      fail("unsupported version envelope")
    }
    let entries : Array[VersionEntry] = []
    let seen : Map[String, Bool] = Map([])
    for value in envelope.entries {
      let raw = decode_identity(value)
      guard seen.get(raw.agent) is None else { fail("duplicate version entry") }
      seen[raw.agent] = true
      entries.push({ replica_id: raw.agent, sequence: raw.seq })
    }
    entries.sort_by(fn(a, b) { a.replica_id.compare(b.replica_id) })
    Version(entries)
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
  for op in self.operations {
    operations.push(op_json(op))
  }
  let heads : Array[Json] = []
  for head in self.heads {
    heads.push(identity_json(head))
  }
  Json::object({
    "schema": (1).to_json(),
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
      @core.Op::new_insert(
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
      @core.Op::new_delete(0, parents, id.agent, id.seq, origin_left)
    }
    "undelete" => {
      guard wire.content is Json::Null && origin_right is None else {
        fail("undelete fields are invalid")
      }
      @core.Op::new_undelete(0, parents, id.agent, id.seq, origin_left)
    }
    _ => fail("unknown operation kind")
  }
}

///|
fn decode_sync_json(
  json_str : String,
  limits : @sync.Limits,
) -> SyncMessage raise TextError {
  if !is_well_formed_utf16(json_str) {
    raise TextError::SyncFailed(
      @sync.Failure::MalformedMessage(detail="invalid text sync JSON"),
    )
  }
  let encoded_size = @utf8.encode(json_str).length()
  if encoded_size > limits.max_encoded_bytes() {
    raise TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=limits.max_encoded_bytes(),
        actual=encoded_size,
      ),
    )
  }
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
    guard envelope.schema == 1 && envelope.format == text_sync_format else {
      fail("unsupported sync envelope")
    }
    guard envelope.operations.length() <= limits.max_decoded_operations() else {
      raise @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::DecodedOperations,
        limit=limits.max_decoded_operations(),
        actual=envelope.operations.length(),
      )
    }
    let operations : Array[@core.Op] = []
    for value in envelope.operations {
      operations.push(decode_op(value))
    }
    let heads : Array[@core.RawVersion] = []
    for value in envelope.heads {
      heads.push(decode_identity(value))
    }
    SyncMessage::SyncMessage(operations, heads, Some(encoded_size), limits~)
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
/// Decode a synchronization message using the default protocol limits.
///
/// Use `TextState::sync().decode_json(...)` when decoding for a receiver with
/// explicitly configured synchronization limits.
pub fn SyncMessage::from_json_string(
  json_str : String,
) -> SyncMessage raise TextError {
  decode_sync_json(json_str, @sync.Limits::default())
}

///|
fn current_heads(doc : TextState) -> Array[@core.RawVersion] raise TextError {
  doc.inner.get_frontier_raw() catch {
    error => raise TextError::from_document_error(error, doc.len())
  }
}

///|
/// Decode synchronization JSON using this receiver's configured limits.
pub fn SyncSession::decode_json(
  self : SyncSession,
  json_str : String,
) -> SyncMessage raise TextError {
  decode_sync_json(json_str, self.doc.sync_limits)
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
    if !peer_version.includes(op.agent(), op.seq()) {
      operations.push(op)
    }
  }
  let heads = current_heads(self.doc)
  map_sync_failure(fn() raise @sync.Failure {
    SyncMessage::SyncMessage(operations, heads, None)
  })
}

///|
fn local_payloads(local_ops : Array[@core.Op]) -> Map[String, String] {
  let result : Map[String, String] = Map([])
  for op in local_ops {
    result[raw_key(op_identity(op))] = op_payload_key(op)
  }
  result
}

///|
/// Parse a message and receiver snapshot into a total commit plan.
///
/// This is the functional core. It does not mutate the document or pending
/// queue, and a failure therefore leaves all receiver state untouched.
fn prepare_sync(
  message : SyncMessage,
  limits : @sync.Limits,
  local_ops : Array[@core.Op],
  pending_records : Array[@core.Op],
) -> PreparedSync raise @sync.Failure {
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
  if message.operations.length() > limits.max_decoded_operations() {
    raise @sync.Failure::LimitExceeded(
      kind=@sync.LimitKind::DecodedOperations,
      limit=limits.max_decoded_operations(),
      actual=message.operations.length(),
    )
  }
  let local_payload_map = local_payloads(local_ops)
  let candidates : Map[String, SyncCandidate] = Map([])
  for pending in pending_records {
    candidates[raw_key(op_identity(pending))] = FromPending(pending)
  }
  let mut duplicates = 0
  for op in message.operations {
    validate_op(op, limits)
    let id = op_identity(op)
    let key = raw_key(id)
    let payload = op_payload_key(op)
    match local_payload_map.get(key) {
      Some(existing) =>
        if existing == payload {
          duplicates = duplicates + 1
        } else {
          raise @sync.Failure::ConflictingIdentity(
            replica_id=id.agent,
            sequence=id.seq,
          )
        }
      None =>
        match candidates.get(key) {
          Some(existing) =>
            if op_payload_key(existing.raw()) == payload {
              duplicates = duplicates + 1
              candidates[key] = existing.observe_message(op)
            } else {
              raise @sync.Failure::ConflictingIdentity(
                replica_id=id.agent,
                sequence=id.seq,
              )
            }
          None => candidates[key] = FromMessage(op)
        }
    }
  }
  let all_candidates : Array[@core.Op] = []
  for candidate in candidates.values() {
    all_candidates.push(candidate.raw())
  }
  let known_ops : Map[String, @core.Op] = Map([])
  for local_op in local_ops {
    known_ops[raw_key(op_identity(local_op))] = local_op
  }
  for candidate in all_candidates {
    known_ops[raw_key(op_identity(candidate))] = candidate
  }
  let ordered = canonical_order(all_candidates)
  let resolved : Map[String, Unit] = Map([])
  let applicable : Array[ApplicableOp] = []
  let pending : Array[@core.Op] = []
  for op in ordered {
    let candidate = candidates.get(raw_key(op_identity(op))).unwrap()
    let parsed = parse_sync_candidate(
      candidate, local_payload_map, resolved, known_ops,
    )
    match parsed {
      Apply(applicable_op) => {
        resolved[raw_key(op_identity(op))] = ()
        applicable.push(applicable_op)
      }
      Defer(pending_op) => pending.push(pending_op)
      DiscardInvalidPending => ()
    }
  }
  if pending.length() > limits.max_pending_operations() {
    raise @sync.Failure::LimitExceeded(
      kind=@sync.LimitKind::PendingOperations,
      limit=limits.max_pending_operations(),
      actual=pending.length(),
    )
  }
  { applicable, pending, duplicate_operations: duplicates }
}

///|
/// Apply a message after parsing it into a receiver-specific commit plan.
pub fn SyncSession::apply(
  self : SyncSession,
  message : SyncMessage,
) -> SyncReport raise TextError {
  let prepared = map_sync_failure(fn() raise @sync.Failure {
    prepare_sync(
      message,
      self.doc.sync_limits,
      self.doc.inner.get_all_ops(),
      self.doc.pending_sync_records.copy(),
    )
  })
  // Imperative shell: PreparedSync is only constructible after complete
  // preflight, so protocol failures cannot occur after the first mutation.
  for parsed_op in prepared.applicable {
    self.doc.inner.apply_remote(parsed_op.raw()) catch {
      error => raise TextError::from_document_error(error, self.doc.len())
    }
  }
  self.doc.pending_sync_records = prepared.pending
  prepared.report()
}

///|
pub fn SyncSession::current_version(self : SyncSession) -> Version {
  self.doc.version()
}

///|
pub fn SyncSession::pending_sync_count(self : SyncSession) -> Int {
  self.doc.pending_sync_records.length()
}

///|
pub fn SyncSession::clear_pending_sync(self : SyncSession) -> Unit {
  self.doc.pending_sync_records = []
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
  buffer.write_bytes(b"event-graph-walker:text-sync:v1")
  write_uvarint(buffer, self.operations.length())
  for op in self.operations {
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
