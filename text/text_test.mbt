///|
/// Tests for user-friendly text API
test "TextDoc::new creates empty document" {
  let doc = TextDoc::new("alice")
  inspect(doc.text(), content="")
  inspect(doc.len(), content="0")
  inspect(doc.is_empty(), content="true")
}

///|
test "TextDoc::insert adds text" {
  let doc = TextDoc::new("alice")
  let _ = doc.insert(Pos::at(0), "Hello")
  inspect(doc.text(), content="Hello")
  inspect(doc.len(), content="5")
}

///|
test "TextDoc::insert at position" {
  let doc = TextDoc::new("alice")
  let _ = doc.insert(Pos::at(0), "W")
  let _ = doc.insert(Pos::at(1), "o")
  let _ = doc.insert(Pos::at(2), "r")
  let _ = doc.insert(Pos::at(3), "l")
  let _ = doc.insert(Pos::at(4), "d")
  inspect(doc.text(), content="World")
}

///|
test "TextDoc::delete removes character" {
  let doc = TextDoc::new("alice")
  let _ = doc.insert(Pos::at(0), "Hello")
  let _ = doc.delete(Pos::at(4))
  inspect(doc.text(), content="Hell")
}

///|
test "TextDoc::insert returns Change" {
  let doc = TextDoc::new("alice")
  let change = doc.insert(Pos::at(0), "H")
  inspect(change.is_insert(), content="true")
  inspect(change.is_delete(), content="false")
  inspect(change.get_text(), content="Some(\"H\")")
}

///|
test "TextDoc::delete returns Change" {
  let doc = TextDoc::new("alice")
  let _ = doc.insert(Pos::at(0), "Hi")
  let change = doc.delete(Pos::at(0))
  inspect(change.is_insert(), content="false")
  inspect(change.is_delete(), content="true")
}

///|
test "TextDoc::version changes after edit" {
  let doc = TextDoc::new("alice")
  let v1 = doc.version()
  let _ = doc.insert(Pos::at(0), "Hello")
  let v2 = doc.version()
  inspect(v1 == v2, content="false")
}

///|
test "Pos::at clamps negative values" {
  let pos = Pos::at(-5)
  inspect(pos.value(), content="0")
}

///|
test "Range::from_ints creates range" {
  let range = Range::from_ints(0, 5)
  inspect(range.start.value(), content="0")
  inspect(range.end.value(), content="5")
}

///|
test "TextError::message provides user message" {
  let err : TextError = TextError::InvalidPosition(pos=10, len=5)
  inspect(
    err.message(),
    content="Invalid position: 10 is out of bounds for text of length 5",
  )
}

///|
test "TextError::help provides guidance" {
  let err : TextError = TextError::InvalidPosition(pos=10, len=5)
  inspect(
    err.help(),
    content="Use a position between 0 and 5 (inclusive for insert, exclusive for delete)",
  )
}

///|
test "TextError::is_retryable for sync errors" {
  let retryable : TextError = TextError::SyncFailed(
    SyncFailure::MissingDependency(hint="test"),
  )
  let not_retryable : TextError = TextError::SyncFailed(
    SyncFailure::MalformedMessage(detail="test"),
  )
  inspect(retryable.is_retryable(), content="true")
  inspect(not_retryable.is_retryable(), content="false")
}

///|
test "SyncSession::export_all and apply" {
  let doc1 = TextDoc::new("alice")
  let doc2 = TextDoc::new("bob")
  let _ = doc1.insert(Pos::at(0), "H")
  let _ = doc1.insert(Pos::at(1), "i")
  let msg = doc1.sync().export_all()
  inspect(msg.is_empty(), content="false")
  inspect(msg.op_count(), content="2")
  doc2.sync().apply(msg)
  inspect(doc2.text(), content="Hi")
}

///|
test "SyncSession::export_since sends delta" {
  let doc1 = TextDoc::new("alice")
  let doc2 = TextDoc::new("bob")
  let _ = doc1.insert(Pos::at(0), "H")
  let _ = doc1.insert(Pos::at(1), "i")
  let msg1 = doc1.sync().export_all()
  doc2.sync().apply(msg1)
  let v2 = doc2.version()
  let _ = doc1.insert(Pos::at(2), "!")
  let msg2 = doc1.sync().export_since(v2)
  inspect(msg2.op_count(), content="1")
  doc2.sync().apply(msg2)
  inspect(doc2.text(), content="Hi!")
}

///|
test "TextDoc::checkout creates historical view" {
  let doc = TextDoc::new("alice")
  let _ = doc.insert(Pos::at(0), "Hello")
  let v1 = doc.version()
  let _ = doc.insert(Pos::at(5), " World")
  let view = doc.checkout(v1)
  inspect(view.text(), content="Hello")
  inspect(doc.text(), content="Hello World")
}

///|
test "TextDoc::apply_remote applies remote operation" {
  let doc1 = TextDoc::new("alice")
  let doc2 = TextDoc::new("bob")
  let _ = doc1.insert(Pos::at(0), "Hi")
  let msg = doc1.sync().export_all()
  for op in msg.get_ops() {
    doc2.apply_remote(op)
  }
  inspect(doc2.text(), content="Hi")
}

///|
test "TextDoc::from_document wraps existing document" {
  let doc = @document.Document::new("alice")
  let text_doc = TextDoc::from_document(doc)
  inspect(text_doc.text(), content="")
  inspect(text_doc.is_empty(), content="true")
}

///|
test "SyncFailure::Timeout is retryable" {
  let err : TextError = TextError::SyncFailed(
    SyncFailure::Timeout(detail="operation timed out after 30s"),
  )
  inspect(err.is_retryable(), content="true")
  inspect(
    err.message(),
    content="Sync timed out: operation timed out after 30s",
  )
}

///|
test "SyncFailure::Cancelled is not retryable" {
  let err : TextError = TextError::SyncFailed(
    SyncFailure::Cancelled(detail="user cancelled"),
  )
  inspect(err.is_retryable(), content="false")
  inspect(err.message(), content="Sync cancelled: user cancelled")
}

///|
test "Version::empty creates empty version" {
  let v = Version::empty()
  let f = v.to_frontier()
  inspect(f, content="Frontier([])")
}

///|
test "TextDoc insert at invalid position raises error" {
  let doc = TextDoc::new("alice")
  let result : Result[Change, TextError] = Ok(doc.insert(Pos::at(10), "Hello")) catch {
    e => Err(e)
  }
  match result {
    Err(InvalidPosition(pos~, len~)) => {
      inspect(pos, content="10")
      inspect(len, content="0")
    }
    _ => fail("Expected InvalidPosition error")
  }
}

///|
test "TextDoc delete at invalid position raises error" {
  let doc = TextDoc::new("alice")
  let _ = doc.insert(Pos::at(0), "Hi")
  let result : Result[Change, TextError] = Ok(doc.delete(Pos::at(5))) catch {
    e => Err(e)
  }
  match result {
    Err(InvalidPosition(pos~, len~)) => {
      inspect(pos, content="5")
      inspect(len, content="2")
    }
    _ => fail("Expected InvalidPosition error")
  }
}

///|
test "TextView::to_rle returns RLE view" {
  let doc = TextDoc::new("alice")
  let _ = doc.insert(Pos::at(0), "Hello")
  let view = doc.checkout(doc.version())
  let rle = view.to_rle()
  inspect(rle.count(), content="1")
  inspect(rle.len(), content="5")
  inspect(rle.to_string(), content="Hello")
}

///|
test "TextView::runs iterates over runs" {
  let doc = TextDoc::new("alice")
  let _ = doc.insert(Pos::at(0), "Hello")
  let view = doc.checkout(doc.version())
  let runs = view.runs().collect()
  inspect(runs.length(), content="1")
  inspect(runs[0], content="Hello")
}

// =============================================================================
// Gap 3: Network Reconnection/Sync Recovery Tests
// =============================================================================

///|
/// Test: Peer reconnects after divergence - both edited while disconnected
test "sync recovery - peer reconnects after divergence" {
  let doc1 = TextDoc::new("alice")
  let doc2 = TextDoc::new("bob")

  // Initial sync - both start with "Hello"
  let _ = doc1.insert(Pos::at(0), "Hello")
  let msg_init = doc1.sync().export_all()
  doc2.sync().apply(msg_init)
  inspect(doc1.text(), content="Hello")
  inspect(doc2.text(), content="Hello")

  // Save version before divergence
  let version_before = doc1.version()

  // === Network disconnection - both edit independently ===
  // Alice adds " World"
  let _ = doc1.insert(Pos::at(5), " World")
  inspect(doc1.text(), content="Hello World")

  // Bob adds "!"
  let _ = doc2.insert(Pos::at(5), "!")
  inspect(doc2.text(), content="Hello!")

  // === Reconnection using export_since ===
  // Alice sends her changes since the shared version
  let msg_alice = doc1.sync().export_since(version_before)
  inspect(msg_alice.op_count() > 0, content="true")

  // Bob sends his changes since the shared version
  let msg_bob = doc2.sync().export_since(version_before)
  inspect(msg_bob.op_count() > 0, content="true")

  // Apply changes to each other
  doc2.sync().apply(msg_alice)
  doc1.sync().apply(msg_bob)

  // Both should converge to the same text
  inspect(doc1.text() == doc2.text(), content="true")
  // Both insertions should be present
  inspect(doc1.text().contains("World"), content="true")
  inspect(doc1.text().contains("!"), content="true")
}

///|
/// Test: Peer only received partial sync, reconnects with stale version
test "sync recovery - partial operation log" {
  let doc1 = TextDoc::new("alice")
  let doc2 = TextDoc::new("bob")

  // Alice inserts multiple characters
  let _ = doc1.insert(Pos::at(0), "A")
  let _ = doc1.insert(Pos::at(1), "B")
  let _ = doc1.insert(Pos::at(2), "C")

  // Bob only received ops up to v1 (partial sync)
  let partial_msg = doc1.sync().export_since(Version::empty())
  // Simulate partial by only applying first op
  let first_op = partial_msg.get_ops()[0]
  doc2.apply_remote(first_op)
  inspect(doc2.text(), content="A")

  // Now Bob reconnects with his stale version
  let bob_version = doc2.version()

  // Alice sends delta from Bob's version
  let delta_msg = doc1.sync().export_since(bob_version)
  // Should contain "B" and "C" ops
  inspect(delta_msg.op_count(), content="2")

  doc2.sync().apply(delta_msg)
  inspect(doc2.text(), content="ABC")
}

///|
/// Test: Use saved old version for export_since, verify correct delta
test "sync recovery - stale version vector" {
  let doc1 = TextDoc::new("alice")
  let doc2 = TextDoc::new("bob")

  // Build up some history
  let _ = doc1.insert(Pos::at(0), "Hello")
  let old_version = doc1.version() // Save this for later

  let _ = doc1.insert(Pos::at(5), " ")
  let _ = doc1.insert(Pos::at(6), "World")
  let _ = doc1.insert(Pos::at(11), "!")

  // Sync everything to doc2
  let full_msg = doc1.sync().export_all()
  doc2.sync().apply(full_msg)
  inspect(doc2.text(), content="Hello World!")

  // Now test export_since with the old version
  // Should only include ops after "Hello"
  let delta = doc1.sync().export_since(old_version)

  // The delta should have ops for " World!" (7 chars = 7 ops)
  // Each character is a separate op in this implementation
  inspect(delta.op_count(), content="7")

  // Verify that delta contains the expected characters
  let delta_ops = delta.get_ops()
  inspect(delta_ops.length(), content="7")
}

///|
/// Test: Two partitions evolve separately, reunify, all three converge
test "sync recovery - network partition reunion (3 peers)" {
  let doc_a = TextDoc::new("alice")
  let doc_b = TextDoc::new("bob")
  let doc_c = TextDoc::new("carol")

  // Initial state: all three have "X"
  let _ = doc_a.insert(Pos::at(0), "X")
  let msg_init = doc_a.sync().export_all()
  doc_b.sync().apply(msg_init)
  doc_c.sync().apply(msg_init)

  let shared_version = doc_a.version()

  // === Partition 1: Alice and Bob ===
  // Alice inserts "A"
  let _ = doc_a.insert(Pos::at(1), "A")
  // Sync within partition
  let msg_a = doc_a.sync().export_since(shared_version)
  doc_b.sync().apply(msg_a)
  // Bob inserts "B"
  let _ = doc_b.insert(Pos::at(2), "B")
  let msg_b = doc_b.sync().export_since(doc_a.version())
  doc_a.sync().apply(msg_b)

  // Partition 1 now has "XAB"
  inspect(doc_a.text() == doc_b.text(), content="true")

  // === Partition 2: Carol alone ===
  // Carol inserts "C"
  let _ = doc_c.insert(Pos::at(1), "C")
  inspect(doc_c.text(), content="XC")

  // === Reunification ===
  // Exchange all ops
  // Carol sends to Alice
  let carol_ops = doc_c.sync().export_since(shared_version)
  doc_a.sync().apply(carol_ops)
  doc_b.sync().apply(carol_ops)

  // Alice sends to Carol
  let alice_ops = doc_a.sync().export_since(shared_version)
  doc_c.sync().apply(alice_ops)

  // All three should converge
  inspect(doc_a.text() == doc_b.text(), content="true")
  inspect(doc_b.text() == doc_c.text(), content="true")

  // All insertions should be present
  let final_text = doc_a.text()
  inspect(final_text.contains("A"), content="true")
  inspect(final_text.contains("B"), content="true")
  inspect(final_text.contains("C"), content="true")
  inspect(final_text.contains("X"), content="true")
}

///|
/// Test: Both peers have local-only ops, sync both directions simultaneously
test "sync recovery - bidirectional delta after disconnect" {
  let doc1 = TextDoc::new("alice")
  let doc2 = TextDoc::new("bob")

  // Shared initial state
  let _ = doc1.insert(Pos::at(0), "START")
  let msg_init = doc1.sync().export_all()
  doc2.sync().apply(msg_init)

  let shared = doc1.version()

  // Both make local changes while disconnected
  let _ = doc1.insert(Pos::at(5), "-A1")
  let _ = doc1.insert(Pos::at(8), "-A2")

  let _ = doc2.insert(Pos::at(5), "-B1")
  let _ = doc2.insert(Pos::at(8), "-B2")

  // Compute deltas from shared version (simultaneously)
  let delta1 = doc1.sync().export_since(shared)
  let delta2 = doc2.sync().export_since(shared)

  // Apply deltas (simulate simultaneous network delivery)
  doc1.sync().apply(delta2)
  doc2.sync().apply(delta1)

  // Both should converge
  inspect(doc1.text() == doc2.text(), content="true")

  // All local ops from both should be present
  let text = doc1.text()
  inspect(text.contains("A1"), content="true")
  inspect(text.contains("A2"), content="true")
  inspect(text.contains("B1"), content="true")
  inspect(text.contains("B2"), content="true")
}
