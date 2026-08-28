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
test "Version accepts the 4096-entry resource boundaries" {
  let range_boundary = version_resource_fixture(1, 4096).to_json_string()
  let decoded_ranges = try! Version::from_json_string(range_boundary)
  assert_eq(decoded_ranges.to_json_string(), range_boundary)
  let agent_boundary = version_resource_fixture(4096, 1).to_json_string()
  let decoded_agents = try! Version::from_json_string(agent_boundary)
  assert_eq(decoded_agents.to_json_string(), agent_boundary)
  let frontier : Array[@core.RawVersion] = []
  for sequence in 0..<4096 {
    frontier.push(@core.RawVersion("agent", sequence))
  }
  let frontier_boundary = Version::from_graph_version(
    try! @causal_graph.GraphVersion::from_parts(frontier, [
      ("agent", [(0U, 4096U)]),
    ]),
  ).to_json_string()
  let decoded_frontier = try! Version::from_json_string(frontier_boundary)
  assert_eq(decoded_frontier.to_json_string(), frontier_boundary)
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
    version_resource_fixture(1, 4097).to_json_string(),
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
  let encoded = Version::from_graph_version(graph_version).to_json_string()
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
