///| Release-profile stage measurements for the Issue #107 Phase A model.

///|
fn prepared_benchmark_fixture(
  replica_id : String,
  record_count : Int,
) -> (Document, TreeNodeId) {
  let document = try! Document::new(replica_id)
  let parent = try! document.create_node(parent=root_id)
  for index in 0..<record_count {
    let child = try! document.create_node(parent~)
    document.set_property(child, "record_type", "benchmark/record/v1")
    document.set_property(child, "entity_id", "entity-" + index.to_string())
    document.set_property(
      child,
      "body",
      "prepared local mutation benchmark body " + index.to_string(),
    )
  }
  let operations = try! document.sync().export_all().op_count()
  println(
    "issue107 fixture records=" +
    record_count.to_string() +
    " operations=" +
    operations.to_string(),
  )
  (document, parent)
}

///|
fn benchmark_prepared_full_prepare(
  b : @bench.T,
  replica_id : String,
  record_count : Int,
) -> Unit {
  let (document, parent) = prepared_benchmark_fixture(replica_id, record_count)
  b.bench(fn() {
    let capability = try! document.prepare_tree_property_append(parent, [
      ("one", "1"),
      ("two", "2"),
      ("three", "3"),
    ])
    b.keep(capability.evidence().successor_json_bytes)
  })
}

///|
test "issue 107 prepare empty-4" (b : @bench.T) {
  benchmark_prepared_full_prepare(b, "prepared-bench-empty", 0)
}

///|
test "issue 107 prepare records-128-4" (b : @bench.T) {
  benchmark_prepared_full_prepare(b, "prepared-bench-128", 128)
}

///|
test "issue 107 prepare records-499-4" (b : @bench.T) {
  benchmark_prepared_full_prepare(b, "prepared-bench-499", 499)
}

///|
fn prepared_benchmark_candidate(
  replica_id : String,
) -> (PreparedLocalMutation, SyncMessage) {
  let (document, parent) = prepared_benchmark_fixture(replica_id, 499)
  let capability = try! document.prepare_tree_property_append(parent, [
    ("one", "1"),
    ("two", "2"),
    ("three", "3"),
  ])
  let candidate = try! prepared_local_successor_message(
    document,
    capability.records,
  )
  (capability, candidate)
}

///|
test "issue 107 successor message records-499-4" (b : @bench.T) {
  let (capability, _) = prepared_benchmark_candidate("prepared-bench-message")
  b.bench(fn() {
    let candidate = try! prepared_local_successor_message(
      capability.source,
      capability.records,
    )
    b.keep(candidate.op_count())
  })
}

///|
test "issue 107 JSON encoding records-499-4" (b : @bench.T) {
  let (_, candidate) = prepared_benchmark_candidate("prepared-bench-json")
  b.bench(fn() { b.keep(candidate.to_json_string().length()) })
}

///|
test "issue 107 canonical encoding records-499-4" (b : @bench.T) {
  let (_, candidate) = prepared_benchmark_candidate("prepared-bench-canonical")
  b.bench(fn() { b.keep(candidate.to_canonical_bytes().length()) })
}

///|
test "issue 107 fence validation records-499-4" (b : @bench.T) {
  let (capability, _) = prepared_benchmark_candidate("prepared-bench-fence")
  b.bench(fn() {
    let current = try! prepared_local_source_snapshot(capability.source)
    b.keep(current == capability.fence)
  })
}
