///| P3 red tests for Text report mapping and the core-owned ingress seam.

///|
test "P3 same-message raw duplicates canonicalize before admission" {
  let operation = "{\"id\":{\"replica_id\":\"p3-raw\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}"
  let json = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[" +
    operation +
    "," +
    operation +
    "],\"heads\":[{\"replica_id\":\"p3-raw\",\"sequence\":0}]}"
  let message = try! SyncMessage::from_json_string(json)
  assert_eq(message.op_count(), 1)

  let receiver = try! TextState::new("p3-raw-receiver")
  let limits = try! @sync.Limits::Limits(max_decoded_operations=2)
  let report = try! receiver.sync().apply_with_limits(message, limits)

  assert_eq(report.applied_operations(), 1)
  assert_eq(report.duplicate_operations(), 0)
  assert_eq(report.pending_operations(), 0)
  assert_eq(receiver.text(), "A")
}

///|
test "P3 one message invokes one Document admission boundary" {
  let source = try! TextState::new("p3-boundary-source")
  try! source.insert(Pos::at(0), "A")
  try! source.insert(Pos::at(1), "B")
  let message = try! source.sync().export_all()
  let receiver = try! TextState::new("p3-boundary-receiver")
  let mut admission_calls = 0
  let session = SyncSession::{
    doc: receiver,
    prepare_for_mutation_override: None,
    admit_remote_override: Some((
      document,
      operations,
      max_pending_after_complete,
    ) => {
      admission_calls = admission_calls + 1
      document.admit_remote(operations, max_pending_after_complete~)
    }),
  }

  let report = try! session.apply(message)

  assert_eq(admission_calls, 1)
  assert_eq(report.applied_operations(), 2)
  assert_eq(report.pending_operations(), 0)
}

///|
test "P3 complete report maps committed evidence and invalidates version cache" {
  let source = try! TextState::new("p3-complete-source")
  try! source.insert(Pos::at(0), "A")
  let message = try! source.sync().export_all()
  let receiver = try! TextState::new("p3-complete-receiver")
  let session = receiver.sync()
  assert_true(session.doc.cached_version is Ready(_))

  let report = try! session.apply(message)

  assert_eq(report.applied_operations(), 1)
  assert_eq(report.duplicate_operations(), 0)
  assert_eq(report.pending_operations(), 0)
  assert_true(session.doc.cached_version is Invalid)
}

///|
test "P3 duplicate-only report keeps the version cache valid" {
  let source = try! TextState::new("p3-duplicate-source")
  try! source.insert(Pos::at(0), "A")
  let message = try! source.sync().export_all()
  let receiver = try! TextState::new("p3-duplicate-receiver")
  let session = receiver.sync()
  ignore(try! session.apply(message))
  ignore(session.current_version())
  assert_true(session.doc.cached_version is Ready(_))

  let duplicate = try! session.apply(message)

  assert_eq(duplicate.applied_operations(), 0)
  assert_eq(duplicate.duplicate_operations(), 1)
  assert_eq(duplicate.pending_operations(), 0)
  assert_true(session.doc.cached_version is Ready(_))
}

///|
test "P3 pending ingress belongs to core and leaves no outer pending owner" {
  let receiver = try! TextState::new("p3-pending-owner")
  let message = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"p3-parent\",\"sequence\":1},\"parents\":[{\"replica_id\":\"p3-parent\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"p3-parent\",\"sequence\":1}]}",
  )
  let session = receiver.sync()
  let report = try! session.apply(message)

  assert_eq(report.applied_operations(), 0)
  assert_eq(report.pending_operations(), 1)
  assert_eq(session.doc.inner.pending_count(), 1)
}

///|
test "P3 clear pending delegates live closure ownership to core" {
  let receiver = try! TextState::new("p3-clear-pending")
  let deferred = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"p3-clear-pending\",\"sequence\":1},\"parents\":[{\"replica_id\":\"p3-clear-pending\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"p3-clear-pending\",\"sequence\":1}]}",
  )
  ignore(try! receiver.sync().apply(deferred))
  let before = receiver.version()
  assert_eq(receiver.sync().pending_sync_count(), 1)

  receiver.sync().clear_pending_sync()

  assert_eq(receiver.sync().pending_sync_count(), 0)
  assert_eq(receiver.version(), before)
  let parent = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"p3-clear-pending\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"p3-clear-pending\",\"sequence\":0}]}",
  )
  let report = try! receiver.sync().apply(parent)
  assert_eq(report.applied_operations(), 1)
  assert_eq(receiver.text(), "A")
}

///|
test "P3 parent-after drains core pending without outer replay" {
  let receiver = try! TextState::new("p3-parent-after")
  let deferred = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"p3-parent-after\",\"sequence\":1},\"parents\":[{\"replica_id\":\"p3-parent-after\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"p3-parent-after\",\"sequence\":1}]}",
  )
  let first = try! receiver.sync().apply(deferred)
  assert_eq(first.applied_operations(), 0)
  assert_eq(first.pending_operations(), 1)

  let parent = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"p3-parent-after\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"p3-parent-after\",\"sequence\":0}]}",
  )
  let second = try! receiver.sync().apply(parent)

  assert_eq(second.applied_operations(), 2)
  assert_eq(second.pending_operations(), 0)
  assert_eq(receiver.sync().doc.inner.pending_count(), 0)
  assert_eq(receiver.text(), "AB")
}
