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
}

///|
/// Validating custom constructor used by decode and export paths.
fn SyncMessage::SyncMessage(
  operations : Array[@core.Op],
  heads : Array[@core.RawVersion],
) -> SyncMessage raise @sync.Failure {
  let limits : @sync.Limits = @sync.Limits::default()
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
  { operations: ordered, heads: sorted_raw(heads) }
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
fn decode_identity(json : Json) -> @core.RawVersion raise {
  let object = match json {
    Json::Object(value) => value
    _ => fail("identity must be an object")
  }
  guard exact_object_fields(object, ["replica_id", "sequence"]) else {
    fail("identity contains missing or unknown fields")
  }
  let replica_id : String = @json.from_json(
    object.get("replica_id").unwrap_or(Json::null()),
  )
  let sequence : Int = @json.from_json(
    object.get("sequence").unwrap_or(Json::null()),
  )
  guard replica_id != "" && sequence >= 0 else { fail("identity is invalid") }
  @core.RawVersion::new(replica_id, sequence)
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
    let schema : Int = @json.from_json(
      object.get("schema").unwrap_or(Json::null()),
    )
    let format : String = @json.from_json(
      object.get("format").unwrap_or(Json::null()),
    )
    guard schema == 1 && format == text_version_format else {
      fail("unsupported version envelope")
    }
    let values : Array[Json] = @json.from_json(
      object.get("entries").unwrap_or(Json::null()),
    )
    let entries : Array[VersionEntry] = []
    let seen : Map[String, Bool] = Map([])
    for value in values {
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
  let id = decode_identity(object.get("id").unwrap_or(Json::null()))
  let parent_values : Array[Json] = @json.from_json(
    object.get("parents").unwrap_or(Json::null()),
  )
  let parents : Array[@core.RawVersion] = []
  let seen_parents : Map[String, Bool] = Map([])
  for value in parent_values {
    let parent = decode_identity(value)
    guard seen_parents.get(raw_key(parent)) is None else {
      fail("duplicate parent")
    }
    seen_parents[raw_key(parent)] = true
    parents.push(parent)
  }
  let kind : String = @json.from_json(
    object.get("kind").unwrap_or(Json::null()),
  )
  let origin_left = decode_optional_identity(
    object.get("origin_left").unwrap_or(Json::null()),
  )
  let origin_right = decode_optional_identity(
    object.get("origin_right").unwrap_or(Json::null()),
  )
  match kind {
    "insert" => {
      let content : String = @json.from_json(
        object.get("content").unwrap_or(Json::null()),
      )
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
      guard object.get("content") is Some(Json::Null) && origin_right is None else {
        fail("delete fields are invalid")
      }
      @core.Op::new_delete(0, parents, id.agent, id.seq, origin_left)
    }
    "undelete" => {
      guard object.get("content") is Some(Json::Null) && origin_right is None else {
        fail("undelete fields are invalid")
      }
      @core.Op::new_undelete(0, parents, id.agent, id.seq, origin_left)
    }
    _ => fail("unknown operation kind")
  }
}

///|
pub fn SyncMessage::from_json_string(
  json_str : String,
) -> SyncMessage raise TextError {
  if !is_well_formed_utf16(json_str) {
    raise TextError::SyncFailed(
      @sync.Failure::MalformedMessage(detail="invalid text sync JSON"),
    )
  }
  let encoded_size = @utf8.encode(json_str).length()
  let limits : @sync.Limits = @sync.Limits::default()
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
    let schema : Int = @json.from_json(
      object.get("schema").unwrap_or(Json::null()),
    )
    let format : String = @json.from_json(
      object.get("format").unwrap_or(Json::null()),
    )
    guard schema == 1 && format == text_sync_format else {
      fail("unsupported sync envelope")
    }
    let operation_values : Array[Json] = @json.from_json(
      object.get("operations").unwrap_or(Json::null()),
    )
    guard operation_values.length() <= limits.max_decoded_operations() else {
      raise @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::DecodedOperations,
        limit=limits.max_decoded_operations(),
        actual=operation_values.length(),
      )
    }
    let operations : Array[@core.Op] = []
    for value in operation_values {
      operations.push(decode_op(value))
    }
    let head_values : Array[Json] = @json.from_json(
      object.get("heads").unwrap_or(Json::null()),
    )
    let heads : Array[@core.RawVersion] = []
    for value in head_values {
      heads.push(decode_identity(value))
    }
    SyncMessage::SyncMessage(operations, heads)
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
fn current_heads(doc : TextState) -> Array[@core.RawVersion] raise TextError {
  doc.inner.get_frontier_raw() catch {
    error => raise TextError::from_document_error(error, doc.len())
  }
}

///|
pub fn SyncSession::export_all(
  self : SyncSession,
) -> SyncMessage raise TextError {
  let heads = current_heads(self.doc)
  map_sync_failure(fn() raise @sync.Failure {
    SyncMessage::SyncMessage(self.doc.inner.get_all_ops(), heads)
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
    SyncMessage::SyncMessage(operations, heads)
  })
}

///|
fn local_payloads(doc : TextState) -> Map[String, String] {
  let result : Map[String, String] = Map([])
  for op in doc.inner.get_all_ops() {
    result[raw_key(op_identity(op))] = op_payload_key(op)
  }
  result
}

///|
/// Apply a message after complete validation and preparation.
pub fn SyncSession::apply(
  self : SyncSession,
  message : SyncMessage,
) -> SyncReport raise TextError {
  let limits = self.doc.sync_limits
  if message.operations.length() > limits.max_decoded_operations() {
    raise TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::DecodedOperations,
        limit=limits.max_decoded_operations(),
        actual=message.operations.length(),
      ),
    )
  }
  let local_payload_map = local_payloads(self.doc)
  let candidates : Map[String, @core.Op] = Map([])
  for pending in self.doc.pending_sync_records {
    candidates[raw_key(op_identity(pending))] = pending
  }
  let mut duplicates = 0
  for op in message.operations {
    map_sync_failure(fn() raise @sync.Failure { validate_op(op, limits) })
    let id = op_identity(op)
    let key = raw_key(id)
    let payload = op_payload_key(op)
    match local_payload_map.get(key) {
      Some(existing) =>
        if existing == payload {
          duplicates = duplicates + 1
        } else {
          raise TextError::SyncFailed(
            @sync.Failure::ConflictingIdentity(
              replica_id=id.agent,
              sequence=id.seq,
            ),
          )
        }
      None =>
        match candidates.get(key) {
          Some(existing) =>
            if op_payload_key(existing) == payload {
              duplicates = duplicates + 1
            } else {
              raise TextError::SyncFailed(
                @sync.Failure::ConflictingIdentity(
                  replica_id=id.agent,
                  sequence=id.seq,
                ),
              )
            }
          None => candidates[key] = op
        }
    }
  }
  let all_candidates = candidates.values().to_array()
  let ordered = map_sync_failure(fn() raise @sync.Failure {
    canonical_order(all_candidates)
  })
  let resolvable : Map[String, Bool] = Map([])
  let applicable : Array[@core.Op] = []
  let pending : Array[@core.Op] = []
  for op in ordered {
    let mut ready = true
    for dep in op_dependencies(op) {
      let key = raw_key(dep)
      if local_payload_map.get(key) is None && resolvable.get(key) != Some(true) {
        ready = false
      }
    }
    if ready {
      resolvable[raw_key(op_identity(op))] = true
      applicable.push(op)
    } else {
      resolvable[raw_key(op_identity(op))] = false
      pending.push(op)
    }
  }
  if pending.length() > limits.max_pending_operations() {
    raise TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::PendingOperations,
        limit=limits.max_pending_operations(),
        actual=pending.length(),
      ),
    )
  }
  // Imperative shell: every expected protocol failure has been handled above.
  for op in applicable {
    self.doc.inner.apply_remote(op) catch {
      error => raise TextError::from_document_error(error, self.doc.len())
    }
  }
  self.doc.pending_sync_records = pending
  let report : SyncReport = {
    applied_operations: applicable.length(),
    duplicate_operations: duplicates,
    pending_operations: pending.length(),
  }
  report
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
