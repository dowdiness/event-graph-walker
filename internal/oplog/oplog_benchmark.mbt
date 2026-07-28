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
fn benchmark_remote_live_planner(
  n : Int,
) -> RemoteAdmissionPlanner raise OpLogError {
  let planner = RemoteAdmissionPlanner()
  for i in 0..<n {
    let op = @core.Op::new_insert(
      -1,
      [],
      "compact-benchmark-live",
      i,
      "x",
      None,
      None,
    )
    planner.register_pending(op, _ => false)
  }
  planner
}

///|
fn benchmark_remote_compaction_planner(
  n : Int,
) -> RemoteAdmissionPlanner raise OpLogError {
  let planner = RemoteAdmissionPlanner()
  let rejected : Array[@core.RawVersion] = []
  for i in 0..<n {
    let op = @core.Op::new_insert(
      -1,
      [],
      "compact-benchmark",
      i,
      "x",
      None,
      None,
    )
    planner.register_pending(op, _ => false)
    if i % 2 == 0 {
      rejected.push(remote_admission_raw(op))
    }
  }
  planner.reject_pending_dependents(rejected)
  planner
}

///|
/// The closure only times the O(N) live-index rebuild; all N nodes remain
/// live, so repeating compact rebuilds the same-sized planner.
test "oplog - remote planner compact clean-live rebuild (10000 live nodes)" (
  b : @bench.T,
) {
  let planner = try! benchmark_remote_live_planner(10000)
  b.bench(
    fn() {
      planner.compact(_ => false)
      b.keep(planner)
    },
    count=10,
  )
}

///|
/// The closure times fresh build+reject lifecycle work without compaction;
/// pair this with the following benchmark to isolate compaction overhead.
test "oplog - remote planner build+reject baseline (10000 entries)" (
  b : @bench.T,
) {
  b.bench(
    fn() {
      let planner = try! benchmark_remote_compaction_planner(10000)
      b.keep(planner)
    },
    count=10,
  )
}

///|
/// The closure times fresh build+reject plus policy-triggered compaction at
/// weighted stale = 2 * live. Compare it with the matched baseline above.
test "oplog - remote planner build+reject+policy compact (10000 entries)" (
  b : @bench.T,
) {
  b.bench(
    fn() {
      let planner = try! benchmark_remote_compaction_planner(10000)
      b.keep((planner.maybe_compact(_ => false), planner))
    },
    count=10,
  )
}

///|
/// Build retained ready-queue state only through production planner lifecycle
/// transitions. Two canonical nodes remain live: one ready and one unresolved.
/// Each acknowledged ready node contributes one stale order tombstone and one
/// stale ready reference, so 511/512/513 entries exercise weighted stale counts
/// 1022/1024/1026 around the policy floor.
fn benchmark_retained_ready_planner(
  stale_ready_entries : Int,
) -> RemoteAdmissionPlanner raise OpLogError {
  let planner = RemoteAdmissionPlanner()
  planner.register_pending(
    @core.Op::new_insert(-1, [], "retained-ready-live", 0, "x", None, None),
    _ => false,
  )
  planner.register_pending(
    @core.Op::new_insert(
      -1,
      [@core.RawVersion::new("retained-ready-missing", 0)],
      "retained-ready-unresolved",
      0,
      "x",
      None,
      None,
    ),
    _ => false,
  )
  for i in 0..<stale_ready_entries {
    let op = @core.Op::new_insert(
      -1,
      [],
      "retained-ready-stale",
      i,
      "x",
      None,
      None,
    )
    planner.register_pending(op, _ => false)
    planner.acknowledge_admitted(remote_admission_raw(op))
  }
  planner
}

///|
/// Pin retained counts and exact prepare output before timing. The benchmark
/// closure performs 100 non-mutating preparations against one prebuilt state;
/// divide the reported duration by 100 for the per-prepare cost.
fn benchmark_repeated_retained_ready_prepare(
  b : @bench.T,
  stale_ready_entries : Int,
  after_quiescent_policy : Bool,
  incoming : Array[@core.Op],
) -> Unit raise {
  let before = try! benchmark_retained_ready_planner(stale_ready_entries)
  let after = try! benchmark_retained_ready_planner(stale_ready_entries)
  assert_eq(before.pending.length(), 2)
  assert_eq(before.ready.length(), stale_ready_entries + 1)
  assert_eq(before.stale_ready_refs, stale_ready_entries)
  assert_eq(before.stale_count(), stale_ready_entries * 2)
  let policy_compacted = after.maybe_compact(_ => false)
  assert_eq(policy_compacted, stale_ready_entries >= 512)
  assert_eq(after.pending.length(), 2)
  if policy_compacted {
    assert_eq(after.ready.length(), 1)
    assert_eq(after.stale_ready_refs, 0)
    assert_eq(after.stale_count(), 0)
  } else {
    assert_eq(after.ready.length(), stale_ready_entries + 1)
    assert_eq(after.stale_ready_refs, stale_ready_entries)
    assert_eq(after.stale_count(), stale_ready_entries * 2)
  }
  let before_plan = try! before.prepare(incoming, _ => false)
  let after_plan = try! after.prepare(incoming, _ => false)
  benchmark_assert_raws(
    benchmark_raws(before_plan.operations().to_owned()),
    benchmark_raws(after_plan.operations().to_owned()),
  )
  benchmark_assert_raws(
    before_plan.remaining_raws(before),
    after_plan.remaining_raws(after),
  )
  let planner = if after_quiescent_policy {
    assert_true(policy_compacted)
    after
  } else {
    before
  }
  b.bench(fn() {
    let mut planned_count = 0
    for _ in 0..<100 {
      let plan = try! planner.prepare(incoming, _ => false)
      planned_count += plan.operations().length()
    }
    b.keep(planned_count)
  })
}

///|
test "oplog - retained stale ready below policy, small-ready prepare x100 (511 stale)" (
  b : @bench.T,
) {
  benchmark_repeated_retained_ready_prepare(
    b,
    511,
    false,
    benchmark_remote_chain(1),
  )
}

///|
test "oplog - retained stale ready below policy, unresolved prepare x100 (511 stale)" (
  b : @bench.T,
) {
  benchmark_repeated_retained_ready_prepare(b, 511, false, [
    benchmark_remote_chain(2)[1],
  ])
}

///|
test "oplog - retained stale ready at policy, small-ready prepare x100 (512 stale)" (
  b : @bench.T,
) {
  benchmark_repeated_retained_ready_prepare(
    b,
    512,
    false,
    benchmark_remote_chain(1),
  )
}

///|
test "oplog - compacted at policy, small-ready prepare x100 (0 stale)" (
  b : @bench.T,
) {
  benchmark_repeated_retained_ready_prepare(
    b,
    512,
    true,
    benchmark_remote_chain(1),
  )
}

///|
test "oplog - retained stale ready at policy, unresolved prepare x100 (512 stale)" (
  b : @bench.T,
) {
  benchmark_repeated_retained_ready_prepare(b, 512, false, [
    benchmark_remote_chain(2)[1],
  ])
}

///|
test "oplog - compacted at policy, unresolved prepare x100 (0 stale)" (
  b : @bench.T,
) {
  benchmark_repeated_retained_ready_prepare(b, 512, true, [
    benchmark_remote_chain(2)[1],
  ])
}

///|
test "oplog - retained stale ready above policy, small-ready prepare x100 (513 stale)" (
  b : @bench.T,
) {
  benchmark_repeated_retained_ready_prepare(
    b,
    513,
    false,
    benchmark_remote_chain(1),
  )
}

///|
test "oplog - retained stale ready above policy, unresolved prepare x100 (513 stale)" (
  b : @bench.T,
) {
  benchmark_repeated_retained_ready_prepare(b, 513, false, [
    benchmark_remote_chain(2)[1],
  ])
}

///|
/// One unresolved operation keeps canonical pending membership live while
/// independent remote deliveries pass through the production OpLog lifecycle.
fn benchmark_remote_stream_blocker() -> @core.Op {
  @core.Op::new_insert(
    -1,
    [@core.RawVersion::new("incidence-missing", 0)],
    "incidence-blocked",
    0,
    "blocked",
    None,
    None,
  )
}

///|
/// Replay either one-operation deliveries or one batch through production
/// prepare/begin/acknowledge/compaction transitions. A fresh OpLog is required
/// inside timing because the trace mutates graph and planner state.
fn benchmark_remote_stream_lifecycle(
  ready_ops : Array[@core.Op],
  retain_unresolved : Bool,
  batched : Bool,
) -> OpLog raise OpLogError {
  let oplog = OpLog::new("incidence-local")
  if retain_unresolved {
    ignore(oplog.apply_remote(benchmark_remote_stream_blocker()))
  }
  if batched {
    let plan = oplog.prepare_remote(ready_ops)
    ignore(oplog.commit_remote(plan))
  } else {
    for op in ready_ops {
      ignore(oplog.apply_remote(op))
    }
  }
  oplog
}

///|
/// Observe each delivery immediately before its one production prepare call.
/// Every `apply_remote` returns through commit and `maybe_compact`, so the
/// maximum prepares per quiescent caller transition is structurally one.
fn benchmark_remote_stream_incidence(
  ready_ops : Array[@core.Op],
) -> (Int, Int, Int, Int, Int, Int) raise OpLogError {
  let oplog = OpLog::new("incidence-evidence")
  ignore(oplog.apply_remote(benchmark_remote_stream_blocker()))
  let mut prepares_with_stale_ready = 0
  let mut max_stale_ready = 0
  let mut max_weighted_stale = 0
  let mut max_ready_length = 0
  let mut max_live_pending = 0
  let mut compactions = 0
  for op in ready_ops {
    let stale_before = oplog.planner.stale_count()
    if oplog.planner.stale_ready_refs > 0 {
      prepares_with_stale_ready += 1
    }
    max_stale_ready = max_stale_ready.max(oplog.planner.stale_ready_refs)
    max_weighted_stale = max_weighted_stale.max(stale_before)
    max_ready_length = max_ready_length.max(oplog.planner.ready.length())
    max_live_pending = max_live_pending.max(oplog.planner.pending.length())
    ignore(oplog.apply_remote(op))
    if stale_before > 0 && oplog.planner.stale_count() == 0 {
      compactions += 1
    }
  }
  (
    prepares_with_stale_ready, max_stale_ready, max_weighted_stale, max_ready_length,
    max_live_pending, compactions,
  )
}

///|
/// Pin equal admitted output for the production single-delivery control,
/// retained-pending stream, and retained-pending batch before timing.
fn benchmark_assert_remote_stream_equivalence(
  ready_ops : Array[@core.Op],
) -> Unit raise {
  let control = try! benchmark_remote_stream_lifecycle(ready_ops, false, false)
  let retained = try! benchmark_remote_stream_lifecycle(ready_ops, true, false)
  let batched = try! benchmark_remote_stream_lifecycle(ready_ops, true, true)
  let expected = benchmark_raws(control.get_all_ops())
  benchmark_assert_raws(benchmark_raws(retained.get_all_ops()), expected)
  benchmark_assert_raws(benchmark_raws(batched.get_all_ops()), expected)
  assert_eq(expected.length(), ready_ops.length())
  assert_true(!control.has_pending())
  assert_true(retained.has_pending())
  assert_true(batched.has_pending())
  let (
    prepares_with_stale_ready,
    max_stale_ready,
    max_weighted_stale,
    max_ready_length,
    max_live_pending,
    compactions,
  ) = try! benchmark_remote_stream_incidence(ready_ops)
  assert_eq(prepares_with_stale_ready, ready_ops.length() - 1)
  assert_eq(max_stale_ready, 511)
  assert_eq(max_weighted_stale, 1022)
  assert_eq(max_ready_length, 511)
  assert_eq(max_live_pending, 1)
  assert_eq(compactions, 1)
}

///|
test "oplog - realistic remote stream, no pending (512 single deliveries)" (
  b : @bench.T,
) {
  let ready_ops = benchmark_remote_chain(512)
  try! benchmark_assert_remote_stream_equivalence(ready_ops)
  b.bench(fn() {
    let oplog = try! benchmark_remote_stream_lifecycle(ready_ops, false, false)
    b.keep((oplog.op_count(), oplog.has_pending()))
  })
}

///|
test "oplog - realistic remote stream, one unresolved pending (512 single deliveries)" (
  b : @bench.T,
) {
  let ready_ops = benchmark_remote_chain(512)
  try! benchmark_assert_remote_stream_equivalence(ready_ops)
  b.bench(fn() {
    let oplog = try! benchmark_remote_stream_lifecycle(ready_ops, true, false)
    b.keep((oplog.op_count(), oplog.has_pending()))
  })
}

///|
test "oplog - realistic remote batch, one unresolved pending (512 ops)" (
  b : @bench.T,
) {
  let ready_ops = benchmark_remote_chain(512)
  try! benchmark_assert_remote_stream_equivalence(ready_ops)
  b.bench(fn() {
    let oplog = try! benchmark_remote_stream_lifecycle(ready_ops, true, true)
    b.keep((oplog.op_count(), oplog.has_pending()))
  })
}

///|
// Benchmark-only copy of the historical pending-first fixed-point planner.
// This must remain independent of OpLog and receives admitted identities
// explicitly so the timed oracle has no hidden graph state.
fn benchmark_fixed_point_oracle(
  candidates : Array[@core.Op],
  known : Array[@core.RawVersion],
) -> (Array[@core.Op], Array[@core.Op]) raise OpLogError {
  let mut candidates = candidates
  let planned : Array[@core.Op] = []
  let planned_raws : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  let known_raws : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet(known)
  let mut progress = true
  while progress {
    progress = false
    let remaining : Array[@core.Op] = []
    for op in candidates {
      let raw = @core.RawVersion::new(op.agent(), op.seq())
      if known_raws.contains(raw) || planned_raws.contains(raw) {
        progress = true
        continue
      }
      if (op.is_delete() || op.is_undelete()) && op.origin_left() is None {
        raise OpLogError::MissingOrigin
      }
      let mut ready = true
      for parent in op.parents_iter() {
        if !known_raws.contains(parent) && !planned_raws.contains(parent) {
          ready = false
          break
        }
      }
      if ready {
        match op.origin_left() {
          None => ()
          Some(origin) =>
            if !known_raws.contains(origin) && !planned_raws.contains(origin) {
              ready = false
            }
        }
      }
      if ready {
        match op.origin_right() {
          None => ()
          Some(origin) =>
            if !known_raws.contains(origin) && !planned_raws.contains(origin) {
              ready = false
            }
        }
      }
      if ready {
        planned.push(op)
        planned_raws.add(raw)
        progress = true
      } else {
        remaining.push(op)
      }
    }
    candidates = remaining
  }
  (planned, candidates)
}

///|
fn benchmark_raws(ops : Array[@core.Op]) -> Array[@core.RawVersion] {
  [
    for op in ops => @core.RawVersion::new(op.agent(), op.seq())
  ]
}

///|
fn benchmark_assert_raws(
  actual : Array[@core.RawVersion],
  expected : Array[@core.RawVersion],
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for i in 0..<actual.length() {
    assert_eq(actual[i], expected[i])
  }
}

///|
fn benchmark_production_plan(
  ops : Array[@core.Op],
) -> (Array[@core.Op], Array[@core.RawVersion]) raise OpLogError {
  let oplog = OpLog::new("local")
  let plan = oplog.prepare_remote(ops)
  (plan.operations().to_owned(), plan.remaining_raws(oplog.planner))
}

///|
/// Benchmark-only: planned ops for production path timing. Creates a fresh
/// OpLog and delegates to the compatibility wrapper.
fn benchmark_production_planned(
  ops : Array[@core.Op],
) -> Array[@core.Op] raise OpLogError {
  let oplog = OpLog::new("local")
  oplog.plan_remote(ops)
}

///|
/// Planner-only preparation for one-operation overhead gates. Larger retained
/// gates continue to cover the OpLog wrapper separately.
fn benchmark_production_planner_planned(
  ops : Array[@core.Op],
) -> Array[@core.Op] raise OpLogError {
  let planner = RemoteAdmissionPlanner()
  planner.prepare(ops, _ => false).operations().to_owned()
}

///|
// Compare both planned order and the exact remaining pending order before the
// benchmark closure. Each production comparison starts from an empty OpLog.
fn benchmark_assert_planner_equivalence(ops : Array[@core.Op]) -> Unit raise {
  let (oracle_planned, oracle_remaining) = benchmark_fixed_point_oracle(
    ops.copy(),
    [],
  )
  let (production_planned, production_remaining) = benchmark_production_plan(
    ops,
  )
  benchmark_assert_raws(
    benchmark_raws(oracle_planned),
    benchmark_raws(production_planned),
  )
  benchmark_assert_raws(benchmark_raws(oracle_remaining), production_remaining)
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
test "oplog - oracle reverse dependency chain plan batch (100 ops)" (
  b : @bench.T,
) {
  let ops = benchmark_reverse_ops(benchmark_remote_chain(100))
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(
    fn() {
      let (planned, _remaining) = try! benchmark_fixed_point_oracle(
        ops.copy(),
        [],
      )
      b.keep(benchmark_raws(planned))
    },
    count=1,
  )
}

///|
test "oplog - production reverse dependency chain plan batch (100 ops)" (
  b : @bench.T,
) {
  let ops = benchmark_reverse_ops(benchmark_remote_chain(100))
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(
    fn() {
      let planned = try! benchmark_production_planned(ops)
      b.keep(benchmark_raws(planned))
    },
    count=1,
  )
}

///|
test "oplog - oracle reverse dependency chain plan batch (1000 ops)" (
  b : @bench.T,
) {
  let ops = benchmark_reverse_ops(benchmark_remote_chain(1000))
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(
    fn() {
      let (planned, _remaining) = try! benchmark_fixed_point_oracle(
        ops.copy(),
        [],
      )
      b.keep(benchmark_raws(planned))
    },
    count=1,
  )
}

///|
test "oplog - production reverse dependency chain plan batch (1000 ops)" (
  b : @bench.T,
) {
  let ops = benchmark_reverse_ops(benchmark_remote_chain(1000))
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(
    fn() {
      let planned = try! benchmark_production_planned(ops)
      b.keep(benchmark_raws(planned))
    },
    count=1,
  )
}

///|
test "oplog - oracle reverse dependency chain plan batch (10000 ops)" (
  b : @bench.T,
) {
  let ops = benchmark_reverse_ops(benchmark_remote_chain(10000))
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(
    fn() {
      let (planned, _remaining) = try! benchmark_fixed_point_oracle(
        ops.copy(),
        [],
      )
      b.keep(benchmark_raws(planned))
    },
    count=1,
  )
}

///|
test "oplog - production reverse dependency chain plan batch (10000 ops)" (
  b : @bench.T,
) {
  let ops = benchmark_reverse_ops(benchmark_remote_chain(10000))
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(
    fn() {
      let planned = try! benchmark_production_planned(ops)
      b.keep(benchmark_raws(planned))
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
test "oplog - oracle reverse branching dependencies plan batch (4 x 250 ops)" (
  b : @bench.T,
) {
  let ops = benchmark_reverse_ops(benchmark_remote_branches(250))
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(
    fn() {
      let (planned, _remaining) = try! benchmark_fixed_point_oracle(
        ops.copy(),
        [],
      )
      b.keep(benchmark_raws(planned))
    },
    count=1,
  )
}

///|
test "oplog - production reverse branching dependencies plan batch (4 x 250 ops)" (
  b : @bench.T,
) {
  let ops = benchmark_reverse_ops(benchmark_remote_branches(250))
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(
    fn() {
      let planned = try! benchmark_production_planned(ops)
      b.keep(benchmark_raws(planned))
    },
    count=1,
  )
}

///|
fn benchmark_all_ready_batch(n : Int) -> Array[@core.Op] {
  let ops : Array[@core.Op] = []
  for i in 0..<n {
    ops.push(@core.Op::new_insert(-1, [], "ready", i, "x", None, None))
  }
  ops
}

///|
fn benchmark_duplicate_heavy_batch(
  unique_count : Int,
  copies : Int,
) -> Array[@core.Op] {
  let unique = benchmark_all_ready_batch(unique_count)
  let ops : Array[@core.Op] = []
  for _ in 0..<copies {
    for op in unique {
      ops.push(op)
    }
  }
  ops
}

///|
test "oplog - oracle all-ready batch plan (32 ops)" (b : @bench.T) {
  let ops = benchmark_all_ready_batch(32)
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(fn() {
    let (planned, _remaining) = try! benchmark_fixed_point_oracle(ops.copy(), [])
    b.keep(benchmark_raws(planned))
  })
}

///|
test "oplog - production all-ready batch plan (32 ops)" (b : @bench.T) {
  let ops = benchmark_all_ready_batch(32)
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(fn() {
    let planned = try! benchmark_production_planned(ops)
    b.keep(benchmark_raws(planned))
  })
}

///|
test "oplog - oracle in-order dependency chain plan (64 ops)" (b : @bench.T) {
  let ops = benchmark_remote_chain(64)
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(fn() {
    let (planned, _remaining) = try! benchmark_fixed_point_oracle(ops.copy(), [])
    b.keep(benchmark_raws(planned))
  })
}

///|
test "oplog - production in-order dependency chain plan (64 ops)" (b : @bench.T) {
  let ops = benchmark_remote_chain(64)
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(fn() {
    let planned = try! benchmark_production_planned(ops)
    b.keep(benchmark_raws(planned))
  })
}

///|
test "oplog - oracle duplicate-heavy batch plan (32 ops x 8 copies)" (
  b : @bench.T,
) {
  let ops = benchmark_duplicate_heavy_batch(32, 8)
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(fn() {
    let (planned, _remaining) = try! benchmark_fixed_point_oracle(ops.copy(), [])
    b.keep(benchmark_raws(planned))
  })
}

///|
test "oplog - production duplicate-heavy batch plan (32 ops x 8 copies)" (
  b : @bench.T,
) {
  let ops = benchmark_duplicate_heavy_batch(32, 8)
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(fn() {
    let planned = try! benchmark_production_planned(ops)
    b.keep(benchmark_raws(planned))
  })
}

///|
test "oplog - oracle all-ready batch plan (1 op)" (b : @bench.T) {
  let ops = benchmark_all_ready_batch(1)
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(fn() {
    let (planned, _remaining) = try! benchmark_fixed_point_oracle(ops.copy(), [])
    b.keep(benchmark_raws(planned))
  })
}

///|
test "oplog - production planner all-ready batch (1 op)" (b : @bench.T) {
  let ops = benchmark_all_ready_batch(1)
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(fn() {
    let planned = try! benchmark_production_planner_planned(ops)
    b.keep(benchmark_raws(planned))
  })
}

///|
test "oplog - oracle in-order dependency chain plan (1 op)" (b : @bench.T) {
  let ops = benchmark_remote_chain(1)
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(fn() {
    let (planned, _remaining) = try! benchmark_fixed_point_oracle(ops.copy(), [])
    b.keep(benchmark_raws(planned))
  })
}

///|
test "oplog - production planner in-order dependency chain (1 op)" (
  b : @bench.T,
) {
  let ops = benchmark_remote_chain(1)
  try! benchmark_assert_planner_equivalence(ops)
  b.bench(fn() {
    let planned = try! benchmark_production_planner_planned(ops)
    b.keep(benchmark_raws(planned))
  })
}

///|
/// Matched production lifecycle: prepare, begin, and acknowledge every planned
/// operation. The result shape is checked against the historical oracle before
/// timing so the benchmark cannot pass by shifting or omitting work.
fn benchmark_remote_admission_lifecycle(
  ops : Array[@core.Op],
) -> (Array[@core.RawVersion], Array[@core.RawVersion]) raise OpLogError {
  let planner = RemoteAdmissionPlanner()
  let plan = planner.prepare(ops, _ => false)
  match planner.begin(plan, _ => false) {
    RemoteAdmissionBeginResult::Applied => ()
    _ => abort("production lifecycle begin failed")
  }
  let planned = benchmark_raws(plan.operations().to_owned())
  for op in plan.operations() {
    planner.acknowledge_admitted(remote_admission_raw(op))
  }
  (planned, planner.pending_raws())
}

///|
fn benchmark_assert_lifecycle_equivalence(ops : Array[@core.Op]) -> Unit raise {
  let (oracle_planned, oracle_remaining) = try! benchmark_fixed_point_oracle(
    ops.copy(),
    [],
  )
  let (production_planned, production_remaining) = try! benchmark_remote_admission_lifecycle(
    ops,
  )
  benchmark_assert_raws(production_planned, benchmark_raws(oracle_planned))
  benchmark_assert_raws(production_remaining, benchmark_raws(oracle_remaining))
}

///|
test "oplog - production lifecycle all-ready batch (32 ops)" (b : @bench.T) {
  let ops = benchmark_all_ready_batch(32)
  benchmark_assert_lifecycle_equivalence(ops)
  b.bench(fn() { b.keep(try! benchmark_remote_admission_lifecycle(ops)) })
}

///|
test "oplog - production lifecycle in-order chain (64 ops)" (b : @bench.T) {
  let ops = benchmark_remote_chain(64)
  benchmark_assert_lifecycle_equivalence(ops)
  b.bench(fn() { b.keep(try! benchmark_remote_admission_lifecycle(ops)) })
}

///|
test "oplog - production lifecycle reverse branches (4 x 250 ops)" (
  b : @bench.T,
) {
  let ops = benchmark_reverse_ops(benchmark_remote_branches(250))
  benchmark_assert_lifecycle_equivalence(ops)
  b.bench(
    fn() { b.keep(try! benchmark_remote_admission_lifecycle(ops)) },
    count=1,
  )
}

///|
test "oplog - production lifecycle reverse chain (10000 ops)" (b : @bench.T) {
  let ops = benchmark_reverse_ops(benchmark_remote_chain(10000))
  benchmark_assert_lifecycle_equivalence(ops)
  b.bench(
    fn() { b.keep(try! benchmark_remote_admission_lifecycle(ops)) },
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
