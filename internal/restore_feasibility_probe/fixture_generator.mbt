///|
/// Deterministic fixture construction failures.
suberror FixtureError {
  Invalid(detail~ : String)
} derive(Eq)

///|
/// One canonical event in catalog generation order.
struct FixtureEvent {
  ordinal : Int
  identity : RawIdentity
  parents : Array[RawIdentity]
  body : CanonicalBody
  canonical_body_bytes : Bytes
} derive(Eq)

///|
/// One generated morphology with its expected stable replay order.
struct GeneratedFixture {
  fixture_id : String
  document_id : String
  events : Array[FixtureEvent]
  replay_order : Array[RawIdentity]
  final_text : String
} derive(Eq)

///|
/// Immutable per-fixture catalog summary.
struct CatalogFixture {
  fixture_id : String
  document_id : String
  event_count : Int
  canonical_sha256 : String
  replay_order : Array[RawIdentity]
  final_text : String
} derive(Eq)

///|
/// Complete required morphology catalog summary.
struct FixtureCatalog {
  schema_version : Int
  fixture_seed : String
  fixtures : Array[CatalogFixture]
} derive(Eq)

///|
/// Stable JSON summary used to prove repeated generation is byte-identical.
fn FixtureCatalog::to_json_string(self : FixtureCatalog) -> String {
  let fixtures : Array[Json] = []
  for fixture in self.fixtures {
    fixtures.push(
      Json::object({
        "fixture_id": fixture.fixture_id.to_json(),
        "document_id": fixture.document_id.to_json(),
        "event_count": fixture.event_count.to_json(),
        "canonical_sha256": fixture.canonical_sha256.to_json(),
        "replay_order": fixture.replay_order
        .map(identity => identity.agent + ":" + identity.sequence.to_string())
        .to_json(),
        "final_text": fixture.final_text.to_json(),
      }),
    )
  }
  Json::object({
    "schema_version": self.schema_version.to_json(),
    "fixture_seed": self.fixture_seed.to_json(),
    "fixtures": fixtures.to_json(),
  }).stringify()
}

///|
/// Encode one event independently for catalog audit and replay handoff.
fn canonical_event_bytes(event : FixtureEvent) -> Bytes raise FixtureError {
  let buffer = Buffer()
  try {
    write_domain(buffer, "loomark-r0-fixture-event:v1")
    write_uvarint(buffer, event.ordinal)
    write_raw_identity(buffer, event.identity)
    write_uvarint(buffer, event.parents.length())
    for parent in event.parents {
      write_raw_identity(buffer, parent)
    }
    write_lp_bytes(buffer, event.canonical_body_bytes)
  } catch {
    _ => raise FixtureError::Invalid(detail="fixture event codec failure")
  }
  buffer.to_bytes()
}

///|
/// Fully expanded catalog row; no event identity, parent, or body is implicit.
fn GeneratedFixture::to_full_json_string(
  self : GeneratedFixture,
) -> String raise FixtureError {
  let events : Array[Json] = []
  for event in self.events {
    let parents : Array[Json] = []
    for parent in event.parents {
      parents.push(
        Json::object({
          "agent": parent.agent.to_json(),
          "sequence": parent.sequence.to_json(),
        }),
      )
    }
    let body = match event.body {
      InsertScalar(position, scalar) =>
        Json::object({
          "kind": "insert".to_json(),
          "position": position.to_json(),
          "scalar": scalar.to_json(),
        })
      DeleteScalar(position) =>
        Json::object({
          "kind": "delete".to_json(),
          "position": position.to_json(),
        })
      Undelete(target) =>
        Json::object({
          "kind": "undelete".to_json(),
          "target": Json::object({
            "agent": target.agent.to_json(),
            "sequence": target.sequence.to_json(),
          }),
        })
    }
    events.push(
      Json::object({
        "ordinal": event.ordinal.to_json(),
        "identity": Json::object({
          "agent": event.identity.agent.to_json(),
          "sequence": event.identity.sequence.to_json(),
        }),
        "parents": parents.to_json(),
        "body": body,
        "canonical_body_bytes_hex": bytes_hex(event.canonical_body_bytes).to_json(),
        "canonical_event_bytes_hex": bytes_hex(canonical_event_bytes(event)).to_json(),
      }),
    )
  }
  Json::object({
    "fixture_id": self.fixture_id.to_json(),
    "document_id": self.document_id.to_json(),
    "event_count": self.events.length().to_json(),
    "canonical_sha256": sha256_hex(canonical_fixture_bytes(self)).to_json(),
    "events": events.to_json(),
    "replay_order": self.replay_order
    .map(identity => identity.agent + ":" + identity.sequence.to_string())
    .to_json(),
    "final_text": self.final_text.to_json(),
    "adapter_observation_sha256": sha256_hex(
      strict_utf8(self.final_text) catch {
        _ => raise FixtureError::Invalid(detail="final text encoding failure")
      },
    ).to_json(),
  }).stringify()
}

///|
/// A visible scalar retains the insert identity required by delete/undelete evidence.
struct VisibleScalar {
  value : String
  identity : RawIdentity
}

///|
/// Session-owned mutable state for one deterministic fixture.
struct FixtureBuilder {
  events : Array[FixtureEvent]
  visible : Array[VisibleScalar]
  next_sequences : Map[String, Int]
}

///|
fn FixtureBuilder::new() -> FixtureBuilder {
  { events: [], visible: [], next_sequences: Default::default() }
}

///|
fn raw_identity_key(identity : RawIdentity) -> String {
  identity.agent + "\u{0}" + identity.sequence.to_string()
}

///|
fn FixtureBuilder::next_identity(
  self : FixtureBuilder,
  agent : String,
) -> RawIdentity {
  let sequence = self.next_sequences.get(agent).unwrap_or(0)
  self.next_sequences[agent] = sequence + 1
  RawIdentity(agent~, sequence~)
}

///|
fn sorted_parents(parents : Array[RawIdentity]) -> Array[RawIdentity] {
  let result = parents.copy()
  result.sort_by(compare_raw_identity)
  result
}

///|
fn FixtureBuilder::append_event(
  self : FixtureBuilder,
  agent : String,
  parents : Array[RawIdentity],
  body : CanonicalBody,
) -> FixtureEvent raise FixtureError {
  let canonical_body_bytes = encode_canonical_body(body) catch {
    _ => raise FixtureError::Invalid(detail="canonical body codec failure")
  }
  let event = FixtureEvent::{
    ordinal: self.events.length(),
    identity: self.next_identity(agent),
    parents: sorted_parents(parents),
    body,
    canonical_body_bytes,
  }
  self.events.push(event)
  event
}

///|
fn FixtureBuilder::insert(
  self : FixtureBuilder,
  agent : String,
  parents : Array[RawIdentity],
  position : Int,
  scalar : String,
) -> FixtureEvent raise FixtureError {
  if position < 0 || position > self.visible.length() {
    raise FixtureError::Invalid(detail="insert position outside visible text")
  }
  let event = self.append_event(agent, parents, InsertScalar(position, scalar))
  self.visible.insert(position, { value: scalar, identity: event.identity })
  event
}

///|
fn FixtureBuilder::delete(
  self : FixtureBuilder,
  agent : String,
  parents : Array[RawIdentity],
  position : Int,
) -> (FixtureEvent, VisibleScalar) raise FixtureError {
  if position < 0 || position >= self.visible.length() {
    raise FixtureError::Invalid(detail="delete position outside visible text")
  }
  let deleted = self.visible[position]
  let event = self.append_event(agent, parents, DeleteScalar(position))
  self.visible.remove(position) |> ignore
  (event, deleted)
}

///|
fn FixtureBuilder::undelete(
  self : FixtureBuilder,
  agent : String,
  parents : Array[RawIdentity],
  position : Int,
  scalar : VisibleScalar,
) -> FixtureEvent raise FixtureError {
  if position < 0 || position > self.visible.length() {
    raise FixtureError::Invalid(detail="undelete position outside visible text")
  }
  let event = self.append_event(agent, parents, Undelete(scalar.identity))
  self.visible.insert(position, scalar)
  event
}

///|
fn FixtureBuilder::chain_parents(self : FixtureBuilder) -> Array[RawIdentity] {
  if self.events.is_empty() {
    []
  } else {
    [self.events[self.events.length() - 1].identity]
  }
}

///|
fn default_writer(ordinal : Int) -> String {
  if ordinal / 64 % 2 == 0 {
    "r0-a"
  } else {
    "r0-b"
  }
}

///|
fn scalar_pattern(ordinal : Int) -> String {
  match ordinal % 7 {
    0 => "a"
    1 => "é"
    2 => "e"
    3 => "́"
    4 => "🙂"
    5 => "\n"
    _ => "\r"
  }
}

///|
fn visible_text(visible : Array[VisibleScalar]) -> String {
  let values : Array[String] = []
  for scalar in visible {
    values.push(scalar.value)
  }
  values.join("")
}

///|
/// Construct an event directly for ordering conformance tests.
fn fixture_event_for_order(
  ordinal : Int,
  identity : RawIdentity,
  parents : Array[RawIdentity],
) -> FixtureEvent {
  let body = InsertScalar(0, "a")
  FixtureEvent::{
    ordinal,
    identity,
    parents: sorted_parents(parents),
    body,
    canonical_body_bytes: try! encode_canonical_body(body),
  }
}

///|
fn insert_ready_identity(
  ready : Array[RawIdentity],
  identity : RawIdentity,
) -> Unit {
  let mut low = 0
  let mut high = ready.length()
  while low < high {
    let middle = low + (high - low) / 2
    if compare_raw_identity(ready[middle], identity) < 0 {
      low = middle + 1
    } else {
      high = middle
    }
  }
  ready.insert(low, identity)
}

///|
/// Stable Kahn replay: ready events are selected by UTF-8 agent bytes then sequence.
fn stable_topological_order(
  events : Array[FixtureEvent],
) -> Array[RawIdentity] raise FixtureError {
  let by_key : Map[String, FixtureEvent] = Default::default()
  let remaining : Map[String, Int] = Default::default()
  let children : Map[String, Array[RawIdentity]] = Default::default()
  for event in events {
    let key = raw_identity_key(event.identity)
    if by_key.contains(key) {
      raise FixtureError::Invalid(detail="duplicate raw identity")
    }
    by_key[key] = event
    remaining[key] = event.parents.length()
  }
  for event in events {
    for parent in event.parents {
      let parent_key = raw_identity_key(parent)
      if !by_key.contains(parent_key) {
        raise FixtureError::Invalid(detail="missing declared parent")
      }
      let dependents = children.get(parent_key).unwrap_or([])
      dependents.push(event.identity)
      children[parent_key] = dependents
    }
  }
  let ready : Array[RawIdentity] = []
  for event in events {
    if remaining[raw_identity_key(event.identity)] == 0 {
      insert_ready_identity(ready, event.identity)
    }
  }
  let result : Array[RawIdentity] = []
  while !ready.is_empty() {
    let identity = ready[0]
    ready.remove(0) |> ignore
    result.push(identity)
    for child in children.get(raw_identity_key(identity)).unwrap_or([]) {
      let child_key = raw_identity_key(child)
      let count = remaining[child_key] - 1
      remaining[child_key] = count
      if count == 0 {
        insert_ready_identity(ready, child)
      }
    }
  }
  if result.length() != events.length() {
    raise FixtureError::Invalid(detail="cyclic fixture graph")
  }
  result
}

///|
fn add_default_insert(
  builder : FixtureBuilder,
  position : Int,
) -> FixtureEvent raise FixtureError {
  let ordinal = builder.events.length()
  builder.insert(
    default_writer(ordinal),
    builder.chain_parents(),
    position,
    scalar_pattern(ordinal),
  )
}

///|
fn generate_sequential(
  shape : String,
  event_count : Int,
) -> FixtureBuilder raise FixtureError {
  let builder = FixtureBuilder::new()
  match shape {
    "S-linear" | "S-unicode" =>
      for iteration = 0; iteration < event_count; iteration = iteration + 1 {
        add_default_insert(builder, builder.visible.length()) |> ignore
      }
    "S-distributed" =>
      for i = 0; i < event_count; i = i + 1 {
        let position = (i.to_uint64() *
        2654435761UL %
        (builder.visible.length() + 1).to_uint64()).to_int()
        add_default_insert(builder, position) |> ignore
      }
    "S-tombstone" => {
      let insert_count = (2 * event_count + 2) / 3
      for iteration = 0; iteration < insert_count; iteration = iteration + 1 {
        add_default_insert(builder, builder.visible.length()) |> ignore
      }
      for j = 0; j < event_count - insert_count; j = j + 1 {
        let ordinal = builder.events.length()
        let position = (j.to_uint64() *
        2654435761UL %
        builder.visible.length().to_uint64()).to_int()
        builder.delete(
          default_writer(ordinal),
          builder.chain_parents(),
          position,
        )
        |> ignore
      }
    }
    "S-replacement" => {
      let initial = if event_count < 50 { event_count } else { 50 }
      for iteration = 0; iteration < initial; iteration = iteration + 1 {
        add_default_insert(builder, builder.visible.length()) |> ignore
      }
      while builder.events.length() < event_count {
        let deletes_left = event_count - builder.events.length()
        let delete_count = if deletes_left < 50 { deletes_left } else { 50 }
        for iteration = 0; iteration < delete_count; iteration = iteration + 1 {
          let ordinal = builder.events.length()
          builder.delete(
            default_writer(ordinal),
            builder.chain_parents(),
            builder.visible.length() - 1,
          )
          |> ignore
        }
        let inserts_left = event_count - builder.events.length()
        let insert_count = if inserts_left < 50 { inserts_left } else { 50 }
        for iteration = 0; iteration < insert_count; iteration = iteration + 1 {
          add_default_insert(builder, builder.visible.length()) |> ignore
        }
      }
    }
    _ => raise FixtureError::Invalid(detail="unknown sequential morphology")
  }
  builder
}

///|
fn generate_u_mixed(event_count : Int) -> FixtureBuilder raise FixtureError {
  if event_count % 4 != 0 {
    raise FixtureError::Invalid(
      detail="U-mixed event count must be divisible by four",
    )
  }
  let builder = FixtureBuilder::new()
  for block = 0; block < event_count / 4; block = block + 1 {
    let start = builder.visible.length()
    let x = builder.insert("r0-a", builder.chain_parents(), start, "x")
    builder.insert("r0-a", [x.identity], start + 1, "y") |> ignore
    let (deleted_event, deleted) = builder.delete(
      "r0-a",
      builder.chain_parents(),
      start,
    )
    builder.undelete("r0-a", [deleted_event.identity], start, deleted) |> ignore
  }
  builder
}

///|
fn generate_c_short(event_count : Int) -> FixtureBuilder raise FixtureError {
  let builder = FixtureBuilder::new()
  let block_count = event_count / 17
  for block = 0; block < block_count; block = block + 1 {
    let base_length = builder.visible.length()
    let shared = builder.chain_parents()
    let mut a_tip : RawIdentity? = None
    for offset = 0; offset < 8; offset = offset + 1 {
      let parents = match a_tip {
        Some(tip) => [tip]
        None => shared.copy()
      }
      let event = builder.insert(
        "r0-a",
        parents,
        base_length + offset,
        scalar_pattern(builder.events.length()),
      )
      a_tip = Some(event.identity)
    }
    let mut b_tip : RawIdentity? = None
    for offset = 0; offset < 8; offset = offset + 1 {
      let parents = match b_tip {
        Some(tip) => [tip]
        None => shared.copy()
      }
      let event = builder.insert(
        "r0-b",
        parents,
        base_length + offset,
        scalar_pattern(builder.events.length()),
      )
      b_tip = Some(event.identity)
    }
    builder.insert(
      "r0-merge",
      sorted_parents([a_tip.unwrap(), b_tip.unwrap()]),
      base_length + 16,
      scalar_pattern(builder.events.length()),
    )
    |> ignore
  }
  while builder.events.length() < event_count {
    builder.insert(
      "r0-merge",
      builder.chain_parents(),
      builder.visible.length(),
      scalar_pattern(builder.events.length()),
    )
    |> ignore
  }
  builder
}

///|
fn generate_a_long(
  event_count : Int,
  ratio_percent : Int,
) -> FixtureBuilder raise FixtureError {
  let builder = FixtureBuilder::new()
  let branch_total = event_count * ratio_percent / 100
  let a_length = branch_total / 2
  let b_length = branch_total - a_length
  let prefix_length = event_count - branch_total - 1
  if prefix_length < 0 || a_length == 0 || b_length == 0 {
    raise FixtureError::Invalid(detail="A-long scale cannot form both branches")
  }
  for prefix = 0; prefix < prefix_length; prefix = prefix + 1 {
    builder.insert(
      "r0-merge",
      builder.chain_parents(),
      builder.visible.length(),
      scalar_pattern(builder.events.length()),
    )
    |> ignore
  }
  let shared = builder.chain_parents()
  let shared_length = builder.visible.length()
  let mut a_tip : RawIdentity? = None
  for offset = 0; offset < a_length; offset = offset + 1 {
    let parents = match a_tip {
      Some(tip) => [tip]
      None => shared.copy()
    }
    let event = builder.insert(
      "r0-a",
      parents,
      shared_length + offset,
      scalar_pattern(builder.events.length()),
    )
    a_tip = Some(event.identity)
  }
  let mut b_tip : RawIdentity? = None
  for offset = 0; offset < b_length; offset = offset + 1 {
    let parents = match b_tip {
      Some(tip) => [tip]
      None => shared.copy()
    }
    let event = builder.insert(
      "r0-b",
      parents,
      shared_length + offset,
      scalar_pattern(builder.events.length()),
    )
    b_tip = Some(event.identity)
  }
  builder.insert(
    "r0-merge",
    sorted_parents([a_tip.unwrap(), b_tip.unwrap()]),
    builder.visible.length(),
    scalar_pattern(builder.events.length()),
  )
  |> ignore
  builder
}

///|
fn generate_c_multiroot(event_count : Int) -> FixtureBuilder raise FixtureError {
  let builder = FixtureBuilder::new()
  let a_length = event_count / 2
  let b_length = event_count - a_length
  let mut a_tip : RawIdentity? = None
  for offset = 0; offset < a_length; offset = offset + 1 {
    let parents = match a_tip {
      Some(tip) => [tip]
      None => []
    }
    let event = builder.insert(
      "r0-a",
      parents,
      offset,
      scalar_pattern(builder.events.length()),
    )
    a_tip = Some(event.identity)
  }
  let mut b_tip : RawIdentity? = None
  for offset = 0; offset < b_length; offset = offset + 1 {
    let parents = match b_tip {
      Some(tip) => [tip]
      None => []
    }
    let event = builder.insert(
      "r0-b",
      parents,
      offset,
      scalar_pattern(builder.events.length()),
    )
    b_tip = Some(event.identity)
  }
  builder
}

///|
fn fixture_id(
  shape : String,
  event_count : Int,
  ratio_percent : Int?,
) -> String {
  match ratio_percent {
    Some(1) => "A-long-" + event_count.to_string() + "-r001"
    Some(10) => "A-long-" + event_count.to_string() + "-r010"
    Some(50) => "A-long-" + event_count.to_string() + "-r050"
    _ => shape + "-" + event_count.to_string()
  }
}

///|
/// Generate one canonical morphology from an empty document.
fn generate_fixture(
  shape : String,
  event_count : Int,
) -> GeneratedFixture raise FixtureError {
  if event_count <= 0 {
    raise FixtureError::Invalid(detail="fixture event count must be positive")
  }
  let (builder, ratio) = match shape {
    "S-linear"
    | "S-distributed"
    | "S-tombstone"
    | "S-replacement"
    | "S-unicode" => (generate_sequential(shape, event_count), None)
    "C-short" => (generate_c_short(event_count), None)
    "A-long-r001" => (generate_a_long(event_count, 1), Some(1))
    "A-long-r010" => (generate_a_long(event_count, 10), Some(10))
    "A-long-r050" => (generate_a_long(event_count, 50), Some(50))
    "U-mixed" => (generate_u_mixed(event_count), None)
    "C-multiroot" => (generate_c_multiroot(event_count), None)
    _ =>
      raise FixtureError::Invalid(detail="unknown fixture morphology: " + shape)
  }
  let id = fixture_id(shape, event_count, ratio)
  {
    fixture_id: id,
    document_id: "loomark-r0-fixture-" + id,
    events: builder.events,
    replay_order: stable_topological_order(builder.events),
    final_text: visible_text(builder.visible),
  }
}

///|
/// Immutable fixture matrix fixed by the R0 decision contract.
fn required_fixture_specs() -> Array[(String, Int)] {
  [
    ("S-linear", 1000),
    ("S-linear", 10000),
    ("S-linear", 100000),
    ("S-distributed", 1000),
    ("S-distributed", 10000),
    ("S-tombstone", 1000),
    ("S-tombstone", 10000),
    ("S-replacement", 1000),
    ("S-replacement", 10000),
    ("S-unicode", 1000),
    ("S-unicode", 10000),
    ("C-short", 10000),
    ("A-long-r001", 10000),
    ("A-long-r010", 10000),
    ("A-long-r050", 10000),
    ("U-mixed", 1000),
    ("U-mixed", 10000),
    ("C-multiroot", 4),
    ("C-multiroot", 1000),
  ]
}

///|
fn canonical_fixture_bytes(
  fixture : GeneratedFixture,
) -> Bytes raise FixtureError {
  let buffer = Buffer()
  try {
    write_domain(buffer, "loomark-r0-fixture:v1")
    write_lp_utf8(buffer, fixture.fixture_id)
    write_lp_utf8(buffer, fixture.document_id)
    write_uvarint(buffer, fixture.events.length())
    for event in fixture.events {
      write_uvarint(buffer, event.ordinal)
      write_raw_identity(buffer, event.identity)
      write_uvarint(buffer, event.parents.length())
      for parent in event.parents {
        write_raw_identity(buffer, parent)
      }
      write_lp_bytes(buffer, event.canonical_body_bytes)
    }
    write_uvarint(buffer, fixture.replay_order.length())
    for identity in fixture.replay_order {
      write_raw_identity(buffer, identity)
    }
    write_lp_utf8(buffer, fixture.final_text)
  } catch {
    _ => raise FixtureError::Invalid(detail="fixture codec failure")
  }
  buffer.to_bytes()
}

///|
fn catalog_fixture(
  fixture : GeneratedFixture,
) -> CatalogFixture raise FixtureError {
  {
    fixture_id: fixture.fixture_id,
    document_id: fixture.document_id,
    event_count: fixture.events.length(),
    canonical_sha256: sha256_hex(canonical_fixture_bytes(fixture)),
    replay_order: fixture.replay_order,
    final_text: fixture.final_text,
  }
}

///|
/// Generate every scale fixed by the R0 decision contract.
fn generate_required_catalog() -> FixtureCatalog raise FixtureError {
  let fixtures : Array[CatalogFixture] = []
  for spec in required_fixture_specs() {
    let (shape, count) = spec
    fixtures.push(catalog_fixture(generate_fixture(shape, count)))
  }
  { schema_version: 1, fixture_seed: "none", fixtures }
}

///|
/// Generate one required fixture by its immutable catalog identity.
fn generate_required_fixture(
  required_id : String,
) -> GeneratedFixture raise FixtureError {
  for spec in required_fixture_specs() {
    let (shape, count) = spec
    let fixture = generate_fixture(shape, count)
    if fixture.fixture_id == required_id {
      return fixture
    }
  }
  raise FixtureError::Invalid(detail="fixture is not in required catalog")
}

///|
/// Emit the complete catalog without retaining all fixture trees at once.
fn generate_full_catalog_json() -> String raise FixtureError {
  let builder = StringBuilder::new()
  builder.write_string(
    "{\"schema_version\":1,\"fixture_seed\":\"none\",\"fixtures\":[",
  )
  let mut first = true
  for spec in required_fixture_specs() {
    let (shape, count) = spec
    if first {
      first = false
    } else {
      builder.write_char(',')
    }
    builder.write_string(generate_fixture(shape, count).to_full_json_string())
  }
  builder.write_string("]}")
  builder.to_string()
}

///|
/// Emit one fully expanded fixture in the same catalog envelope.
fn generate_single_catalog_json(
  fixture_id : String,
) -> String raise FixtureError {
  "{\"schema_version\":1,\"fixture_seed\":\"none\",\"fixtures\":[" +
  generate_required_fixture(fixture_id).to_full_json_string() +
  "]}"
}
