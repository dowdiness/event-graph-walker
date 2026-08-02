///| Isolated-process memory fixtures for Issue #107 Phase A.

///|
fn prepared_memory_fixture(
  replica_id : String,
  record_count : Int,
) -> (Document, TreeNodeId) {
  let document = try! Document::new(replica_id)
  let parent = try! document.create_node(parent=root_id)
  for index in 0..<record_count {
    let child = try! document.create_node(parent~)
    document.set_property(child, "record_type", "memory/record/v1")
    document.set_property(child, "entity_id", "entity-" + index.to_string())
    document.set_property(
      child,
      "body",
      "prepared local mutation memory body " + index.to_string(),
    )
  }
  (document, parent)
}

///|
fn prepared_memory_properties(operation_count : Int) -> Array[(String, String)] {
  let properties = []
  for index in 1..<operation_count {
    properties.push(
      ("property-" + index.to_string(), "value-" + index.to_string()),
    )
  }
  properties
}

///|
fn prepared_memory_run(
  scenario : String,
  record_count : Int,
  operation_count : Int,
  commit : Bool,
) -> Unit {
  let stage = if commit { "commit" } else { "prepare" }
  let (document, parent) = prepared_memory_fixture(
    "prepared-memory-" + scenario,
    record_count,
  )
  let before = try! document.sync().export_all().op_count()
  let capability = try! document.prepare_tree_property_append(
    parent,
    prepared_memory_properties(operation_count),
  )
  if commit {
    match (try! capability.commit()) {
      CommitAll(count) if count == operation_count => ()
      _ => abort("prepared memory fixture commit must succeed")
    }
  }
  let after = try! document.sync().export_all().op_count()
  let successor_canonical_bytes = capability.evidence().successor_canonical_bytes.length()
  let fence_json_bytes = @utf8.encode(capability.fence.full_json).length()
  let fence_canonical_bytes = capability.fence.canonical_bytes.length()
  // Exact encoded payloads retained logically by the capability. This excludes
  // object/container overhead and is not an in-memory object-size estimate.
  let logical_encoded_payload_lower_bound = capability.evidence().successor_json_bytes +
    successor_canonical_bytes +
    fence_json_bytes +
    fence_canonical_bytes
  println(
    "issue107-memory scenario=" +
    scenario +
    " stage=" +
    stage +
    " before_ops=" +
    before.to_string() +
    " after_ops=" +
    after.to_string() +
    " prepared_ops=" +
    capability.evidence().delta_operation_count.to_string() +
    " successor_json_bytes=" +
    capability.evidence().successor_json_bytes.to_string() +
    " successor_canonical_bytes=" +
    successor_canonical_bytes.to_string() +
    " fence_json_bytes=" +
    fence_json_bytes.to_string() +
    " fence_canonical_bytes=" +
    fence_canonical_bytes.to_string() +
    " logical_encoded_payload_lower_bound_bytes=" +
    logical_encoded_payload_lower_bound.to_string(),
  )
}

///|
test "issue 107 memory baseline" {
  println("issue107-memory stage=baseline")
}

///|
test "issue 107 memory prepare empty-4" {
  prepared_memory_run("empty-4", 0, 4, false)
}

///|
test "issue 107 memory prepare records-128-4" {
  prepared_memory_run("records-128-4", 128, 4, false)
}

///|
test "issue 107 memory prepare records-499-4" {
  prepared_memory_run("records-499-4", 499, 4, false)
}

///|
test "issue 107 memory prepare ops-1" {
  prepared_memory_run("ops-1", 0, 1, false)
}

///|
test "issue 107 memory prepare ops-4" {
  prepared_memory_run("ops-4", 0, 4, false)
}

///|
test "issue 107 memory prepare ops-16" {
  prepared_memory_run("ops-16", 0, 16, false)
}

///|
test "issue 107 memory prepare ops-64" {
  prepared_memory_run("ops-64", 0, 64, false)
}

///|
test "issue 107 memory commit empty-4" {
  prepared_memory_run("empty-4", 0, 4, true)
}

///|
test "issue 107 memory commit records-128-4" {
  prepared_memory_run("records-128-4", 128, 4, true)
}

///|
test "issue 107 memory commit records-499-4" {
  prepared_memory_run("records-499-4", 499, 4, true)
}

///|
test "issue 107 memory commit ops-1" {
  prepared_memory_run("ops-1", 0, 1, true)
}

///|
test "issue 107 memory commit ops-4" {
  prepared_memory_run("ops-4", 0, 4, true)
}

///|
test "issue 107 memory commit ops-16" {
  prepared_memory_run("ops-16", 0, 16, true)
}

///|
test "issue 107 memory commit ops-64" {
  prepared_memory_run("ops-64", 0, 64, true)
}

///|
fn prepared_memory_fixture_only(scenario : String, record_count : Int) -> Unit {
  let (document, _) = prepared_memory_fixture(
    "prepared-memory-" + scenario,
    record_count,
  )
  let operations = try! document.sync().export_all().op_count()
  println(
    "issue107-memory scenario=" +
    scenario +
    " stage=fixture" +
    " operations=" +
    operations.to_string(),
  )
}

///|
test "issue 107 memory fixture empty-4" {
  prepared_memory_fixture_only("empty-4", 0)
}

///|
test "issue 107 memory fixture records-128-4" {
  prepared_memory_fixture_only("records-128-4", 128)
}

///|
test "issue 107 memory fixture records-499-4" {
  prepared_memory_fixture_only("records-499-4", 499)
}

///|
test "issue 107 memory fixture ops-1" {
  prepared_memory_fixture_only("ops-1", 0)
}

///|
test "issue 107 memory fixture ops-4" {
  prepared_memory_fixture_only("ops-4", 0)
}

///|
test "issue 107 memory fixture ops-16" {
  prepared_memory_fixture_only("ops-16", 0)
}

///|
test "issue 107 memory fixture ops-64" {
  prepared_memory_fixture_only("ops-64", 0)
}
