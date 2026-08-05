///|
test "SyncSession admission uses per-call limits atomically" {
  let source = try! TextState::new("source")
  try! source.insert(Pos::at(0), "A")
  let message = try! source.sync().export_all()
  let encoded_size = @utf8.encode(message.to_json_string()).length()
  let receiver = try! TextState::new("receiver")
  let exact = try! @sync.Limits::Limits(max_encoded_bytes=encoded_size)
  let admitted = try! receiver.sync().apply_with_limits(message, exact)
  inspect(admitted.applied_operations(), content="1")
  inspect(receiver.text(), content="A")

  let before_text = receiver.text()
  let before_version = receiver.version()
  let before_pending = receiver.sync().pending_sync_count()
  let over = try! @sync.Limits::Limits(max_encoded_bytes=encoded_size - 1)
  try receiver.sync().apply_with_limits(message, over) catch {
    TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=_,
        actual=_
      )
    ) => ()
    _ => fail("expected per-call encoded byte limit")
  } noraise {
    _ => fail("over-limit admission must reject")
  }
  inspect(receiver.text(), content=before_text)
  inspect(receiver.version() == before_version, content="true")
  inspect(
    receiver.sync().pending_sync_count() == before_pending,
    content="true",
  )
}

///|
test "text sync rejects conflicting duplicate identities in one message atomically" {
  let receiver = try! TextState::new("receiver")
  let before_version = receiver.version()
  let conflict = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[" +
    "{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}," +
    "{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[]}"
  try SyncMessage::from_json_string(conflict) catch {
    TextError::SyncFailed(
      @sync.Failure::ConflictingIdentity(replica_id="alice", sequence=0)
    ) => ()
    _ => fail("expected in-message ConflictingIdentity")
  } noraise {
    _ => fail("conflicting duplicate must fail during decoding")
  }
  inspect(receiver.text(), content="")
  inspect(receiver.version() == before_version, content="true")
  inspect(receiver.sync().pending_sync_count(), content="0")
}

///|
test "text sync retains authoritative pending payload after identity conflict" {
  let receiver = try! TextState::new("receiver")
  let future = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":1}]}",
  )
  let deferred = try! receiver.sync().apply(future)
  inspect(deferred.applied_operations(), content="0")
  inspect(receiver.sync().pending_sync_count(), content="1")
  let before_version = receiver.version()
  let conflict = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"C\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":1}]}",
  )
  try receiver.sync().apply(conflict) catch {
    TextError::SyncFailed(
      @sync.Failure::ConflictingIdentity(replica_id="alice", sequence=1)
    ) => ()
    _ => fail("expected pending ConflictingIdentity")
  } noraise {
    _ => fail("pending conflict must fail")
  }
  inspect(receiver.text(), content="")
  inspect(receiver.version() == before_version, content="true")
  inspect(receiver.sync().pending_sync_count(), content="1")

  // The identical authoritative retransmission is still eligible to drain.
  let authoritative = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":1}]}",
  )
  let admitted = try! receiver
    .sync()
    .apply_with_limits(authoritative, @sync.Limits::default())
  inspect(admitted.applied_operations(), content="2")
  inspect(admitted.duplicate_operations(), content="1")
  inspect(admitted.pending_operations(), content="0")
  inspect(receiver.text(), content="AB")
  inspect(receiver.sync().pending_sync_count(), content="0")

  let duplicate = try! receiver
    .sync()
    .apply_with_limits(authoritative, @sync.Limits::default())
  inspect(duplicate.applied_operations(), content="0")
  inspect(duplicate.duplicate_operations(), content="2")
  inspect(duplicate.pending_operations(), content="0")

  let pending_receiver = try! TextState::new("pending-receiver")
  let pending_limits = try! @sync.Limits::Limits(max_pending_operations=1)
  let pending_report = try! pending_receiver
    .sync()
    .apply_with_limits(future, pending_limits)
  inspect(pending_report.applied_operations(), content="0")
  inspect(pending_report.duplicate_operations(), content="0")
  inspect(pending_report.pending_operations(), content="1")

  let strict_receiver = try! TextState::new("strict-pending-receiver")
  let before_text = strict_receiver.text()
  let before_version = strict_receiver.version()
  let before_pending = strict_receiver.sync().pending_sync_count()
  let strict_limits = try! @sync.Limits::Limits(max_pending_operations=0)
  try strict_receiver.sync().apply_with_limits(future, strict_limits) catch {
    TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::PendingOperations,
        limit=0,
        actual=1
      )
    ) => ()
    _ => fail("expected pending-operation limit")
  } noraise {
    _ => fail("over-limit pending admission must reject")
  }
  inspect(strict_receiver.text(), content=before_text)
  inspect(strict_receiver.version() == before_version, content="true")
  inspect(
    strict_receiver.sync().pending_sync_count() == before_pending,
    content="true",
  )
}

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
test "resent decidable malformed pending operation does not poison later sync" {
  let receiver = try! TextState::new("receiver")
  let malformed_future = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":2},\"parents\":[],\"kind\":\"insert\",\"content\":\"C\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":2}]}",
  )
  let deferred = try! receiver.sync().apply(malformed_future)
  inspect(deferred.applied_operations(), content="0")
  inspect(receiver.sync().pending_sync_count(), content="1")
  let valid_predecessors = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":{\"replica_id\":\"alice\",\"sequence\":0},\"origin_right\":null},{\"id\":{\"replica_id\":\"alice\",\"sequence\":2},\"parents\":[],\"kind\":\"insert\",\"content\":\"C\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":2}]}",
  )
  let applied = try! receiver.sync().apply(valid_predecessors)
  inspect(applied.applied_operations(), content="2")
  inspect(receiver.text(), content="AB")
  inspect(receiver.sync().pending_sync_count(), content="0")
}

///|
test "decode accepts structurally valid JSON and apply enforces receiver limits" {
  let json = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[],\"heads\":[]}"
  let limits = try! @sync.Limits::Limits(max_encoded_bytes=json.length() - 1)
  let receiver = try! TextState::new("receiver")
  let message = try! receiver.sync().decode_json(json)
  try receiver.sync().apply_with_limits(message, limits) catch {
    TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=_,
        actual=_
      )
    ) => ()
    _ => fail("expected receiver encoded byte limit during apply")
  } noraise {
    _ => fail("apply must enforce receiver limits atomically")
  }
}

///|
test "receiver-specific decoder may raise the default encoded byte limit" {
  let envelope = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[],\"heads\":[]}"
  let json = envelope + " ".repeat(16 * 1024 * 1024)
  let message = try! SyncMessage::from_json_string(json)
  let limits = try! @sync.Limits::Limits(max_encoded_bytes=json.length() - 1)
  let receiver = try! TextState::new_with_sync_limits("receiver", limits)
  try receiver.sync().apply(message) catch {
    TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::EncodedBytes,
        limit=_,
        actual=_
      )
    ) => ()
    _ => fail("expected apply encoded byte limit")
  } noraise {
    _ => fail("apply must reject oversized decoded message")
  }
}

///|
test "receiver-specific decoder honors raised parent limits in validation" {
  let parents : Array[String] = []
  for sequence in 0..<257 {
    parents.push("{\"replica_id\":\"parent-\{sequence}\",\"sequence\":0}")
  }
  let json = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[" +
    parents.join(",") +
    "],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":0}]}"
  let message = try! SyncMessage::from_json_string(json)
  inspect(message.op_count(), content="1")
  let strict = try! TextState::new("strict")
  try strict.sync().apply_with_limits(message, @sync.Limits::default()) catch {
    TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::ParentsPerOperation,
        limit=256,
        actual=257
      )
    ) => ()
    _ => fail("expected receiver parent limit during apply")
  } noraise {
    _ => fail("apply must enforce parent policy")
  }
}

///|
test "duplicate-heavy decoded operation limit counts wire operations" {
  let operation = "{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}"
  let json = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[" +
    operation +
    "," +
    operation +
    "],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":0}]}"
  let message = try! SyncMessage::from_json_string(json)
  inspect(message.op_count(), content="1")
  let receiver = try! TextState::new("duplicate-limit")
  let limits = try! @sync.Limits::Limits(max_decoded_operations=1)
  try receiver.sync().apply_with_limits(message, limits) catch {
    TextError::SyncFailed(
      @sync.Failure::LimitExceeded(
        kind=@sync.LimitKind::DecodedOperations,
        limit=1,
        actual=2
      )
    ) => ()
    _ => fail("wire operation count must survive canonical deduplication")
  } noraise {
    _ => fail("duplicate-heavy payload must exceed the decoded limit")
  }
  inspect(receiver.text(), content="")
  inspect(receiver.version() == Version::empty(), content="true")
}
