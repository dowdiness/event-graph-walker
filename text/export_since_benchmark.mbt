///|
/// Focused export benchmarks. Fixture construction and peer Version capture
/// happen outside b.bench; timed work is export/difference/message construction.
fn export_benchmark_fixture(history : Int, delta : Int) -> (TextState, Version) {
  let document = try! TextState::new("benchmark")
  let shared = history - delta
  for index in 0..<shared {
    try! document.insert(Pos::at(index), "x")
  }
  let peer = document.version()
  for index in shared..<history {
    try! document.insert(Pos::at(index), "x")
  }
  (document, peer)
}

///|
fn export_benchmark_oracle(document : TextState, peer : Version) -> SyncMessage {
  let operations = document.inner
    .get_all_ops()
    .filter(op => !peer.graph().contains(op_identity(op)))
  try! SyncMessage::SyncMessage(operations, try! current_heads(document), None)
}

///|
fn benchmark_sparse_export(
  b : @bench.T,
  history : Int,
  delta : Int,
  oracle : Bool,
) -> Unit {
  let (document, peer) = export_benchmark_fixture(history, delta)
  if oracle {
    b.bench(() => b.keep(export_benchmark_oracle(document, peer)))
  } else {
    b.bench(() => b.keep(try! document.sync().export_since(peer)))
  }
}

///|
/// Measure first observation without warming the source summary. Each sample's
/// fixture and peer DTO are built before the timer starts.
fn benchmark_cold_export_once(b : @bench.T, history : Int, delta : Int) -> Unit {
  let timings : Array[Double] = []
  for _ in 0..<3 {
    let document = try! TextState::new("cold-benchmark")
    for index in 0..<history {
      try! document.insert(Pos::at(index), "x")
    }
    let shared = history - delta
    let graph_version = if shared == 0 {
      try! @causal_graph.GraphVersion::from_parts([], [])
    } else {
      try! @causal_graph.GraphVersion::from_parts(
        [@core.RawVersion("cold-benchmark", shared - 1)],
        [("cold-benchmark", [(0U, shared.reinterpret_as_uint())])],
      )
    }
    let peer = Version::from_graph_version(graph_version)
    let start = @bench.monotonic_clock_start()
    b.keep(try! document.sync().export_since(peer))
    timings.push(@bench.monotonic_clock_end(start))
  }
  let sorted = timings.copy()
  sorted.sort()
  println(
    "{\"benchmark\":\"cold export H\{history} D\{delta}\",\"median_us\":\{sorted[1]}}",
  )
  b.keep(timings)
}

///|
test "export_since steady H1000 D1" (b : @bench.T) {
  benchmark_sparse_export(b, 1000, 1, false)
}

///|
test "export_since oracle H1000 D1" (b : @bench.T) {
  benchmark_sparse_export(b, 1000, 1, true)
}

///|
test "export_since steady H10000 D1" (b : @bench.T) {
  benchmark_sparse_export(b, 10000, 1, false)
}

///|
test "export_since oracle H10000 D1" (b : @bench.T) {
  benchmark_sparse_export(b, 10000, 1, true)
}

///|
test "export_since steady H100000 D1" (b : @bench.T) {
  benchmark_sparse_export(b, 100000, 1, false)
}

///|
test "export_since oracle H100000 D1" (b : @bench.T) {
  benchmark_sparse_export(b, 100000, 1, true)
}

///|
test "export_since cold H1000 D1" (b : @bench.T) {
  benchmark_cold_export_once(b, 1000, 1)
}

///|
test "export_since cold H10000 D1" (b : @bench.T) {
  benchmark_cold_export_once(b, 10000, 1)
}

///|
test "export_since cold H100000 D1" (b : @bench.T) {
  benchmark_cold_export_once(b, 100000, 1)
}

///|
test "export_since steady H10000 D0" (b : @bench.T) {
  benchmark_sparse_export(b, 10000, 0, false)
}

///|
test "export_since oracle H10000 D0" (b : @bench.T) {
  benchmark_sparse_export(b, 10000, 0, true)
}

///|
test "export_since steady H10000 D50" (b : @bench.T) {
  benchmark_sparse_export(b, 10000, 50, false)
}

///|
test "export_since oracle H10000 D50" (b : @bench.T) {
  benchmark_sparse_export(b, 10000, 50, true)
}

///|
test "export_since after hot remote admission H10000 D1" (b : @bench.T) {
  let (document, peer) = export_benchmark_fixture(10000, 0)
  let raw = @core.RawVersion("remote-benchmark", 1000000)
  let remote = try! SyncMessage::SyncMessage(
    [@core.Op::insert(-1, [], raw.agent, raw.seq, "r", None, None)],
    [raw],
    None,
  )
  ignore(try! document.sync().apply(remote))
  b.bench(() => b.keep(try! document.sync().export_since(peer)))
}

///|
test "export_since plus canonical bytes H10000 D1" (b : @bench.T) {
  let (document, peer) = export_benchmark_fixture(10000, 1)
  b.bench(fn() {
    b.keep(try! document.sync().export_since(peer).to_canonical_bytes())
  })
}

///|
test "export_since steady H10000 full" (b : @bench.T) {
  let (document, _) = export_benchmark_fixture(10000, 0)
  let empty = Version::empty()
  b.bench(() => b.keep(try! document.sync().export_since(empty)))
}

///|
test "export_since oracle H10000 full" (b : @bench.T) {
  let (document, _) = export_benchmark_fixture(10000, 0)
  let empty = Version::empty()
  b.bench(() => b.keep(export_benchmark_oracle(document, empty)))
}
