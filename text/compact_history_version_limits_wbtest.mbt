///|
/// Decode sparse identities through the public schema-2 receiver path.
/// Every operation depends on the previous one, including across actors, so
/// there is exactly one head and the head limit cannot mask the range limit.
fn compact_sparse_version_source_for_test(
  ranges_per_actor : Array[Int],
) -> TextState raise {
  let operations : Array[Json] = []
  let mut previous = Json::null()
  let mut total = 0
  for actor_index, range_count in ranges_per_actor {
    let actor = "sparse-" + actor_index.to_string()
    for index in 0..<range_count {
      let id = Json::object({
        "replica_id": actor.to_json(),
        "sequence": (index * 2).to_json(),
      })
      let parents = if total == 0 { [] } else { [previous] }
      operations.push(
        Json::object({
          "id": id,
          "parents": parents.to_json(),
          "kind": "insert".to_json(),
          "content": "x".to_json(),
          "origin_left": previous,
          "origin_right": Json::null(),
        }),
      )
      previous = id
      total = total + 1
    }
  }
  let encoded = Json::object({
    "schema": (2).to_json(),
    "format": "event-graph-walker/text-sync".to_json(),
    "operations": operations.to_json(),
    "heads": [previous].to_json(),
  }).stringify()
  let source = TextState::new("sparse-receiver")
  let report = source.sync().apply(SyncMessage::from_json_string(encoded))
  assert_eq(report.applied_operations(), total)
  assert_eq(report.pending_operations(), 0)
  assert_eq(source.sync().export_all().op_count(), total)
  assert_eq(source.sync().export_all().heads.length(), 1)
  let ranges = source.version().graph().ranges()
  assert_eq(ranges.length(), ranges_per_actor.length())
  for index, entry in ranges {
    assert_eq(entry.1.length(), ranges_per_actor[index])
    for range_index, range in entry.1 {
      let start = (range_index * 2).reinterpret_as_uint()
      assert_eq(range, (start, start + 1U))
    }
  }
  assert_eq(source.text(), String::make(total, 'x'))
  source
}

///|
fn compact_check_version_range_boundary_for_test(
  at_limit : Array[Int],
  over_limit : Array[Int],
) -> Unit raise {
  let source = compact_sparse_version_source_for_test(at_limit)
  assert_eq(source.sync().export_all().op_count(), 4096)
  let expected = source.version().to_json_string()
  let archive = source.export_compact_experimental()
  let restored = TextState::restore_compact_direct_experimental(
    archive, "sparse-restored", expected,
  )
  assert_eq(restored.text(), source.text())
  assert_eq(restored.version(), source.version())
  assert_eq(restored.version().to_json_string(), expected)
  assert_eq(
    restored.sync().export_all().heads,
    source.sync().export_all().heads,
  )
  assert_eq(
    restored.sync().export_all().to_json_string(),
    source.sync().export_all().to_json_string(),
  )
  assert_eq(restored.sync().pending_sync_count(), 0)
  let rejected = compact_sparse_version_source_for_test(over_limit)
  assert_eq(rejected.sync().export_all().op_count(), 4097)
  let before_version = rejected.version()
  let before_history = rejected.sync().export_all().to_json_string()
  let before_text = rejected.text()
  let before_heads = rejected.sync().export_all().heads
  try rejected.export_compact_experimental() catch {
    TextError::SyncFailed(@sync.Failure::LimitExceeded(kind~, limit~, actual~)) => {
      assert_eq(kind, @sync.LimitKind::DecodedOperations)
      assert_eq(limit, 4096)
      assert_eq(actual, 4097)
    }
    error => raise error
  } noraise {
    _ => fail("compact export accepted 4097 sparse Version ranges")
  }
  assert_eq(rejected.version(), before_version)
  assert_eq(rejected.text(), before_text)
  assert_eq(rejected.sync().export_all().heads, before_heads)
  assert_eq(rejected.sync().export_all().to_json_string(), before_history)
  assert_eq(rejected.sync().pending_sync_count(), 0)
}

///|
test "compact Version accepts 4096 sparse ranges and rejects 4097 without mutation" {
  compact_check_version_range_boundary_for_test([4096], [4097])
}

///|
test "compact Version range limit is global across actors with one causal head" {
  compact_check_version_range_boundary_for_test([2048, 2048], [2048, 2049])
}
