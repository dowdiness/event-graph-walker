///|
fn version_cache_benchmark_doc(operation_count : Int) -> TextState {
  let doc = try! TextState::new("alice")
  for i = 0; i < operation_count; i = i + 1 {
    let _ = try! doc.insert(Pos::at(doc.len()), "x")
  }
  doc
}

///|
/// Build sorted entries so the benchmark isolates Version::advance's
/// replica-entry copy and scan rather than operation-log reconstruction.
fn version_cache_benchmark_version(replica_count : Int) -> Version {
  let entries : Array[VersionEntry] = []
  for i = 0; i < replica_count; i = i + 1 {
    let replica_id = if i < 10 {
      "agent-0" + i.to_string()
    } else {
      "agent-" + i.to_string()
    }
    entries.push({ replica_id, sequence: 100 })
  }
  Version(entries)
}

///|
fn bench_version_advance(
  b : @bench.T,
  replica_count : Int,
  replica_id : String,
) -> Unit {
  let version = version_cache_benchmark_version(replica_count)
  b.bench(() => b.keep(version.advance(replica_id, 101)))
}

///|
/// Measure only a warm cache hit after building the requested operation log.
fn bench_cached_version_read(b : @bench.T, operation_count : Int) -> Unit {
  let doc = version_cache_benchmark_doc(operation_count)
  ignore(doc.version())
  b.bench(() => b.keep(doc.version()))
}

///|
test "perf: TextState cached version read (1000 ops)" (b : @bench.T) {
  bench_cached_version_read(b, 1000)
}

///|
test "perf: TextState cached version read (10000 ops)" (b : @bench.T) {
  bench_cached_version_read(b, 10000)
}

///|
test "perf: TextState cached version read (100000 ops)" (b : @bench.T) {
  bench_cached_version_read(b, 100000)
}

///|
test "perf: TextState version reconstruction oracle (1000 ops)" (b : @bench.T) {
  let doc = version_cache_benchmark_doc(1000)
  b.bench(() => b.keep(Version::from_ops(doc.inner.get_all_ops())))
}

///|
test "perf: TextState lazy version rebuild (1000 ops)" (b : @bench.T) {
  let doc = version_cache_benchmark_doc(1000)
  b.bench(() => {
    doc.invalidate_cached_version()
    b.keep(doc.version())
  })
}

///|
test "perf: Version::advance (1 replica)" (b : @bench.T) {
  bench_version_advance(b, 1, "agent-00")
}

///|
test "perf: Version::advance (8 replicas)" (b : @bench.T) {
  bench_version_advance(b, 8, "agent-07")
}

///|
test "perf: Version::advance (32 replicas)" (b : @bench.T) {
  bench_version_advance(b, 32, "agent-31")
}
