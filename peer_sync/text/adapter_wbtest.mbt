///|
test "text adapter maps complete and pending reports" {
  let source = try! @egw_text.TextState::new("source")
  try! source.insert(@egw_text.Pos::at(0), "A")
  let baseline = source.version()
  try! source.insert(@egw_text.Pos::at(1), "B")
  let receiver = try! @egw_text.TextState::new("receiver")
  let pending = try! receiver
    .sync()
    .apply(try! source.sync().export_since(baseline))
  match apply_disposition(pending) {
    @peer_sync.ApplyDisposition::PendingDependencies => ()
    _ => fail("text pending report must remain pending")
  }
  let complete = try! receiver.sync().apply(try! source.sync().export_all())
  match apply_disposition(complete) {
    @peer_sync.ApplyDisposition::CausallyComplete => ()
    _ => fail("text complete report must be causally complete")
  }
}

///|
test "text adapter maps shared and local errors" {
  match classify_error(@egw_text.TextError::VersionNotFound) {
    Some(@peer_sync.FailureDisposition::Recoverable) => ()
    _ => fail("version not found must be recoverable")
  }
  match classify_error(@egw_text.TextError::EmptyReplicaId) {
    None => ()
    _ => fail("empty replica ID is local")
  }
  match classify_error(@egw_text.TextError::InvalidPosition(pos=1, len=0)) {
    None => ()
    _ => fail("invalid position is local")
  }
  match classify_error(@egw_text.TextError::InvalidRange(start=2, end=1)) {
    None => ()
    _ => fail("invalid range is local")
  }
  match classify_error(@egw_text.TextError::Internal(detail="local")) {
    None => ()
    _ => fail("internal text error is local")
  }

  match
    classify_error(
      @egw_text.TextError::SyncFailed(
        @sync.Failure::MissingDependency(replica_id="peer", sequence=1),
      ),
    ) {
    Some(@peer_sync.FailureDisposition::Recoverable) => ()
    _ => fail("missing dependency must be recoverable")
  }
  match
    classify_error(
      @egw_text.TextError::SyncFailed(
        @sync.Failure::MalformedMessage(detail="bad"),
      ),
    ) {
    Some(@peer_sync.FailureDisposition::Terminal) => ()
    _ => fail("malformed message must be terminal")
  }
  match
    classify_error(
      @egw_text.TextError::SyncFailed(
        @sync.Failure::InvalidContent(detail="bad"),
      ),
    ) {
    Some(@peer_sync.FailureDisposition::Terminal) => ()
    _ => fail("invalid content must be terminal")
  }
  match
    classify_error(
      @egw_text.TextError::SyncFailed(
        @sync.Failure::ConflictingIdentity(replica_id="peer", sequence=1),
      ),
    ) {
    Some(@peer_sync.FailureDisposition::Terminal) => ()
    _ => fail("conflicting identity must be terminal")
  }
  match
    classify_error(
      @egw_text.TextError::SyncFailed(
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
