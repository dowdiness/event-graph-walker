///|
/// Tests for CausalGraph
test "create empty graph" {
  let graph = @causal_graph.CausalGraph::new()
  @debug.debug_inspect(graph.get_frontier().to_array(), content="[]")
}

///|
test "add single version" {
  let graph = @causal_graph.CausalGraph::new()
  let lv = try! graph.add_version([], "agent1")
  inspect(lv, content="0")
  @debug.debug_inspect(graph.get_frontier().to_array(), content="[0]")
}

///|
test "add version with parent" {
  let graph = @causal_graph.CausalGraph::new()
  let lv0 = try! graph.add_version([], "agent1")
  let lv1 = try! graph.add_version([lv0], "agent1")
  inspect(lv1, content="1")
  @debug.debug_inspect(graph.get_frontier().to_array(), content="[1]")
}

///|
test "lv to raw version conversion" {
  let graph = @causal_graph.CausalGraph::new()
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
  let graph = @causal_graph.CausalGraph::new()
  ignore(try! graph.add_version([], "agent1"))
  let raw = @core.RawVersion("agent1", 0)
  match graph.raw_to_lv(raw) {
    Some(lv_result) => inspect(lv_result, content="0")
    None => fail("Expected Some(LV)")
  }
}

///|
test "concurrent versions create two frontier heads" {
  let graph = @causal_graph.CausalGraph::new()
  let lv0 = try! graph.add_version([], "agent1")
  let lv1 = try! graph.add_version([], "agent2") // Concurrent with lv0
  let frontier = graph.get_frontier()
  inspect(frontier.length(), content="2")
  inspect(frontier.to_array().contains(lv0), content="true")
  inspect(frontier.to_array().contains(lv1), content="true")
}

///|
test "duplicate RawVersion is rejected without graph mutation" {
  let graph = @causal_graph.CausalGraph::new()
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
test "graph change application owns parent storage and rejects invalid identities" {
  let graph = @causal_graph.CausalGraph::new()
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
  let graph = @causal_graph.CausalGraph::new()
  let lv0 = try! graph.add_version([], "agent1")
  let lv1 = try! graph.add_version([lv0], "agent1")
  inspect(graph.is_ancestor(lv0, lv1), content="true")
  inspect(graph.is_ancestor(lv1, lv0), content="false")
}

///|
test "graph_diff with no overlap" {
  let graph = @causal_graph.CausalGraph::new()
  let lv0 = try! graph.add_version([], "agent1")
  let lv1 = try! graph.add_version([lv0], "agent1")
  let lv2 = try! graph.add_version([lv0], "agent2") // Branch from lv0
  let (retreat, advance) = graph.diff_frontiers_lvs(
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

///|
test "continuous identities preserve interior branches sparse roots and maximum sequence" {
  let g = @causal_graph.CausalGraph::new()
  for i in 0..<100 {
    let parents = if i == 0 { [] } else { [i - 1] }
    assert_eq(g.add_version_with_seq(parents, "a", 1000 + i), i)
  }
  let saved = g.current_graph_version()
  // A later child of an interior entry must coexist with its implicit successor.
  assert_eq(g.add_version_with_seq([37, 37], "branch", 0), 100)
  assert_eq(g.children_counts()[37], 3)
  assert_eq(g.get_entry(100).unwrap().parents, [37, 37])
  assert_eq(g.get_entry(100).unwrap().timestamp, 38)
  assert_true(g.is_ancestor(37, 100))
  assert_false(g.is_ancestor(38, 100))
  // Sequence order is not LV order and is not an implicit causal edge.
  assert_eq(g.add_version_with_seq([], "a", 4), 101)
  assert_eq(g.add_version_with_seq([101], "a", 5), 102)
  assert_false(g.is_ancestor(99, 102))
  for i in 0..<100 {
    let entry = g.get_entry(i).unwrap()
    assert_eq(entry.seq, 1000 + i)
    assert_eq(entry.timestamp, i)
    assert_eq(entry.parents, if i == 0 { [] } else { [i - 1] })
    assert_eq(g.raw_to_lv(@core.RawVersion("a", 1000 + i)), Some(i))
  }
  assert_eq(g.raw_to_lv(@core.RawVersion("a", 4)), Some(101))
  assert_eq(g.raw_to_lv(@core.RawVersion("a", 5)), Some(102))
  for missing in [-1, 3, 6, 999, 1100, 2147483647] {
    assert_eq(g.raw_to_lv(@core.RawVersion("a", missing)), None)
  }
  assert_eq(g.resolve_graph_version(saved).unwrap().to_array(), [99])
  let max1 = g.add_version_with_seq([102], "max", 2147483646)
  let max2 = g.add_version_with_seq([max1], "max", 2147483647)
  assert_eq(g.lv_to_raw(max2), Some(@core.RawVersion("max", 2147483647)))
  assert_eq(g.raw_to_lv(@core.RawVersion("max", 2147483647)), Some(max2))
  // The maximum sequence must also resolve outside the latest run.
  ignore(g.add_version_with_seq([max2], "tail", 0))
  assert_eq(g.raw_to_lv(@core.RawVersion("max", 2147483646)), Some(max1))
  assert_eq(g.raw_to_lv(@core.RawVersion("max", 2147483647)), Some(max2))
  assert_eq(g.raw_to_lv(@core.RawVersion("max", 2147483645)), None)
  let version = g.current_graph_version()
  assert_true(
    try g.add_version_with_seq([], "a", 1042) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_eq(g.current_graph_version(), version)
}

///|
test "identity lookup preserves gaps and growing ranges after nested page splits" {
  for descending in [true, false] {
    let graph = @causal_graph.CausalGraph::new()
    // Enough independently addressed intervals to split both leaves and branches.
    for i in 0..<6144 {
      let group = if descending { 2047 - i / 3 } else { i / 3 * 37 % 2048 }
      let seq = group * 4 + i % 3
      assert_eq(
        graph.add_version_with_seq(if i == 0 { [] } else { [i - 1] }, "a", seq),
        i,
      )
      for offset in 0..<=(i % 3) {
        assert_eq(
          graph.raw_to_lv(@core.RawVersion("a", group * 4 + offset)),
          Some(i - i % 3 + offset),
        )
      }
      assert_eq(graph.raw_to_lv(@core.RawVersion("a", group * 4 + 3)), None)
    }
    for i in 0..<6144 {
      let lv = if i % 2 == 0 { i / 2 } else { 6143 - i / 2 }
      let group = if descending { 2047 - lv / 3 } else { lv / 3 * 37 % 2048 }
      let raw = @core.RawVersion("a", group * 4 + lv % 3)
      assert_eq(graph.lv_to_raw(lv), Some(raw))
      assert_eq(graph.raw_to_lv(raw), Some(lv))
    }
  }
}
