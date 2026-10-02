///| Experimental accepted-history archive v1. Additive: no schema-2 decoder changes.
/// The archive contains accepted operations, not pending packets or local Undo stacks.

///|
let compact_format : String = "event-graph-walker/experimental-accepted-history"

///|
let compact_max_bytes : Int = 16 * 1024 * 1024

///|
let compact_max_ops : Int = 100000

///|
let compact_max_edges : Int = 1000000

///|
let compact_max_expanded_identity_bytes : Int = 64 * 1024 * 1024

///|
priv struct CompactRecord {
  kind : String
  actor : Int
  sequence : Int
  parents : Array[@core.RawVersion]
  left : @core.RawVersion?
  right : @core.RawVersion?
  text : String
}

///|
fn compact_add_budget(total : Int, amount : Int, limit : Int) -> Int raise {
  guard amount >= 0 && total <= limit && amount <= limit - total else {
    fail("compact archive resource budget exceeded")
  }
  total + amount
}

///|
fn compact_mul_budget(value : Int, count : Int, limit : Int) -> Int raise {
  guard value >= 0 && count >= 0 && (count == 0 || value <= limit / count) else {
    fail("compact archive expansion budget exceeded")
  }
  value * count
}

///|
/// Bound input and nesting before allocating a JSON tree. Strings/escapes do not count.
fn compact_preparse(source : String) -> Int raise {
  guard source.length() <= compact_max_bytes && is_well_formed_utf16(source) else {
    fail("compact archive input size or UTF-16 invalid")
  }
  let size = @utf8.encode(source).length()
  guard size <= compact_max_bytes else {
    fail("compact archive encoded byte limit")
  }
  let mut quoted = false
  let mut escaped = false
  let mut depth = 0
  for ch in source {
    if quoted {
      if escaped {
        escaped = false
      } else if ch == '\\' {
        escaped = true
      } else if ch == '"' {
        quoted = false
      }
    } else if ch == '"' {
      quoted = true
    } else if ch == '{' || ch == '[' {
      depth = depth + 1
      guard depth <= 16 else { fail("compact archive nesting limit") }
    } else if ch == '}' || ch == ']' {
      depth = depth - 1
      guard depth >= 0 else { fail("compact archive unmatched delimiter") }
    }
  }
  guard !quoted && depth == 0 else { fail("compact archive truncated JSON") }
  size
}

///|
fn compact_integer(value : Json) -> Int raise {
  match value {
    Json::Number(number, ..) => {
      guard number >= 0.0 && number <= 2147483647.0 else {
        fail("compact integer out of range")
      }
      let integer = number.to_int()
      guard integer.to_double() == number else {
        fail("compact fractional integer")
      }
      integer
    }
    _ => fail("compact integer required")
  }
}

///|
fn compact_identity(
  json : Json,
  actors : Array[String],
) -> @core.RawVersion raise {
  let raw : Array[Json] = @json.from_json(json)
  let values = raw.map(compact_integer)
  guard values.length() == 2 &&
    values[0] >= 0 &&
    values[0] < actors.length() &&
    values[1] >= 0 else {
    fail("compact identity index or sequence invalid")
  }
  @core.RawVersion(actors[values[0]], values[1])
}

///|
fn compact_optional_identity(
  json : Json,
  actors : Array[String],
) -> @core.RawVersion? raise {
  match json {
    Json::Null => None
    other => Some(compact_identity(other, actors))
  }
}

///|
fn compact_pack_identity(
  id : @core.RawVersion,
  actors : Map[String, Int],
) -> Json {
  [actors.get(id.agent).unwrap(), id.seq].to_json()
}

///|
fn compact_pack_optional(
  id : @core.RawVersion?,
  actors : Map[String, Int],
) -> Json {
  match id {
    None => Json::null()
    Some(id) => compact_pack_identity(id, actors)
  }
}

///|
fn compact_preflight(
  source : String,
  expected_external : String,
  writer : String?,
) -> (
  Array[String],
  Array[CompactRecord],
  Array[@core.RawVersion],
  Version,
  Int,
  Int,
) raise {
  let encoded_size = compact_preparse(source)
  let root = @json.parse(source)
  let object = match root {
    Json::Object(object) => object
    _ => fail("compact root must be object")
  }
  guard exact_object_fields(object, [
    "format", "schema", "actors", "records", "heads", "version",
  ]) else {
    fail("compact archive missing or unknown root fields")
  }
  let format : String = @json.from_json(object["format"])
  let schema = compact_integer(object["schema"])
  guard format == compact_format && schema == 1 else {
    fail("unsupported compact archive format")
  }
  let actors : Array[String] = @json.from_json(object["actors"])
  guard actors.length() <= 4096 else { fail("compact actor count limit") }
  let actor_bytes : Map[String, Int] = Map([])
  let mut total_actor_bytes = 0
  for actor in actors {
    guard actor != "" &&
      is_well_formed_utf16(actor) &&
      actor_bytes.get(actor) is None else {
      fail("compact empty, malformed, or duplicate actor")
    }
    let bytes = @utf8.encode(actor).length()
    total_actor_bytes = compact_add_budget(
      total_actor_bytes,
      bytes,
      1024 * 1024,
    )
    actor_bytes[actor] = bytes
  }
  match writer {
    Some(writer) => {
      guard writer != "" &&
        is_well_formed_utf16(writer) &&
        actor_bytes.get(writer) is None else {
        fail("compact restore requires a fresh nonempty writer identity")
      }
    }
    None => ()
  }
  let expected_string : String = @json.from_json(object["version"])
  let expected = Version::from_json_string(expected_string)
  guard expected.to_json_string() == expected_string else {
    fail("compact header Version must use canonical encoding")
  }
  let external = Version::from_json_string(expected_external)
  guard external.to_json_string() == expected_external else {
    fail("external expected Version must use canonical encoding")
  }
  guard expected == external else {
    fail("compact archive disagrees with externally supplied expected Version")
  }
  let head_json : Array[Json] = @json.from_json(object["heads"])
  guard head_json.length() <= 4096 else { fail("compact head count limit") }
  let heads = head_json.map(head => compact_identity(head, actors))
  let raw_records : Array[Json] = @json.from_json(object["records"])
  guard raw_records.length() <= compact_max_ops else {
    fail("compact record count limit")
  }
  let records : Array[CompactRecord] = []
  let mut total_ops = 0
  let mut total_edges = 0
  let mut expanded_identity_bytes = 0
  let mut text_bytes = 0
  for raw in raw_records {
    let row : Array[Json] = @json.from_json(raw)
    guard row.length() == 5 || row.length() == 7 else {
      fail("compact record arity invalid")
    }
    let kind : String = @json.from_json(row[0])
    let actor = compact_integer(row[1])
    let sequence = compact_integer(row[2])
    guard actor >= 0 && actor < actors.length() && sequence >= 0 else {
      fail("compact record actor or sequence invalid")
    }
    let parent_json : Array[Json] = @json.from_json(row[3])
    guard parent_json.length() <= 256 else {
      fail("compact parent count limit")
    }
    let parents = parent_json.map(parent => compact_identity(parent, actors))
    let left = compact_optional_identity(row[4], actors)
    let (right, text, count) = if kind == "i" && row.length() == 7 {
      let right = compact_optional_identity(row[5], actors)
      let text : String = @json.from_json(row[6])
      guard text != "" && is_well_formed_utf16(text) else {
        fail("compact insert must contain well-formed nonempty scalar text")
      }
      let mut count = 0
      for _ in text {
        count = compact_add_budget(count, 1, compact_max_ops)
      }
      text_bytes = compact_add_budget(
        text_bytes,
        @utf8.encode(text).length(),
        4 * compact_max_ops,
      )
      (right, text, count)
    } else if (kind == "d" || kind == "u") && row.length() == 5 {
      guard left is Some(_) else {
        fail("compact delete/undelete missing target")
      }
      (None, "", 1)
    } else {
      fail("compact record kind or arity invalid")
    }
    guard count - 1 <= 2147483647 - sequence else {
      fail("compact sequence overflow")
    }
    total_ops = compact_add_budget(total_ops, count, compact_max_ops)
    let origin_count = (if left is Some(_) { 1 } else { 0 }) +
      (if right is Some(_) { 1 } else { 0 })
    total_edges = compact_add_budget(
      total_edges,
      parents.length() + origin_count,
      compact_max_edges,
    )
    total_edges = compact_add_budget(
      total_edges,
      compact_mul_budget(
        count - 1,
        2 + (if right is Some(_) { 1 } else { 0 }),
        compact_max_edges,
      ),
      compact_max_edges,
    )
    let own_bytes = actor_bytes.get(actors[actor]).unwrap()
    expanded_identity_bytes = compact_add_budget(
      expanded_identity_bytes,
      compact_mul_budget(own_bytes, count, compact_max_expanded_identity_bytes),
      compact_max_expanded_identity_bytes,
    )
    for parent in parents {
      expanded_identity_bytes = compact_add_budget(
        expanded_identity_bytes,
        actor_bytes.get(parent.agent).unwrap(),
        compact_max_expanded_identity_bytes,
      )
    }
    match left {
      Some(left) =>
        expanded_identity_bytes = compact_add_budget(
          expanded_identity_bytes,
          actor_bytes.get(left.agent).unwrap(),
          compact_max_expanded_identity_bytes,
        )
      None => ()
    }
    match right {
      Some(right) =>
        expanded_identity_bytes = compact_add_budget(
          expanded_identity_bytes,
          compact_mul_budget(
            actor_bytes.get(right.agent).unwrap(),
            count,
            compact_max_expanded_identity_bytes,
          ),
          compact_max_expanded_identity_bytes,
        )
      None => ()
    }
    expanded_identity_bytes = compact_add_budget(
      expanded_identity_bytes,
      compact_mul_budget(
        own_bytes,
        (count - 1) * 2,
        compact_max_expanded_identity_bytes,
      ),
      compact_max_expanded_identity_bytes,
    )
    records.push({ kind, actor, sequence, parents, left, right, text, })
  }
  (actors, records, heads, expected, encoded_size, total_ops)
}

///|
fn compact_decode(
  source : String,
  expected_external : String,
  writer : String,
  chain? : Bool = false,
) -> (SyncMessage, Version) raise {
  let (actors, records, heads, expected, encoded_size, total_ops) = compact_preflight(
    source,
    expected_external,
    Some(writer),
  )
  // No expanded operation objects are allocated until every record has passed budgets.
  let operations : Array[@core.Op] = []
  for record in records {
    let actor = actors[record.actor]
    if record.kind == "i" {
      let mut offset = 0
      for ch in record.text {
        let previous = @core.RawVersion(actor, record.sequence + offset - 1)
        let parents = if offset == 0 { record.parents } else { [previous] }
        let left = if offset == 0 { record.left } else { Some(previous) }
        operations.push(
          @core.Op::insert(
            0,
            parents,
            actor,
            record.sequence + offset,
            ch.to_string(),
            left,
            record.right,
          ),
        )
        offset = offset + 1
      }
    } else if record.kind == "d" {
      operations.push(
        @core.Op::delete(0, record.parents, actor, record.sequence, record.left),
      )
    } else {
      operations.push(
        @core.Op::undelete(
          0,
          record.parents,
          actor,
          record.sequence,
          record.left,
        ),
      )
    }
  }
  // Existing structural proofs, identity conflicts, deterministic Kahn order, and heads checks.
  let chain_candidate = chain &&
    records.length() == 1 &&
    records[0].kind == "i" &&
    records[0].parents.is_empty() &&
    records[0].left is None &&
    records[0].right is None
  let message = if chain_candidate {
    compact_chain_message(operations, heads, encoded_size)
  } else {
    SyncMessage::SyncMessage(operations, heads, Some(encoded_size))
  }
  guard message.operations.length() == total_ops else {
    fail("compact duplicate operation identity")
  }
  (message, expected)
}

///|
/// Serialize accepted history losslessly. Deliberately does not serialize pending or Undo stacks.
pub fn TextState::export_compact_experimental(
  self : TextState,
) -> String raise TextError {
  let message = self.sync().export_all()
  let actors : Array[String] = []
  let actor_map : Map[String, Int] = Map([])
  for op in message.operations {
    let agent = op.agent()
    if actor_map.get(agent) is None {
      actor_map[agent] = actors.length()
      actors.push(agent)
    }
  }
  let records : Array[Json] = []
  let mut i = 0
  while i < message.operations.length() {
    let first = message.operations[i]
    let parents = sorted_raw(first.parents()).map(parent => {
      compact_pack_identity(parent, actor_map)
    })
    match first.content() {
      @core.Insert(text) => {
        let builder = StringBuilder()
        builder.write_string(text)
        let mut j = i + 1
        let mut keep = true
        while j < message.operations.length() && keep {
          let next = message.operations[j]
          let previous = op_identity(message.operations[j - 1])
          match next.content() {
            @core.Insert(content) =>
              if next.agent() == first.agent() &&
                next.seq() > first.seq() &&
                next.seq() - first.seq() == j - i &&
                next.parents() == [previous] &&
                next.origin_left() == Some(previous) &&
                next.origin_right() == first.origin_right() {
                builder.write_string(content)
                j = j + 1
              } else {
                keep = false
              }
            _ => keep = false
          }
        }
        records.push(
          [
            "i".to_json(),
            actor_map.get(first.agent()).unwrap().to_json(),
            first.seq().to_json(),
            parents.to_json(),
            compact_pack_optional(first.origin_left(), actor_map),
            compact_pack_optional(first.origin_right(), actor_map),
            builder.to_string().to_json(),
          ].to_json(),
        )
        i = j
      }
      @core.Delete | @core.Undelete => {
        let kind = match first.content() {
          @core.Delete => "d"
          _ => "u"
        }
        records.push(
          [
            kind.to_json(),
            actor_map.get(first.agent()).unwrap().to_json(),
            first.seq().to_json(),
            parents.to_json(),
            compact_pack_optional(first.origin_left(), actor_map),
          ].to_json(),
        )
        i = i + 1
      }
    }
  }
  let source = (
    {
      "format": compact_format.to_json(),
      "schema": (1).to_json(),
      "actors": actors.to_json(),
      "records": records.to_json(),
      "heads": message.heads
      .map(head => compact_pack_identity(head, actor_map))
      .to_json(),
      "version": self.version().to_json_string().to_json(),
    } : Json).stringify()
  ignore(compact_preflight(source, self.version().to_json_string(), None)) catch {
    error =>
      raise TextError::SyncFailed(
        @sync.Failure::MalformedMessage(detail=error.to_string()),
      )
  }
  source
}

///|
/// Metadata-only eligibility is not acceptance; accepted operations still receive
/// exactly the existing structural validation before constructing a message.
fn compact_is_single_chain(
  operations : Array[@core.Op],
  heads : Array[@core.RawVersion],
) -> Bool {
  if operations.is_empty() {
    return false
  }
  let first = operations[0]
  if first.seq() < 0 ||
    operations.length() - 1 > 2147483647 - first.seq() ||
    first.agent() == "" ||
    !first.parents().is_empty() ||
    first.origin_left() is Some(_) ||
    first.origin_right() is Some(_) {
    return false
  }
  let last = op_identity(operations[operations.length() - 1])
  if heads != [last] {
    return false
  }
  for index, op in operations {
    if !(op.content() is @core.Insert(_)) ||
      op.agent() != first.agent() ||
      op.seq() != first.seq() + index ||
      op.origin_right() is Some(_) {
      return false
    }
    if index > 0 {
      let previous = op_identity(operations[index - 1])
      if op.parents() != [previous] || op.origin_left() != Some(previous) {
        return false
      }
    }
  }
  true
}

///|
/// A single insertion chain has one unique topological order and no competing
/// ready identities. Prove that narrow case; otherwise use the original constructor.
fn compact_chain_message(
  operations : Array[@core.Op],
  heads : Array[@core.RawVersion],
  encoded_size : Int,
) -> SyncMessage raise @sync.Failure {
  if !compact_is_single_chain(operations, heads) {
    return SyncMessage::SyncMessage(operations, heads, Some(encoded_size))
  }
  let structural_operations : Array[StructuralOp] = []
  for op in operations {
    structural_operations.push(StructuralOp::StructuralOp(op))
  }
  // Unique checked consecutive identities, valid first actor, and sole proved
  // last head establish the exact original head invariants without a head map.
  {
    operations: operations.copy(),
    structural_operations,
    heads: heads.copy(),
    encoded_size: Some(encoded_size),
    decoded_operation_count: operations.length(),
  }
}

///|
/// Separate offline importer: complete proof -> direct authority -> canonical
/// projection -> derived index. No live planner/pending registration is needed.
pub fn TextState::restore_compact_direct_experimental(
  source : String,
  writer : String,
  expected_external : String,
) -> TextState raise TextError {
  try {
    let (message, expected) = compact_decode(
      source,
      expected_external,
      writer,
      chain=true,
    )
    let limits : @sync.Limits = Default::default()
    validate_message_limits(message, limits)
    let proof = @oplog.ClosedHistory::prepare_experimental(message.operations)
    if Version::from_graph_version(proof.version_experimental()) != expected ||
      sorted_raw(proof.heads_experimental()) != message.heads {
      fail("closed history heads or expected Version mismatch")
    }
    let doc : TextState = {
      inner: @document.Document::from_closed_history_experimental(writer, proof),
      sync_limits: limits,
    }
    if doc.sync().pending_sync_count() != 0 ||
      doc.version() != expected ||
      sorted_raw(current_heads(doc)) != message.heads {
      fail("direct history post-build validation failed")
    }
    ignore(doc.text())
    doc
  } catch {
    error =>
      raise TextError::SyncFailed(
        @sync.Failure::MalformedMessage(detail=error.to_string()),
      )
  }
}
