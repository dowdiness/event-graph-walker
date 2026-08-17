///| P3 pending-limit compatibility tests for the Text public contract.

///|
test "P3 public pending limit zero accepts a ready operation" {
  let source = try! TextState::new("p3-limit-ready-zero-source")
  try! source.insert(Pos::at(0), "A")
  let message = try! source.sync().export_all()
  let receiver = try! TextState::new("p3-limit-ready-zero-receiver")
  let limits = try! @sync.Limits::Limits(max_pending_operations=0)

  let report = try! receiver.sync().apply_with_limits(message, limits)

  assert_eq(report.applied_operations(), 1)
  assert_eq(report.pending_operations(), 0)
  assert_eq(receiver.sync().pending_sync_count(), 0)
  assert_eq(receiver.text(), "A")
}

///|
test "P3 public pending limit counts only the mixed transition after commit" {
  let receiver = try! TextState::new("p3-limit-mixed-receiver")
  let message = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"p3-limit-ready\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null},{\"id\":{\"replica_id\":\"p3-limit-future\",\"sequence\":0},\"parents\":[{\"replica_id\":\"p3-limit-missing\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[]}",
  )
  let limits = try! @sync.Limits::Limits(max_pending_operations=1)

  let report = try! receiver.sync().apply_with_limits(message, limits)

  assert_eq(report.applied_operations(), 1)
  assert_eq(report.pending_operations(), 1)
  assert_eq(receiver.sync().pending_sync_count(), 1)
  assert_eq(receiver.text(), "A")
}

///|
test "P3 all-ready batch can exceed the public pending limit" {
  let source = try! TextState::new("p3-limit-all-ready-source")
  try! source.insert(Pos::at(0), "A")
  try! source.insert(Pos::at(1), "B")
  let message = try! source.sync().export_all()
  let receiver = try! TextState::new("p3-limit-all-ready-receiver")
  let limits = try! @sync.Limits::Limits(max_pending_operations=1)

  let report = try! receiver.sync().apply_with_limits(message, limits)

  assert_eq(report.applied_operations(), 2)
  assert_eq(report.pending_operations(), 0)
  assert_eq(receiver.sync().pending_sync_count(), 0)
  assert_eq(receiver.text(), "AB")
}
