///| Release-profile stage measurements for the Issue #107 Phase A model.

///|
fn prepared_benchmark_properties(
  operation_count : Int,
) -> Array[(String, String)] {
  let properties = []
  for index in 1..<operation_count {
    properties.push(
      ("property-" + index.to_string(), "value-" + index.to_string()),
    )
  }
  properties
}

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
  (document, parent)
}

///|
fn prepared_benchmark_print_operations(
  scenario : String,
  document : Document,
  phase : String,
) -> Unit {
  let operations = try! document.sync().export_all().op_count()
  println(
    "issue107 scenario=" +
    scenario +
    " phase=" +
    phase +
    " operations=" +
    operations.to_string(),
  )
}

///|
fn benchmark_prepared_full_prepare(
  b : @bench.T,
  scenario : String,
  record_count : Int,
  operation_count : Int,
) -> Unit {
  let (document, parent) = prepared_benchmark_fixture(
    "prepared-full-" + scenario,
    record_count,
  )
  let properties = prepared_benchmark_properties(operation_count)
  prepared_benchmark_print_operations(scenario, document, "before")
  b.bench(fn() {
    let capability = try! document.prepare_tree_property_append(
      parent, properties,
    )
    b.keep(capability.evidence().successor_json_bytes)
  })
}

///|
test "issue 107 full prepare empty-4" (b : @bench.T) {
  benchmark_prepared_full_prepare(b, "empty-4", 0, 4)
}

///|
test "issue 107 full prepare records-128-4" (b : @bench.T) {
  benchmark_prepared_full_prepare(b, "records-128-4", 128, 4)
}

///|
test "issue 107 full prepare records-499-4" (b : @bench.T) {
  benchmark_prepared_full_prepare(b, "records-499-4", 499, 4)
}

///|
fn prepared_benchmark_candidate(
  replica_id : String,
) -> (PreparedLocalMutation, SyncMessage) {
  let (document, parent) = prepared_benchmark_fixture(replica_id, 499)
  let capability = try! document.prepare_tree_property_append(
    parent,
    prepared_benchmark_properties(4),
  )
  let candidate = try! prepared_local_successor_message(
    document,
    capability.records,
  )
  (capability, candidate)
}

///|
test "issue 107 detached lowering records-499-4" (b : @bench.T) {
  let (document, parent) = prepared_benchmark_fixture("prepared-lowering", 499)
  let properties = prepared_benchmark_properties(4)
  prepared_benchmark_print_operations("records-499-4", document, "before")
  b.bench(fn() {
    let records = try! prepared_local_lower_tree_property_append(
      document,
      parent.to_inner(),
      properties,
    )
    b.keep(records.length())
  })
}

///|
test "issue 107 successor message records-499-4" (b : @bench.T) {
  let (capability, _) = prepared_benchmark_candidate("prepared-message")
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
  let (_, candidate) = prepared_benchmark_candidate("prepared-json")
  b.bench(fn() { b.keep(@utf8.encode(candidate.to_json_string()).length()) })
}

///|
test "issue 107 canonical encoding records-499-4" (b : @bench.T) {
  let (_, candidate) = prepared_benchmark_candidate("prepared-canonical")
  b.bench(fn() { b.keep(candidate.to_canonical_bytes().length()) })
}

///|
test "issue 107 fence validation records-499-4" (b : @bench.T) {
  let (capability, _) = prepared_benchmark_candidate("prepared-fence")
  b.bench(fn() {
    let current = try! prepared_local_source_snapshot(capability.source)
    b.keep(current == capability.fence)
  })
}

///|
fn prepared_benchmark_commit_sample(
  replica_id : String,
  direct : Bool,
) -> Double {
  let (document, parent) = prepared_benchmark_fixture(replica_id, 499)
  let properties = prepared_benchmark_properties(4)
  if direct {
    let started = @bench.monotonic_clock_start()
    try! document.transaction(fn() {
      let child = try! document.create_node(parent~)
      for property in properties {
        document.set_property(child, property.0, property.1)
      }
    })
    @bench.monotonic_clock_end(started)
  } else {
    let capability = try! document.prepare_tree_property_append(
      parent, properties,
    )
    let started = @bench.monotonic_clock_start()
    guard (try! capability.commit()) is CommitAll(4) else {
      abort("prepared benchmark commit must succeed")
    }
    @bench.monotonic_clock_end(started)
  }
}

///|
fn prepared_benchmark_print_commit_samples(
  b : @bench.T,
  label : String,
  direct : Bool,
) -> Unit {
  for warmup in 0..<3 {
    b.keep(
      prepared_benchmark_commit_sample(
        "commit-comparison-warmup-" + warmup.to_string(),
        direct,
      ),
    )
  }
  for sample in 0..<10 {
    let elapsed_us = prepared_benchmark_commit_sample(
      "commit-comparison-sample-" + sample.to_string(),
      direct,
    )
    println(
      "issue107 stage=" +
      label +
      " sample=" +
      sample.to_string() +
      " elapsed_us=" +
      elapsed_us.to_string(),
    )
    b.keep(elapsed_us)
  }
}

///|
test "issue 107 commit only records-499-4" (b : @bench.T) {
  prepared_benchmark_print_commit_samples(b, "commit-only", false)
}

///|
fn prepared_benchmark_committed(replica_id : String) -> Document {
  let (document, parent) = prepared_benchmark_fixture(replica_id, 499)
  prepared_benchmark_print_operations("records-499-4", document, "before")
  let capability = try! document.prepare_tree_property_append(
    parent,
    prepared_benchmark_properties(4),
  )
  guard (try! capability.commit()) is CommitAll(4) else {
    abort("prepared benchmark setup commit must succeed")
  }
  prepared_benchmark_print_operations("records-499-4", document, "after")
  document
}

///|
test "issue 107 post-commit full export records-499-4" (b : @bench.T) {
  let document = prepared_benchmark_committed("prepared-post-export")
  b.bench(fn() { b.keep(try! document.sync().export_all().op_count()) })
}

///|
test "issue 107 post-commit JSON encoding records-499-4" (b : @bench.T) {
  let document = prepared_benchmark_committed("prepared-post-json")
  let exported = try! document.sync().export_all()
  b.bench(fn() { b.keep(@utf8.encode(exported.to_json_string()).length()) })
}

///|
test "issue 107 post-commit canonical encoding records-499-4" (b : @bench.T) {
  let document = prepared_benchmark_committed("prepared-post-canonical")
  let exported = try! document.sync().export_all()
  b.bench(fn() { b.keep(exported.to_canonical_bytes().length()) })
}

///|
test "issue 107 direct local baseline records-499-4" (b : @bench.T) {
  prepared_benchmark_print_commit_samples(b, "direct-local", true)
}

///|
fn benchmark_prepared_detached_ops(b : @bench.T, operation_count : Int) -> Unit {
  let scenario = "ops-" + operation_count.to_string()
  let (document, parent) = prepared_benchmark_fixture(
    "prepared-lowering-" + scenario,
    0,
  )
  let properties = prepared_benchmark_properties(operation_count)
  prepared_benchmark_print_operations(scenario, document, "before")
  b.bench(fn() {
    let records = try! prepared_local_lower_tree_property_append(
      document,
      parent.to_inner(),
      properties,
    )
    b.keep(records.length())
  })
}

///|
test "issue 107 detached lowering ops-1" (b : @bench.T) {
  benchmark_prepared_detached_ops(b, 1)
}

///|
test "issue 107 detached lowering ops-4" (b : @bench.T) {
  benchmark_prepared_detached_ops(b, 4)
}

///|
test "issue 107 detached lowering ops-16" (b : @bench.T) {
  benchmark_prepared_detached_ops(b, 16)
}

///|
test "issue 107 detached lowering ops-64" (b : @bench.T) {
  benchmark_prepared_detached_ops(b, 64)
}

///|
test "issue 107 full prepare ops-1" (b : @bench.T) {
  benchmark_prepared_full_prepare(b, "ops-1", 0, 1)
}

///|
test "issue 107 full prepare ops-4" (b : @bench.T) {
  benchmark_prepared_full_prepare(b, "ops-4", 0, 4)
}

///|
test "issue 107 full prepare ops-16" (b : @bench.T) {
  benchmark_prepared_full_prepare(b, "ops-16", 0, 16)
}

///|
test "issue 107 full prepare ops-64" (b : @bench.T) {
  benchmark_prepared_full_prepare(b, "ops-64", 0, 64)
}
