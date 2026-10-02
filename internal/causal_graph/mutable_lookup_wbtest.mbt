///|
test "owned lookup maps preserve snapshots and reject before mutation" {
  let graph = CausalGraph::new()
  let root = try! graph.add_version_with_seq([], "writer", 50)
  let old = graph.current_graph_version()
  let frontier = graph.get_frontier()
  let entry = graph.get_entry(root).unwrap()
  let count = graph.op_count()
  for
    invalid in [
      ([], "writer", 50),
      ([999], "writer", 51),
      ([], "", 0),
      ([], "writer", -1),
    ] {
    let (parents, agent, seq) = invalid
    try graph.add_version_with_seq(parents, agent, seq) catch {
      _ => ()
    } noraise {
      _ => fail("expected invalid graph insertion to raise")
    }
    assert_eq(graph.op_count(), count)
    assert_eq(graph.get_frontier(), frontier)
    assert_eq(graph.raw_to_lv(@core.RawVersion("writer", 50)), Some(root))
    assert_eq(graph.raw_to_lv(@core.RawVersion("writer", 51)), None)
  }
  ignore(try! graph.add_version_with_seq([root], "writer", 10))
  let next = try! graph.add_version([1], "writer")
  assert_eq(graph.lv_to_raw(next), Some(@core.RawVersion("writer", 51)))
  assert_true(!old.contains(@core.RawVersion("writer", 10)))
  assert_true(!old.contains(@core.RawVersion("writer", 51)))
  assert_eq(frontier.to_array(), [root])
  assert_eq(entry.parents, [])
}

///|
test "local sequence overflow does not change graph authority" {
  let graph = CausalGraph::new()
  let last = try! graph.add_version_with_seq([], "max-writer", 2147483647)
  let before = graph.current_graph_version()
  let frontier = graph.get_frontier()
  try graph.add_version([last], "max-writer") catch {
    _ => ()
  } noraise {
    _ => fail("expected sequence overflow to raise")
  }
  assert_eq(graph.op_count(), 1)
  assert_eq(graph.get_frontier(), frontier)
  assert_eq(graph.current_graph_version().ranges(), before.ranges())
  assert_eq(graph.raw_to_lv(@core.RawVersion("max-writer", -2147483648)), None)
}

///|
test "owned maps preserve many agent identities and sparse sequence allocation" {
  let graph = CausalGraph::new()
  for seq = 0; seq < 8; seq = seq + 1 {
    for agent = 0; agent < 256; agent = agent + 1 {
      let count = graph.op_count()
      let parents = if count == 0 { [] } else { [count - 1] }
      ignore(
        try! graph.add_version_with_seq(parents, "agent-\{agent}", seq * 2),
      )
    }
  }
  for seq = 0; seq < 8; seq = seq + 1 {
    for agent = 0; agent < 256; agent = agent + 1 {
      assert_eq(
        graph.raw_to_lv(@core.RawVersion("agent-\{agent}", seq * 2)),
        Some(seq * 256 + agent),
      )
    }
  }
  let local_lv = try! graph.add_version([graph.op_count() - 1], "agent-0")
  assert_eq(graph.lv_to_raw(local_lv), Some(@core.RawVersion("agent-0", 15)))
}
