///|
test "container adapter maps complete and pending reports" {
  let source = try! @egw_container.Document::new("source")
  let first = try! source.create_node(parent=@egw_container.root_id)
  let baseline = source.version()
  let second = try! source.create_node(parent=@egw_container.root_id)
  let receiver = try! @egw_container.Document::new("receiver")
  let pending = try! receiver
    .sync()
    .apply(try! source.sync().export_since(baseline))
  match apply_disposition(pending) {
    @peer_sync.ApplyDisposition::PendingDependencies => ()
    _ => fail("container pending report must remain pending")
  }
  let complete = try! receiver.sync().apply(try! source.sync().export_all())
  match apply_disposition(complete) {
    @peer_sync.ApplyDisposition::CausallyComplete => ()
    _ => fail("container complete report must be causally complete")
  }
  inspect(receiver.is_alive(first), content="true")
  inspect(receiver.is_alive(second), content="true")
}

///|
test "container adapter maps shared and local errors" {
  match classify_error(@egw_container.DocumentError::EmptyReplicaId) {
    None => ()
    _ => fail("empty replica ID is local")
  }
  match classify_error(@egw_container.DocumentError::TargetNotFound) {
    None => ()
    _ => fail("target-not-found is local")
  }
  match classify_error(@egw_container.DocumentError::ParentNotFound) {
    None => ()
    _ => fail("parent-not-found is local")
  }
  match classify_error(@egw_container.DocumentError::CycleDetected) {
    None => ()
    _ => fail("cycle-detected is local")
  }
  match classify_error(@egw_container.DocumentError::Internal(detail="local")) {
    None => ()
    _ => fail("internal container error is local")
  }

  match
    classify_error(
      @egw_container.DocumentError::SyncFailed(
        @sync.Failure::MissingDependency(replica_id="peer", sequence=1),
      ),
    ) {
    Some(@peer_sync.FailureDisposition::Recoverable) => ()
    _ => fail("missing dependency must be recoverable")
  }
  match
    classify_error(
      @egw_container.DocumentError::SyncFailed(
        @sync.Failure::MalformedMessage(detail="bad"),
      ),
    ) {
    Some(@peer_sync.FailureDisposition::Terminal) => ()
    _ => fail("malformed message must be terminal")
  }
  match
    classify_error(
      @egw_container.DocumentError::SyncFailed(
        @sync.Failure::InvalidContent(detail="bad"),
      ),
    ) {
    Some(@peer_sync.FailureDisposition::Terminal) => ()
    _ => fail("invalid content must be terminal")
  }
  match
    classify_error(
      @egw_container.DocumentError::SyncFailed(
        @sync.Failure::ConflictingIdentity(replica_id="peer", sequence=1),
      ),
    ) {
    Some(@peer_sync.FailureDisposition::Terminal) => ()
    _ => fail("conflicting identity must be terminal")
  }
  match
    classify_error(
      @egw_container.DocumentError::SyncFailed(
        @sync.Failure::LimitExceeded(
          kind=@sync.LimitKind::DecodedOperations,
          limit=1,
          actual=2,
        ),
      ),
    ) {
    Some(@peer_sync.FailureDisposition::Terminal) => ()
    _ => fail("limit failure must be terminal")
  }
}
