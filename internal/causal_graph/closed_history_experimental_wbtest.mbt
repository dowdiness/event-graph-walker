///|
fn closed_graph_oracle(operations : Array[@core.Op]) -> Unit raise {
  let built = CausalGraph::from_topological_ops_experimental(operations[:])
  let replay = CausalGraph::new()
  for op in operations {
    let parents = op.parents().map(raw => replay.raw_to_lv(raw).unwrap())
    ignore(replay.add_version_with_seq(parents, op.agent(), op.seq()))
  }
  assert_eq(built.next_lv, replay.next_lv)
  assert_eq(built.frontier.to_array(), replay.frontier.to_array())
  assert_true(built.version_cache is Cold)
  assert_true(built.query_visited.is_empty())
  for lv = 0; lv < built.next_lv; lv = lv + 1 {
    let a = built.get_entry(lv).unwrap()
    let b = replay.get_entry(lv).unwrap()
    assert_eq(a.parents, b.parents)
    assert_eq(a.timestamp, b.timestamp)
    assert_eq(a.agent, b.agent)
    assert_eq(a.seq, b.seq)
    assert_eq(built.children[lv], replay.children[lv])
    let raw = built.lv_to_raw(lv).unwrap()
    assert_eq(built.raw_to_lv(raw), Some(lv))
    assert_eq(built.agent_seqs.get(raw.agent), replay.agent_seqs.get(raw.agent))
  }
  let saved_a = built.current_graph_version()
  let saved_b = replay.current_graph_version()
  assert_eq(saved_a, saved_b)
  assert_eq(built.current_graph_version(), saved_a)
  for a = 0; a < built.next_lv; a = a + 1 {
    for b = 0; b < built.next_lv; b = b + 1 {
      assert_eq(built.is_ancestor(a, b), replay.is_ancestor(a, b))
    }
  }
  let next_a = built.add_version(built.get_frontier().to_array(), "fresh")
  let next_b = replay.add_version(replay.get_frontier().to_array(), "fresh")
  assert_eq(next_a, next_b)
  assert_eq(built.current_graph_version(), replay.current_graph_version())
  assert_eq(saved_a, saved_b)
  assert_eq(
    built.resolve_graph_version(saved_a).unwrap().to_array(),
    replay.resolve_graph_version(saved_b).unwrap().to_array(),
  )
  let entry = built.get_entry(next_a).unwrap()
  let original_parents = entry.parents.copy()
  entry.parents.clear()
  assert_eq(built.get_entry(next_a).unwrap().parents, original_parents)
}

///|
test "direct graph exact entries children ranks frontier sparse membership and queries" {
  let ops : Array[@core.Op] = []
  for i = 0; i < 12; i = i + 1 {
    ops.push(
      @core.Op::insert(-99, [], "root-" + i.to_string(), i * 3, "x", None, None),
    )
  }
  for i = 0; i < 64; i = i + 1 {
    let parents = if i == 0 {
      [@core.RawVersion("root-0", 0)]
    } else {
      [
        @core.RawVersion("fork", (i - 1) * 2),
        @core.RawVersion("root-" + (i % 12).to_string(), i % 12 * 3),
      ]
    }
    ops.push(
      @core.Op::insert(
        -9,
        parents,
        "fork",
        i * 2,
        "😀",
        Some(@core.RawVersion("root-0", 0)),
        None,
      ),
    )
  }
  closed_graph_oracle(ops)
}

///|
test "direct graph origin is not parent and decreasing sequences keep allocation maximum" {
  let ops = [
    @core.Op::insert(123, [], "actor", 2, "a", None, None),
    @core.Op::insert(
      42,
      [],
      "actor",
      0,
      "b",
      Some(@core.RawVersion("actor", 2)),
      None,
    ),
    @core.Op::delete(
      -1,
      [@core.RawVersion("actor", 0), @core.RawVersion("actor", 2)],
      "actor",
      1,
      Some(@core.RawVersion("actor", 2)),
    ),
  ]
  closed_graph_oracle(ops)
  let graph = CausalGraph::from_topological_ops_experimental(ops[:])
  assert_eq(graph.entries[1].timestamp, 0)
  assert_eq(graph.entries[1].parents, [])
  let lv = graph.add_version(graph.frontier.to_array(), "actor")
  assert_eq(graph.lv_to_raw(lv), Some(@core.RawVersion("actor", 3)))
  let max_ops = [@core.Op::insert(-1, [], "max", 2147483647, "x", None, None)]
  let maximum = CausalGraph::from_topological_ops_experimental(max_ops[:])
  let reference = CausalGraph::new()
  ignore(reference.add_version_with_seq([], "max", 2147483647))
  assert_eq(maximum.current_graph_version(), reference.current_graph_version())
  assert_true(
    try maximum.add_version([], "max") catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try reference.add_version([], "max") catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}

///|
test "direct graph rejects duplicate and unknown parent without input aliasing" {
  let one = @core.Op::insert(0, [], "a", 0, "x", None, None)
  assert_true(
    try CausalGraph::from_topological_ops_experimental([one, one][:]) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  let missing = @core.Op::insert(
    0,
    [@core.RawVersion("missing", 0)],
    "a",
    1,
    "x",
    None,
    None,
  )
  assert_true(
    try CausalGraph::from_topological_ops_experimental([missing][:]) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  let input = [one]
  let graph = CausalGraph::from_topological_ops_experimental(input[:])
  input.clear()
  assert_eq(graph.op_count(), 1)
}
