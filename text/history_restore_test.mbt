///|
/// Test-only implementation of the documented accepted-history restore recipe.
/// The caller supplies a fresh writer ID and keeps the original saved strings.
fn restore_history(
  history : String,
  version : String,
  writer : String,
  limits : @sync.Limits,
) -> @text.TextState raise {
  // Bound code units without encoding potentially malformed UTF-16.
  // apply_with_limits enforces the exact UTF-8 byte budget after decoding.
  guard history.length() <= limits.max_encoded_bytes() else {
    fail("history exceeds pre-decode code-unit budget")
  }
  let expected = @text.Version::from_json_string(version)
  let candidate = @text.TextState::new(writer)
  let message = candidate.sync().decode_json(history)
  let _ = candidate.sync().apply_with_limits(message, limits)
  guard candidate.sync().pending_sync_count() == 0 else {
    fail("incomplete history")
  }
  guard candidate.version() == expected else {
    fail("saved Version does not match history")
  }
  candidate
}

///|
fn strict_restore_limits() -> @sync.Limits {
  try! @sync.Limits(max_pending_operations=0)
}

///|
/// Capture is synchronous: no edits may interleave these two observations.
fn reopen_history(doc : @text.TextState, writer : String) -> @text.TextState {
  let history = try! doc.sync().export_all().to_json_string()
  let version = try! doc.version().to_json_string()
  try! restore_history(history, version, writer, strict_restore_limits())
}

///|
fn assert_same_history(a : @text.TextState, b : @text.TextState) -> Unit raise {
  assert_eq(a.text(), b.text())
  assert_eq(a.version(), b.version())
  assert_eq(a.sync().pending_sync_count(), b.sync().pending_sync_count())
  assert_eq(
    a.sync().export_all().to_canonical_bytes(),
    b.sync().export_all().to_canonical_bytes(),
  )
  assert_true(a.sync().export_since(b.version()).is_empty())
  assert_true(b.sync().export_since(a.version()).is_empty())
}

///|
test "accepted history reopens twice and continues delta synchronization" {
  let a = try! @text.TextState::new("a-before")
  let b = try! @text.TextState::new("b-before")
  try! a.insert(@text.Pos::at(0), "abc")
  let _ = try! b.sync().apply(try! a.sync().export_all())
  try! a.delete(@text.Pos::at(1))
  try! a.insert(@text.Pos::at(a.len()), "日本👩‍💻")
  let saved_version = a.version()
  let restored = reopen_history(a, "a-after")
  assert_eq(restored.text(), "ac日本👩‍💻")
  assert_same_history(a, restored)
  try! restored.insert(@text.Pos::at(restored.len()), "!")
  let continued = try! restored.sync().export_since(saved_version)
  assert_eq(continued.op_count(), 1)
  let delta = try! restored.sync().export_since(b.version())
  assert_true(delta.op_count() > continued.op_count())
  assert_true(delta.op_count() < (try! restored.sync().export_all()).op_count())
  let delivered = try! b.sync().decode_json(delta.to_json_string())
  let report = try! b.sync().apply(delivered)
  assert_eq(report.applied_operations(), delta.op_count())
  assert_eq(report.pending_operations(), 0)
  assert_eq(b.text(), "ac日本👩‍💻!")
  assert_same_history(restored, b)
  let before = try! b.sync().export_all().to_canonical_bytes()
  let duplicate = try! b.sync().apply(delivered)
  assert_eq(duplicate.applied_operations(), 0)
  assert_eq(duplicate.duplicate_operations(), delta.op_count())
  assert_eq(duplicate.pending_operations(), 0)
  assert_eq(try! b.sync().export_all().to_canonical_bytes(), before)
  let reopened_b = reopen_history(b, "b-after")
  assert_same_history(b, reopened_b)
  try! reopened_b.insert(@text.Pos::at(0), ">")
  let back = try! reopened_b.sync().export_since(restored.version())
  assert_eq(back.op_count(), 1)
  let _ = try! restored.sync().apply(back)
  assert_eq(restored.text(), ">ac日本👩‍💻!")
  assert_same_history(restored, reopened_b)
}

///|
/// Unlike a sequential reopen, keeping the old writer alive detects accidental
/// reuse of its identity/counter when both writers create their next operation.
test "fresh restored writer coexists with old writer and concurrent peer" {
  let old = try! @text.TextState::new("old")
  try! old.insert(@text.Pos::at(0), "x")
  let restored = reopen_history(old, "new")
  let peer = reopen_history(old, "peer")
  let base = old.version()
  try! old.insert(@text.Pos::at(1), "A")
  try! restored.insert(@text.Pos::at(1), "B")
  try! peer.insert(@text.Pos::at(1), "C")
  let da = try! old.sync().export_since(base)
  let db = try! restored.sync().export_since(base)
  let dc = try! peer.sync().export_since(base)
  for message in [dc, db, db] {
    let _ = try! old.sync().apply(message)
  }
  for message in [da, dc, da] {
    let _ = try! restored.sync().apply(message)
  }
  for message in [db, da, db] {
    let _ = try! peer.sync().apply(message)
  }
  assert_eq(old.len(), 4)
  assert_eq(try! old.sync().export_all().op_count(), 4)
  assert_same_history(old, restored)
  assert_same_history(old, peer)
}

///|
test "restore preserves deleted origins and conflicting identity evidence" {
  let live = try! @text.TextState::new("author")
  try! live.insert(@text.Pos::at(0), "abc")
  let delayed = reopen_history(live, "delayed")
  let base = live.version()
  // The delayed insertion references b, which will be deleted before restore.
  try! delayed.insert(@text.Pos::at(2), "X")
  let late = try! delayed.sync().export_since(base)
  try! live.delete(@text.Pos::at(1))
  let restored = reopen_history(live, "restored")
  assert_eq(restored.text(), "ac")
  assert_eq(try! live.sync().apply(late), try! restored.sync().apply(late))
  assert_eq(restored.text(), "aXc")
  assert_same_history(live, restored)
  assert_eq(try! live.sync().apply(late), try! restored.sync().apply(late))
  // A fresh state using the historical author ID manufactures a conflicting
  // identity through public APIs, without depending on private wire layout.
  let imposter = try! @text.TextState::new("author")
  try! imposter.insert(@text.Pos::at(0), "Z")
  let conflict = try! imposter.sync().export_all()
  for receiver in [live, restored] {
    let before = try! receiver.sync().export_all().to_canonical_bytes()
    try receiver.sync().apply(conflict) catch {
      @text.TextError::SyncFailed(
        @sync.Failure::ConflictingIdentity(replica_id="author", sequence=0)
      ) => ()
      _ => fail("expected preserved identity conflict evidence")
    } noraise {
      _ => fail("conflicting identity must not be treated as a duplicate")
    }
    assert_eq(try! receiver.sync().export_all().to_canonical_bytes(), before)
  }
  assert_same_history(live, restored)
}

///|
test "restore rejects incomplete history and mismatched saved Version" {
  let source = try! @text.TextState::new("source")
  try! source.insert(@text.Pos::at(0), "a")
  let prefix = try! source.sync().export_all().to_json_string()
  let prefix_version = source.version()
  try! source.insert(@text.Pos::at(1), "b")
  let child = try! source.sync().export_since(prefix_version).to_json_string()
  let expected = try! source.version().to_json_string()
  let unsupported = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[],\"heads\":[]}"
  // The prefix is causally complete, so pending=0 alone cannot detect loss.
  for input in [prefix, child] {
    try
      restore_history(input, expected, "candidate", strict_restore_limits())
    catch {
      _ => ()
    } noraise {
      _ => fail("invalid/incomplete archive must not be published")
    }
  }
  // An empty expected Version ensures a decoder that substitutes an empty
  // document cannot hide behind the later Version-mismatch check.
  let empty_version = try! @text.Version::empty().to_json_string()
  for input in ["{", unsupported] {
    try
      restore_history(
        input,
        empty_version,
        "candidate",
        strict_restore_limits(),
      )
    catch {
      @text.TextError::SyncFailed(@sync.Failure::MalformedMessage(detail=_)) =>
        ()
      _ => fail("expected malformed/unsupported history error")
    } noraise {
      _ => fail("invalid JSON/schema must not restore as empty history")
    }
  }
  let complete = try! source.sync().export_all().to_json_string()
  try
    restore_history(complete, "{", "candidate", strict_restore_limits())
  catch {
    _ => ()
  } noraise {
    _ => fail("invalid saved Version must not be accepted")
  }
  assert_eq(source.text(), "ab")
  assert_eq(try! source.version().to_json_string(), expected)
}

///|
test "restore rejects unpaired UTF-16 surrogates without aborting" {
  let source = try! @text.TextState::new("source")
  let history = try! source.sync().export_all().to_json_string()
  let version = try! source.version().to_json_string()
  for bytes in [b"\x00\xD8", b"\x00\xDC"] {
    let malformed = history + bytes.to_unchecked_string()
    try
      restore_history(malformed, version, "candidate", strict_restore_limits())
    catch {
      @text.TextError::SyncFailed(@sync.Failure::MalformedMessage(detail=_)) =>
        ()
      _ => fail("expected malformed UTF-16 error")
    } noraise {
      _ => fail("unpaired surrogate must not be accepted")
    }
  }
}

///|
test "restore preserves sparse identity knowledge rather than sequence maxima" {
  let high = try! @text.SyncMessage::from_json_string(
    "{\"schema\":2,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"sparse\",\"sequence\":2},\"parents\":[],\"kind\":\"insert\",\"content\":\"C\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"sparse\",\"sequence\":2}]}",
  )
  let low = try! @text.SyncMessage::from_json_string(
    "{\"schema\":2,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"sparse\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"sparse\",\"sequence\":0}]}",
  )
  let peer = try! @text.TextState::new("peer")
  let _ = try! peer.sync().apply(high)
  let restored_peer = reopen_history(peer, "restored-peer")
  let source = try! @text.TextState::new("source")
  let _ = try! source.sync().apply(low)
  let _ = try! source.sync().apply(high)
  let restored_source = reopen_history(source, "restored-source")
  let delta = try! restored_source.sync().export_since(restored_peer.version())
  assert_eq(delta.op_count(), 1)
  let report = try! restored_peer.sync().apply(delta)
  assert_eq(report.applied_operations(), 1)
  assert_eq(report.duplicate_operations(), 0)
  assert_eq(report.pending_operations(), 0)
  assert_same_history(source, restored_peer)
}

///|
test "accepted-only restore recovers discarded pending through sender retransmission" {
  let source = try! @text.TextState::new("source")
  try! source.insert(@text.Pos::at(0), "a")
  let parent = try! source.sync().export_all()
  let base = source.version()
  try! source.insert(@text.Pos::at(1), "b")
  let child = try! source.sync().export_since(base)
  let live = try! @text.TextState::new("live")
  // Include independently accepted work: a pending queue must not prevent its save.
  try! live.insert(@text.Pos::at(0), "Z")
  let report = try! live.sync().apply(child)
  assert_eq(report.applied_operations(), 0)
  assert_eq(report.pending_operations(), 1)
  let restored = reopen_history(live, "restored")
  assert_eq(restored.text(), "Z")
  assert_eq(restored.version(), live.version())
  assert_eq(restored.sync().pending_sync_count(), 0)
  // Restoring with strict limits must not disable pending for later networking.
  assert_eq((try! restored.sync().apply(child)).pending_operations(), 1)
  assert_eq(try! live.sync().apply(parent), try! restored.sync().apply(parent))
  assert_same_history(live, restored)
  // A second crash drops pending without redelivery before the parent arrives.
  let lost = try! @text.TextState::new("lost")
  let _ = try! lost.sync().apply(child)
  let recovered = reopen_history(lost, "recovered")
  let retry = try! source.sync().export_since(recovered.version())
  assert_eq(retry.op_count(), 2)
  let report = try! recovered.sync().apply(retry)
  assert_eq(report.applied_operations(), 2)
  assert_eq(report.pending_operations(), 0)
  assert_eq(recovered.text(), "ab")
  assert_same_history(source, recovered)
}

///|
test "restore accepts exact byte and operation budgets but rejects one less" {
  let source = try! @text.TextState::new("source")
  try! source.insert(@text.Pos::at(0), "日本👩‍💻")
  let message = try! source.sync().export_all()
  let history = message.to_json_string()
  let version = try! source.version().to_json_string()
  let size = @utf8.encode(history).length()
  let count = message.op_count()
  let exact = try! @sync.Limits(
    max_encoded_bytes=size,
    max_decoded_operations=count,
    max_pending_operations=0,
  )
  let restored = try! restore_history(history, version, "restored", exact)
  assert_same_history(source, restored)
  for
    limits in [
      try! @sync.Limits(max_encoded_bytes=size - 1, max_pending_operations=0),
      try! @sync.Limits(
        max_decoded_operations=count - 1,
        max_pending_operations=0,
      ),
    ] {
    try restore_history(history, version, "candidate", limits) catch {
      _ => ()
    } noraise {
      _ => fail("over-budget restore must fail")
    }
  }
}

///|
/// Same immutable suffix operations, not new edits under different writer IDs:
/// new writer IDs can legitimately change concurrent insertion ordering.
test "property: restore at a generated cut preserves future admission and deltas" {
  @qc.quick_check_fn(fn(input : (RealOps, UInt)) -> Bool {
    let (ops, cut_seed) = input
    let source = try! @text.TextState::new("source")
    // Independent control world: it never passes through serialization/replay.
    let live = try! @text.TextState::new("source")
    let cut = (cut_seed % (ops.edits.length() + 1).reinterpret_as_uint()).reinterpret_as_int()
    for edit in ops.edits[:cut] {
      let _ = apply_edit(source, edit)
      let _ = apply_edit(live, edit)
    }
    let restored = reopen_history(live, "restored")
    let checkpoint = live.version()
    let suffix : Array[@text.SyncMessage] = []
    for edit in ops.edits[cut:] {
      let before = source.version()
      let _ = apply_edit(source, edit)
      suffix.push(try! source.sync().export_since(before))
    }
    // Reverse delivery forces dependencies to wait; duplicate every delivery.
    for i = suffix.length(); i > 0; i = i - 1 {
      let message = try! @text.SyncMessage::from_json_string(
        suffix[i - 1].to_json_string(),
      )
      for _ in 0..<2 {
        if (try! live.sync().apply(message)) !=
          (try! restored.sync().apply(message)) {
          return false
        }
        if live.text() != restored.text() ||
          live.version() != restored.version() ||
          live.sync().pending_sync_count() !=
          restored.sync().pending_sync_count() ||
          (try! live.sync().export_all()).to_canonical_bytes() !=
          (try! restored.sync().export_all()).to_canonical_bytes() {
          return false
        }
      }
    }
    live.text() == source.text() &&
    restored.version() == source.version() &&
    restored.sync().pending_sync_count() == 0 &&
    (try! restored.sync().export_all()).to_canonical_bytes() ==
    (try! source.sync().export_all()).to_canonical_bytes() &&
    (try! restored.sync().export_since(checkpoint)).to_canonical_bytes() ==
    (try! source.sync().export_since(checkpoint)).to_canonical_bytes() &&
    (try! restored.sync().export_since(source.version())).is_empty()
  })
}
