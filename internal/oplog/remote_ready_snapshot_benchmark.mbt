// Benchmark-only mixed-state comparison for Issue #87.
// Each case forces one snapshot strategy independently of production selection.

///|
/// Construct mixed ready state only through production pending-changes owner transitions.
fn benchmark_ready_matrix_pending_changes(
  stale_ready : Int,
  live_ready : Int,
  live_unresolved : Int,
) -> PendingChanges raise OpLogError {
  let pending_changes = PendingChanges()
  let missing = @core.RawVersion("ready-matrix-missing", 0)
  for i in 0..<live_unresolved {
    pending_changes.register_pending(
      @core.Op::insert(
        -1,
        [missing],
        "ready-matrix-unresolved",
        i,
        "u",
        None,
        None,
      ),
      _ => false,
    )
  }
  for i in 0..<live_ready {
    pending_changes.register_pending(
      @core.Op::insert(-1, [], "ready-matrix-live", i, "l", None, None),
      _ => false,
    )
  }
  for i in 0..<stale_ready {
    let op = @core.Op::insert(-1, [], "ready-matrix-stale", i, "s", None, None)
    pending_changes.register_pending(op, _ => false)
    pending_changes.acknowledge_applied(apply_changes_raw(op))
  }
  pending_changes
}

///|
/// Return the compatibility-ordered live identities after either copying the
/// retained queue or rebuilding a disposable queue from canonical order.
fn benchmark_ready_matrix_order(
  pending_changes : PendingChanges,
  rebuild : Bool,
) -> Array[@core.RawVersion] {
  let ready = if rebuild {
    let rebuilt : @priority_queue.PriorityQueue[ReadyChange] = Default::default()
    for entry in pending_changes.pending_order {
      match pending_changes.pending.get(entry.raw) {
        Some(node) =>
          if node.arrival == entry.arrival && node.unresolved_count == 0 {
            rebuilt.push({
              round_key: 0,
              arrival_key: -node.arrival,
              raw: entry.raw,
            })
          }
        None => ()
      }
    }
    rebuilt
  } else {
    pending_changes.ready.copy()
  }
  let raws : Array[@core.RawVersion] = []
  while ready.pop() is Some(entry) {
    match pending_changes.pending.get(entry.raw) {
      Some(node) =>
        if node.arrival == -entry.arrival_key && node.unresolved_count == 0 {
          raws.push(entry.raw)
        }
      None => ()
    }
  }
  raws
}

///|
/// Assert identical output and time 100 snapshots of one prebuilt state.
fn benchmark_ready_matrix_run(
  b : @bench.T,
  stale_ready : Int,
  live_ready : Int,
  live_unresolved : Int,
  rebuild : Bool,
) -> Unit raise {
  let pending_changes = try! benchmark_ready_matrix_pending_changes(
    stale_ready, live_ready, live_unresolved,
  )
  assert_eq(pending_changes.pending.length(), live_ready + live_unresolved)
  assert_eq(
    pending_changes.pending_order.length(),
    stale_ready + live_ready + live_unresolved,
  )
  assert_eq(pending_changes.ready.length(), stale_ready + live_ready)
  assert_eq(pending_changes.stale_ready_refs, stale_ready)
  assert_eq(pending_changes.stale_count(), stale_ready * 2)
  let copied = benchmark_ready_matrix_order(pending_changes, false)
  let rebuilt = benchmark_ready_matrix_order(pending_changes, true)
  assert_eq(copied.length(), live_ready)
  assert_eq(rebuilt.length(), live_ready)
  for i in 0..<live_ready {
    assert_eq(copied[i], rebuilt[i])
  }
  b.bench(fn() {
    let mut total = 0
    for _ in 0..<100 {
      total += benchmark_ready_matrix_order(pending_changes, rebuild).length()
    }
    b.keep(total)
  })
}

///|
test "ready snapshot copy S0 L1 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 0, 1, 1, false)
}

///|
test "ready snapshot rebuild S0 L1 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 0, 1, 1, true)
}

///|
test "ready snapshot copy S64 L1 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 64, 1, 1, false)
}

///|
test "ready snapshot rebuild S64 L1 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 64, 1, 1, true)
}

///|
test "ready snapshot copy S256 L1 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 256, 1, 1, false)
}

///|
test "ready snapshot rebuild S256 L1 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 256, 1, 1, true)
}

///|
test "ready snapshot copy S511 L1 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 1, 1, false)
}

///|
test "ready snapshot rebuild S511 L1 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 1, 1, true)
}

///|
test "ready snapshot copy S64 L16 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 64, 16, 1, false)
}

///|
test "ready snapshot rebuild S64 L16 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 64, 16, 1, true)
}

///|
test "ready snapshot copy S256 L64 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 256, 64, 1, false)
}

///|
test "ready snapshot rebuild S256 L64 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 256, 64, 1, true)
}

///|
test "ready snapshot copy S511 L16 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 16, 1, false)
}

///|
test "ready snapshot rebuild S511 L16 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 16, 1, true)
}

///|
test "ready snapshot copy S511 L64 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 64, 1, false)
}

///|
test "ready snapshot rebuild S511 L64 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 64, 1, true)
}

///|
test "ready snapshot copy S511 L256 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 256, 1, false)
}

///|
test "ready snapshot rebuild S511 L256 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 256, 1, true)
}

///|
test "ready snapshot copy S511 L511 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 511, 1, false)
}

///|
test "ready snapshot rebuild S511 L511 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 511, 1, true)
}

///|
test "ready snapshot copy S64 L3 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 64, 3, 1, false)
}

///|
test "ready snapshot rebuild S64 L3 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 64, 3, 1, true)
}

///|
test "ready snapshot copy S64 L4 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 64, 4, 1, false)
}

///|
test "ready snapshot rebuild S64 L4 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 64, 4, 1, true)
}

///|
test "ready snapshot copy S256 L15 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 256, 15, 1, false)
}

///|
test "ready snapshot rebuild S256 L15 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 256, 15, 1, true)
}

///|
test "ready snapshot copy S256 L16 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 256, 16, 1, false)
}

///|
test "ready snapshot rebuild S256 L16 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 256, 16, 1, true)
}

///|
test "ready snapshot copy S511 L30 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 30, 1, false)
}

///|
test "ready snapshot rebuild S511 L30 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 30, 1, true)
}

///|
test "ready snapshot copy S511 L31 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 31, 1, false)
}

///|
test "ready snapshot rebuild S511 L31 U1 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 31, 1, true)
}

///|
test "ready snapshot copy S511 L1 U64 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 1, 64, false)
}

///|
test "ready snapshot rebuild S511 L1 U64 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 1, 64, true)
}

///|
test "ready snapshot copy S511 L1 U512 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 1, 512, false)
}

///|
test "ready snapshot rebuild S511 L1 U512 x100" (b : @bench.T) {
  benchmark_ready_matrix_run(b, 511, 1, 512, true)
}
