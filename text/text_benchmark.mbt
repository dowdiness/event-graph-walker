// Benchmarks for the user-facing TextState API
// Run with: moon bench --package text --release

// =============================================================================
// Insert
// =============================================================================

///|
/// Benchmark: Sequential append — simulates end-of-document typing (100 chars)
test "text - insert append (100 chars)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    for i = 0; i < 100; i = i + 1 {
      ignore(try! doc.insert(Pos::at(i), "x"))
    }
    b.keep(doc)
  })
}

///|
/// Benchmark: Sequential append — simulates end-of-document typing (1000 chars)
test "text - insert append (1000 chars)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    for i = 0; i < 1000; i = i + 1 {
      ignore(try! doc.insert(Pos::at(i), "x"))
    }
    b.keep(doc)
  })
}

///|
/// Benchmark: Prepend — insert at position 0 every time (100 chars)
/// Every insert triggers FugueMax conflict resolution against the head.
test "text - insert prepend (100 chars)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    for i = 0; i < 100; i = i + 1 {
      ignore(try! doc.insert(Pos::at(0), "x"))
    }
    b.keep(doc)
  })
}

// =============================================================================
// Delete
// =============================================================================

///|
/// Benchmark: Delete every character from a 100-char document
test "text - delete (100 deletes from 100-char doc)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    for i = 0; i < 100; i = i + 1 {
      ignore(try! doc.insert(Pos::at(i), "x"))
    }
    for i = 99; i >= 0; i = i - 1 {
      ignore(try! doc.delete(Pos::at(i)))
    }
    b.keep(doc)
  })
}

// =============================================================================
// Read — text() and len()
// =============================================================================

///|
/// Benchmark: Reconstruct text string from a 100-char document
test "text - text() (100-char doc)" (b : @bench.T) {
  let doc = TextState::new("alice")
  for i = 0; i < 100; i = i + 1 {
    ignore(try! doc.insert(Pos::at(i), "x"))
  }
  b.bench(fn() {
    let result = doc.text()
    b.keep(result)
  })
}

///|
/// Benchmark: Reconstruct text string from a 1000-char document
test "text - text() (1000-char doc)" (b : @bench.T) {
  let doc = TextState::new("alice")
  for i = 0; i < 1000; i = i + 1 {
    ignore(try! doc.insert(Pos::at(i), "x"))
  }
  b.bench(fn() {
    let result = doc.text()
    b.keep(result)
  })
}

///|
/// Benchmark: len() — should be O(1) via tree's visible_count
test "text - len() (1000-char doc)" (b : @bench.T) {
  let doc = TextState::new("alice")
  for i = 0; i < 1000; i = i + 1 {
    ignore(try! doc.insert(Pos::at(i), "x"))
  }
  b.bench(fn() {
    let result = doc.len()
    b.keep(result)
  })
}

// =============================================================================
// Sync — export_all, export_since, apply
// =============================================================================

///|
/// Benchmark: SyncSession::export_all (100 ops)
test "text - sync export_all (100 ops)" (b : @bench.T) {
  let doc = TextState::new("alice")
  for i = 0; i < 100; i = i + 1 {
    ignore(try! doc.insert(Pos::at(i), "x"))
  }
  b.bench(fn() {
    let msg = try! doc.sync().export_all()
    b.keep(msg)
  })
}

///|
/// Benchmark: SyncSession::export_all (1000 ops)
test "text - sync export_all (1000 ops)" (b : @bench.T) {
  let doc = TextState::new("alice")
  for i = 0; i < 1000; i = i + 1 {
    ignore(try! doc.insert(Pos::at(i), "x"))
  }
  b.bench(fn() {
    let msg = try! doc.sync().export_all()
    b.keep(msg)
  })
}

///|
/// Benchmark: SyncSession::export_since — 50-op delta over a 1000-op document
test "text - sync export_since (50-op delta, 1000-op base)" (b : @bench.T) {
  let doc = TextState::new("alice")
  for i = 0; i < 950; i = i + 1 {
    ignore(try! doc.insert(Pos::at(i), "x"))
  }
  let base_version = doc.version()
  for i = 950; i < 1000; i = i + 1 {
    ignore(try! doc.insert(Pos::at(i), "x"))
  }
  b.bench(fn() {
    let msg = try! doc.sync().export_since(base_version)
    b.keep(msg)
  })
}

///|
/// Benchmark: SyncSession::apply — receive and apply 50 remote ops
test "text - sync apply (50 remote ops)" (b : @bench.T) {
  let bob = TextState::new("bob")
  for i = 0; i < 50; i = i + 1 {
    ignore(try! bob.insert(Pos::at(i), "b"))
  }
  let msg = try! bob.sync().export_all()
  b.bench(fn() {
    let alice = TextState::new("alice")
    try! alice.sync().apply(msg)
    b.keep(alice)
  })
}

///|
/// Benchmark: SyncSession::apply — receive and apply 500 remote ops
test "text - sync apply (500 remote ops)" (b : @bench.T) {
  let bob = TextState::new("bob")
  for i = 0; i < 500; i = i + 1 {
    ignore(try! bob.insert(Pos::at(i), "b"))
  }
  let msg = try! bob.sync().export_all()
  b.bench(fn() {
    let alice = TextState::new("alice")
    try! alice.sync().apply(msg)
    b.keep(alice)
  })
}

///|
/// Benchmark: Bidirectional sync — two peers exchanging 50 concurrent ops each
test "text - bidirectional sync (2 peers, 50 ops each)" (b : @bench.T) {
  let alice_msg = {
    let doc = TextState::new("alice")
    for i = 0; i < 50; i = i + 1 {
      ignore(try! doc.insert(Pos::at(i), "a"))
    }
    try! doc.sync().export_all()
  }
  let bob_msg = {
    let doc = TextState::new("bob")
    for i = 0; i < 50; i = i + 1 {
      ignore(try! doc.insert(Pos::at(i), "b"))
    }
    try! doc.sync().export_all()
  }
  b.bench(fn() {
    let alice = TextState::new("alice")
    let bob = TextState::new("bob")
    try! alice.sync().apply(bob_msg)
    try! bob.sync().apply(alice_msg)
    b.keep((alice, bob))
  })
}

// =============================================================================
// checkout
// =============================================================================

///|
/// Benchmark: TextState::checkout — reconstruct document at midpoint of 100-op history
test "text - checkout (midpoint of 100-op doc)" (b : @bench.T) {
  let doc = TextState::new("alice")
  for i = 0; i < 50; i = i + 1 {
    ignore(try! doc.insert(Pos::at(i), "x"))
  }
  let mid_version = doc.version()
  for i = 50; i < 100; i = i + 1 {
    ignore(try! doc.insert(Pos::at(i), "y"))
  }
  b.bench(fn() {
    let view = try! doc.checkout(mid_version)
    b.keep(view)
  })
}

///|
/// Benchmark: TextState::checkout — reconstruct document at midpoint of 1000-op history
test "text - checkout (midpoint of 1000-op doc)" (b : @bench.T) {
  let doc = TextState::new("alice")
  for i = 0; i < 500; i = i + 1 {
    ignore(try! doc.insert(Pos::at(i), "x"))
  }
  let mid_version = doc.version()
  for i = 500; i < 1000; i = i + 1 {
    ignore(try! doc.insert(Pos::at(i), "y"))
  }
  b.bench(fn() {
    let view = try! doc.checkout(mid_version)
    b.keep(view)
  })
}

// =============================================================================
// Undo / Redo
// (UndoManager is imported via the undo dependency of the text package)
// =============================================================================

///|
/// Benchmark: Record 100 inserts merged into a single undo group
/// (all timestamps within the 10-second capture window)
test "text - undo record_insert (100 ops, 1 group)" (b : @bench.T) {
  b.bench(fn() {
    let mgr = @undo.UndoManager::new("alice", capture_timeout_ms=10000)
    for i = 0; i < 100; i = i + 1 {
      mgr.record_insert(i, "alice", i * 10)
    }
    b.keep(mgr)
  })
}

///|
/// Benchmark: Record 100 inserts as 100 separate undo groups
/// (each timestamp 1000 ms apart, beyond the 100-ms capture window)
test "text - undo record_insert (100 ops, 100 groups)" (b : @bench.T) {
  b.bench(fn() {
    let mgr = @undo.UndoManager::new("alice", capture_timeout_ms=100)
    for i = 0; i < 100; i = i + 1 {
      mgr.record_insert(i, "alice", i * 1000)
    }
    b.keep(mgr)
  })
}

///|
/// Benchmark: Undo a single group containing 10 insert ops
test "text - undo undo() (10-op group)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    let mgr = @undo.UndoManager::new("alice", capture_timeout_ms=10000)
    for i = 0; i < 10; i = i + 1 {
      try! doc.insert_and_record(Pos::at(i), "x", mgr, timestamp_ms=i * 10)
    }
    ignore(try! mgr.undo(doc))
    b.keep((doc, mgr))
  })
}

///|
/// Benchmark: Undo a single group containing 50 insert ops
test "text - undo undo() (50-op group)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    let mgr = @undo.UndoManager::new("alice", capture_timeout_ms=10000)
    for i = 0; i < 50; i = i + 1 {
      try! doc.insert_and_record(Pos::at(i), "x", mgr, timestamp_ms=i * 10)
    }
    ignore(try! mgr.undo(doc))
    b.keep((doc, mgr))
  })
}

///|
/// Benchmark: Undo + redo roundtrip for a 10-op group
test "text - undo undo+redo roundtrip (10-op group)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    let mgr = @undo.UndoManager::new("alice", capture_timeout_ms=10000)
    for i = 0; i < 10; i = i + 1 {
      try! doc.insert_and_record(Pos::at(i), "x", mgr, timestamp_ms=i * 10)
    }
    ignore(try! mgr.undo(doc))
    ignore(try! mgr.redo(doc))
    b.keep((doc, mgr))
  })
}

///|
/// Benchmark: 10 consecutive undo+redo cycles on a 10-op group
test "text - undo 10 undo+redo cycles (10-op group)" (b : @bench.T) {
  b.bench(fn() {
    let doc = TextState::new("alice")
    let mgr = @undo.UndoManager::new("alice", capture_timeout_ms=10000)
    for i = 0; i < 10; i = i + 1 {
      try! doc.insert_and_record(Pos::at(i), "x", mgr, timestamp_ms=i * 10)
    }
    for i = 0; i < 10; i = i + 1 {
      ignore(try! mgr.undo(doc))
      ignore(try! mgr.redo(doc))
    }
    b.keep((doc, mgr))
  })
}
