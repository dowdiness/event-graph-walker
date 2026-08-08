///|
fn version_cache_benchmark_doc() -> TextState {
  let doc = try! TextState::new("alice")
  for i = 0; i < 1000; i = i + 1 {
    let _ = try! doc.insert(Pos::at(doc.len()), "x")
  }
  doc
}

///|
test "perf: TextState cached version read (1000 ops)" (b : @bench.T) {
  let doc = version_cache_benchmark_doc()
  ignore(doc.version())
  b.bench(() => b.keep(doc.version()))
}

///|
test "perf: TextState version reconstruction oracle (1000 ops)" (b : @bench.T) {
  let doc = version_cache_benchmark_doc()
  b.bench(() => b.keep(Version::from_ops(doc.inner.get_all_ops())))
}
