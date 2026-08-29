///|
test "graph version canonicalizes sparse identities with one union algorithm" {
  let graph = CausalGraph::new()
  ignore(try! graph.add_version_with_seq([], "agent", 4))
  ignore(try! graph.add_version_with_seq([], "agent", 0))
  ignore(try! graph.add_version_with_seq([], "agent", 2))
  ignore(try! graph.add_version_with_seq([], "agent", 1))
  ignore(try! graph.add_version_with_seq([], "agent", 3))
  let version = graph.current_graph_version()
  @debug.debug_inspect(version.ranges(), content="[(\"agent\", [(0, 5)])]")
  for sequence in 0..<5 {
    assert_true(version.contains(@core.RawVersion("agent", sequence)))
  }
}

///|
test "cold snapshot becomes hot and advances without mutating old values" {
  let graph = CausalGraph::new()
  let first = try! graph.add_version_with_seq([], "agent", 0)
  let old = graph.current_graph_version()
  ignore(try! graph.add_version_with_seq([], "agent", 2))
  let sparse = graph.current_graph_version()
  ignore(try! graph.add_version_with_seq([], "agent", 1))
  let bridged = graph.current_graph_version()
  @debug.debug_inspect(old.ranges(), content="[(\"agent\", [(0, 1)])]")
  @debug.debug_inspect(
    sparse.ranges(),
    content="[(\"agent\", [(0, 1), (2, 3)])]",
  )
  @debug.debug_inspect(bridged.ranges(), content="[(\"agent\", [(0, 3)])]")
  assert_eq(
    graph.resolve_graph_version(old),
    Some(@core.Frontier::from_array([first])),
  )
}

///|
test "resolve rejects knowledge outside the checkpoint closure" {
  let graph = CausalGraph::new()
  ignore(try! graph.add_version_with_seq([], "agent", 0))
  ignore(try! graph.add_version_with_seq([], "agent", 1))
  let false_claim = try! GraphVersion::from_parts(
    [@core.RawVersion("agent", 0)],
    [("agent", [(0U, 2U)])],
  )
  assert_eq(graph.resolve_graph_version(false_claim), None)
}

///|
test "resolve rejects a redundant nonmaximal checkpoint" {
  let graph = CausalGraph::new()
  let root = try! graph.add_version_with_seq([], "agent", 0)
  let child = try! graph.add_version_with_seq([root], "agent", 1)
  let redundant = try! GraphVersion::from_parts(
    [@core.RawVersion("agent", 0), @core.RawVersion("agent", 1)],
    [("agent", [(0U, 2U)])],
  )
  assert_eq(graph.resolve_graph_version(redundant), None)
  let exact = graph.current_graph_version()
  assert_eq(
    graph.resolve_graph_version(exact),
    Some(@core.Frontier::from_array([child])),
  )
}

///|
test "graph version constructor owns structural canonicality" {
  try GraphVersion::from_parts([], [("agent", [(0U, 1U)])]) catch {
    GraphVersionError::Invalid => ()
  } noraise {
    _ => fail("empty checkpoint with knowledge must fail")
  }
  try
    GraphVersion::from_parts([@core.RawVersion("agent", 0)], [
      ("agent", [(0U, 1U), (1U, 2U)]),
    ])
  catch {
    GraphVersionError::Invalid => ()
  } noraise {
    _ => fail("adjacent noncanonical ranges must fail")
  }
  try
    GraphVersion::from_parts([@core.RawVersion("agent", 1)], [
      ("agent", [(0U, 1U)]),
    ])
  catch {
    GraphVersionError::Invalid => ()
  } noraise {
    _ => fail("frontier outside knowledge must fail")
  }
}

///|
test "generation buffer resize does not hide an old ancestor" {
  let graph = CausalGraph::new()
  let mut head = try! graph.add_version([], "agent")
  for _ in 0..<7 {
    head = try! graph.add_version([head], "agent")
  }
  let first_walk = graph
    .walk_from_frontier(@core.Frontier::from_array([head]))
    .iter_units()
    .collect()
  assert_eq(first_walk.length(), 8)
  for _ in 0..<12 {
    head = try! graph.add_version([head], "agent")
  }
  let grown_walk = graph
    .walk_from_frontier(@core.Frontier::from_array([head]))
    .iter_units()
    .collect()
  assert_eq(grown_walk.length(), 20)
  assert_true(grown_walk.contains(0))
}
