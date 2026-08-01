// Benchmarks for position cache rebuild cost.
// This is what incremental remote op cache updates optimize.
// Run with: cd event-graph-walker && moon bench --release

///|
fn build_doc(n : Int) -> Document {
  let doc = Document::new("bench")
  if n > 0 {
    let _ = doc.insert(0, "x".repeat(n)) catch { _ => abort("unreachable") }
  }
  doc
}

///|
fn build_remote_chain(n : Int) -> Array[@core.Op] {
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
fn reverse_remote_ops(ops : Array[@core.Op]) -> Array[@core.Op] {
  let reversed : Array[@core.Op] = []
  for i in 0..<ops.length() {
    reversed.push(ops[ops.length() - i - 1])
  }
  reversed
}

///|
fn merge_remote_chain(doc : Document, ops : Array[@core.Op]) -> Unit {
  doc.merge_remote(ops, []) catch {
    _ => abort("remote merge failed in benchmark")
  }
}

///|
fn build_remote_branches(depth : Int) -> Array[@core.Op] {
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
test "bench: merge reverse branching dependencies (4 x 250 ops)" (b : @bench.T) {
  let ops = reverse_remote_ops(build_remote_branches(250))
  b.bench(
    fn() {
      let doc = Document::new("local")
      merge_remote_chain(doc, ops)
      b.keep(doc.visible_count())
    },
    count=1,
  )
}

///|
test "bench: merge reverse dependency chain (100 ops)" (b : @bench.T) {
  let ops = reverse_remote_ops(build_remote_chain(100))
  b.bench(
    fn() {
      let doc = Document::new("local")
      merge_remote_chain(doc, ops)
      b.keep(doc.visible_count())
    },
    count=1,
  )
}

///|
test "bench: merge reverse dependency chain (1000 ops)" (b : @bench.T) {
  let ops = reverse_remote_ops(build_remote_chain(1000))
  b.bench(
    fn() {
      let doc = Document::new("local")
      merge_remote_chain(doc, ops)
      b.keep(doc.visible_count())
    },
    count=1,
  )
}

///|
test "bench: merge reverse dependency chain (10000 ops)" (b : @bench.T) {
  let ops = reverse_remote_ops(build_remote_chain(10000))
  b.bench(
    fn() {
      let doc = Document::new("local")
      merge_remote_chain(doc, ops)
      b.keep(doc.visible_count())
    },
    count=1,
  )
}

// =============================================================================
// Cache rebuild cost: invalidate warm cache, then force rebuild via position query.
// This is the cost paid after every remote op in the current implementation.
// =============================================================================

///|
test "bench: cache invalidate + position query (1000 chars)" (b : @bench.T) {
  let doc = build_doc(1000)
  // Warm cache
  ignore(doc.lv_at_position(0))
  b.bench(fn() {
    doc.invalidate_cache()
    b.keep(doc.lv_at_position(500))
  })
}

///|
test "bench: cache invalidate + position query (5000 chars)" (b : @bench.T) {
  let doc = build_doc(5000)
  ignore(doc.lv_at_position(0))
  b.bench(fn() {
    doc.invalidate_cache()
    b.keep(doc.lv_at_position(2500))
  })
}

///|
test "bench: cache invalidate + position query (10000 chars)" (b : @bench.T) {
  let doc = build_doc(10000)
  ignore(doc.lv_at_position(0))
  b.bench(fn() {
    doc.invalidate_cache()
    b.keep(doc.lv_at_position(5000))
  })
}

// =============================================================================
// apply_remote + query: measures incremental cache update benefit.
// Each iteration: build bob, sync with alice, warm cache, then receive
// 10 more remote inserts with position queries between each.
// =============================================================================

///|
test "bench: 10 remote inserts + queries (1000-char doc)" (b : @bench.T) {
  b.bench(fn() {
    let alice = build_doc(1000)
    let bob = Document::new("bob")
    for op in alice.get_all_ops() {
      bob.apply_remote(op) catch {
        _ => abort("unreachable")
      }
    }
    ignore(bob.lv_at_position(0))
    // Alice types 10 more chars
    for i in 0..<10 {
      let _ = alice.insert(500 + i, "y") catch { _ => abort("unreachable") }
    }
    let ops = alice.get_all_ops()
    // Bob receives them one at a time, querying position after each
    for i in 1000..<ops.length() {
      bob.apply_remote(ops[i]) catch {
        _ => abort("remote apply failed in benchmark")
      }
      ignore(bob.lv_at_position(500))
    }
    b.keep(bob.visible_count())
  })
}

///|
test "bench: 10 remote inserts + queries (5000-char doc)" (b : @bench.T) {
  b.bench(fn() {
    let alice = build_doc(5000)
    let bob = Document::new("bob")
    for op in alice.get_all_ops() {
      bob.apply_remote(op) catch {
        _ => abort("unreachable")
      }
    }
    ignore(bob.lv_at_position(0))
    for i in 0..<10 {
      let _ = alice.insert(2500 + i, "y") catch { _ => abort("unreachable") }
    }
    let ops = alice.get_all_ops()
    for i in 5000..<ops.length() {
      bob.apply_remote(ops[i]) catch {
        _ => abort("remote apply failed in benchmark")
      }
      ignore(bob.lv_at_position(2500))
    }
    b.keep(bob.visible_count())
  })
}

// =============================================================================
// Warm cache position query: baseline cost when cache is valid.
// =============================================================================

///|
test "bench: warm cache position query (1000 chars)" (b : @bench.T) {
  let doc = build_doc(1000)
  ignore(doc.lv_at_position(0))
  b.bench(fn() { b.keep(doc.lv_at_position(500)) })
}

///|
test "bench: warm cache position query (10000 chars)" (b : @bench.T) {
  let doc = build_doc(10000)
  ignore(doc.lv_at_position(0))
  b.bench(fn() { b.keep(doc.lv_at_position(5000)) })
}

// =============================================================================
// Warm-index remote projection: five isolated apply_remote timings.
// Each sample creates, replays, and primes a fresh target before the clock.
// =============================================================================

///|
fn benchmark_remote_projection(
  b : @bench.T,
  name : String,
  base_ops : Array[@core.Op],
  setup_ops : Array[@core.Op],
  incoming : @core.Op,
  expected_count : Int,
) -> Unit raise {
  let timings : Array[Double] = []
  for _ in 0..<5 {
    let sample = Document::new("sample")
    for op in base_ops {
      sample.apply_remote(op) catch {
        _ => abort("benchmark setup failed")
      }
    }
    for op in setup_ops {
      sample.apply_remote(op) catch {
        _ => abort("benchmark setup failed")
      }
    }
    ignore(sample.get_visible_items())
    let start = @bench.monotonic_clock_start()
    sample.apply_remote(incoming) catch {
      _ => abort("benchmark projection failed")
    }
    let elapsed_us = @bench.monotonic_clock_end(start)
    assert_eq(sample.visible_count(), expected_count)
    timings.push(elapsed_us)
  }
  let sorted = timings.copy()
  sorted.sort()
  let median_us = sorted[2]
  let raw_us = timings.map(value => value.to_string()).join(",")
  println(
    "{\"benchmark\":\"\{name}\",\"raw_us\":[\{raw_us}],\"median_us\":\{median_us.to_string()}}",
  )
  b.keep(timings)
}

///|
test "bench: observed Insert (1000-char warm index)" (b : @bench.T) {
  let source = build_doc(1000)
  let base_ops = source.get_all_ops()
  let incoming = try! source.insert(500, "y")
  benchmark_remote_projection(
    b,
    "bench: observed Insert (1000-char warm index)",
    base_ops,
    [],
    incoming,
    1001,
  )
}

///|
test "bench: observed Insert (10000-char warm index)" (b : @bench.T) {
  let source = build_doc(10000)
  let base_ops = source.get_all_ops()
  let incoming = try! source.insert(5000, "y")
  benchmark_remote_projection(
    b,
    "bench: observed Insert (10000-char warm index)",
    base_ops,
    [],
    incoming,
    10001,
  )
}

///|
test "bench: observed Insert (100000-char warm index)" (b : @bench.T) {
  let source = build_doc(100000)
  let base_ops = source.get_all_ops()
  let incoming = try! source.insert(50000, "y")
  benchmark_remote_projection(
    b,
    "bench: observed Insert (100000-char warm index)",
    base_ops,
    [],
    incoming,
    100001,
  )
}

///|
test "bench: observed Delete (1000-char warm index)" (b : @bench.T) {
  let source = build_doc(1000)
  let base_ops = source.get_all_ops()
  let incoming = try! source.delete(500)
  benchmark_remote_projection(
    b,
    "bench: observed Delete (1000-char warm index)",
    base_ops,
    [],
    incoming,
    999,
  )
}

///|
test "bench: observed Delete (10000-char warm index)" (b : @bench.T) {
  let source = build_doc(10000)
  let base_ops = source.get_all_ops()
  let incoming = try! source.delete(5000)
  benchmark_remote_projection(
    b,
    "bench: observed Delete (10000-char warm index)",
    base_ops,
    [],
    incoming,
    9999,
  )
}

///|
test "bench: observed Delete (100000-char warm index)" (b : @bench.T) {
  let source = build_doc(100000)
  let base_ops = source.get_all_ops()
  let incoming = try! source.delete(50000)
  benchmark_remote_projection(
    b,
    "bench: observed Delete (100000-char warm index)",
    base_ops,
    [],
    incoming,
    99999,
  )
}

///|
test "bench: observed Undelete (1000-char warm index)" (b : @bench.T) {
  let source = build_doc(1000)
  let base_ops = source.get_all_ops()
  let delete_op = try! source.delete(500)
  let incoming = try! source.undelete(500)
  benchmark_remote_projection(
    b,
    "bench: observed Undelete (1000-char warm index)",
    base_ops,
    [delete_op],
    incoming,
    1000,
  )
}

///|
test "bench: observed Undelete (10000-char warm index)" (b : @bench.T) {
  let source = build_doc(10000)
  let base_ops = source.get_all_ops()
  let delete_op = try! source.delete(5000)
  let incoming = try! source.undelete(5000)
  benchmark_remote_projection(
    b,
    "bench: observed Undelete (10000-char warm index)",
    base_ops,
    [delete_op],
    incoming,
    10000,
  )
}

///|
test "bench: observed Undelete (100000-char warm index)" (b : @bench.T) {
  let source = build_doc(100000)
  let base_ops = source.get_all_ops()
  let delete_op = try! source.delete(50000)
  let incoming = try! source.undelete(50000)
  benchmark_remote_projection(
    b,
    "bench: observed Undelete (100000-char warm index)",
    base_ops,
    [delete_op],
    incoming,
    100000,
  )
}
