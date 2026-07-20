///|
test "encoded byte limit succeeds at boundary and fails one over" {
  let limits = try! @sync.Limits(max_encoded_bytes=4)
  inspect(try! container_encoded_size("1234", limits), content="4")
  try container_encoded_size("12345", limits) catch {
    @sync.Failure::LimitExceeded(
      kind=@sync.LimitKind::EncodedBytes,
      limit=4,
      actual=5
    ) => ()
    _ => fail("expected encoded-byte limit classification")
  } noraise {
    _ => fail("one-over encoded input must fail")
  }
}

///|
test "decoded and pending operation limits are exact and failure atomic" {
  let source = try! Document::new("source")
  let _ = try! source.create_node(parent=root_id)
  let first_version = source.version()
  let _ = try! source.create_node(parent=root_id)
  let one = try! source.sync().export_since(first_version)
  let one_limit = try! @sync.Limits(
    max_decoded_operations=1,
    max_pending_operations=1,
  )
  let pending_receiver = try! Document::new_with_sync_limits(
    "pending-receiver", one_limit,
  )
  let report = try! pending_receiver.sync().apply(one)
  inspect(report.pending_operations(), content="1")
  let two = try! source.sync().export_all()
  let limited = try! Document::new_with_sync_limits("limited", one_limit)
  let before = limited.version()
  try limited.sync().apply(two) catch {
    DocumentError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::DecodedOperations,
        limit=1,
        actual=2
      )
    ) => ()
    _ => fail("expected decoded-operation limit classification")
  } noraise {
    _ => fail("one-over decoded operation input must fail")
  }
  inspect(limited.version() == before, content="true")
  inspect(limited.sync().pending_sync_count(), content="0")
}

///|
test "parent limit succeeds at boundary and rejects one over atomically" {
  let source = try! Document::new("parent-source")
  let _ = try! source.create_node(parent=root_id)
  let version = source.version()
  let _ = try! source.create_node(parent=root_id)
  let message = try! source.sync().export_since(version)
  let exact = try! Document::new_with_sync_limits(
    "exact-parent",
    try! @sync.Limits(max_parents_per_operation=1),
  )
  let _ = try! exact.sync().apply(message)
  let over = try! Document::new_with_sync_limits(
    "over-parent",
    try! @sync.Limits(max_parents_per_operation=0),
  )
  try over.sync().apply(message) catch {
    DocumentError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::ParentsPerOperation,
        limit=0,
        actual=1
      )
    ) => ()
    _ => fail("expected parent limit classification")
  } noraise {
    _ => fail("one-over parent count must fail")
  }
  inspect(over.version() == Version::empty(), content="true")
  inspect(over.sync().pending_sync_count(), content="0")
}
