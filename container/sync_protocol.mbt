///| Stable v1 wire protocol for the container façade.

///|
let container_version_format : String = "event-graph-walker/container-version"

///|
let container_sync_format : String = "event-graph-walker/container-sync"

///|
fn sync_raw_key(raw : @core.RawVersion) -> String {
  raw_version_key(raw)
}

///|
fn compare_sync_raw(a : @core.RawVersion, b : @core.RawVersion) -> Int {
  match a.agent.compare(b.agent) {
    0 => a.seq.compare(b.seq)
    other => other
  }
}

///|
fn sorted_sync_raw(values : Array[@core.RawVersion]) -> Array[@core.RawVersion] {
  let result = values.copy()
  result.sort_by(compare_sync_raw)
  result
}

///|
fn sync_record_version(record : SyncOpRecord) -> @core.RawVersion {
  match record {
    Tree(op) => op.version
    Text(op) => op.version
  }
}

///|
fn sync_record_parents(record : SyncOpRecord) -> Array[@core.RawVersion] {
  match record {
    Tree(op) => op.parents.copy()
    Text(op) => op.parents.copy()
  }
}

///|
fn sync_record_key(record : SyncOpRecord) -> String {
  sync_raw_key(sync_record_version(record))
}

///|
fn optional_sync_raw_key(raw : @core.RawVersion?) -> String {
  match raw {
    Some(value) => "1:" + sync_raw_key(value)
    None => "0"
  }
}

///|
fn sync_parents_key(parents : Array[@core.RawVersion]) -> String {
  sorted_sync_raw(parents).map(sync_raw_key).join(",")
}

///|
fn sync_record_payload_key(record : SyncOpRecord) -> String {
  let parent_key = sync_parents_key(sync_record_parents(record))
  match record {
    Tree(versioned) => parent_key + "|" + op_key(versioned.op)
    Text(versioned) => {
      let block = encode_field(internal_node_key(versioned.block))
      let payload = match versioned.op {
        Insert(op) =>
          "insert|" +
          sync_raw_key(op.id) +
          "|" +
          optional_sync_raw_key(op.origin_left) +
          "|" +
          optional_sync_raw_key(op.origin_right) +
          "|" +
          op.timestamp.to_string() +
          "|" +
          encode_field(op.agent) +
          "|" +
          encode_field(op.content)
        Delete(op) =>
          "delete|" +
          sync_raw_key(op.target) +
          "|" +
          op.timestamp.to_string() +
          "|" +
          encode_field(op.agent)
        Undelete(op) =>
          "undelete|" +
          sync_raw_key(op.target) +
          "|" +
          op.timestamp.to_string() +
          "|" +
          encode_field(op.agent)
      }
      parent_key + "|text|" + block + "|" + payload
    }
  }
}

///|
fn sync_record_dependencies(record : SyncOpRecord) -> Array[@core.RawVersion] {
  let id = sync_record_version(record)
  let dependencies = sync_record_parents(record)
  if id.seq > 0 {
    dependencies.push(@core.RawVersion::new(id.agent, id.seq - 1))
  }
  match record {
    Tree(_) => ()
    Text(versioned) =>
      match versioned.op {
        Insert(op) => {
          match op.origin_left {
            Some(origin) => dependencies.push(origin)
            None => ()
          }
          match op.origin_right {
            Some(origin) => dependencies.push(origin)
            None => ()
          }
        }
        Delete(op) => dependencies.push(op.target)
        Undelete(op) => dependencies.push(op.target)
      }
  }
  let unique : Map[String, @core.RawVersion] = Map([])
  for dependency in dependencies {
    unique[sync_raw_key(dependency)] = dependency
  }
  let result = unique.values().to_array()
  result.sort_by(compare_sync_raw)
  result
}

///|
/// Return whether `target` is reachable through the declared causal parents.
///
/// The implicit replica predecessor is deliberately excluded: it constrains
/// applicability, but only `parents` define graph ancestry.
fn sync_parents_reach_identity(
  parents : Array[@core.RawVersion],
  target : @core.RawVersion,
  known_records : Map[String, SyncOpRecord],
) -> Bool {
  let queue = parents.copy()
  let visited : Map[String, Bool] = Map([])
  let target_key = sync_raw_key(target)
  let mut index = 0
  while index < queue.length() {
    let current = queue[index]
    index = index + 1
    let current_key = sync_raw_key(current)
    if current_key == target_key {
      return true
    }
    if visited.get(current_key) is None {
      visited[current_key] = true
      match known_records.get(current_key) {
        Some(parent_record) =>
          for ancestor in sync_record_parents(parent_record) {
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
fn validate_sync_sequence_descent(
  record : SyncOpRecord,
  known_records : Map[String, SyncOpRecord],
) -> Unit raise @sync.Failure {
  let id = sync_record_version(record)
  if id.seq == 0 {
    return
  }
  let predecessor = @core.RawVersion::new(id.agent, id.seq - 1)
  if !sync_parents_reach_identity(
      sync_record_parents(record),
      predecessor,
      known_records,
    ) {
    raise @sync.Failure::MalformedMessage(
      detail="operation does not causally descend from its replica predecessor",
    )
  }
}

///|
/// Require every text item reference to resolve to an Insert in the same block.
///
/// Global causal presence is insufficient because tree operations and inserts
/// in other blocks also have raw identities. This preflight keeps malformed
/// references out of the causal graph and per-block pending queues.
fn validate_sync_text_references(
  record : SyncOpRecord,
  known_records : Map[String, SyncOpRecord],
) -> Unit raise @sync.Failure {
  match record {
    Tree(_) => ()
    Text(versioned) => {
      fn require_same_block_insert(
        reference : @core.RawVersion,
        block : @mt.TreeNodeId,
        known_records : Map[String, SyncOpRecord],
      ) -> Unit raise @sync.Failure {
        match known_records.get(sync_raw_key(reference)) {
          Some(Text(target)) =>
            match target.op {
              Insert(insert) =>
                if target.block == block && insert.id == reference {
                  return
                }
              Delete(_) | Undelete(_) => ()
            }
          Some(Tree(_)) | None => ()
        }
        raise @sync.Failure::InvalidContent(
          detail="text reference does not identify an insert in the target block",
        )
      }
      match versioned.op {
        Insert(insert) => {
          match insert.origin_left {
            Some(origin) =>
              require_same_block_insert(origin, versioned.block, known_records)
            None => ()
          }
          match insert.origin_right {
            Some(origin) =>
              require_same_block_insert(origin, versioned.block, known_records)
            None => ()
          }
        }
        Delete(delete) =>
          require_same_block_insert(
            delete.target,
            versioned.block,
            known_records,
          )
        Undelete(undelete) =>
          require_same_block_insert(
            undelete.target,
            versioned.block,
            known_records,
          )
      }
    }
  }
}

///|
/// Parse a raw record into the only representation accepted by the apply shell.
///
/// The returned type preserves the knowledge gained by the state-aware checks;
/// callers cannot accidentally discard a check and still append the raw record
/// to a `PreparedSync` commit plan.
fn parse_applicable_sync_record(
  record : SyncOpRecord,
  known_records : Map[String, SyncOpRecord],
) -> ApplicableSyncOp raise @sync.Failure {
  validate_sync_sequence_descent(record, known_records)
  validate_sync_text_references(record, known_records)
  match record {
    Tree(op) => ApplyTree(op)
    Text(op) => ApplyText(op)
  }
}

///|
fn sync_record_compare(a : SyncOpRecord, b : SyncOpRecord) -> Int {
  compare_sync_raw(sync_record_version(a), sync_record_version(b))
}

///|
fn canonical_sync_order(
  records : Array[SyncOpRecord],
) -> Array[SyncOpRecord] raise @sync.Failure {
  canonical_sync_order_counted(records).0
}

///|
/// Dependency-indexed Kahn ordering with a deterministic comparison count.
fn canonical_sync_order_counted(
  records : Array[SyncOpRecord],
) -> (Array[SyncOpRecord], Int) raise @sync.Failure {
  let candidates : Map[String, SyncOpRecord] = Map([])
  for record in records {
    let id = sync_record_version(record)
    let key = sync_raw_key(id)
    match candidates.get(key) {
      Some(previous) =>
        if sync_record_payload_key(previous) != sync_record_payload_key(record) {
          raise @sync.Failure::ConflictingIdentity(
            replica_id=id.agent,
            sequence=id.seq,
          )
        }
      None => candidates[key] = record
    }
  }
  let missing_counts : Map[String, Int] = Map([])
  let dependency_waiters : Map[String, Array[String]] = Map([])
  candidates.each(fn(key, record) {
    let mut count = 0
    for dependency in sync_record_dependencies(record) {
      let dependency_key = sync_raw_key(dependency)
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
  let ready : Array[SyncOpRecord] = []
  candidates.each(fn(key, record) {
    if missing_counts.get(key) == Some(0) {
      ready.push(record)
    }
  })
  ready.sort_by(fn(a, b) {
    comparisons = comparisons + 1
    sync_record_compare(a, b)
  })
  let ordered : Array[SyncOpRecord] = []
  let mut ready_index = 0
  while ready_index < ready.length() {
    let next = ready[ready_index]
    ready_index = ready_index + 1
    ordered.push(next)
    let next_key = sync_record_key(next)
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
          if sync_record_compare(waiter, ready[middle]) < 0 {
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
fn validate_sync_identity(
  identity : @core.RawVersion,
) -> Unit raise @sync.Failure {
  if identity.agent == "" || identity.seq < 0 {
    raise @sync.Failure::MalformedMessage(
      detail="operation identity is invalid",
    )
  }
}

///|
fn validate_sync_node(
  node : @mt.TreeNodeId,
  allow_sentinel : Bool,
) -> Unit raise @sync.Failure {
  if node == @mt.root_id || node == @mt.trash_id {
    if allow_sentinel {
      return
    }
    raise @sync.Failure::InvalidContent(
      detail="sentinel node is not valid in this field",
    )
  }
  if node.agent == "" || node.counter < 0 {
    raise @sync.Failure::MalformedMessage(detail="node identity is invalid")
  }
}

///|
fn valid_container_scalar(text : String) -> Bool {
  if text.length() == 1 {
    let value = text[0].to_int()
    return value < 0xD800 || value > 0xDFFF
  }
  if text.length() == 2 {
    let high = text[0].to_int()
    let low = text[1].to_int()
    return high >= 0xD800 && high <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF
  }
  false
}

///|
fn validate_sync_record(
  record : SyncOpRecord,
  limits : @sync.Limits,
) -> Unit raise @sync.Failure {
  let id = sync_record_version(record)
  validate_sync_identity(id)
  let parents = sync_record_parents(record)
  if parents.length() > limits.max_parents_per_operation() {
    raise @sync.Failure::LimitExceeded(
      kind=@sync.LimitKind::ParentsPerOperation,
      limit=limits.max_parents_per_operation(),
      actual=parents.length(),
    )
  }
  let seen_parents : Map[String, Bool] = Map([])
  for parent in parents {
    validate_sync_identity(parent)
    let key = sync_raw_key(parent)
    if key == sync_raw_key(id) || seen_parents.get(key) is Some(_) {
      raise @sync.Failure::MalformedMessage(
        detail="operation contains a self or duplicate parent",
      )
    }
    seen_parents[key] = true
  }
  match record {
    Tree(versioned) =>
      match versioned.op {
        @mt.Move(op) => {
          if op.agent != id.agent || op.timestamp < 0 {
            raise @sync.Failure::ConflictingIdentity(
              replica_id=id.agent,
              sequence=id.seq,
            )
          }
          validate_sync_node(op.target, false)
          validate_sync_node(op.new_parent, true)
          let elements = op.position.elements()
          for element in elements {
            if element < 0 || element >= 65536 {
              raise @sync.Failure::InvalidContent(
                detail="fractional position element is invalid",
              )
            }
          }
        }
        @mt.SetProperty(op) => {
          if op.agent != id.agent || op.timestamp < 0 {
            raise @sync.Failure::ConflictingIdentity(
              replica_id=id.agent,
              sequence=id.seq,
            )
          }
          validate_sync_node(op.target, false)
        }
      }
    Text(versioned) => {
      validate_sync_node(versioned.block, false)
      match versioned.op {
        Insert(op) => {
          validate_sync_identity(op.id)
          if op.id != id || op.agent != id.agent || op.timestamp < 0 {
            raise @sync.Failure::ConflictingIdentity(
              replica_id=id.agent,
              sequence=id.seq,
            )
          }
          if !valid_container_scalar(op.content) {
            raise @sync.Failure::InvalidContent(
              detail="text insert must contain one Unicode scalar value",
            )
          }
          match op.origin_left {
            Some(origin) => validate_sync_identity(origin)
            None => ()
          }
          match op.origin_right {
            Some(origin) => validate_sync_identity(origin)
            None => ()
          }
        }
        Delete(op) => {
          validate_sync_identity(op.target)
          if op.agent != id.agent || op.timestamp < 0 {
            raise @sync.Failure::ConflictingIdentity(
              replica_id=id.agent,
              sequence=id.seq,
            )
          }
        }
        Undelete(op) => {
          validate_sync_identity(op.target)
          if op.agent != id.agent || op.timestamp < 0 {
            raise @sync.Failure::ConflictingIdentity(
              replica_id=id.agent,
              sequence=id.seq,
            )
          }
        }
      }
    }
  }
}

///|
fn exact_container_fields(
  object : Map[String, Json],
  expected : Array[String],
) -> Bool {
  if object.length() != expected.length() {
    return false
  }
  for key in object.keys() {
    let mut found = false
    for expected_key in expected {
      if key == expected_key {
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
fn container_identity_json(raw : @core.RawVersion) -> Json {
  Json::object({
    "replica_id": raw.agent.to_json(),
    "sequence": raw.seq.to_json(),
  })
}

///|
fn decode_container_identity(json : Json) -> @core.RawVersion raise {
  let object = match json {
    Json::Object(value) => value
    _ => fail("identity must be an object")
  }
  guard exact_container_fields(object, ["replica_id", "sequence"]) else {
    fail("identity contains missing or unknown fields")
  }
  let replica_id : String = @json.from_json(
    object.get("replica_id").unwrap_or(Json::null()),
  )
  let sequence : Int = @json.from_json(
    object.get("sequence").unwrap_or(Json::null()),
  )
  guard replica_id != "" && sequence >= 0 else { fail("invalid identity") }
  @core.RawVersion::new(replica_id, sequence)
}

///|
fn optional_container_identity_json(raw : @core.RawVersion?) -> Json {
  match raw {
    Some(value) => container_identity_json(value)
    None => Json::null()
  }
}

///|
fn decode_optional_container_identity(json : Json) -> @core.RawVersion? raise {
  match json {
    Json::Null => None
    value => Some(decode_container_identity(value))
  }
}

///|
fn container_node_json(node : @mt.TreeNodeId) -> Json {
  if node == @mt.root_id {
    Json::object({ "kind": "root".to_json() })
  } else if node == @mt.trash_id {
    Json::object({ "kind": "trash".to_json() })
  } else {
    Json::object({
      "kind": "node".to_json(),
      "replica_id": node.agent.to_json(),
      "sequence": node.counter.to_json(),
    })
  }
}

///|
fn decode_container_node(json : Json) -> @mt.TreeNodeId raise {
  let object = match json {
    Json::Object(value) => value
    _ => fail("node must be an object")
  }
  let kind : String = @json.from_json(
    object.get("kind").unwrap_or(Json::null()),
  )
  match kind {
    "root" => {
      guard exact_container_fields(object, ["kind"]) else {
        fail("root node contains unknown fields")
      }
      @mt.root_id
    }
    "trash" => {
      guard exact_container_fields(object, ["kind"]) else {
        fail("trash node contains unknown fields")
      }
      @mt.trash_id
    }
    "node" => {
      guard exact_container_fields(object, ["kind", "replica_id", "sequence"]) else {
        fail("node contains missing or unknown fields")
      }
      let replica_id : String = @json.from_json(
        object.get("replica_id").unwrap_or(Json::null()),
      )
      let sequence : Int = @json.from_json(
        object.get("sequence").unwrap_or(Json::null()),
      )
      guard replica_id != "" && sequence >= 0 else {
        fail("node identity is invalid")
      }
      { agent: replica_id, counter: sequence }
    }
    _ => fail("unknown node kind")
  }
}

///|
fn container_parents_json(parents : Array[@core.RawVersion]) -> Json {
  let values : Array[Json] = []
  for parent in sorted_sync_raw(parents) {
    values.push(container_identity_json(parent))
  }
  values.to_json()
}

///|
fn container_tree_payload_json(op : @mt.TreeOp) -> Json {
  match op {
    @mt.Move(value) =>
      Json::object({
        "kind": "move".to_json(),
        "timestamp": value.timestamp.to_json(),
        "agent": value.agent.to_json(),
        "target": container_node_json(value.target),
        "parent": container_node_json(value.new_parent),
        "position": value.position.elements().to_json(),
      })
    @mt.SetProperty(value) =>
      Json::object({
        "kind": "property".to_json(),
        "timestamp": value.timestamp.to_json(),
        "agent": value.agent.to_json(),
        "target": container_node_json(value.target),
        "key": value.key.to_json(),
        "value": value.value.to_json(),
      })
  }
}

///|
fn container_text_payload_json(block : @mt.TreeNodeId, op : TextOp) -> Json {
  match op {
    Insert(value) =>
      Json::object({
        "kind": "insert".to_json(),
        "timestamp": value.timestamp.to_json(),
        "agent": value.agent.to_json(),
        "block": container_node_json(block),
        "item": container_identity_json(value.id),
        "content": value.content.to_json(),
        "origin_left": optional_container_identity_json(value.origin_left),
        "origin_right": optional_container_identity_json(value.origin_right),
      })
    Delete(value) =>
      Json::object({
        "kind": "delete".to_json(),
        "timestamp": value.timestamp.to_json(),
        "agent": value.agent.to_json(),
        "block": container_node_json(block),
        "target": container_identity_json(value.target),
      })
    Undelete(value) =>
      Json::object({
        "kind": "undelete".to_json(),
        "timestamp": value.timestamp.to_json(),
        "agent": value.agent.to_json(),
        "block": container_node_json(block),
        "target": container_identity_json(value.target),
      })
  }
}

///|
fn container_record_json(record : SyncOpRecord) -> Json {
  let (domain, payload) = match record {
    Tree(value) => ("tree", container_tree_payload_json(value.op))
    Text(value) => ("text", container_text_payload_json(value.block, value.op))
  }
  Json::object({
    "id": container_identity_json(sync_record_version(record)),
    "parents": container_parents_json(sync_record_parents(record)),
    "domain": domain.to_json(),
    "payload": payload,
  })
}

///|
fn decode_container_parents(json : Json) -> Array[@core.RawVersion] raise {
  let values : Array[Json] = @json.from_json(json)
  let parents : Array[@core.RawVersion] = []
  let seen : Map[String, Bool] = Map([])
  for value in values {
    let parent = decode_container_identity(value)
    let key = sync_raw_key(parent)
    guard seen.get(key) is None else { fail("duplicate parent") }
    seen[key] = true
    parents.push(parent)
  }
  parents
}

///|
fn decode_container_tree_payload(json : Json) -> @mt.TreeOp raise {
  let object = match json {
    Json::Object(value) => value
    _ => fail("tree payload must be an object")
  }
  let kind : String = @json.from_json(
    object.get("kind").unwrap_or(Json::null()),
  )
  let timestamp : Int = @json.from_json(
    object.get("timestamp").unwrap_or(Json::null()),
  )
  let agent : String = @json.from_json(
    object.get("agent").unwrap_or(Json::null()),
  )
  match kind {
    "move" => {
      guard exact_container_fields(object, [
        "kind", "timestamp", "agent", "target", "parent", "position",
      ]) else {
        fail("move payload contains missing or unknown fields")
      }
      let elements : Array[Int] = @json.from_json(
        object.get("position").unwrap_or(Json::null()),
      )
      for element in elements {
        guard element >= 0 && element < 65536 else {
          fail("fractional position element is invalid")
        }
      }
      @mt.Move({
        timestamp,
        agent,
        target: decode_container_node(
          object.get("target").unwrap_or(Json::null()),
        ),
        new_parent: decode_container_node(
          object.get("parent").unwrap_or(Json::null()),
        ),
        position: @fi.FractionalIndex::new(elements),
      })
    }
    "property" => {
      guard exact_container_fields(object, [
        "kind", "timestamp", "agent", "target", "key", "value",
      ]) else {
        fail("property payload contains missing or unknown fields")
      }
      @mt.SetProperty({
        timestamp,
        agent,
        target: decode_container_node(
          object.get("target").unwrap_or(Json::null()),
        ),
        key: @json.from_json(object.get("key").unwrap_or(Json::null())),
        value: @json.from_json(object.get("value").unwrap_or(Json::null())),
      })
    }
    _ => fail("unknown tree operation kind")
  }
}

///|
fn decode_container_text_payload(json : Json) -> (@mt.TreeNodeId, TextOp) raise {
  let object = match json {
    Json::Object(value) => value
    _ => fail("text payload must be an object")
  }
  let kind : String = @json.from_json(
    object.get("kind").unwrap_or(Json::null()),
  )
  let timestamp : Int = @json.from_json(
    object.get("timestamp").unwrap_or(Json::null()),
  )
  let agent : String = @json.from_json(
    object.get("agent").unwrap_or(Json::null()),
  )
  let block = decode_container_node(object.get("block").unwrap_or(Json::null()))
  match kind {
    "insert" => {
      guard exact_container_fields(object, [
        "kind", "timestamp", "agent", "block", "item", "content", "origin_left",
        "origin_right",
      ]) else {
        fail("insert payload contains missing or unknown fields")
      }
      (
        block,
        Insert({
          id: decode_container_identity(
            object.get("item").unwrap_or(Json::null()),
          ),
          content: @json.from_json(
            object.get("content").unwrap_or(Json::null()),
          ),
          origin_left: decode_optional_container_identity(
            object.get("origin_left").unwrap_or(Json::null()),
          ),
          origin_right: decode_optional_container_identity(
            object.get("origin_right").unwrap_or(Json::null()),
          ),
          timestamp,
          agent,
        }),
      )
    }
    "delete" | "undelete" => {
      guard exact_container_fields(object, [
        "kind", "timestamp", "agent", "block", "target",
      ]) else {
        fail("delete payload contains missing or unknown fields")
      }
      let target = decode_container_identity(
        object.get("target").unwrap_or(Json::null()),
      )
      if kind == "delete" {
        (block, Delete({ target, timestamp, agent }))
      } else {
        (block, Undelete({ target, timestamp, agent }))
      }
    }
    _ => fail("unknown text operation kind")
  }
}

///|
fn decode_container_record(json : Json) -> SyncOpRecord raise {
  let object = match json {
    Json::Object(value) => value
    _ => fail("operation must be an object")
  }
  guard exact_container_fields(object, ["id", "parents", "domain", "payload"]) else {
    fail("operation contains missing or unknown fields")
  }
  let version = decode_container_identity(
    object.get("id").unwrap_or(Json::null()),
  )
  let parents = decode_container_parents(
    object.get("parents").unwrap_or(Json::null()),
  )
  let domain : String = @json.from_json(
    object.get("domain").unwrap_or(Json::null()),
  )
  match domain {
    "tree" =>
      Tree({
        version,
        parents,
        op: decode_container_tree_payload(
          object.get("payload").unwrap_or(Json::null()),
        ),
      })
    "text" => {
      let (block, op) = decode_container_text_payload(
        object.get("payload").unwrap_or(Json::null()),
      )
      Text({ version, parents, block, op })
    }
    _ => fail("unknown operation domain")
  }
}

///|
fn container_message_records(message : SyncMessage) -> Array[SyncOpRecord] {
  let records : Array[SyncOpRecord] = []
  for op in message.tree_ops {
    records.push(Tree(op))
  }
  for op in message.text_ops {
    records.push(Text(op))
  }
  records
}

///|
fn container_message_from_records(
  records : Array[SyncOpRecord],
  encoded_size : Int?,
) -> SyncMessage {
  let tree_ops : Array[VersionedTreeOp] = []
  let text_ops : Array[VersionedBlockTextOp] = []
  for record in records {
    match record {
      Tree(op) => tree_ops.push(op)
      Text(op) => text_ops.push(op)
    }
  }
  SyncMessage::SyncMessage(tree_ops, text_ops, encoded_size)
}

///|
/// Parse a message and receiver snapshot into a total commit plan.
///
/// This is the functional core. It does not mutate the document, causal graph,
/// or pending queue, and a failure therefore leaves receiver state untouched.
fn prepare_container_sync(
  message : SyncMessage,
  limits : @sync.Limits,
  local_records : Map[String, SyncOpRecord],
  pending_records : Array[SyncOpRecord],
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
  let incoming = container_message_records(message)
  if incoming.length() > limits.max_decoded_operations() {
    raise @sync.Failure::LimitExceeded(
      kind=@sync.LimitKind::DecodedOperations,
      limit=limits.max_decoded_operations(),
      actual=incoming.length(),
    )
  }
  let candidates : Map[String, SyncCandidate] = Map([])
  for record in pending_records {
    candidates[sync_record_key(record)] = FromPending(record)
  }
  let mut duplicates = 0
  for record in incoming {
    validate_sync_record(record, limits)
    let id = sync_record_version(record)
    let key = sync_raw_key(id)
    let payload = sync_record_payload_key(record)
    match local_records.get(key) {
      Some(existing) => {
        if sync_record_payload_key(existing) != payload {
          raise @sync.Failure::ConflictingIdentity(
            replica_id=id.agent,
            sequence=id.seq,
          )
        }
        duplicates = duplicates + 1
      }
      None =>
        match candidates.get(key) {
          Some(existing) => {
            if sync_record_payload_key(existing.raw()) != payload {
              raise @sync.Failure::ConflictingIdentity(
                replica_id=id.agent,
                sequence=id.seq,
              )
            }
            duplicates = duplicates + 1
            candidates[key] = existing.observe_message(record)
          }
          None => candidates[key] = FromMessage(record)
        }
    }
  }
  let all_candidates : Array[SyncOpRecord] = []
  for candidate in candidates.values() {
    all_candidates.push(candidate.raw())
  }
  let known_records : Map[String, SyncOpRecord] = Map([])
  local_records.each(fn(key, record) { known_records[key] = record })
  for record in all_candidates {
    known_records[sync_record_key(record)] = record
  }
  let ordered = canonical_sync_order(all_candidates)
  let resolvable : Map[String, Bool] = Map([])
  let applicable : Array[ApplicableSyncOp] = []
  let pending : Array[SyncOpRecord] = []
  for record in ordered {
    let mut ready = true
    for dependency in sync_record_dependencies(record) {
      let key = sync_raw_key(dependency)
      if local_records.get(key) is None && resolvable.get(key) != Some(true) {
        ready = false
      }
    }
    let key = sync_record_key(record)
    if ready {
      let candidate = candidates.get(key).unwrap()
      match candidate {
        FromMessage(_) => {
          let parsed = parse_applicable_sync_record(record, known_records)
          resolvable[key] = true
          applicable.push(parsed)
        }
        FromPending(_) | FromPendingAndMessage(_) => {
          let parsed = Some(parse_applicable_sync_record(record, known_records)) catch {
            _ => None
          }
          match parsed {
            Some(applicable_record) => {
              resolvable[key] = true
              applicable.push(applicable_record)
            }
            None => ()
          }
        }
      }
    } else {
      resolvable[key] = false
      pending.push(record)
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
pub fn SyncMessage::is_empty(self : SyncMessage) -> Bool {
  self.tree_ops.is_empty() && self.text_ops.is_empty()
}

///|
pub fn SyncMessage::op_count(self : SyncMessage) -> Int {
  self.tree_ops.length() + self.text_ops.length()
}

///|
pub fn SyncMessage::has_text_operations(self : SyncMessage) -> Bool {
  !self.text_ops.is_empty()
}

///|
pub fn SyncMessage::to_json_string(self : SyncMessage) -> String {
  let records = canonical_sync_order(container_message_records(self)) catch {
    _ => container_message_records(self)
  }
  let operations : Array[Json] = []
  for record in records {
    operations.push(container_record_json(record))
  }
  Json::object({
    "schema": (1).to_json(),
    "format": container_sync_format.to_json(),
    "operations": operations.to_json(),
  }).stringify()
}

///|
fn container_encoded_size(
  json_string : String,
  limits : @sync.Limits,
) -> Int raise @sync.Failure {
  if !is_container_well_formed_utf16(json_string) {
    raise @sync.Failure::MalformedMessage(detail="invalid sync JSON")
  }
  let size = @utf8.encode(json_string).length()
  if size > limits.max_encoded_bytes() {
    raise @sync.Failure::LimitExceeded(
      kind=@sync.LimitKind::EncodedBytes,
      limit=limits.max_encoded_bytes(),
      actual=size,
    )
  }
  size
}

///|
fn is_container_well_formed_utf16(text : String) -> Bool {
  let mut index = 0
  while index < text.length() {
    let value = text[index].to_int()
    if value >= 0xD800 && value <= 0xDBFF {
      if index + 1 >= text.length() {
        return false
      }
      let low = text[index + 1].to_int()
      if low < 0xDC00 || low > 0xDFFF {
        return false
      }
      index = index + 2
    } else if value >= 0xDC00 && value <= 0xDFFF {
      return false
    } else {
      index = index + 1
    }
  }
  true
}

///|
fn decode_container_sync_json(
  json_string : String,
  limits : @sync.Limits,
) -> SyncMessage raise DocumentError {
  let encoded_size = container_encoded_size(json_string, limits) catch {
    failure => raise DocumentError::SyncFailed(failure)
  }
  try {
    let root = @json.parse(json_string)
    let object = match root {
      Json::Object(value) => value
      _ => fail("sync envelope must be an object")
    }
    guard exact_container_fields(object, ["schema", "format", "operations"]) else {
      fail("sync envelope contains missing or unknown fields")
    }
    let schema : Int = @json.from_json(
      object.get("schema").unwrap_or(Json::null()),
    )
    let format : String = @json.from_json(
      object.get("format").unwrap_or(Json::null()),
    )
    guard schema == 1 && format == container_sync_format else {
      fail("unsupported sync envelope")
    }
    let values : Array[Json] = @json.from_json(
      object.get("operations").unwrap_or(Json::null()),
    )
    guard values.length() <= limits.max_decoded_operations() else {
      raise @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::DecodedOperations,
        limit=limits.max_decoded_operations(),
        actual=values.length(),
      )
    }
    let records : Array[SyncOpRecord] = []
    for value in values {
      let record = decode_container_record(value)
      validate_sync_record(record, limits)
      records.push(record)
    }
    container_message_from_records(
      canonical_sync_order(records),
      Some(encoded_size),
    )
  } catch {
    @sync.Failure::MalformedMessage(detail~) =>
      raise DocumentError::SyncFailed(@sync.Failure::MalformedMessage(detail~))
    @sync.Failure::InvalidContent(detail~) =>
      raise DocumentError::SyncFailed(@sync.Failure::InvalidContent(detail~))
    @sync.Failure::MissingDependency(replica_id~, sequence~) =>
      raise DocumentError::SyncFailed(
        @sync.Failure::MissingDependency(replica_id~, sequence~),
      )
    @sync.Failure::ConflictingIdentity(replica_id~, sequence~) =>
      raise DocumentError::SyncFailed(
        @sync.Failure::ConflictingIdentity(replica_id~, sequence~),
      )
    @sync.Failure::LimitExceeded(kind~, limit~, actual~) =>
      raise DocumentError::SyncFailed(
        @sync.Failure::LimitExceeded(kind~, limit~, actual~),
      )
    _ =>
      raise DocumentError::SyncFailed(
        @sync.Failure::MalformedMessage(detail="invalid container sync JSON"),
      )
  }
}

///|
/// Decode a synchronization message using the default protocol limits.
///
/// Use `Document::sync().decode_json(...)` when decoding for a receiver with
/// explicitly configured synchronization limits.
pub fn SyncMessage::from_json_string(
  json_string : String,
) -> SyncMessage raise DocumentError {
  decode_container_sync_json(json_string, @sync.Limits::default())
}

///|
/// Decode synchronization JSON using this receiver's configured limits.
pub fn SyncSession::decode_json(
  self : SyncSession,
  json_string : String,
) -> SyncMessage raise DocumentError {
  decode_container_sync_json(json_string, self.document.sync_limits)
}

///|
pub fn Version::to_json_string(self : Version) -> String {
  let agents = self.inner.agents()
  agents.sort()
  let entries : Array[Json] = []
  for agent in agents {
    entries.push(
      Json::object({
        "replica_id": agent.to_json(),
        "sequence": self.inner.sequence_for(agent).unwrap().to_json(),
      }),
    )
  }
  Json::object({
    "schema": (1).to_json(),
    "format": container_version_format.to_json(),
    "entries": entries.to_json(),
  }).stringify()
}

///|
pub fn Version::from_json_string(
  json_string : String,
) -> Version raise DocumentError {
  let limits : @sync.Limits = @sync.Limits::default()
  let _ = container_encoded_size(json_string, limits) catch {
    failure => raise DocumentError::SyncFailed(failure)
  }
  try {
    let root = @json.parse(json_string)
    let object = match root {
      Json::Object(value) => value
      _ => fail("version envelope must be an object")
    }
    guard exact_container_fields(object, ["schema", "format", "entries"]) else {
      fail("version envelope contains missing or unknown fields")
    }
    let schema : Int = @json.from_json(
      object.get("schema").unwrap_or(Json::null()),
    )
    let format : String = @json.from_json(
      object.get("format").unwrap_or(Json::null()),
    )
    guard schema == 1 && format == container_version_format else {
      fail("unsupported version envelope")
    }
    let values : Array[Json] = @json.from_json(
      object.get("entries").unwrap_or(Json::null()),
    )
    let mut vector = @cg.VersionVector::new()
    let seen : Map[String, Bool] = Map([])
    for value in values {
      let identity = decode_container_identity(value)
      guard seen.get(identity.agent) is None else {
        fail("duplicate version entry")
      }
      seen[identity.agent] = true
      vector = vector.set(identity.agent, identity.seq)
    }
    Version(vector)
  } catch {
    _ =>
      raise DocumentError::SyncFailed(
        @sync.Failure::MalformedMessage(detail="invalid container version JSON"),
      )
  }
}

///|
fn write_container_uvarint(buffer : Buffer, value : Int) -> Unit {
  let mut remaining = value
  while remaining >= 0x80 {
    buffer.write_byte(((remaining & 0x7F) | 0x80).to_byte())
    remaining = remaining >> 7
  }
  buffer.write_byte(remaining.to_byte())
}

///|
fn write_container_string(buffer : Buffer, value : String) -> Unit {
  let bytes = @utf8.encode(value)
  write_container_uvarint(buffer, bytes.length())
  buffer.write_bytes(bytes)
}

///|
fn write_container_raw(buffer : Buffer, raw : @core.RawVersion) -> Unit {
  write_container_string(buffer, raw.agent)
  write_container_uvarint(buffer, raw.seq)
}

///|
fn write_container_optional_raw(
  buffer : Buffer,
  raw : @core.RawVersion?,
) -> Unit {
  match raw {
    Some(value) => {
      buffer.write_byte(b'\x01')
      write_container_raw(buffer, value)
    }
    None => buffer.write_byte(b'\x00')
  }
}

///|
fn write_container_node(buffer : Buffer, node : @mt.TreeNodeId) -> Unit {
  if node == @mt.root_id {
    buffer.write_byte(b'\x00')
  } else if node == @mt.trash_id {
    buffer.write_byte(b'\x01')
  } else {
    buffer.write_byte(b'\x02')
    write_container_string(buffer, node.agent)
    write_container_uvarint(buffer, node.counter)
  }
}

///|
fn write_container_record(buffer : Buffer, record : SyncOpRecord) -> Unit {
  write_container_raw(buffer, sync_record_version(record))
  let parents = sorted_sync_raw(sync_record_parents(record))
  write_container_uvarint(buffer, parents.length())
  for parent in parents {
    write_container_raw(buffer, parent)
  }
  match record {
    Tree(versioned) =>
      match versioned.op {
        @mt.Move(op) => {
          buffer.write_byte(b'\x00')
          write_container_uvarint(buffer, op.timestamp)
          write_container_string(buffer, op.agent)
          write_container_node(buffer, op.target)
          write_container_node(buffer, op.new_parent)
          let elements = op.position.elements()
          write_container_uvarint(buffer, elements.length())
          for element in elements {
            write_container_uvarint(buffer, element)
          }
        }
        @mt.SetProperty(op) => {
          buffer.write_byte(b'\x01')
          write_container_uvarint(buffer, op.timestamp)
          write_container_string(buffer, op.agent)
          write_container_node(buffer, op.target)
          write_container_string(buffer, op.key)
          write_container_string(buffer, op.value)
        }
      }
    Text(versioned) => {
      write_container_node(buffer, versioned.block)
      match versioned.op {
        Insert(op) => {
          buffer.write_byte(b'\x02')
          write_container_uvarint(buffer, op.timestamp)
          write_container_string(buffer, op.agent)
          write_container_raw(buffer, op.id)
          write_container_string(buffer, op.content)
          write_container_optional_raw(buffer, op.origin_left)
          write_container_optional_raw(buffer, op.origin_right)
        }
        Delete(op) => {
          buffer.write_byte(b'\x03')
          write_container_uvarint(buffer, op.timestamp)
          write_container_string(buffer, op.agent)
          write_container_raw(buffer, op.target)
        }
        Undelete(op) => {
          buffer.write_byte(b'\x04')
          write_container_uvarint(buffer, op.timestamp)
          write_container_string(buffer, op.agent)
          write_container_raw(buffer, op.target)
        }
      }
    }
  }
}

///|
pub fn SyncMessage::to_canonical_bytes(self : SyncMessage) -> Bytes {
  let buffer = Buffer()
  buffer.write_bytes(b"event-graph-walker:container-sync:v1")
  let records = canonical_sync_order(container_message_records(self)) catch {
    _ => container_message_records(self)
  }
  write_container_uvarint(buffer, records.length())
  for record in records {
    write_container_record(buffer, record)
  }
  buffer.to_bytes()
}
