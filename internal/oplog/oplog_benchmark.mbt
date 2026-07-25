// Benchmarks for operation log performance
// Run with: moon bench --package oplog --release

///|
fn benchmark_raw_versions(n : Int) -> Array[@core.RawVersion] {
  let raws : Array[@core.RawVersion] = []
  for i in 0..<n {
    raws.push(@core.RawVersion::new("bench", i))
  }
  raws
}

///|
test "oplog - immutable hashset build (1000 raw versions)" (b : @bench.T) {
  let raws = benchmark_raw_versions(1000)
  b.bench(fn() {
    let mut set : @immut/hashset.HashSet[@core.RawVersion] = @immut/hashset.new()
    for raw in raws {
      set = set.add(raw)
    }
    b.keep(set.length())
  })
}

///|
test "oplog - mutable hashset build (1000 raw versions)" (b : @bench.T) {
  let raws = benchmark_raw_versions(1000)
  b.bench(fn() {
    let set : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
    for raw in raws {
      set.add(raw)
    }
    b.keep(set.length())
  })
}

///|
/// Benchmark: Insert operations (linear, 100 ops)
fn benchmark_remote_chain(n : Int) -> Array[@core.Op] {
  let ops : Array[@core.Op] = []
  for i in 0..<n {
    let parents = if i == 0 {
      []
    } else {
      [@core.RawVersion::new("remote", i - 1)]
    }
    ops.push(@core.Op::new_insert(-1, parents, "remote", i, "x", None, None))
  }
  ops
}

///|
fn benchmark_apply_reverse_chain(
  oplog : OpLog,
  ops : Array[@core.Op],
) -> Unit raise OpLogError {
  for i in 0..<ops.length() {
    ignore(oplog.apply_remote(ops[ops.length() - i - 1]))
  }
}

///|
fn benchmark_reverse_ops(ops : Array[@core.Op]) -> Array[@core.Op] {
  let reversed : Array[@core.Op] = []
  for i in 0..<ops.length() {
    reversed.push(ops[ops.length() - i - 1])
  }
  reversed
}

///|
test "oplog - reverse dependency chain apply (100 ops)" (b : @bench.T) {
  let ops = benchmark_remote_chain(100)
  b.bench(
    fn() {
      let oplog = OpLog::new("local")
      try! benchmark_apply_reverse_chain(oplog, ops)
      b.keep(oplog.op_count())
    },
    count=1,
  )
}

///|
test "oplog - reverse dependency chain apply (1000 ops)" (b : @bench.T) {
  let ops = benchmark_remote_chain(1000)
  b.bench(
    fn() {
      let oplog = OpLog::new("local")
      try! benchmark_apply_reverse_chain(oplog, ops)
      b.keep(oplog.op_count())
    },
    count=1,
  )
}

///|
test "oplog - reverse dependency chain apply (10000 ops)" (b : @bench.T) {
  let ops = benchmark_remote_chain(10000)
  b.bench(
    fn() {
      let oplog = OpLog::new("local")
      try! benchmark_apply_reverse_chain(oplog, ops)
      b.keep(oplog.op_count())
    },
    count=1,
  )
}

///|
test "oplog - reverse dependency chain plan batch (100 ops)" (b : @bench.T) {
  let ops = benchmark_reverse_ops(benchmark_remote_chain(100))
  b.bench(
    fn() {
      let oplog = OpLog::new("local")
      let planned = try! oplog.plan_remote(ops)
      b.keep(planned.length())
    },
    count=1,
  )
}

///|
test "oplog - reverse dependency chain plan batch (1000 ops)" (b : @bench.T) {
  let ops = benchmark_reverse_ops(benchmark_remote_chain(1000))
  b.bench(
    fn() {
      let oplog = OpLog::new("local")
      let planned = try! oplog.plan_remote(ops)
      b.keep(planned.length())
    },
    count=1,
  )
}

///|
test "oplog - reverse dependency chain plan batch (10000 ops)" (b : @bench.T) {
  let ops = benchmark_reverse_ops(benchmark_remote_chain(10000))
  b.bench(
    fn() {
      let oplog = OpLog::new("local")
      let planned = try! oplog.plan_remote(ops)
      b.keep(planned.length())
    },
    count=1,
  )
}

///|
fn benchmark_remote_branches(depth : Int) -> Array[@core.Op] {
  let agents = ["remote-a", "remote-b", "remote-c", "remote-d"]
  let ops : Array[@core.Op] = []
  for level in 0..<depth {
    for branch in 0..<agents.length() {
      let parents = if level == 0 {
        []
      } else {
        [@core.RawVersion::new(agents[branch], level - 1)]
      }
      ops.push(
        @core.Op::new_insert(
          -1,
          parents,
          agents[branch],
          level,
          "x",
          None,
          None,
        ),
      )
    }
  }
  ops
}

///|
test "oplog - reverse branching dependencies apply (4 x 250 ops)" (b : @bench.T) {
  let ops = benchmark_remote_branches(250)
  b.bench(
    fn() {
      let oplog = OpLog::new("local")
      try! benchmark_apply_reverse_chain(oplog, ops)
      b.keep(oplog.op_count())
    },
    count=1,
  )
}

///|
test "oplog - insert (100 ops)" (b : @bench.T) {
  b.bench(fn() {
    let oplog = OpLog::new("agent_a")
    let mut prev = -1
    for i = 0; i < 100; i = i + 1 {
      let op = try! oplog.insert("a", prev, -1)
      prev = op.lv()
    }
    b.keep(oplog)
  })
}

///|
/// Benchmark: Insert operations (linear, 1000 ops)
test "oplog - insert (1000 ops)" (b : @bench.T) {
  b.bench(fn() {
    let oplog = OpLog::new("agent_a")
    let mut prev = -1
    for i = 0; i < 1000; i = i + 1 {
      let op = try! oplog.insert("a", prev, -1)
      prev = op.lv()
    }
    b.keep(oplog)
  })
}

///|
/// Benchmark: Insert and delete mix (50% delete rate)
test "oplog - insert and delete mix (100 ops)" (b : @bench.T) {
  b.bench(fn() {
    let oplog = OpLog::new("agent_a")
    let mut prev = -1
    let lvs = []

    // Insert 100 characters
    for i = 0; i < 100; i = i + 1 {
      let op = try! oplog.insert("a", prev, -1)
      let lv = op.lv()
      lvs.push(lv)
      prev = lv
    }

    // Delete every other character
    for i = 0; i < lvs.length(); i = i + 2 {
      let _del = try! oplog.delete(lvs[i])
    }
    b.keep(oplog)
  })
}

///|
/// Benchmark: Apply remote operations (50 ops)
test "oplog - apply_remote (50 ops)" (b : @bench.T) {
  // Pre-create remote operations
  let remote_oplog = OpLog::new("agent_b")
  let mut prev = -1
  let remote_ops = []
  for i = 0; i < 50; i = i + 1 {
    let op = try! remote_oplog.insert("b", prev, -1)
    remote_ops.push(op)
    prev = op.lv()
  }
  b.bench(fn() {
    let oplog = OpLog::new("agent_a")
    for op in remote_ops {
      ignore(try! oplog.apply_remote(op))
    }
    b.keep(oplog)
  })
}

///|
/// Benchmark: Get operation by LV (from 1000 ops)
test "oplog - get_op (1000 ops)" (b : @bench.T) {
  let oplog = OpLog::new("agent_a")
  let mut prev = -1
  for i = 0; i < 1000; i = i + 1 {
    let op = try! oplog.insert("a", prev, -1)
    prev = op.lv()
  }
  b.bench(fn() {
    // Get operations at various positions
    let op1 = oplog.get_op(0)
    let op2 = oplog.get_op(500)
    let op3 = oplog.get_op(999)
    b.keep((op1, op2, op3))
  })
}

///|
/// Benchmark: Get frontier (single agent)
test "oplog - get_frontier (single agent)" (b : @bench.T) {
  let oplog = OpLog::new("agent_a")
  let mut prev = -1
  for i = 0; i < 100; i = i + 1 {
    let op = try! oplog.insert("a", prev, -1)
    prev = op.lv()
  }
  b.bench(fn() {
    let result = oplog.get_frontier()
    b.keep(result)
  })
}

///|
/// Benchmark: Get frontier (multiple agents merged)
test "oplog - get_frontier (5 agents)" (b : @bench.T) {
  let oplog = OpLog::new("agent_main")

  // Merge operations from 5 agents
  let agents = ["agent_a", "agent_b", "agent_c", "agent_d", "agent_e"]
  for agent in agents {
    let remote_oplog = OpLog::new(agent)
    let mut prev = -1
    for i = 0; i < 20; i = i + 1 {
      let op = try! remote_oplog.insert(agent, prev, -1)
      ignore(try! oplog.apply_remote(op))
      prev = op.lv()
    }
  }
  b.bench(fn() {
    let result = oplog.get_frontier()
    b.keep(result)
  })
}

///|
/// Benchmark: Walk and collect operations (100 ops)
test "oplog - walk_and_collect (100 ops)" (b : @bench.T) {
  let oplog = OpLog::new("agent_a")
  let mut prev = -1
  for i = 0; i < 100; i = i + 1 {
    let op = try! oplog.insert("a", prev, -1)
    prev = op.lv()
  }
  let frontier = oplog.get_frontier()
  b.bench(fn() {
    let result = oplog.walk_and_collect(frontier)
    b.keep(result)
  })
}

///|
/// Benchmark: Walk and collect with concurrent branches
test "oplog - walk_and_collect (concurrent)" (b : @bench.T) {
  let oplog = OpLog::new("agent_main")

  // Create two concurrent branches
  let oplog_a = OpLog::new("agent_a")
  let mut prev_a = -1
  for i = 0; i < 50; i = i + 1 {
    let op = try! oplog_a.insert("a", prev_a, -1)
    ignore(try! oplog.apply_remote(op))
    prev_a = op.lv()
  }
  let oplog_b = OpLog::new("agent_b")
  let mut prev_b = -1
  for i = 0; i < 50; i = i + 1 {
    let op = try! oplog_b.insert("b", prev_b, -1)
    ignore(try! oplog.apply_remote(op))
    prev_b = op.lv()
  }
  let frontier = oplog.get_frontier()
  b.bench(fn() {
    let result = oplog.walk_and_collect(frontier)
    b.keep(result)
  })
}

///|
/// Benchmark: Diff and collect (advance 20 ops)
test "oplog - diff_and_collect (advance 20)" (b : @bench.T) {
  let oplog = OpLog::new("agent_a")
  let mut prev = -1

  // Build base: 100 operations
  for i = 0; i < 100; i = i + 1 {
    let op = try! oplog.insert("a", prev, -1)
    prev = op.lv()
  }
  let from_frontier = oplog.get_frontier()

  // Add 20 more operations
  for i = 0; i < 20; i = i + 1 {
    let op = try! oplog.insert("b", prev, -1)
    prev = op.lv()
  }
  let to_frontier = oplog.get_frontier()
  b.bench(fn() {
    let result = oplog.diff_and_collect(from_frontier, to_frontier)
    b.keep(result)
  })
}

///|
/// Benchmark: Walk filtered (filter inserts only)
test "oplog - walk_filtered (inserts only)" (b : @bench.T) {
  let oplog = OpLog::new("agent_a")
  let mut prev = -1
  let lvs = []

  // Insert 50 characters
  for i = 0; i < 50; i = i + 1 {
    let op = try! oplog.insert("a", prev, -1)
    let lv = op.lv()
    lvs.push(lv)
    prev = lv
  }

  // Delete 25 characters
  for i = 0; i < 25; i = i + 1 {
    let _del = try! oplog.delete(lvs[i])
  }
  let frontier = oplog.get_frontier()
  b.bench(fn() {
    let result = oplog.walk_filtered(frontier, fn(op) {
      match op.content() {
        @core.Insert(_) => true
        @core.Delete | @core.Undelete => false
      }
    })
    b.keep(result)
  })
}

///|
/// Benchmark: Sequential inserts (simulate typing, 500 chars)
test "oplog - sequential typing (500 chars)" (b : @bench.T) {
  b.bench(fn() {
    let oplog = OpLog::new("agent_a")
    let mut prev = -1

    // Simulate typing a 500-character document
    for i = 0; i < 500; i = i + 1 {
      let op = try! oplog.insert("x", prev, -1)
      prev = op.lv()
    }
    b.keep(oplog)
  })
}

///|
/// Benchmark: Random position inserts (simulate editing)
test "oplog - random position inserts (100 ops)" (b : @bench.T) {
  b.bench(fn() {
    let oplog = OpLog::new("agent_a")
    let lvs = []

    // Insert at various positions
    for i = 0; i < 100; i = i + 1 {
      let pos = if lvs.length() == 0 { -1 } else { lvs[i % lvs.length()] }
      let op = try! oplog.insert("x", pos, -1)
      lvs.push(op.lv())
    }
    b.keep(oplog)
  })
}

// =============================================================================
// Gap 2: Large Document Stress Tests (100k+ ops)
// =============================================================================

///|
/// Benchmark: Sequential typing (100000 chars) - simulate typing a large document
test "oplog - sequential typing (100000 chars)" (b : @bench.T) {
  b.bench(fn() {
    let oplog = OpLog::new("agent_a")
    let mut prev = -1

    // Simulate typing a 100,000-character document
    for i = 0; i < 100000; i = i + 1 {
      let op = try! oplog.insert("x", prev, -1)
      prev = op.lv()
    }
    b.keep(oplog)
  })
}

///|
/// Benchmark: Diff and collect (100000 ops advance)
/// Tests performance of computing delta from an old frontier to current
test "oplog - diff_and_collect (100000 ops advance)" (b : @bench.T) {
  let oplog = OpLog::new("agent_a")
  let mut prev = -1

  // Build base: 100 operations
  for i = 0; i < 100; i = i + 1 {
    let op = try! oplog.insert("a", prev, -1)
    prev = op.lv()
  }
  let from_frontier = oplog.get_frontier()

  // Add 100000 more operations
  for i = 0; i < 100000; i = i + 1 {
    let op = try! oplog.insert("b", prev, -1)
    prev = op.lv()
  }
  let to_frontier = oplog.get_frontier()
  b.bench(fn() {
    let result = oplog.diff_and_collect(from_frontier, to_frontier)
    b.keep(result)
  })
}
