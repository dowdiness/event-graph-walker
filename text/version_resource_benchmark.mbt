///|
fn version_resource_agent_name(index : Int) -> String {
  let digits = index.to_string()
  "agent-" + "0".repeat(5 - digits.length()) + digits
}

///|
/// Construct a canonical Version DTO with independent per-agent frontiers and
/// non-adjacent even sequence numbers. Mutation is confined to fixture building.
fn version_resource_fixture(
  agent_count : Int,
  ranges_per_agent : Int,
) -> Version {
  let frontier : Array[@core.RawVersion] = []
  let ranges : Array[(String, Array[(UInt, UInt)])] = []
  for agent_index in 0..<agent_count {
    let agent = version_resource_agent_name(agent_index)
    let agent_ranges : Array[(UInt, UInt)] = []
    for range_index in 0..<ranges_per_agent {
      let start = (range_index * 2).reinterpret_as_uint()
      agent_ranges.push((start, start + 1U))
    }
    frontier.push(@core.RawVersion(agent, (ranges_per_agent - 1) * 2))
    ranges.push((agent, agent_ranges))
  }
  Version::from_graph_version(
    try! @causal_graph.GraphVersion::from_parts(frontier, ranges),
  )
}

///|
fn version_resource_json(
  label : String,
  agent_count : Int,
  ranges_per_agent : Int,
) -> String raise Failure {
  let encoded = try! version_resource_fixture(agent_count, ranges_per_agent).to_json_string()
  let encoded_bytes = @utf8.encode(encoded).length()
  guard encoded_bytes <= 1024 * 1024 else {
    fail("resource fixture exceeds 1 MiB: " + label)
  }
  println(
    "resource fixture " + label + ": " + encoded_bytes.to_string() + " bytes",
  )
  encoded
}

///|
fn version_resource_unchecked_json(
  label : String,
  agent_count : Int,
  ranges_per_agent : Int,
) -> String raise Failure {
  let version = version_resource_fixture(agent_count, ranges_per_agent)
  let graph_version = version.graph()
  let encoded = Json::object({
    "schema": text_schema.to_json(),
    "format": text_version_format.to_json(),
    "frontier": version_frontier_json(graph_version.frontier()),
    "ranges": version_ranges_json(graph_version.ranges()),
  }).stringify()
  let encoded_bytes = @utf8.encode(encoded).length()
  guard encoded_bytes <= 1024 * 1024 else {
    fail("resource fixture exceeds 1 MiB: " + label)
  }
  println(
    "resource fixture " + label + ": " + encoded_bytes.to_string() + " bytes",
  )
  encoded
}

///|
fn version_resource_is_rejected(encoded : String) -> Bool {
  try {
    ignore(Version::from_json_string(encoded))
    false
  } catch {
    TextError::SyncFailed(@sync.Failure::LimitExceeded(..)) => true
    _ => false
  }
}

///|
fn version_resource_encoding_is_rejected(version : Version) -> Bool {
  try {
    ignore(version.to_json_string())
    false
  } catch {
    TextError::SyncFailed(@sync.Failure::LimitExceeded(..)) => true
    _ => false
  }
}

///|
fn version_resource_text_state(
  agent_count : Int,
  ranges_per_agent : Int,
) -> TextState raise @document.DocumentError {
  let document = @document.Document::new("resource-receiver")
  let operations : Array[@core.Op] = []
  for agent_index in 0..<agent_count {
    let agent = version_resource_agent_name(agent_index)
    let mut previous : @core.RawVersion? = None
    for range_index in 0..<ranges_per_agent {
      let sequence = range_index * 2
      let raw = @core.RawVersion(agent, sequence)
      let parents = match previous {
        Some(parent) => [parent]
        None => []
      }
      operations.push(
        @core.Op::insert(0, parents, agent, sequence, "x", previous, None),
      )
      previous = Some(raw)
    }
  }
  ignore(
    document.admit_remote(
      operations,
      max_pending=operations.length(),
      max_pending_after_complete=0,
    ),
  )
  TextState::{ inner: document, sync_limits: @sync.Limits::default() }
}

///|
test "resource: reject Version (1 agent x 37000 ranges)" (b : @bench.T) {
  let encoded = version_resource_unchecked_json("1x37000", 1, 37000)
  b.bench(() => b.keep(version_resource_is_rejected(encoded)))
}

///|
test "resource: reject Version (8000 agents x 1 range)" (b : @bench.T) {
  let encoded = version_resource_unchecked_json("8000x1", 8000, 1)
  b.bench(() => b.keep(version_resource_is_rejected(encoded)))
}

///|
test "resource: reject Version (512 agents x 64 ranges)" (b : @bench.T) {
  let encoded = version_resource_unchecked_json("512x64", 512, 64)
  b.bench(() => b.keep(version_resource_is_rejected(encoded)))
}

///|
test "resource: reject local Version encoding (1 agent x 37000 ranges)" (
  b : @bench.T,
) {
  let version = version_resource_fixture(1, 37000)
  b.bench(() => b.keep(version_resource_encoding_is_rejected(version)))
}

///|
test "resource: export_since (1 agent x 37000 ranges)" (b : @bench.T) {
  let document = version_resource_text_state(1, 37000)
  let current = document.version()
  b.bench(() => b.keep(try! document.sync().export_since(current)))
}

///|
test "resource: export_since (8000 agents x 1 range)" (b : @bench.T) {
  let document = version_resource_text_state(8000, 1)
  let current = document.version()
  b.bench(() => b.keep(try! document.sync().export_since(current)))
}

///|
test "resource: export_since (512 agents x 64 ranges)" (b : @bench.T) {
  let document = version_resource_text_state(512, 64)
  let current = document.version()
  b.bench(() => b.keep(try! document.sync().export_since(current)))
}

///|
test "resource limit: decode Version (1 agent x 4096 ranges)" (b : @bench.T) {
  let encoded = version_resource_json("1x4096", 1, 4096)
  b.bench(() => b.keep(try! Version::from_json_string(encoded)))
}

///|
test "resource limit: decode Version (4096 agents x 1 range)" (b : @bench.T) {
  let encoded = version_resource_json("4096x1", 4096, 1)
  b.bench(() => b.keep(try! Version::from_json_string(encoded)))
}

///|
test "resource limit: decode Version (64 agents x 64 ranges)" (b : @bench.T) {
  let encoded = version_resource_json("64x64", 64, 64)
  b.bench(() => b.keep(try! Version::from_json_string(encoded)))
}

///|
test "resource limit: export_since (1 agent x 4096 ranges)" (b : @bench.T) {
  let document = version_resource_text_state(1, 4096)
  let current = document.version()
  b.bench(() => b.keep(try! document.sync().export_since(current)))
}

///|
test "resource limit: export_since (4096 agents x 1 range)" (b : @bench.T) {
  let document = version_resource_text_state(4096, 1)
  let current = document.version()
  b.bench(() => b.keep(try! document.sync().export_since(current)))
}

///|
test "resource limit: export_since (64 agents x 64 ranges)" (b : @bench.T) {
  let document = version_resource_text_state(64, 64)
  let current = document.version()
  b.bench(() => b.keep(try! document.sync().export_since(current)))
}
