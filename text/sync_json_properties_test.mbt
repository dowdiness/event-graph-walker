///| Property tests for JSON round-trips in text sync/version boundaries.

///|
fn prop_version_json_roundtrip(ops : RealOps) -> Bool {
  let doc = @text.TextState::new("alice")
  let versions : Array[Version] = []
  versions.push(doc.version())
  if !apply_edits(doc, ops.edits) {
    return false
  }

  // capture every intermediate version after each edit
  let replay = @text.TextState::new("alice")
  versions.push(replay.version())
  for edit in ops.edits {
    if !apply_edit(replay, edit) {
      return false
    }
    versions.push(replay.version())
  }

  for version in versions {
    let roundtrip = Version::from_json_string(version.to_json_string()) catch {
      _ => return false
    }
    if roundtrip != version {
      return false
    }
  }
  true
}

///|
test "property: Version JSON round-trip preserves frontier" {
  @qc.quick_check_fn(prop_version_json_roundtrip)
}

///|
fn prop_sync_message_json_roundtrip_metadata(ops : RealOps) -> Bool {
  let doc = @text.TextState::new("alice")
  if !apply_edits(doc, ops.edits) {
    return false
  }
  let message = doc.sync().export_all() catch { _ => return false }
  let roundtrip = SyncMessage::from_json_string(message.to_json_string()) catch {
    _ => return false
  }
  message.op_count() == roundtrip.op_count() &&
  message.is_empty() == roundtrip.is_empty()
}

///|
test "property: SyncMessage JSON round-trip keeps op_count and emptiness" {
  @qc.quick_check_fn(prop_sync_message_json_roundtrip_metadata)
}

///|
fn prop_sync_message_roundtrip_apply_equivalence(ops : RealOps) -> Bool {
  let origin = @text.TextState::new("alice")
  if !apply_edits(origin, ops.edits) {
    return false
  }
  let message = origin.sync().export_all() catch { _ => return false }
  let roundtrip = SyncMessage::from_json_string(message.to_json_string()) catch {
    _ => return false
  }

  let peer_direct = @text.TextState::new("bob")
  let peer_roundtrip = @text.TextState::new("bob")

  peer_direct.sync().apply(message) catch {
    _ => return false
  }
  peer_roundtrip.sync().apply(roundtrip) catch {
    _ => return false
  }

  peer_direct.text() == peer_roundtrip.text() &&
  peer_direct.text() == origin.text()
}

///|
test "property: SyncMessage JSON round-trip preserves application result" {
  @qc.quick_check_fn(prop_sync_message_roundtrip_apply_equivalence)
}

///|
fn prop_export_since_current_json_roundtrip_is_empty(ops : RealOps) -> Bool {
  let doc = @text.TextState::new("alice")
  if !apply_edits(doc, ops.edits) {
    return false
  }
  let version = doc.version()
  let message = doc.sync().export_since(version) catch { _ => return false }
  if !message.is_empty() {
    return false
  }
  let roundtrip = SyncMessage::from_json_string(message.to_json_string()) catch {
    _ => return false
  }
  roundtrip.is_empty() && roundtrip.op_count() == 0
}

///|
test "property: export_since(current) stays empty after JSON round-trip" {
  @qc.quick_check_fn(prop_export_since_current_json_roundtrip_is_empty)
}

///|
fn prop_invalid_version_json_fails(seed : Int) -> Bool {
  let invalid = if seed % 2 == 0 { "" } else { "{not_json" }
  let result : Result[Version, TextError] = Ok(
    Version::from_json_string(invalid),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(TextError::Internal(_)) => true
    _ => false
  }
}

///|
test "property: Version::from_json_string fails safely on malformed JSON" {
  @qc.quick_check_fn(prop_invalid_version_json_fails)
}

///|
fn prop_invalid_sync_message_json_fails(seed : Int) -> Bool {
  let invalid = if seed % 2 == 0 { "" } else { "{" }
  let result : Result[SyncMessage, TextError] = Ok(
    SyncMessage::from_json_string(invalid),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(TextError::Internal(_)) => true
    _ => false
  }
}

///|
test "property: SyncMessage::from_json_string fails safely on malformed JSON" {
  @qc.quick_check_fn(prop_invalid_sync_message_json_fails)
}

///|
fn prop_malformed_sync_content_rejected(seed : Int) -> Bool {
  // Build a legacy sync payload that includes a malformed insert op.
  // A lone surrogate should be rejected as malformed UTF-16.
  let malformed_char = Int::unsafe_to_char(0xD800).to_string()
  let bad_op = @core.Op::new_insert(
    seed,
    [],
    "malicious",
    0,
    malformed_char,
    None,
    None,
  )
  let op_json = bad_op.to_json().stringify()
  let malformed = "{\"ops\":[" + op_json + "],\"heads\":[] }"
  let message = SyncMessage::from_json_string(malformed) catch {
    _ => return false
  }
  let target = @text.TextState::new("bob")
  let result : Result[Unit, TextError] = Ok(target.sync().apply(message)) catch {
    e => Err(e)
  }
  match result {
    Err(TextError::SyncFailed(SyncFailure::MalformedContent(_))) => true
    Err(TextError::SyncFailed(SyncFailure::MalformedMessage(_))) => true
    _ => false
  }
}

///|
test "property: malformed sync payload content is reported as sync failure" {
  @qc.quick_check_fn(prop_malformed_sync_content_rejected)
}
