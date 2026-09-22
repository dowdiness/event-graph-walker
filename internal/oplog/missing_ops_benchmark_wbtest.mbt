///|
/// Fixture construction and Version creation are outside the timed boundary.
fn missing_ops_contiguous_fixture(
  history : Int,
) -> (OpLog, @causal_graph.GraphVersion) {
  let log = OpLog("agent")
  let mut previous = -1
  for _ in 0..<history {
    previous = (try! log.insert("x", previous, -1)).lv()
  }
  let peer = try! @causal_graph.GraphVersion::from_parts(
    [@core.RawVersion("agent", history - 2)],
    [("agent", [(0U, (history - 1).reinterpret_as_uint())])],
  )
  ignore(log.causal_graph().current_graph_version())
  (log, peer)
}

///|
fn missing_ops_fragmented_fixture(
  range_count : Int,
) -> (OpLog, @causal_graph.GraphVersion) {
  let log = OpLog("local")
  let peer_ranges : Array[(UInt, UInt)] = []
  for index in 0..<range_count {
    let sequence = index * 2
    let parents = if index == 0 {
      []
    } else {
      [@core.RawVersion("agent", sequence - 2)]
    }
    let operation = @core.Op::insert(
      -1,
      parents,
      "agent",
      sequence,
      "x",
      None,
      None,
    )
    ignore(try! log.apply_remote(operation))
    if index + 1 < range_count {
      let start = sequence.reinterpret_as_uint()
      peer_ranges.push((start, start + 1U))
    }
  }
  let peer = try! @causal_graph.GraphVersion::from_parts(
    [@core.RawVersion("agent", (range_count - 2) * 2)],
    [("agent", peer_ranges)],
  )
  ignore(log.causal_graph().current_graph_version())
  (log, peer)
}

///|
/// Time the first lookup after an append invalidates RLE's lazy prefix cache.
/// Fixture construction, graph-summary warming, and append stay outside timing.
fn benchmark_post_mutation_export_once(
  b : @bench.T,
  history : Int,
) -> Unit raise {
  let timings : Array[Double] = []
  let samples : Array[(OpLog, @causal_graph.GraphVersion)] = []
  for _ in 0..<3 {
    let (log, initial_peer) = missing_ops_many_runs_fixture(history - 1)
    ignore(try! log.collect_missing_ops(initial_peer))
    ignore(log.get_op(history - 2))
    let peer = log.causal_graph().current_graph_version()
    let previous = @core.RawVersion("agent", history - 2)
    ignore(
      try! log.apply_remote(
        @core.Op::insert(-1, [previous], "agent", history - 1, "x", None, None),
      ),
    )
    samples.push((log, peer))
  }
  for sample in samples {
    let start = @bench.monotonic_clock_start()
    let operations = try! sample.0.collect_missing_ops(sample.1)
    timings.push(@bench.monotonic_clock_end(start))
    assert_eq(operations.length(), 1)
    b.keep(operations)
  }
  let sorted = timings.copy()
  sorted.sort()
  println(
    "{\"benchmark\":\"post mutation runs \{history}\",\"median_us\":\{sorted[1]}}",
  )
  b.keep(timings)
}

///|
/// Build one contiguous identity range backed by singleton operation runs.
fn missing_ops_many_runs_fixture(
  history : Int,
) -> (OpLog, @causal_graph.GraphVersion) {
  let log = OpLog("local")
  for sequence in 0..<history {
    let parents = if sequence == 0 {
      []
    } else {
      [@core.RawVersion("agent", sequence - 1)]
    }
    ignore(
      try! log.apply_remote(
        @core.Op::insert(-1, parents, "agent", sequence, "x", None, None),
      ),
    )
  }
  let peer = try! @causal_graph.GraphVersion::from_parts(
    [@core.RawVersion("agent", history - 2)],
    [("agent", [(0U, (history - 1).reinterpret_as_uint())])],
  )
  ignore(log.causal_graph().current_graph_version())
  (log, peer)
}

///|
test "missing ops one run R1 H10000 D1" (b : @bench.T) {
  let (log, peer) = missing_ops_contiguous_fixture(10000)
  b.bench(() => b.keep(try! log.collect_missing_ops(peer)))
}

///|
test "missing ops many runs R1 H10000 D1" (b : @bench.T) {
  let (log, peer) = missing_ops_many_runs_fixture(10000)
  b.bench(() => b.keep(try! log.collect_missing_ops(peer)))
}

///|
test "missing ops first export after mutation K1000 D1" (b : @bench.T) {
  benchmark_post_mutation_export_once(b, 1000)
}

///|
test "missing ops first export after mutation K10000 D1" (b : @bench.T) {
  benchmark_post_mutation_export_once(b, 10000)
}

///|
test "missing ops fragmented R1000 H1000 D1" (b : @bench.T) {
  let (log, peer) = missing_ops_fragmented_fixture(1000)
  b.bench(() => b.keep(try! log.collect_missing_ops(peer)))
}

///|
test "missing ops fragmented R10000 H10000 D1" (b : @bench.T) {
  let (log, peer) = missing_ops_fragmented_fixture(10000)
  b.bench(() => b.keep(try! log.collect_missing_ops(peer)))
}
