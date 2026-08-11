///| Matched admission benchmarks for the causal-cut performance gate.
///
/// The file intentionally uses only the existing OpLog surface. Run the same
/// file on a clean worktree and a candidate worktree to isolate extra
/// admission cost.

///|
fn benchmark_linear_operations(count : Int) -> Array[@core.Op] {
  let source = OpLog::new("admission-source")
  let mut previous = -1
  for _ in 0..<count {
    let operation = try! source.insert("x", previous, -1)
    previous = operation.lv()
  }
  source.get_all_ops()
}

///|
fn benchmark_reverse_operations(
  operations : Array[@core.Op],
) -> Array[@core.Op] {
  let reversed : Array[@core.Op] = []
  for index = 0; index < operations.length(); index = index + 1 {
    reversed.push(operations[operations.length() - index - 1])
  }
  reversed
}

///|
fn benchmark_local_admission(b : @bench.T, count : Int) -> Unit {
  b.bench(fn() {
    let target = OpLog::new("local-admission")
    let mut previous = -1
    for _ in 0..<count {
      let operation = try! target.insert("x", previous, -1)
      previous = operation.lv()
    }
    b.keep(target.op_count())
  })
}

///|
fn benchmark_remote_admission(
  b : @bench.T,
  operations : Array[@core.Op],
) -> Unit {
  b.bench(fn() {
    let target = OpLog::new("remote-admission")
    for operation in operations {
      ignore(try! target.apply_remote(operation))
    }
    b.keep(target.op_count())
  })
}

///|
fn benchmark_pending_drain(b : @bench.T, operations : Array[@core.Op]) -> Unit {
  let reversed = benchmark_reverse_operations(operations)
  b.bench(fn() {
    let target = OpLog::new("pending-admission")
    for operation in reversed {
      ignore(try! target.apply_remote(operation))
    }
    b.keep(target.op_count())
  })
}

///|
test "bench: matched local admission (1000 operations)" (b : @bench.T) {
  benchmark_local_admission(b, 1000)
}

///|
test "bench: matched local admission (10000 operations)" (b : @bench.T) {
  benchmark_local_admission(b, 10000)
}

///|
test "bench: matched remote admission (1000 operations)" (b : @bench.T) {
  let operations = benchmark_linear_operations(1000)
  benchmark_remote_admission(b, operations)
}

///|
test "bench: matched remote admission (10000 operations)" (b : @bench.T) {
  let operations = benchmark_linear_operations(10000)
  benchmark_remote_admission(b, operations)
}

///|
test "bench: matched pending drain (1000 operations)" (b : @bench.T) {
  let operations = benchmark_linear_operations(1000)
  benchmark_pending_drain(b, operations)
}
