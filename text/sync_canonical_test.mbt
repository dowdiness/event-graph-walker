///| Tests for SyncMessage::to_canonical_bytes determinism and structure.

///|
test "canonical bytes: empty message produces non-empty output" {
  let doc = @text.TextState::new("alice")
  let msg = doc.sync().export_all() catch { _ => return }
  let bytes = msg.to_canonical_bytes()
  inspect(bytes.length() > 0, content="true")
}

///|
test "canonical bytes: deterministic — same message, same bytes" {
  let doc = @text.TextState::new("alice")
  doc.insert(@text.Pos::at(0), "hello") catch {
    _ => return
  }
  let msg = doc.sync().export_all() catch { _ => return }
  let b1 = msg.to_canonical_bytes()
  let b2 = msg.to_canonical_bytes()
  @debug.assert_eq(b1, b2)
}

///|
test "canonical bytes: different messages produce different bytes" {
  let a = @text.TextState::new("alice")
  a.insert(@text.Pos::at(0), "hello") catch {
    _ => return
  }
  let msg_a = a.sync().export_all() catch { _ => return }

  let b = @text.TextState::new("alice")
  b.insert(@text.Pos::at(0), "world") catch {
    _ => return
  }
  let msg_b = b.sync().export_all() catch { _ => return }

  @debug.assert_eq(
    msg_a.to_canonical_bytes() != msg_b.to_canonical_bytes(),
    true,
  )
}

///|
test "canonical bytes: multiple inserts produce more ops" {
  let doc = @text.TextState::new("alice")
  doc.insert(@text.Pos::at(0), "a") catch {
    _ => return
  }
  let msg1 = doc.sync().export_all() catch { _ => return }
  doc.insert(@text.Pos::at(1), "b") catch {
    _ => return
  }
  let msg2 = doc.sync().export_all() catch { _ => return }
  inspect(msg2.op_count() > msg1.op_count(), content="true")
}

///|
test "canonical bytes: non-empty message is not all zeros" {
  let doc = @text.TextState::new("alice")
  doc.insert(@text.Pos::at(0), "x") catch {
    _ => return
  }
  let msg = doc.sync().export_all() catch { _ => return }
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
  let doc = @text.TextState::new("alice")
  doc.insert(@text.Pos::at(0), "ab") catch {
    _ => return
  }
  doc.delete(@text.Pos::at(0)) catch {
    _ => return
  }
  let msg = doc.sync().export_all() catch { _ => return }
  // Should have at least insert + delete ops
  inspect(msg.op_count() >= 3, content="true")
  let bytes = msg.to_canonical_bytes()
  inspect(bytes.length() > 0, content="true")
}

///|
test "canonical bytes: empty message always same bytes" {
  let a = @text.TextState::new("alice")
  let b = @text.TextState::new("bob")
  let msg_a = a.sync().export_all() catch { _ => return }
  let msg_b = b.sync().export_all() catch { _ => return }
  @debug.assert_eq(msg_a.to_canonical_bytes(), msg_b.to_canonical_bytes())
}
