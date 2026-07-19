///|
test "empty local insert is a complete no-op" {
  let document = try! TextState::new("empty-insert")
  let manager = @undo.UndoManager::new("empty-insert")
  let before_version = document.version()
  let before_message = try! document.sync().export_all()
  try! document.insert(Pos::at(0), "")
  try! document.insert_and_record(Pos::at(0), "", manager, timestamp_ms=0)
  inspect(document.text(), content="")
  inspect(document.len(), content="0")
  inspect(document.version() == before_version, content="true")
  inspect(manager.can_undo(), content="false")
  inspect((try! document.sync().export_all()).op_count(), content="0")
  inspect(
    before_message.to_canonical_bytes() ==
    (try! document.sync().export_all()).to_canonical_bytes(),
    content="true",
  )
}

///|
test "empty replica id is rejected" {
  try TextState::new("") catch {
    TextError::EmptyReplicaId => ()
    _ => fail("expected EmptyReplicaId")
  } noraise {
    _ => fail("empty replica id must fail")
  }
}

///|
test "empty remote insert record is rejected" {
  try
    SyncMessage::from_json_string(
      "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":0}]}",
    )
  catch {
    TextError::SyncFailed(@sync.Failure::InvalidContent(detail=_)) => ()
    _ => fail("expected InvalidContent")
  } noraise {
    _ => fail("empty remote insert must fail")
  }
}

///|
test "peer-portable version vectors ignore receiver-local LV numbering" {
  let alice = try! TextState::new("alice")
  let bob = try! TextState::new("bob")
  try! alice.insert(Pos::at(0), "A")
  try! bob.insert(Pos::at(0), "B")
  let alice_initial = try! alice.sync().export_all()
  let bob_initial = try! bob.sync().export_all()
  let _ = try! alice.sync().apply(bob_initial)
  let _ = try! bob.sync().apply(alice_initial)
  let bob_version = bob.version()
  try! alice.insert(Pos::at(alice.len()), "C")
  let delta = try! alice.sync().export_since(bob_version)
  inspect(delta.op_count(), content="1")
  let _ = try! bob.sync().apply(delta)
  inspect(alice.text() == bob.text(), content="true")
  inspect(alice.version() == bob.version(), content="true")
}

///|
test "checkout rejects an unavailable version without changing live state" {
  let document = try! TextState::new("checkout")
  try! document.insert(Pos::at(0), "live")
  let before_text = document.text()
  let before_version = document.version()
  let unknown = try! Version::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-version\",\"entries\":[{\"replica_id\":\"ghost\",\"sequence\":0}]}",
  )
  try document.checkout(unknown) catch {
    TextError::VersionNotFound => ()
    _ => fail("expected VersionNotFound")
  } noraise {
    _ => fail("unknown checkout version must fail")
  }
  inspect(document.text(), content=before_text)
  inspect(document.version() == before_version, content="true")
}
