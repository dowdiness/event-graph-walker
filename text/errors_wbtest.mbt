///|
/// Text mapping seam: lower typed conflicts become the existing shared failure.
test "TextError maps OpLog ConflictingIdentity to sync failure" {
  let err = TextError::from_oplog_error(
    @oplog.OpLogError::ConflictingIdentity(raw=@core.RawVersion("alice", 0)),
  )
  match err {
    TextError::SyncFailed(
      @sync.Failure::ConflictingIdentity(replica_id~, sequence~)
    ) => {
      assert_eq(replica_id, "alice")
      assert_eq(sequence, 0)
    }
    _ => fail("expected shared conflicting identity failure")
  }
}

///|
test "TextError maps projection recovery without reading document length" {
  let error = @document.DocumentError::ProjectionRecoveryRequired(
    frontier=@core.Frontier::from_array([]),
    error=@branch.BranchError::MissingOp(lv=7),
  )
  let mapped = TextError::from_document_error(error, () => {
    abort("projection recovery conversion must not read document length")
  })
  match mapped {
    TextError::ProjectionRecoveryRequired => assert_true(mapped.is_retryable())
    _ => fail("expected projection recovery error")
  }
}
