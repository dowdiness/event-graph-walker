///|
test "graph version canonicalizes sparse identities with one union algorithm" {
  let graph = @causal_graph.CausalGraph::new()
  ignore(graph.current_graph_version())
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
test "warm interval unions match membership through arbitrary insert order" {
  for warm_at in [0, 100] {
    let graph = @causal_graph.CausalGraph::new()
    let agents = ["a", "m", "z"]
    let seen = [
      Array::make(257, false),
      Array::make(257, false),
      Array::make(257, false),
    ]
    for i in 0..<771 {
      if i == warm_at {
        ignore(graph.current_graph_version())
      }
      let agent_index = 2 - i % 3
      let seq = i / 3 * 73 % 257
      ignore(
        try! graph.add_version_with_seq(
          if i == 0 {
            []
          } else {
            [i - 1]
          },
          agents[agent_index],
          seq,
        ),
      )
      seen[agent_index][seq] = true
      if i >= warm_at && (i % 17 == 0 || i == 770) {
        let expected : Array[(String, Array[(UInt32, UInt32)])] = []
        for a in 0..<3 {
          let ranges : Array[(UInt32, UInt32)] = []
          let mut s = 0
          while s < 257 {
            if !seen[a][s] {
              s += 1
              continue
            }
            let start = s
            while s < 257 && seen[a][s] {
              s += 1
            }
            ranges.push((start.reinterpret_as_uint(), s.reinterpret_as_uint()))
          }
          if !ranges.is_empty() {
            expected.push((agents[a], ranges))
          }
        }
        assert_eq(graph.current_graph_version().ranges(), expected)
      }
    }
    ignore(try! graph.add_version_with_seq([770], "max", 2147483647))
    let before = graph.current_graph_version()
    ignore(try! graph.add_version_with_seq([771], "max", 2147483645))
    ignore(try! graph.add_version_with_seq([772], "max", 2147483646))
    assert_eq(
      graph.current_graph_version().ranges().filter(entry => entry.0 == "max"),
      [("max", [(2147483645U, 2147483648U)])],
    )
    assert_eq(before.ranges().filter(entry => entry.0 == "max"), [
      ("max", [(2147483647U, 2147483648U)]),
    ])
  }
}

///|
test "cold snapshot becomes hot and advances without mutating old values" {
  let graph = @causal_graph.CausalGraph::new()
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
  let graph = @causal_graph.CausalGraph::new()
  ignore(try! graph.add_version_with_seq([], "agent", 0))
  ignore(try! graph.add_version_with_seq([], "agent", 1))
  let false_claim = try! @causal_graph.GraphVersion::from_parts(
    [@core.RawVersion("agent", 0)],
    [("agent", [(0U, 2U)])],
  )
  assert_eq(graph.resolve_graph_version(false_claim), None)
}

///|
test "resolve rejects a redundant nonmaximal checkpoint" {
  let graph = @causal_graph.CausalGraph::new()
  let root = try! graph.add_version_with_seq([], "agent", 0)
  let child = try! graph.add_version_with_seq([root], "agent", 1)
  let redundant = try! @causal_graph.GraphVersion::from_parts(
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
  try
    @causal_graph.GraphVersion::from_parts([], [("agent", [(0U, 1U)])])
  catch {
    @causal_graph.GraphVersionError::Invalid => ()
  } noraise {
    _ => fail("empty checkpoint with knowledge must fail")
  }
  try
    @causal_graph.GraphVersion::from_parts([@core.RawVersion("agent", 0)], [
      ("agent", [(0U, 1U), (1U, 2U)]),
    ])
  catch {
    @causal_graph.GraphVersionError::Invalid => ()
  } noraise {
    _ => fail("adjacent noncanonical ranges must fail")
  }
  try
    @causal_graph.GraphVersion::from_parts([@core.RawVersion("agent", 1)], [
      ("agent", [(0U, 1U)]),
    ])
  catch {
    @causal_graph.GraphVersionError::Invalid => ()
  } noraise {
    _ => fail("frontier outside knowledge must fail")
  }
}

///|
test "sparse subtraction preserves holes and range boundaries" {
  let current = try! @causal_graph.GraphVersion::from_parts(
    [
      @core.RawVersion("a", 2),
      @core.RawVersion("b", 14),
      @core.RawVersion("high", 2147483647),
    ],
    [
      ("a", [(0U, 3U), (10U, 13U)]),
      ("b", [(10U, 15U)]),
      ("high", [(2147483647U, 2147483648U)]),
    ],
  )
  let peer = try! @causal_graph.GraphVersion::from_parts(
    [
      @core.RawVersion("a", 99),
      @core.RawVersion("b", 13),
      @core.RawVersion("peer-only", 1000000000),
    ],
    [
      ("a", [(1U, 2U), (11U, 12U), (99U, 100U)]),
      ("b", [(9U, 11U), (13U, 14U)]),
      ("peer-only", [(1000000000U, 1000000001U)]),
    ],
  )
  assert_eq(current.subtract_ranges(peer), [
    ("a", [(0U, 1U), (2U, 3U), (10U, 11U), (12U, 13U)]),
    ("b", [(11U, 13U), (14U, 15U)]),
    ("high", [(2147483647U, 2147483648U)]),
  ])

  let spanning_peer = try! @causal_graph.GraphVersion::from_parts(
    [@core.RawVersion("a", 11)],
    [("a", [(1U, 12U)])],
  )
  assert_eq(current.subtract_ranges(spanning_peer), [
    ("a", [(0U, 1U), (12U, 13U)]),
    ("b", [(10U, 15U)]),
    ("high", [(2147483647U, 2147483648U)]),
  ])
}

///|
test "generation buffer resize does not hide an old ancestor" {
  let graph = @causal_graph.CausalGraph::new()
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
