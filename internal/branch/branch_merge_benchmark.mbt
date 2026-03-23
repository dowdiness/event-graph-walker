// Benchmarks for merge algorithm performance
// Run with: moon bench --package branch --release

///|
fn resolve_origin_lv(
  oplog : @oplog.OpLog,
  raw : @core.RawVersion?,
) -> @fugue.Lv? {
  match raw {
    None => None
    Some(rv) =>
      match oplog.causal_graph().raw_to_lv(rv) {
        Some(lv) => Some(@fugue.Lv(lv))
        None => None
      }
  }
}

///|
/// Benchmark: Merge small concurrent edits (2 agents, 10 ops each)
test "merge - concurrent edits (2 agents x 10)" (b : @bench.T) {
  b.bench(fn() {
    let oplog_a = @oplog.OpLog::new("agent_a")
    let tree_a : @fugue.FugueTree[String] = @fugue.FugueTree::new()
    let oplog_b = @oplog.OpLog::new("agent_b")

    // Agent A inserts 10 characters
    let mut prev_a = -1
    for i = 0; i < 10; i = i + 1 {
      let op = try! oplog_a.insert("a", prev_a, -1)
      tree_a.insert({
        id: @fugue.Lv(op.lv()),
        content: "a",
        origin_left: resolve_origin_lv(oplog_a, op.origin_left()),
        origin_right: resolve_origin_lv(oplog_a, op.origin_right()),
        timestamp: @fugue.Timestamp(i),
        agent: @fugue.ReplicaId("agent_a"),
      })
      prev_a = op.lv()
    }

    // Agent B inserts 10 characters concurrently
    let mut prev_b = -1
    let ops_from_b = []
    for i = 0; i < 10; i = i + 1 {
      let op = try! oplog_b.insert("b", prev_b, -1)
      ops_from_b.push(op)
      prev_b = op.lv()
    }

    // Merge B's operations into A
    try! merge_remote_ops(tree_a, oplog_a, ops_from_b)
    b.keep(tree_a)
  })
}

///|
/// Benchmark: Merge medium concurrent edits (2 agents, 50 ops each)
test "merge - concurrent edits (2 agents x 50)" (b : @bench.T) {
  b.bench(fn() {
    let oplog_a = @oplog.OpLog::new("agent_a")
    let tree_a : @fugue.FugueTree[String] = @fugue.FugueTree::new()
    let oplog_b = @oplog.OpLog::new("agent_b")

    // Agent A inserts 50 characters
    let mut prev_a = -1
    for i = 0; i < 50; i = i + 1 {
      let op = try! oplog_a.insert("a", prev_a, -1)
      tree_a.insert({
        id: @fugue.Lv(op.lv()),
        content: "a",
        origin_left: resolve_origin_lv(oplog_a, op.origin_left()),
        origin_right: resolve_origin_lv(oplog_a, op.origin_right()),
        timestamp: @fugue.Timestamp(i),
        agent: @fugue.ReplicaId("agent_a"),
      })
      prev_a = op.lv()
    }

    // Agent B inserts 50 characters concurrently
    let mut prev_b = -1
    let ops_from_b = []
    for i = 0; i < 50; i = i + 1 {
      let op = try! oplog_b.insert("b", prev_b, -1)
      ops_from_b.push(op)
      prev_b = op.lv()
    }

    // Merge B's operations into A
    try! merge_remote_ops(tree_a, oplog_a, ops_from_b)
    b.keep(tree_a)
  })
}

///|
/// Benchmark: Merge large concurrent edits (2 agents, 200 ops each)
test "merge - concurrent edits (2 agents x 200)" (b : @bench.T) {
  b.bench(fn() {
    let oplog_a = @oplog.OpLog::new("agent_a")
    let tree_a : @fugue.FugueTree[String] = @fugue.FugueTree::new()
    let oplog_b = @oplog.OpLog::new("agent_b")

    // Agent A inserts 200 characters
    let mut prev_a = -1
    for i = 0; i < 200; i = i + 1 {
      let op = try! oplog_a.insert("a", prev_a, -1)
      tree_a.insert({
        id: @fugue.Lv(op.lv()),
        content: "a",
        origin_left: resolve_origin_lv(oplog_a, op.origin_left()),
        origin_right: resolve_origin_lv(oplog_a, op.origin_right()),
        timestamp: @fugue.Timestamp(i),
        agent: @fugue.ReplicaId("agent_a"),
      })
      prev_a = op.lv()
    }

    // Agent B inserts 200 characters concurrently
    let mut prev_b = -1
    let ops_from_b = []
    for i = 0; i < 200; i = i + 1 {
      let op = try! oplog_b.insert("b", prev_b, -1)
      ops_from_b.push(op)
      prev_b = op.lv()
    }

    // Merge B's operations into A
    try! merge_remote_ops(tree_a, oplog_a, ops_from_b)
    b.keep(tree_a)
  })
}

///|
/// Benchmark: Merge with many agents (5 agents, 20 ops each)
test "merge - many agents (5 agents x 20)" (b : @bench.T) {
  b.bench(fn() {
    let oplog_main = @oplog.OpLog::new("agent_main")
    let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

    // Main agent: 20 operations
    let mut prev = -1
    for i = 0; i < 20; i = i + 1 {
      let op = try! oplog_main.insert("m", prev, -1)
      tree.insert({
        id: @fugue.Lv(op.lv()),
        content: "m",
        origin_left: resolve_origin_lv(oplog_main, op.origin_left()),
        origin_right: resolve_origin_lv(oplog_main, op.origin_right()),
        timestamp: @fugue.Timestamp(i),
        agent: @fugue.ReplicaId("agent_main"),
      })
      prev = op.lv()
    }

    // 4 concurrent agents, each with 20 operations
    let agents = ["agent_a", "agent_b", "agent_c", "agent_d"]
    for agent in agents {
      let oplog_remote = @oplog.OpLog::new(agent)
      let mut prev_remote = -1
      let ops = []
      for i = 0; i < 20; i = i + 1 {
        // Use first character of agent name
        let ch = if agent == "agent_a" {
          "a"
        } else if agent == "agent_b" {
          "b"
        } else if agent == "agent_c" {
          "c"
        } else {
          "d"
        }
        let op = try! oplog_remote.insert(ch, prev_remote, -1)
        ops.push(op)
        prev_remote = op.lv()
      }
      try! merge_remote_ops(tree, oplog_main, ops)
    }
    b.keep(tree)
  })
}

///|
/// Benchmark: Merge with deletes (50 inserts, 25 deletes)
test "merge - with deletes (50 inserts, 25 deletes)" (b : @bench.T) {
  b.bench(fn() {
    let oplog_a = @oplog.OpLog::new("agent_a")
    let tree_a : @fugue.FugueTree[String] = @fugue.FugueTree::new()
    let oplog_b = @oplog.OpLog::new("agent_b")

    // Agent A: 50 inserts
    let mut prev_a = -1
    let ops_a : Array[@core.Op] = []
    for i = 0; i < 50; i = i + 1 {
      let op = try! oplog_a.insert("a", prev_a, -1)
      tree_a.insert({
        id: @fugue.Lv(op.lv()),
        content: "a",
        origin_left: resolve_origin_lv(oplog_a, op.origin_left()),
        origin_right: resolve_origin_lv(oplog_a, op.origin_right()),
        timestamp: @fugue.Timestamp(i),
        agent: @fugue.ReplicaId("agent_a"),
      })
      ops_a.push(op)
      prev_a = op.lv()
    }
    for op in ops_a {
      ignore(try! oplog_b.apply_remote(op))
    }

    // Agent B: 25 deletes of A's characters
    let ops_from_b = []
    for i = 0; i < 25; i = i + 1 {
      let raw = @core.RawVersion::new(ops_a[i * 2].agent(), ops_a[i * 2].seq())
      let target_lv = match oplog_b.causal_graph().raw_to_lv(raw) {
        Some(lv) => lv
        None => continue
      }
      let op = try! oplog_b.delete(target_lv)
      ops_from_b.push(op)
    }

    // Merge B's deletes into A
    try! merge_remote_ops(tree_a, oplog_a, ops_from_b)
    b.keep(tree_a)
  })
}

///|
/// Benchmark: Merge using graph_diff (advance 20 ops)
test "merge - graph_diff advance (20 ops)" (b : @bench.T) {
  b.bench(fn() {
    let oplog = @oplog.OpLog::new("agent_a")
    let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

    // Build base: 50 operations
    let mut prev = -1
    for i = 0; i < 50; i = i + 1 {
      let op = try! oplog.insert("a", prev, -1)
      tree.insert({
        id: @fugue.Lv(op.lv()),
        content: "a",
        origin_left: resolve_origin_lv(oplog, op.origin_left()),
        origin_right: resolve_origin_lv(oplog, op.origin_right()),
        timestamp: @fugue.Timestamp(i),
        agent: @fugue.ReplicaId("agent_a"),
      })
      prev = op.lv()
    }
    let from_frontier = oplog.get_frontier()

    // Add 20 more operations
    for i = 0; i < 20; i = i + 1 {
      let op = try! oplog.insert("b", prev, -1)
      tree.insert({
        id: @fugue.Lv(op.lv()),
        content: "b",
        origin_left: resolve_origin_lv(oplog, op.origin_left()),
        origin_right: resolve_origin_lv(oplog, op.origin_right()),
        timestamp: @fugue.Timestamp(i + 50),
        agent: @fugue.ReplicaId("agent_a"),
      })
      prev = op.lv()
    }
    let to_frontier = oplog.get_frontier()

    // Merge using graph_diff
    let tree2 : @fugue.FugueTree[String] = @fugue.FugueTree::new()
    // Apply base first
    for i = 0; i < 50; i = i + 1 {
      match oplog.get_op(i) {
        Some(op) =>
          match op.content() {
            @core.Insert(text) =>
              tree2.insert({
                id: @fugue.Lv(op.lv()),
                content: text,
                origin_left: resolve_origin_lv(oplog, op.origin_left()),
                origin_right: resolve_origin_lv(oplog, op.origin_right()),
                timestamp: @fugue.Timestamp(i),
                agent: @fugue.ReplicaId("agent_a"),
              })
            @core.Delete =>
              match resolve_origin_lv(oplog, op.origin_left()) {
                Some(lv) => try! tree2.delete(lv)
                None => ()
              }
            @core.Undelete =>
              match resolve_origin_lv(oplog, op.origin_left()) {
                Some(lv) => try! tree2.undelete(lv)
                None => ()
              }
          }
        None => ()
      }
    }
    try! merge(tree2, oplog, from_frontier, to_frontier)
    b.keep(tree2)
  })
}

///|
/// Benchmark: Repeated small merges (simulate real-time collaboration)
test "merge - repeated small (10 iterations x 5 ops)" (b : @bench.T) {
  b.bench(fn() {
    let oplog_a = @oplog.OpLog::new("agent_a")
    let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
    let oplog_b = @oplog.OpLog::new("agent_b")

    // Build base
    let mut prev_a = -1
    for i = 0; i < 20; i = i + 1 {
      let op = try! oplog_a.insert("a", prev_a, -1)
      tree.insert({
        id: @fugue.Lv(op.lv()),
        content: "a",
        origin_left: resolve_origin_lv(oplog_a, op.origin_left()),
        origin_right: resolve_origin_lv(oplog_a, op.origin_right()),
        timestamp: @fugue.Timestamp(i),
        agent: @fugue.ReplicaId("agent_a"),
      })
      prev_a = op.lv()
    }

    // Simulate 10 rounds of collaboration (5 ops per round)
    let mut prev_b = -1
    for _round = 0; _round < 10; _round = _round + 1 {
      let ops_from_b = []
      for i = 0; i < 5; i = i + 1 {
        let op = try! oplog_b.insert("b", prev_b, -1)
        ops_from_b.push(op)
        prev_b = op.lv()
      }
      try! merge_remote_ops(tree, oplog_a, ops_from_b)
    }
    b.keep(tree)
  })
}

///|
/// Benchmark: retreat with concurrent deletes.
test "merge - retreat concurrent deletes (500 items, 50 deletes)" (b : @bench.T) {
  // Setup: 500-item document with 50 deletes
  let oplog_a = @oplog.OpLog::new("agent_a")
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert 500 chars
  let mut prev_lv = -1
  for i = 0; i < 500; i = i + 1 {
    let op = try! oplog_a.insert("x", prev_lv, -1)
    tree.insert({
      id: @fugue.Lv(op.lv()),
      content: "x",
      origin_left: if prev_lv == -1 {
        None
      } else {
        Some(@fugue.Lv(prev_lv))
      },
      origin_right: None,
      timestamp: @fugue.Timestamp(i),
      agent: @fugue.ReplicaId("agent_a"),
    })
    prev_lv = op.lv()
  }
  let frontier_base = oplog_a.get_frontier()

  // Agent A deletes 50 items (every 10th)
  for i = 0; i < 50; i = i + 1 {
    let _ = try! oplog_a.delete(i * 10)
    try! tree.delete_with_ts(@fugue.Lv(i * 10), 500 + i, "agent_a")
  }
  let frontier_with_deletes = oplog_a.get_frontier()

  // Pre-build template insert ops (avoid rebuilding 500 items per iteration)
  let template_inserts : Array[@fugue.InsertOp[String]] = Array::new(
    capacity=500,
  )
  for i = 0; i < 500; i = i + 1 {
    template_inserts.push({
      id: @fugue.Lv(i),
      content: "x",
      origin_left: if i == 0 {
        None
      } else {
        Some(@fugue.Lv(i - 1))
      },
      origin_right: None,
      timestamp: @fugue.Timestamp(i),
      agent: @fugue.ReplicaId("agent_a"),
    })
  }
  b.bench(fn() {
    // Build fresh tree from template
    let tree_copy : @fugue.FugueTree[String] = @fugue.FugueTree::new()
    for ins in template_inserts {
      tree_copy.insert(ins)
    }
    for i = 0; i < 50; i = i + 1 {
      try! tree_copy.delete_with_ts(@fugue.Lv(i * 10), 500 + i, "agent_a")
    }
    // Retreat the 50 deletes (merge from frontier_with_deletes to frontier_base)
    try! merge(tree_copy, oplog_a, frontier_with_deletes, frontier_base)
    b.keep(tree_copy.to_text())
  })
}

///|
/// Benchmark: Merge context creation and application
test "merge - context apply operations (50 ops)" (b : @bench.T) {
  let oplog = @oplog.OpLog::new("agent_a")
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Create 50 operations
  let mut prev = -1
  let lv_ints = []
  for i = 0; i < 50; i = i + 1 {
    let op = try! oplog.insert("a", prev, -1)
    lv_ints.push(op.lv())
    prev = op.lv()
  }
  let lvs : @rle.Rle[@core.LvRange] = @rle.Rle::from_sorted_ints(lv_ints)
  b.bench(fn() {
    let ctx = MergeContext::new(tree, oplog)
    try! ctx.apply_operations(lvs)
    b.keep(ctx)
  })
}
