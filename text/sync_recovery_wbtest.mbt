///|
test "sync admission retries recovery before duplicate-only preparation" {
  let source = try! TextState::new("source")
  try! source.insert(Pos::at(0), "A")
  let message = try! source.sync().export_all()

  let receiver = try! TextState::new("receiver")
  let initial = try! receiver.sync().apply(message)
  inspect(initial.applied_operations(), content="1")

  let mut attempts = 0
  let session = SyncSession::{
    doc: receiver,
    prepare_for_mutation_override: Some(() => {
      attempts = attempts + 1
      if attempts == 1 {
        raise TextError::ProjectionRecoveryRequired
      }
    }),
  }
  let before_version = session.current_version()

  let first : SyncReport? = Some(session.apply(message)) catch {
    TextError::ProjectionRecoveryRequired => None
    _ => fail("expected projection recovery error")
  }
  inspect(first is None, content="true")
  inspect(attempts, content="1")
  inspect(session.pending_sync_count(), content="0")
  inspect(session.current_version() == before_version, content="true")

  let report = try! session.apply(message)
  inspect(attempts, content="2")
  inspect(report.applied_operations(), content="0")
  inspect(report.duplicate_operations(), content="1")
  inspect(report.pending_operations(), content="0")
  inspect(session.doc.len(), content="1")
}
