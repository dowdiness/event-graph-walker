///|
/// Tests for CausalGraph
test "create empty graph" {
  let graph = CausalGraph::new()
  @debug.debug_inspect(graph.get_frontier().to_array(), content="[]")
}

///|
test "add single version" {
  let graph = CausalGraph::new()
  let lv = try! graph.add_version([], "agent1")
  inspect(lv, content="0")
  @debug.debug_inspect(graph.get_frontier().to_array(), content="[0]")
}

///|
test "add version with parent" {
  let graph = CausalGraph::new()
  let lv0 = try! graph.add_version([], "agent1")
  let lv1 = try! graph.add_version([lv0], "agent1")
  inspect(lv1, content="1")
  @debug.debug_inspect(graph.get_frontier().to_array(), content="[1]")
}

///|
test "lv to raw version conversion" {
  let graph = CausalGraph::new()
  let lv = try! graph.add_version([], "agent1")
  match graph.lv_to_raw(lv) {
    Some(raw) => {
      inspect(raw.agent, content="agent1")
      inspect(raw.seq, content="0")
    }
    None => fail("Expected Some(RawVersion)")
  }
}

///|
test "raw to lv version conversion" {
  let graph = CausalGraph::new()
  ignore(try! graph.add_version([], "agent1"))
  let raw = @core.RawVersion("agent1", 0)
  match graph.raw_to_lv(raw) {
    Some(lv_result) => inspect(lv_result, content="0")
    None => fail("Expected Some(LV)")
  }
}

///|
test "concurrent versions create two frontier heads" {
  let graph = CausalGraph::new()
  let lv0 = try! graph.add_version([], "agent1")
  let lv1 = try! graph.add_version([], "agent2") // Concurrent with lv0
  let frontier = graph.get_frontier()
  inspect(frontier.length(), content="2")
  inspect(frontier.to_array().contains(lv0), content="true")
  inspect(frontier.to_array().contains(lv1), content="true")
}

///|
test "duplicate RawVersion is rejected without graph mutation" {
  let graph = CausalGraph::new()
  let first = try! graph.add_version_with_seq([], "alice", 0)
  let before_frontier = graph.get_frontier()
  try graph.add_version_with_seq([], "alice", 0) catch {
    DuplicateVersion(raw~) => assert_eq(raw, @core.RawVersion("alice", 0))
    _ => fail("expected duplicate RawVersion")
  } noraise {
    _ => fail("duplicate RawVersion must be rejected")
  }
  inspect(graph.op_count(), content="1")
  inspect(graph.get_frontier() == before_frontier, content="true")
  assert_eq(graph.raw_to_lv(@core.RawVersion("alice", 0)), Some(0))
  inspect(first, content="0")
}

///|
test "graph admission owns parent storage and rejects invalid identities" {
  let graph = CausalGraph::new()
  let root = try! graph.add_version([], "agent")
  let caller_parents = [root]
  let child = try! graph.add_version(caller_parents, "agent")
  caller_parents.clear()
  assert_true(graph.is_ancestor(root, child))

  let exposed = graph[child].unwrap()
  exposed.parents.clear()
  assert_true(graph.is_ancestor(root, child))
  assert_eq(graph[child].unwrap().parents, [root])

  for raw in [@core.RawVersion("", 0), @core.RawVersion("agent", -1)] {
    try graph.add_version_with_seq([], raw.agent, raw.seq) catch {
      InvalidIdentity(raw=actual) => assert_eq(actual, raw)
      _ => fail("expected invalid identity")
    } noraise {
      _ => fail("invalid identity must be rejected")
    }
  }
  assert_eq(graph.op_count(), 2)
}

///|
test "is_ancestor simple case" {
  let graph = CausalGraph::new()
  let lv0 = try! graph.add_version([], "agent1")
  let lv1 = try! graph.add_version([lv0], "agent1")
  inspect(graph.is_ancestor(lv0, lv1), content="true")
  inspect(graph.is_ancestor(lv1, lv0), content="false")
}

///|
test "graph_diff with no overlap" {
  let graph = CausalGraph::new()
  let lv0 = try! graph.add_version([], "agent1")
  let lv1 = try! graph.add_version([lv0], "agent1")
  let lv2 = try! graph.add_version([lv0], "agent2") // Branch from lv0
  let (retreat, advance) = graph.graph_diff(
    @core.Frontier::from_array([lv1]),
    @core.Frontier::from_array([lv2]),
  )

  // lv1 should be in retreat (not reachable from lv2)
  inspect(retreat.contains(lv1), content="true")
  // lv2 should be in advance (not reachable from lv1)
  inspect(advance.contains(lv2), content="true")
  // lv0 should be in neither (reachable from both)
  inspect(retreat.contains(lv0), content="false")
  inspect(advance.contains(lv0), content="false")
}
