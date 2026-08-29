///|
fn version_json_unchecked(version : Version) -> String {
  let graph_version = version.graph()
  Json::object({
    "schema": text_schema.to_json(),
    "format": text_version_format.to_json(),
    "frontier": version_frontier_json(graph_version.frontier()),
    "ranges": version_ranges_json(graph_version.ranges()),
  }).stringify()
}

///|
fn assert_version_limit(
  encoded : String,
  expected_kind : @sync.LimitKind,
  expected_limit : Int,
) -> Unit raise {
  ignore(Version::from_json_string(encoded)) catch {
    TextError::SyncFailed(@sync.Failure::LimitExceeded(kind~, limit~, actual=_)) => {
      assert_eq(kind, expected_kind)
      assert_eq(limit, expected_limit)
      return
    }
    _ => fail("expected a Version resource-limit failure")
  }
  fail("oversized Version must be rejected")
}

///|
fn assert_version_encode_limit(
  version : Version,
  expected_kind : @sync.LimitKind,
  expected_limit : Int,
) -> Unit raise {
  try {
    ignore(version.to_json_string())
    fail("oversized Version must not be encoded")
  } catch {
    TextError::SyncFailed(@sync.Failure::LimitExceeded(kind~, limit~, actual=_)) => {
      assert_eq(kind, expected_kind)
      assert_eq(limit, expected_limit)
    }
    error => raise error
  }
}

///|
test "Version encoder rejects more than 4096 total ranges" {
  assert_version_encode_limit(
    version_resource_fixture(1, 4097),
    @sync.LimitKind::DecodedOperations,
    4096,
  )
}

///|
test "Version encoder rejects more than 4096 frontier entries" {
  let frontier : Array[@core.RawVersion] = []
  for sequence in 0..<=4096 {
    frontier.push(@core.RawVersion("agent", sequence))
  }
  let graph_version = try! @causal_graph.GraphVersion::from_parts(frontier, [
    ("agent", [(0U, 4097U)]),
  ])
  assert_version_encode_limit(
    Version::from_graph_version(graph_version),
    @sync.LimitKind::DecodedOperations,
    4096,
  )
}

///|
test "Version encoder rejects more than 4096 agent entries" {
  let ranges : Array[(String, Array[(UInt, UInt)])] = []
  for agent_index in 0..<=4096 {
    ranges.push((version_resource_agent_name(agent_index), [(0U, 1U)]))
  }
  let graph_version = try! @causal_graph.GraphVersion::from_parts(
    [@core.RawVersion(version_resource_agent_name(0), 0)],
    ranges,
  )
  assert_version_encode_limit(
    Version::from_graph_version(graph_version),
    @sync.LimitKind::DecodedOperations,
    4096,
  )
}

///|
test "Version encoder rejects output above 512 KiB" {
  let agent = "a".repeat(512 * 1024)
  let graph_version = try! @causal_graph.GraphVersion::from_parts(
    [@core.RawVersion(agent, 0)],
    [(agent, [(0U, 1U)])],
  )
  assert_version_encode_limit(
    Version::from_graph_version(graph_version),
    @sync.LimitKind::EncodedBytes,
    512 * 1024,
  )
}

///|
test "admitted fragmented Version reports local encoding failure" {
  let document = try! version_resource_text_state(1, 4097)
  assert_version_encode_limit(
    document.version(),
    @sync.LimitKind::DecodedOperations,
    4096,
  )
}

///|
test "Version accepts the 4096-entry resource boundaries" {
  let range_boundary = try! version_resource_fixture(1, 4096).to_json_string()
  let decoded_ranges = try! Version::from_json_string(range_boundary)
  assert_eq(try! decoded_ranges.to_json_string(), range_boundary)
  let agent_boundary = try! version_resource_fixture(4096, 1).to_json_string()
  let decoded_agents = try! Version::from_json_string(agent_boundary)
  assert_eq(try! decoded_agents.to_json_string(), agent_boundary)
  let frontier : Array[@core.RawVersion] = []
  for sequence in 0..<4096 {
    frontier.push(@core.RawVersion("agent", sequence))
  }
  let frontier_boundary = try! Version::from_graph_version(
    try! @causal_graph.GraphVersion::from_parts(frontier, [
      ("agent", [(0U, 4096U)]),
    ]),
  ).to_json_string()
  let decoded_frontier = try! Version::from_json_string(frontier_boundary)
  assert_eq(try! decoded_frontier.to_json_string(), frontier_boundary)
}

///|
test "Version rejects more than 4096 agent entries" {
  let entries : Array[Json] = []
  for agent in 0..<=4096 {
    entries.push(
      Json::object({
        "replica_id": ("agent-" + agent.to_string()).to_json(),
        "ranges": Json::array([]),
      }),
    )
  }
  let encoded = Json::object({
    "schema": (2).to_json(),
    "format": "event-graph-walker/text-version".to_json(),
    "frontier": Json::array([]),
    "ranges": Json::array(entries),
  }).stringify()
  assert_version_limit(encoded, @sync.LimitKind::DecodedOperations, 4096)
}

///|
test "Version rejects more than 4096 total ranges" {
  assert_version_limit(
    version_json_unchecked(version_resource_fixture(1, 4097)),
    @sync.LimitKind::DecodedOperations,
    4096,
  )
}

///|
test "Version rejects more than 4096 frontier entries" {
  let frontier : Array[@core.RawVersion] = []
  for sequence in 0..<=4096 {
    frontier.push(@core.RawVersion("agent", sequence))
  }
  let graph_version = try! @causal_graph.GraphVersion::from_parts(frontier, [
    ("agent", [(0U, 4097U)]),
  ])
  let encoded = version_json_unchecked(
    Version::from_graph_version(graph_version),
  )
  assert_version_limit(encoded, @sync.LimitKind::DecodedOperations, 4096)
}

///|
test "Version rejects encoded input above 512 KiB before parsing" {
  assert_version_limit(
    "x".repeat(512 * 1024 + 1),
    @sync.LimitKind::EncodedBytes,
    512 * 1024,
  )
}
