///| PROTOTYPE ONLY — Issue #115 Gate 1.

///|
/// Question: can the text façade retain an exact, frozen, payload-bound causal
/// cut without copying complete history when the cut is captured?
///
/// This candidate retains the owning append-only document plus its operation
/// count and causal heads. Capture is bounded by frontier width. Exact equality
/// across different owners deliberately falls back to canonical prefix history;
/// benchmarks characterize that unresolved cost rather than hiding it.

///|
priv struct Gate1PrototypeCut {
  document : TextState
  operation_count : Int
  heads : Array[@core.RawVersion]
}

///|
fn gate1_capture_cut(document : TextState) -> Gate1PrototypeCut raise TextError {
  {
    document,
    operation_count: document.causal_snapshot().op_count(),
    heads: current_heads(document),
  }
}

///|
fn Gate1PrototypeCut::message(
  self : Gate1PrototypeCut,
) -> SyncMessage raise TextError {
  let all = self.document.inner.get_all_ops()
  guard self.operation_count <= all.length() else {
    raise TextError::VersionNotFound
  }
  let prefix = all[:self.operation_count].to_owned()
  map_sync_failure(fn() raise @sync.Failure {
    SyncMessage::SyncMessage(prefix, self.heads.copy(), None)
  })
}

///|
fn gate1_exact_cut_equal(
  left : Gate1PrototypeCut,
  right : Gate1PrototypeCut,
) -> Bool {
  if physical_equal(left.document.inner, right.document.inner) {
    return left.operation_count == right.operation_count &&
      left.heads == right.heads
  }
  let left_bytes = left.message().to_canonical_bytes() catch {
      _ => return false
    }
  let right_bytes = right.message().to_canonical_bytes() catch {
      _ => return false
    }
  left_bytes == right_bytes
}

///|
fn gate1_linear_document(
  operation_count : Int,
  replica_id : String,
) -> TextState {
  let document = try! TextState::new(replica_id)
  for _ in 0..<operation_count {
    try! document.insert(Pos::at(document.len()), "x")
  }
  document
}

///|
test "issue 115 gate 1 prototype: equal versions with conflicting payloads have different cuts" {
  let left = try! TextState::new("gate1-collision")
  let right = try! TextState::new("gate1-collision")
  try! left.insert(Pos::at(0), "A")
  try! right.insert(Pos::at(0), "B")
  assert_eq(left.version(), right.version())
  assert_false(
    gate1_exact_cut_equal(
      try! gate1_capture_cut(left),
      try! gate1_capture_cut(right),
    ),
  )
}

///|
test "issue 115 gate 1 prototype: retained cut stays frozen after owner advances" {
  let writer = try! TextState::new("gate1-frozen-writer")
  try! writer.insert(Pos::at(0), "A")
  let retained = try! gate1_capture_cut(writer)
  let peer = try! TextState::new("gate1-frozen-peer")
  ignore(try! peer.sync().apply(try! writer.sync().export_all()))
  let equivalent = try! gate1_capture_cut(peer)
  assert_true(gate1_exact_cut_equal(retained, equivalent))
  try! writer.insert(Pos::at(1), "B")
  assert_true(gate1_exact_cut_equal(retained, equivalent))
  assert_false(gate1_exact_cut_equal(retained, try! gate1_capture_cut(writer)))
}

///|
test "issue 115 gate 1 prototype: retained cut stays frozen after remote admission" {
  let writer = try! TextState::new("gate1-remote-writer")
  try! writer.insert(Pos::at(0), "A")
  let retained = try! gate1_capture_cut(writer)
  let equivalent_owner = try! TextState::new("gate1-remote-equivalent")
  ignore(try! equivalent_owner.sync().apply(try! writer.sync().export_all()))
  let equivalent = try! gate1_capture_cut(equivalent_owner)
  let remote = try! TextState::new("gate1-remote-peer")
  try! remote.insert(Pos::at(0), "R")
  ignore(try! writer.sync().apply(try! remote.sync().export_all()))
  assert_true(gate1_exact_cut_equal(retained, equivalent))
  assert_false(gate1_exact_cut_equal(retained, try! gate1_capture_cut(writer)))
}

///|
test "issue 115 gate 1 prototype: equivalent merged histories compare equal across owners" {
  let alice = try! TextState::new("gate1-merge-alice")
  let bob = try! TextState::new("gate1-merge-bob")
  try! alice.insert(Pos::at(0), "A")
  try! bob.insert(Pos::at(0), "B")
  let alice_message = try! alice.sync().export_all()
  let bob_message = try! bob.sync().export_all()
  let left = try! TextState::new("gate1-merge-left")
  ignore(try! left.sync().apply(alice_message))
  ignore(try! left.sync().apply(bob_message))
  let right = try! TextState::new("gate1-merge-right")
  ignore(try! right.sync().apply(bob_message))
  ignore(try! right.sync().apply(alice_message))
  assert_eq(left.text(), right.text())
  assert_eq(left.version(), right.version())
  assert_true(
    gate1_exact_cut_equal(
      try! gate1_capture_cut(left),
      try! gate1_capture_cut(right),
    ),
  )
}

///|
fn gate1_bench_capture(b : @bench.T, operation_count : Int) -> Unit {
  let document = gate1_linear_document(
    operation_count,
    "gate1-capture-" + operation_count.to_string(),
  )
  b.bench(() => b.keep(try! gate1_capture_cut(document)))
}

///|
fn gate1_bench_same_owner_equality(b : @bench.T, operation_count : Int) -> Unit {
  let document = gate1_linear_document(
    operation_count,
    "gate1-same-owner-" + operation_count.to_string(),
  )
  let left = try! gate1_capture_cut(document)
  let right = try! gate1_capture_cut(document)
  b.bench(() => b.keep(gate1_exact_cut_equal(left, right)))
}

///|
fn gate1_bench_cross_owner_equality(
  b : @bench.T,
  operation_count : Int,
) -> Unit {
  let source = gate1_linear_document(
    operation_count,
    "gate1-cross-owner-source-" + operation_count.to_string(),
  )
  let target = try! TextState::new(
    "gate1-cross-owner-target-" + operation_count.to_string(),
  )
  ignore(try! target.sync().apply(try! source.sync().export_all()))
  let left = try! gate1_capture_cut(source)
  let right = try! gate1_capture_cut(target)
  b.bench(() => b.keep(gate1_exact_cut_equal(left, right)))
}

///|
test "issue 115 gate 1 perf: capture empty" (b : @bench.T) {
  gate1_bench_capture(b, 0)
}

///|
test "issue 115 gate 1 perf: capture 1000 ops" (b : @bench.T) {
  gate1_bench_capture(b, 1000)
}

///|
test "issue 115 gate 1 perf: capture 10000 ops" (b : @bench.T) {
  gate1_bench_capture(b, 10000)
}

///|
test "issue 115 gate 1 perf: capture 100000 ops" (b : @bench.T) {
  gate1_bench_capture(b, 100000)
}

///|
test "issue 115 gate 1 perf: same-owner equality 1000 ops" (b : @bench.T) {
  gate1_bench_same_owner_equality(b, 1000)
}

///|
test "issue 115 gate 1 perf: same-owner equality 100000 ops" (b : @bench.T) {
  gate1_bench_same_owner_equality(b, 100000)
}

///|
test "issue 115 gate 1 perf: cross-owner equality 1000 ops" (b : @bench.T) {
  gate1_bench_cross_owner_equality(b, 1000)
}

///|
test "issue 115 gate 1 perf: cross-owner equality 10000 ops" (b : @bench.T) {
  gate1_bench_cross_owner_equality(b, 10000)
}
