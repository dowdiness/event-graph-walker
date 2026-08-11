///| Internal prototype benchmarks for causal-cut maintenance and comparison.

///|
fn benchmark_causal_cut_operations(count : Int) -> Array[@core.Op] {
  let log = OpLog::new("causal-cut-benchmark")
  let mut previous = -1
  for _ in 0..<count {
    let operation = try! log.insert("x", previous, -1)
    previous = operation.lv()
  }
  log.get_all_ops()
}

///|
test "bench: causal cut rebuild (1000 operations)" (b : @bench.T) {
  let operations = benchmark_causal_cut_operations(1000)
  b.bench(fn() {
    let cut = CausalCut::from_operations(operations)
    b.keep(cut.op_count())
  })
}

///|
test "bench: causal cut equality (1000 operations)" (b : @bench.T) {
  let operations = benchmark_causal_cut_operations(1000)
  let left = CausalCut::from_operations(operations)
  let right = CausalCut::from_operations(operations)
  b.bench(fn() { b.keep(left.equal(right)) })
}

///|
test "bench: explicit causal cut capture (1000 operations)" (b : @bench.T) {
  let log = OpLog::new("causal-cut-maintained-benchmark")
  let mut previous = -1
  for _ in 0..<1000 {
    let operation = try! log.insert("x", previous, -1)
    previous = operation.lv()
  }
  b.bench(fn() {
    let cut = log.causal_cut()
    b.keep(cut.op_count())
  })
}

///|
test "bench: causal cut frontier read (1000 operations)" (b : @bench.T) {
  let operations = benchmark_causal_cut_operations(1000)
  let cut = CausalCut::from_operations(operations)
  b.bench(fn() { b.keep(cut.frontier().length()) })
}
