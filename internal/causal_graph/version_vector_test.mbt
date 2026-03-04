///| Tests for VersionVector

///|
test "create empty version vector" {
  let vv = VersionVector::new()
  inspect(vv.0.is_empty(), content="true")
  inspect(vv.0.length(), content="0")
  inspect(vv.to_string(), content="VersionVector({})")
}

///|
test "set and get version" {
  let vv = VersionVector::new()
  let vv = vv.set("alice", 5)
  inspect(vv.0.get("alice"), content="Some(5)")
  inspect(vv.0.get("bob"), content="None")
}

///|
test "increment version" {
  let vv = VersionVector::new()
  let vv = vv.increment("alice")
  inspect(vv.0.get("alice"), content="Some(0)")
  let vv = vv.increment("alice")
  inspect(vv.0.get("alice"), content="Some(1)")
  let vv = vv.increment("alice")
  inspect(vv.0.get("alice"), content="Some(2)")
}

///|
test "multiple agents" {
  let vv = VersionVector::new()
  let vv = vv.set("alice", 3)
  let vv = vv.set("bob", 7)
  let vv = vv.set("charlie", 2)
  inspect(vv.0.length(), content="3")
  inspect(vv.0.get("alice"), content="Some(3)")
  inspect(vv.0.get("bob"), content="Some(7)")
  inspect(vv.0.get("charlie"), content="Some(2)")
}

///|
test "merge version vectors - no overlap" {
  let vv1 = VersionVector::new().set("alice", 5)
  let vv2 = VersionVector::new().set("bob", 3)
  let merged = vv1.merge(vv2)
  inspect(merged.0.get("alice"), content="Some(5)")
  inspect(merged.0.get("bob"), content="Some(3)")
}

///|
test "merge version vectors - with overlap" {
  let vv1 = VersionVector::new().set("alice", 5).set("bob", 2)
  let vv2 = VersionVector::new().set("alice", 3).set("bob", 7)
  let merged = vv1.merge(vv2)
  inspect(merged.0.get("alice"), content="Some(5)")
  inspect(merged.0.get("bob"), content="Some(7)")
}

///|
test "version vector equality - equal" {
  let vv1 = VersionVector::new().set("alice", 5).set("bob", 3)
  let vv2 = VersionVector::new().set("alice", 5).set("bob", 3)
  inspect(vv1 == vv2, content="true")
}

///|
test "version vector equality - not equal" {
  let vv1 = VersionVector::new().set("alice", 5).set("bob", 3)
  let vv2 = VersionVector::new().set("alice", 5).set("bob", 4)
  inspect(vv1 == vv2, content="false")
}

///|
test "version vector equality - different agents" {
  let vv1 = VersionVector::new().set("alice", 5)
  let vv2 = VersionVector::new().set("bob", 5)
  inspect(vv1 == vv2, content="false")
}

///|
test "version vector less than or equal - true" {
  let vv1 = VersionVector::new().set("alice", 3).set("bob", 2)
  let vv2 = VersionVector::new().set("alice", 5).set("bob", 4)
  inspect(vv1 <= vv2, content="true")
}

///|
test "version vector less than or equal - false" {
  let vv1 = VersionVector::new().set("alice", 6).set("bob", 2)
  let vv2 = VersionVector::new().set("alice", 5).set("bob", 4)
  inspect(vv1 <= vv2, content="false")
}

///|
test "version vector less than or equal - equal is le" {
  let vv1 = VersionVector::new().set("alice", 5).set("bob", 3)
  let vv2 = VersionVector::new().set("alice", 5).set("bob", 3)
  inspect(vv1 <= vv2, content="true")
}

///|
test "version vector less than or equal - missing agent" {
  let vv1 = VersionVector::new().set("alice", 5).set("bob", 3)
  let vv2 = VersionVector::new().set("alice", 5)
  inspect(vv1 <= vv2, content="false")
}

///|
test "version vector concurrent - true" {
  let vv1 = VersionVector::new().set("alice", 5).set("bob", 2)
  let vv2 = VersionVector::new().set("alice", 3).set("bob", 7)
  inspect(vv1.concurrent(vv2), content="true")
}

///|
test "version vector concurrent - false when one is ancestor" {
  let vv1 = VersionVector::new().set("alice", 3).set("bob", 2)
  let vv2 = VersionVector::new().set("alice", 5).set("bob", 4)
  inspect(vv1.concurrent(vv2), content="false")
}

///|
test "version vector includes version - true" {
  let vv = VersionVector::new().set("alice", 5).set("bob", 3)
  inspect(vv.includes("alice", 3), content="true")
  inspect(vv.includes("alice", 5), content="true")
  inspect(vv.includes("bob", 0), content="true")
}

///|
test "version vector includes version - false" {
  let vv = VersionVector::new().set("alice", 5).set("bob", 3)
  inspect(vv.includes("alice", 6), content="false")
  inspect(vv.includes("charlie", 0), content="false")
}

///|
test "version vector to string" {
  let vv = VersionVector::new().set("alice", 5).set("bob", 3).set("charlie", 7)
  // Note: order may vary, so we just check it contains the right format
  let str = vv.to_string()
  inspect(str.contains("\"alice\": 5"), content="true")
  inspect(str.contains("\"bob\": 3"), content="true")
  inspect(str.contains("\"charlie\": 7"), content="true")
}

///|
test "from_frontier - simple linear history" {
  let graph = CausalGraph::new()
  let lv0 = try! graph.add_version([], "alice")
  let lv1 = try! graph.add_version([lv0], "alice")
  let lv2 = try! graph.add_version([lv1], "alice")
  let frontier = @core.Frontier::from_array([lv2])
  let vv = VersionVector::from_frontier(graph, frontier)
  inspect(vv.0.get("alice"), content="Some(2)")
}

///|
test "from_frontier - multiple agents" {
  let graph = CausalGraph::new()
  let lv0 = try! graph.add_version([], "alice")
  let lv1 = try! graph.add_version([lv0], "alice")
  let lv2 = try! graph.add_version([], "bob")
  let lv3 = try! graph.add_version([lv2], "bob")
  let frontier = @core.Frontier::from_array([lv1, lv3])
  let vv = VersionVector::from_frontier(graph, frontier)
  inspect(vv.0.get("alice"), content="Some(1)")
  inspect(vv.0.get("bob"), content="Some(1)")
}

///|
test "from_frontier - concurrent branches" {
  let graph = CausalGraph::new()
  let lv0 = try! graph.add_version([], "alice")
  let lv1 = try! graph.add_version([lv0], "alice")
  let lv2 = try! graph.add_version([lv0], "bob")
  let lv3 = try! graph.add_version([lv2], "bob")
  let frontier = @core.Frontier::from_array([lv1, lv3])
  let vv = VersionVector::from_frontier(graph, frontier)
  inspect(vv.0.get("alice"), content="Some(1)")
  inspect(vv.0.get("bob"), content="Some(1)")
}

///|
test "to_frontier - single agent" {
  let graph = CausalGraph::new()
  let lv0 = try! graph.add_version([], "alice")
  let lv1 = try! graph.add_version([lv0], "alice")
  let lv2 = try! graph.add_version([lv1], "alice")
  let vv = VersionVector::new().set("alice", 2)
  let frontier = vv.to_frontier(graph)
  inspect(frontier.0.length(), content="1")
  inspect(frontier.0.contains(lv2), content="true")
}

///|
test "to_frontier - multiple agents" {
  let graph = CausalGraph::new()
  let lv0 = try! graph.add_version([], "alice")
  let lv1 = try! graph.add_version([lv0], "alice")
  let lv2 = try! graph.add_version([], "bob")
  let lv3 = try! graph.add_version([lv2], "bob")
  let vv = VersionVector::new().set("alice", 1).set("bob", 1)
  let frontier = vv.to_frontier(graph)
  inspect(frontier.0.length(), content="2")
  inspect(frontier.0.contains(lv1), content="true")
  inspect(frontier.0.contains(lv3), content="true")
}

///|
test "roundtrip - frontier to version vector and back" {
  let graph = CausalGraph::new()
  let lv0 = try! graph.add_version([], "alice")
  let lv1 = try! graph.add_version([lv0], "alice")
  let lv2 = try! graph.add_version([], "bob")
  let lv3 = try! graph.add_version([lv2], "bob")
  let lv4 = try! graph.add_version([lv1, lv3], "charlie")
  let original_frontier = @core.Frontier::from_array([lv4])
  let vv = VersionVector::from_frontier(graph, original_frontier)
  let recovered_frontier = vv.to_frontier(graph)

  // The recovered frontier should be equivalent to the original
  // (it might be a different LV set, but represents the same version vector)
  let vv2 = VersionVector::from_frontier(graph, recovered_frontier)
  inspect(vv == vv2, content="true")
}

///|
test "version vector agents" {
  let vv = VersionVector::new().set("alice", 5).set("bob", 3).set("charlie", 7)
  let agents = vv.agents()
  inspect(agents.length(), content="3")
  inspect(agents.contains("alice"), content="true")
  inspect(agents.contains("bob"), content="true")
  inspect(agents.contains("charlie"), content="true")
}

///|
test "version vector to_json" {
  let vv = VersionVector::new().set("alice", 5).set("bob", 3)
  let json = vv.to_json()
  // Should be a JSON object with string keys and int values
  // Note: order may vary, so we check it contains the expected data
  let json_str = json.stringify()
  inspect(json_str.contains("alice"), content="true")
  inspect(json_str.contains("bob"), content="true")
}

///|
test "version vector json stringify" {
  let original = VersionVector::new()
    .set("alice", 5)
    .set("bob", 3)
    .set("charlie", 7)
  let json = original.to_json()
  let json_str = json.stringify()
  // Check that the JSON contains all the expected agents and values
  inspect(json_str.contains("alice"), content="true")
  inspect(json_str.contains("bob"), content="true")
  inspect(json_str.contains("charlie"), content="true")
}

// =============================================================================
// Empty VersionVector operations
// =============================================================================

///|
test "empty version vector - comparison with itself" {
  let empty = VersionVector::new()
  inspect(empty == empty, content="true")
  inspect(empty <= empty, content="true")
  inspect(empty.compare(empty), content="0")
}

///|
test "empty version vector - comparison with non-empty" {
  let empty = VersionVector::new()
  let non_empty = VersionVector::new().set("alice", 5)
  // Empty is <= any other (has no agents that could be greater)
  inspect(empty <= non_empty, content="true")
  // Non-empty is NOT <= empty (has agents empty doesn't have)
  inspect(non_empty <= empty, content="false")
  inspect(empty.compare(non_empty), content="-1")
  inspect(non_empty.compare(empty), content="1")
}

///|
test "empty version vector - concurrent check" {
  let empty = VersionVector::new()
  let non_empty = VersionVector::new().set("alice", 5)
  // Empty is not concurrent with itself (empty <= empty)
  inspect(empty.concurrent(empty), content="false")
  // Empty is not concurrent with non-empty (empty <= non_empty)
  inspect(empty.concurrent(non_empty), content="false")
}

///|
test "empty version vector - merge with empty" {
  let empty1 = VersionVector::new()
  let empty2 = VersionVector::new()
  let merged = empty1.merge(empty2)
  inspect(merged.0.is_empty(), content="true")
}

///|
test "empty version vector - merge with non-empty" {
  let empty = VersionVector::new()
  let non_empty = VersionVector::new().set("alice", 5).set("bob", 3)
  let merged = empty.merge(non_empty)
  inspect(merged.0.get("alice"), content="Some(5)")
  inspect(merged.0.get("bob"), content="Some(3)")
  // Merge is symmetric
  let merged2 = non_empty.merge(empty)
  inspect(merged2.0.get("alice"), content="Some(5)")
  inspect(merged2.0.get("bob"), content="Some(3)")
}

///|
test "empty version vector - agents list" {
  let empty = VersionVector::new()
  inspect(empty.agents().length(), content="0")
}

///|
test "empty version vector - includes check" {
  let empty = VersionVector::new()
  // Empty vector includes nothing
  inspect(empty.includes("alice", 0), content="false")
  inspect(empty.includes("alice", 1), content="false")
  inspect(empty.includes("nonexistent", 0), content="false")
}

///|
test "empty version vector - increment creates new agent" {
  let empty = VersionVector::new()
  let incremented = empty.increment("alice")
  inspect(incremented.0.get("alice"), content="Some(0)")
  inspect(incremented.0.length(), content="1")
}

///|
test "empty version vector - set creates new agent" {
  let empty = VersionVector::new()
  let updated = empty.set("alice", 42)
  inspect(updated.0.get("alice"), content="Some(42)")
}

///|
test "empty version vector - to_frontier on empty graph" {
  let graph = CausalGraph::new()
  let empty = VersionVector::new()
  let frontier = empty.to_frontier(graph)
  inspect(frontier.0.length(), content="0")
}

///|
test "empty version vector - from_frontier with empty frontier" {
  let graph = CausalGraph::new()
  let empty_frontier = @core.Frontier::from_array([])
  let vv = VersionVector::from_frontier(graph, empty_frontier)
  inspect(vv.0.is_empty(), content="true")
}

///|
test "empty version vector - json roundtrip" {
  let empty = VersionVector::new()
  let json = empty.to_json()
  let parsed : VersionVector = @json.from_json(json)
  inspect(parsed.0.is_empty(), content="true")
  inspect(empty == parsed, content="true")
}
