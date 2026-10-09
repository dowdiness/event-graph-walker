///| Matched change application benchmarks for the causal-cut performance gate.
///
/// The file intentionally uses only the existing OpLog surface. Run the same
/// file on a clean worktree and a candidate worktree to isolate extra
/// change application cost.

///|
fn benchmark_linear_operations(count : Int) -> Array[@core.Op] {
  let source = OpLog("admission-source")
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
fn benchmark_local_apply_changes(b : @bench.T, count : Int) -> Unit {
  b.bench(fn() {
    let target = OpLog("local-admission")
    let mut previous = -1
    for _ in 0..<count {
      let operation = try! target.insert("x", previous, -1)
      previous = operation.lv()
    }
    b.keep(target.op_count())
  })
}

///|
fn benchmark_apply_changes(b : @bench.T, operations : Array[@core.Op]) -> Unit {
  b.bench(fn() {
    let target = OpLog("remote-admission")
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
    let target = OpLog("pending-admission")
    for operation in reversed {
      ignore(try! target.apply_remote(operation))
    }
    b.keep(target.op_count())
  })
}

///|
test "bench: matched local change application (1000 operations)" (b : @bench.T) {
  benchmark_local_apply_changes(b, 1000)
}

///|
test "bench: matched local change application (10000 operations)" (b : @bench.T) {
  benchmark_local_apply_changes(b, 10000)
}

///|
test "bench: matched remote change application (1000 operations)" (b : @bench.T) {
  let operations = benchmark_linear_operations(1000)
  benchmark_apply_changes(b, operations)
}

///|
test "bench: matched remote change application (10000 operations)" (
  b : @bench.T,
) {
  let operations = benchmark_linear_operations(10000)
  benchmark_apply_changes(b, operations)
}

///|
test "bench: matched pending drain (1000 operations)" (b : @bench.T) {
  let operations = benchmark_linear_operations(1000)
  benchmark_pending_drain(b, operations)
}
