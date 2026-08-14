/// Release benchmarks for the P0 semantic same-agent ancestry guard.

///|
fn p0_ancestry_direct_ops(n : Int) -> Array[@core.Op] {
  let ops : Array[@core.Op] = []
  for seq in 0..<n {
    let parents = if seq == 0 {
      []
    } else {
      [@core.RawVersion::new("direct", seq - 1)]
    }
    ops.push(@core.Op::new_insert(-1, parents, "direct", seq, "x", None, None))
  }
  ops
}

///|
/// Every path node has a distinct replica identity, forcing the final
/// same-agent predecessor proof to walk the whole declared-parent chain.
fn p0_ancestry_indirect_ops(depth : Int, invalid : Bool) -> Array[@core.Op] {
  let ops : Array[@core.Op] = [
    @core.Op::new_insert(-1, [], "alice", 0, "root", None, None),
  ]
  for index in 0..<depth {
    let parent = if index == 0 {
      @core.RawVersion::new("alice", 0)
    } else {
      @core.RawVersion::new("path-\{index - 1}", 0)
    }
    ops.push(
      @core.Op::new_insert(-1, [parent], "path-\{index}", 0, "x", None, None),
    )
  }
  let parents = if invalid {
    []
  } else {
    [@core.RawVersion::new("path-\{depth - 1}", 0)]
  }
  ops.push(@core.Op::new_insert(-1, parents, "alice", 1, "tail", None, None))
  ops
}

///|
fn p0_benchmark_valid_ancestry(b : @bench.T, ops : Array[@core.Op]) -> Unit {
  b.bench(
    fn() {
      let oplog = OpLog::new("benchmark")
      let plan = try! oplog.prepare_remote(ops)
      b.keep(plan.operations().length())
    },
    count=1,
  )
}

///|
fn p0_benchmark_invalid_ancestry(b : @bench.T, ops : Array[@core.Op]) -> Unit {
  b.bench(
    fn() {
      let oplog = OpLog::new("benchmark")
      let result : Result[RemoteAdmissionPlan, OpLogError] = Ok(
        oplog.prepare_remote(ops),
      ) catch {
        error => Err(error)
      }
      match result {
        Err(SequenceAncestryViolation(_)) => b.keep(1)
        _ => b.keep(0)
      }
    },
    count=1,
  )
}

///|
test "oplog - P0 direct ancestry prepare (1000 ops)" (b : @bench.T) {
  p0_benchmark_valid_ancestry(b, p0_ancestry_direct_ops(1000))
}

///|
test "oplog - P0 direct ancestry prepare (10000 ops)" (b : @bench.T) {
  p0_benchmark_valid_ancestry(b, p0_ancestry_direct_ops(10000))
}

///|
test "oplog - P0 direct ancestry prepare (100000 ops)" (b : @bench.T) {
  p0_benchmark_valid_ancestry(b, p0_ancestry_direct_ops(100000))
}

///|
test "oplog - P0 indirect ancestry prepare (1000 ops)" (b : @bench.T) {
  p0_benchmark_valid_ancestry(b, p0_ancestry_indirect_ops(1000, false))
}

///|
test "oplog - P0 indirect ancestry prepare (10000 ops)" (b : @bench.T) {
  p0_benchmark_valid_ancestry(b, p0_ancestry_indirect_ops(10000, false))
}

///|
test "oplog - P0 indirect ancestry prepare (100000 ops)" (b : @bench.T) {
  p0_benchmark_valid_ancestry(b, p0_ancestry_indirect_ops(100000, false))
}

///|
test "oplog - P0 invalid ancestry prepare (10000 ops)" (b : @bench.T) {
  p0_benchmark_invalid_ancestry(b, p0_ancestry_indirect_ops(10000, true))
}
