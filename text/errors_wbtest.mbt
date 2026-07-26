///|
/// Text mapping seam: lower typed conflicts become the existing shared failure.
test "TextError maps OpLog ConflictingIdentity to sync failure" {
  let err = TextError::from_oplog_error(
    @oplog.OpLogError::ConflictingIdentity(
      raw=@core.RawVersion::new("alice", 0),
    ),
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
