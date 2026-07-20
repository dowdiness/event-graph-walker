///| Tests for SyncMessage::to_canonical_bytes determinism and structure.

///|
test "canonical bytes: empty message produces non-empty output" {
  let doc = try! @text.TextState::new("alice")
  let msg = try! doc.sync().export_all()
  let bytes = msg.to_canonical_bytes()
  @debug.assert_eq(bytes, b"event-graph-walker:text-sync:v1\x00\x00")
}

///|
test "canonical bytes: deterministic — same message, same bytes" {
  let doc = try! @text.TextState::new("alice")
  try! doc.insert(@text.Pos::at(0), "hello")
  let msg = try! doc.sync().export_all()
  let b1 = msg.to_canonical_bytes()
  let b2 = msg.to_canonical_bytes()
  @debug.assert_eq(b1, b2)
}

///|
test "canonical bytes: different messages produce different bytes" {
  let a = try! @text.TextState::new("alice")
  try! a.insert(@text.Pos::at(0), "hello")
  let msg_a = try! a.sync().export_all()

  let b = try! @text.TextState::new("alice")
  try! b.insert(@text.Pos::at(0), "world")
  let msg_b = try! b.sync().export_all()

  @debug.assert_eq(
    msg_a.to_canonical_bytes() != msg_b.to_canonical_bytes(),
    true,
  )
}

///|
test "canonical bytes: multiple inserts produce more ops" {
  let doc = try! @text.TextState::new("alice")
  try! doc.insert(@text.Pos::at(0), "a")
  let msg1 = try! doc.sync().export_all()
  try! doc.insert(@text.Pos::at(1), "b")
  let msg2 = try! doc.sync().export_all()
  inspect(msg2.op_count() > msg1.op_count(), content="true")
}

///|
test "canonical bytes: non-empty message is not all zeros" {
  let doc = try! @text.TextState::new("alice")
  try! doc.insert(@text.Pos::at(0), "x")
  let msg = try! doc.sync().export_all()
  let bytes = msg.to_canonical_bytes()
  let mut all_zero = true
  for b in bytes {
    if b.to_int() != 0 {
      all_zero = false
      break
    }
  }
  inspect(all_zero, content="false")
}

///|
test "canonical bytes: message with delete produces valid output" {
  let doc = try! @text.TextState::new("alice")
  try! doc.insert(@text.Pos::at(0), "ab")
  try! doc.delete(@text.Pos::at(0))
  let msg = try! doc.sync().export_all()
  // Should have at least insert + delete ops
  inspect(msg.op_count() >= 3, content="true")
  let bytes = msg.to_canonical_bytes()
  inspect(bytes.length() > 0, content="true")
}

///|
test "canonical bytes: empty message always same bytes" {
  let a = try! @text.TextState::new("alice")
  let b = try! @text.TextState::new("bob")
  let msg_a = try! a.sync().export_all()
  let msg_b = try! b.sync().export_all()
  @debug.assert_eq(msg_a.to_canonical_bytes(), msg_b.to_canonical_bytes())
}
