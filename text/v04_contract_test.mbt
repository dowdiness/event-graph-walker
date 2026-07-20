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

///|
test "sequence fork is rejected without changing receiver state" {
  let receiver = try! TextState::new("receiver")
  let before_version = receiver.version()
  let message = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":{\"replica_id\":\"alice\",\"sequence\":0},\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":1}]}",
  )
  try receiver.sync().apply(message) catch {
    TextError::SyncFailed(@sync.Failure::MalformedMessage(detail=_)) => ()
    _ => fail("expected malformed sequence fork")
  } noraise {
    _ => fail("sequence fork must be rejected")
  }
  inspect(receiver.text(), content="")
  inspect(receiver.version() == before_version, content="true")
  inspect(receiver.sync().pending_sync_count(), content="0")
}

///|
test "replica predecessor may be an indirect causal ancestor" {
  let receiver = try! TextState::new("receiver")
  let message = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null},{\"id\":{\"replica_id\":\"bob\",\"sequence\":0},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":{\"replica_id\":\"alice\",\"sequence\":0},\"origin_right\":null},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"bob\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"C\",\"origin_left\":{\"replica_id\":\"bob\",\"sequence\":0},\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":1}]}",
  )
  let report = try! receiver.sync().apply(message)
  inspect(report.applied_operations(), content="3")
  inspect(receiver.text(), content="ABC")
  let current = receiver.version()
  let view = try! receiver.checkout(current)
  inspect(view.text(), content="ABC")
  inspect(view.version() == current, content="true")
}

///|
test "receiver encoded-byte limit succeeds at boundary and rejects one under" {
  let json = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":0}]}"
  let message = try! SyncMessage::from_json_string(json)
  let exact_limits = try! @sync.Limits::Limits(max_encoded_bytes=json.length())
  let exact = try! TextState::new_with_sync_limits("exact", exact_limits)
  let report = try! exact.sync().apply(message)
  inspect(report.applied_operations(), content="1")
  inspect(exact.text(), content="A")
  let over_limits = try! @sync.Limits::Limits(
    max_encoded_bytes=json.length() - 1,
  )
  let over = try! TextState::new_with_sync_limits("over", over_limits)
  try over.sync().apply(message) catch {
    TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=_,
        actual=_
      )
    ) => ()
    _ => fail("expected encoded byte limit")
  } noraise {
    _ => fail("encoded byte limit must reject ingress")
  }
  inspect(over.text(), content="")
  inspect(over.version() == Version::empty(), content="true")
  inspect(over.sync().pending_sync_count(), content="0")
}

///|
test "receiver encoded-byte limit also covers direct exported messages" {
  let source = try! TextState::new("source")
  try! source.insert(Pos::at(0), "A")
  let message = try! source.sync().export_all()
  let encoded_size = message.to_json_string().length()
  let limits = try! @sync.Limits::Limits(max_encoded_bytes=encoded_size - 1)
  let receiver = try! TextState::new_with_sync_limits("receiver", limits)
  try receiver.sync().apply(message) catch {
    TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=_,
        actual=_
      )
    ) => ()
    _ => fail("expected encoded byte limit")
  } noraise {
    _ => fail("encoded byte limit must reject exported ingress")
  }
  inspect(receiver.text(), content="")
  inspect(receiver.version() == Version::empty(), content="true")
}

///|
test "non-insert origin is rejected before any receiver mutation" {
  let receiver = try! TextState::new("receiver")
  try! receiver.insert(Pos::at(0), "X")
  try! receiver.delete(Pos::at(0))
  let before_text = receiver.text()
  let before_version = receiver.version()
  let message = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"remote\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null},{\"id\":{\"replica_id\":\"remote\",\"sequence\":1},\"parents\":[{\"replica_id\":\"remote\",\"sequence\":0},{\"replica_id\":\"receiver\",\"sequence\":1}],\"kind\":\"delete\",\"content\":null,\"origin_left\":{\"replica_id\":\"receiver\",\"sequence\":1},\"origin_right\":null}],\"heads\":[{\"replica_id\":\"remote\",\"sequence\":1}]}",
  )
  try receiver.sync().apply(message) catch {
    TextError::SyncFailed(@sync.Failure::MalformedMessage(detail=_)) => ()
    _ => fail("expected malformed non-insert origin")
  } noraise {
    _ => fail("non-insert origin must be rejected")
  }
  inspect(receiver.text(), content=before_text)
  inspect(receiver.version() == before_version, content="true")
  inspect(receiver.sync().pending_sync_count(), content="0")
}

///|
test "decidable malformed pending operation does not poison later sync" {
  let receiver = try! TextState::new("receiver")
  let malformed_future = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":2},\"parents\":[],\"kind\":\"insert\",\"content\":\"C\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":2}]}",
  )
  let deferred = try! receiver.sync().apply(malformed_future)
  inspect(deferred.applied_operations(), content="0")
  inspect(receiver.sync().pending_sync_count(), content="1")
  let valid_predecessors = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":{\"replica_id\":\"alice\",\"sequence\":0},\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":1}]}",
  )
  let applied = try! receiver.sync().apply(valid_predecessors)
  inspect(applied.applied_operations(), content="2")
  inspect(receiver.text(), content="AB")
  inspect(receiver.sync().pending_sync_count(), content="0")
}

///|
test "sync session decodes JSON with receiver-specific limits" {
  let json = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[],\"heads\":[]}"
  let limits = try! @sync.Limits::Limits(
    max_encoded_bytes=json.length() - 1,
  )
  let receiver = try! TextState::new_with_sync_limits("receiver", limits)
  try receiver.sync().decode_json(json) catch {
    TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=_,
        actual=_
      )
    ) => ()
    _ => fail("expected receiver encoded byte limit")
  } noraise {
    _ => fail("receiver-specific decoder must reject oversized JSON")
  }
}

///|
test "receiver-specific decoder may raise the default encoded byte limit" {
  let envelope = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[],\"heads\":[]}"
  let json = envelope + " ".repeat(16 * 1024 * 1024)
  try SyncMessage::from_json_string(json) catch {
    TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=_,
        actual=_
      )
    ) => ()
    _ => fail("expected default encoded byte limit")
  } noraise {
    _ => fail("default decoder must reject oversized JSON")
  }
  let limits = try! @sync.Limits::Limits(max_encoded_bytes=json.length())
  let receiver = try! TextState::new_with_sync_limits("receiver", limits)
  let message = try! receiver.sync().decode_json(json)
  inspect(message.is_empty(), content="true")
}
