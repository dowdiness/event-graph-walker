///| Tests for Document cache invalidation and position coherency

///|
/// Document wrapping seam: a pending identity conflict does not project or advance.
test "apply_remote wraps pending OpLog ConflictingIdentity atomically" {
  let doc = Document::new("local")
  let seed = try! doc.insert(0, "seed")
  // Warm the derived position cache before the unresolved operation arrives.
  let _ = doc.get_visible_items()
  let missing_parent = @core.RawVersion::new("document-parent", 0)
  let pending = @core.Op::new_insert(
    11,
    [missing_parent],
    "document-pending",
    1,
    "a",
    None,
    None,
  )
  ignore(try! doc.apply_remote(pending))
  let before = doc.causal_snapshot()
  let before_frontier = doc.get_frontier()
  let before_text = doc.to_text()
  let before_position = doc.lv_to_position(seed.lv())
  let conflict = @core.Op::new_insert(
    23,
    [missing_parent],
    "document-pending",
    1,
    "b",
    None,
    None,
  )
  let result : Result[Unit, DocumentError] = try {
    doc.apply_remote(conflict)
    Ok(())
  } catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::OpLog(@oplog.OpLogError::ConflictingIdentity(raw~))) =>
      assert_eq(raw, @core.RawVersion::new("document-pending", 1))
    _ => fail("expected wrapped identity conflict")
  }
  assert_eq(doc.causal_snapshot().op_count(), before.op_count())
  assert_eq(doc.causal_snapshot().frontier(), before.frontier())
  assert_eq(doc.get_frontier(), before_frontier)
  assert_eq(doc.to_text(), before_text)
  assert_eq(doc.lv_to_position(seed.lv()), before_position)
  assert_eq(doc.get_all_ops().length(), before.op_count())

  // The original pending payload remains authoritative and can still drain.
  let parent = @core.Op::new_insert(
    -1,
    [],
    missing_parent.agent,
    missing_parent.seq,
    "p",
    None,
    None,
  )
  try! doc.apply_remote(parent)
  inspect(doc.to_text().contains("a"), content="true")
  inspect(doc.to_text().contains("b"), content="false")
  inspect(doc.get_all_ops().length(), content="6")
}

///|
test "apply_remote rejects graph-only delete target before oplog mutation" {
  let doc = Document::new("local")
  let _ = try! doc.insert(0, "x")
  let delete_op = try! doc.delete(0)
  ignore(doc.get_visible_items())
  let before_snapshot = doc.causal_snapshot()
  let before_op_count = before_snapshot.op_count()
  let before_frontier = before_snapshot.frontier()
  let before_export = doc.get_all_ops().map(op => op.lv())
  let bad_delete = @core.Op::new_delete(
    -1,
    [],
    "remote",
    0,
    Some(@core.RawVersion::new("local", delete_op.seq())),
  )

  let result : Result[Unit, DocumentError] = try {
    doc.apply_remote(bad_delete)
    Ok(())
  } catch {
    e => Err(e)
  }
  match result {
    Err(DocumentError::Fugue(@fugue.FugueError::MissingItem(id~))) =>
      inspect(id, content="Lv(1)")
    _ => fail("expected graph-only target error")
  }
  inspect(doc.causal_snapshot().op_count() == before_op_count, content="true")
  inspect(doc.causal_snapshot().frontier() == before_frontier, content="true")
  inspect(doc.get_all_ops().map(op => op.lv()) == before_export, content="true")
  inspect(doc.get_visible_items().length(), content="0")

  let parent_insert = @core.Op::new_insert(-1, [], "remote", 0, "A", None, None)
  try! doc.apply_remote(parent_insert)
  inspect(doc.to_text(), content="A")
}

///|
test "apply_remote rejects graph-only undelete target before oplog mutation" {
  let doc = Document::new("local")
  let _ = try! doc.insert(0, "x")
  let delete_op = try! doc.delete(0)
  let before_snapshot = doc.causal_snapshot()
  let before_frontier = before_snapshot.frontier()
  let bad_undelete = @core.Op::new_undelete(
    -1,
    [],
    "remote",
    0,
    Some(@core.RawVersion::new("local", delete_op.seq())),
  )

  let result : Result[Unit, DocumentError] = try {
    doc.apply_remote(bad_undelete)
    Ok(())
  } catch {
    e => Err(e)
  }
  match result {
    Err(DocumentError::Fugue(@fugue.FugueError::MissingItem(_))) => ()
    _ => fail("expected graph-only target error")
  }
  inspect(
    doc.causal_snapshot().op_count() == before_snapshot.op_count(),
    content="true",
  )
  inspect(doc.causal_snapshot().frontier() == before_frontier, content="true")
}

///|
test "apply_remote rejects graph-only insert origins before oplog mutation" {
  let doc = Document::new("local")
  let _ = try! doc.insert(0, "x")
  let delete_op = try! doc.delete(0)
  let graph_only = @core.RawVersion::new("local", delete_op.seq())
  let before_snapshot = doc.causal_snapshot()
  let before_export = doc.get_all_ops().map(op => op.lv())
  let bad_left = @core.Op::new_insert(
    -1,
    [],
    "remote",
    0,
    "y",
    Some(graph_only),
    None,
  )
  let bad_right = @core.Op::new_insert(
    -1,
    [],
    "remote",
    0,
    "y",
    None,
    Some(graph_only),
  )
  for bad in [bad_left, bad_right] {
    let result : Result[Unit, DocumentError] = try {
      doc.apply_remote(bad)
      Ok(())
    } catch {
      e => Err(e)
    }
    match result {
      Err(DocumentError::Fugue(@fugue.FugueError::MissingItem(_))) => ()
      _ => fail("expected graph-only origin error")
    }
  }
  inspect(
    doc.causal_snapshot().op_count() == before_snapshot.op_count(),
    content="true",
  )
  inspect(doc.get_all_ops().map(op => op.lv()) == before_export, content="true")
}

///|
test "apply_remote validates an unready incoming origin before pending" {
  let doc = Document::new("local")
  let _ = try! doc.insert(0, "x")
  let delete_op = try! doc.delete(0)
  let graph_only = @core.RawVersion::new("local", delete_op.seq())
  let missing_parent = @core.RawVersion::new("ghost", 0)
  let pending = @core.Op::new_insert(
    -1,
    [missing_parent],
    "remote",
    0,
    "p",
    None,
    None,
  )
  try! doc.apply_remote(pending)
  let before_snapshot = doc.causal_snapshot()
  let bad = @core.Op::new_insert(
    -1,
    [missing_parent],
    "remote",
    1,
    "b",
    Some(graph_only),
    None,
  )
  let result : Result[Unit, DocumentError] = try {
    doc.apply_remote(bad)
    Ok(())
  } catch {
    e => Err(e)
  }
  match result {
    Err(DocumentError::Fugue(@fugue.FugueError::MissingItem(_))) => ()
    _ => fail("expected graph-only origin error")
  }
  inspect(
    doc.causal_snapshot().op_count() == before_snapshot.op_count(),
    content="true",
  )
  let parent = @core.Op::new_insert(-1, [], "ghost", 0, "g", None, None)
  try! doc.apply_remote(parent)
  inspect(doc.visible_count(), content="2")
}

///|
test "merge_remote rejects graph-only target before oplog mutation" {
  let doc = Document::new("local")
  let _ = try! doc.insert(0, "x")
  let delete_op = try! doc.delete(0)
  let before_snapshot = doc.causal_snapshot()
  let before_export = doc.get_all_ops().map(op => op.lv())
  let bad_delete = @core.Op::new_delete(
    -1,
    [],
    "remote",
    0,
    Some(@core.RawVersion::new("local", delete_op.seq())),
  )

  let result : Result[Unit, DocumentError] = try {
    doc.merge_remote([bad_delete], [])
    Ok(())
  } catch {
    e => Err(e)
  }
  match result {
    Err(DocumentError::Fugue(@fugue.FugueError::MissingItem(_))) => ()
    _ => fail("expected graph-only target error")
  }
  inspect(
    doc.causal_snapshot().op_count() == before_snapshot.op_count(),
    content="true",
  )
  inspect(doc.get_all_ops().map(op => op.lv()) == before_export, content="true")
}

///|
test "merge_remote accepts a valid insert-delete batch" {
  let source = Document::new("remote")
  let _ = try! source.insert(0, "x")
  let _ = try! source.delete(0)
  let target = Document::new("local")
  let frontier = try! source.get_frontier_raw()
  try! target.merge_remote(source.get_all_ops(), frontier)
  inspect(target.to_text(), content="")
}

///|
test "apply_remote preflights pending graph-only targets before drain" {
  let doc = Document::new("local")
  let _ = try! doc.insert(0, "x")
  let target_raw = @core.RawVersion::new("remote", 1)
  let pending_delete = @core.Op::new_delete(
    -1,
    [target_raw],
    "remote",
    2,
    Some(target_raw),
  )
  let pending_delete_2 = @core.Op::new_delete(
    -1,
    [target_raw],
    "remote",
    3,
    Some(target_raw),
  )
  let pending_child = @core.Op::new_insert(
    -1,
    [@core.RawVersion::new("remote", 2)],
    "remote",
    4,
    "z",
    None,
    None,
  )
  try! doc.apply_remote(pending_delete)
  try! doc.apply_remote(pending_delete_2)
  try! doc.apply_remote(pending_child)
  let before_snapshot = doc.causal_snapshot()
  let before_frontier = before_snapshot.frontier()
  let before_export = doc.get_all_ops().map(op => op.lv())

  let target_delete = @core.Op::new_delete(
    -1,
    [],
    "remote",
    1,
    Some(@core.RawVersion::new("local", 0)),
  )
  let result : Result[Unit, DocumentError] = try {
    doc.apply_remote(target_delete)
    Ok(())
  } catch {
    e => Err(e)
  }
  match result {
    Err(DocumentError::MissingOrigin(raw~)) =>
      inspect(raw == @core.RawVersion::new("remote", 1), content="true")
    _ => fail("expected pending graph-only target error")
  }
  inspect(
    doc.causal_snapshot().op_count() == before_snapshot.op_count(),
    content="true",
  )
  inspect(doc.causal_snapshot().frontier() == before_frontier, content="true")
  inspect(doc.get_all_ops().map(op => op.lv()) == before_export, content="true")
  inspect(doc.to_text(), content="x")

  // All invalid pending operations were discarded; the valid target op can retry.
  try! doc.apply_remote(target_delete)
  inspect(doc.to_text(), content="")
  let valid_insert = @core.Op::new_insert(-1, [], "other", 0, "y", None, None)
  try! doc.apply_remote(valid_insert)
  inspect(doc.to_text(), content="y")
}

///|
test "unknown local delete target does not poison later synchronization" {
  let alice = Document::new("alice")
  let bob = Document::new("bob")
  let _ = try! alice.insert(0, "A")
  let delete_op = try! alice.delete(0)
  let before_snapshot = alice.causal_snapshot()
  let before_op_count = before_snapshot.op_count()
  let before_frontier = before_snapshot.frontier()
  let before_export = alice.get_all_ops().map(op => op.lv())
  let result : Result[Unit, DocumentError] = Ok(
    // The delete operation LV is in the causal graph but is not a Fugue item.
    {
      let _ = alice.delete_by_lv(delete_op.lv())
      ()
    },
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::Fugue(@fugue.FugueError::MissingItem(id~))) =>
      inspect(id == @fugue.Lv(delete_op.lv()), content="true")
    _ => fail("expected structurally missing target error")
  }
  let after_snapshot = alice.causal_snapshot()
  inspect(after_snapshot.op_count() == before_op_count, content="true")
  inspect(after_snapshot.frontier() == before_frontier, content="true")
  inspect(
    alice.get_all_ops().map(op => op.lv()) == before_export,
    content="true",
  )

  let _ = try! alice.insert(0, "A")
  for op in alice.get_all_ops() {
    try! bob.apply_remote(op)
  }
  inspect(bob.to_text(), content="A")
}

///|
test "cache coherent after apply_remote insert: visible count and text correct" {
  let alice = Document::new("alice")
  let bob = Document::new("bob")

  // Alice inserts "Hello"
  let _ = try! alice.insert(0, "Hello")

  // Prime Bob's cache (empty)
  ignore(bob.get_visible_items())

  // Apply Alice's ops to Bob — must invalidate Bob's cache
  for op in alice.get_all_ops() {
    try! bob.apply_remote(op)
  }

  inspect(bob.to_text(), content="Hello")
  inspect(bob.visible_count(), content="5")
  // Position-based delete should use the rebuilt cache correctly
  let _ = try! bob.delete(0) // delete 'H'
  inspect(bob.to_text(), content="ello")
}

///|
test "cache coherent after apply_remote delete: deleted item gone from positions" {
  let alice = Document::new("alice")
  let bob = Document::new("bob")

  // Both start with "abc"
  let _ = try! alice.insert(0, "abc")
  for op in alice.get_all_ops() {
    try! bob.apply_remote(op)
  }
  inspect(bob.to_text(), content="abc")

  // Alice deletes 'b' (position 1)
  let _ = try! alice.delete(1)

  // Prime Bob's cache ("abc")
  ignore(bob.get_visible_items())

  // Apply delete — must invalidate Bob's cache
  let delete_op = alice.get_all_ops()[alice.get_all_ops().length() - 1]
  try! bob.apply_remote(delete_op)

  inspect(bob.to_text(), content="ac")
  // With stale cache this would return 3 — directly exposes the invalidation bug
  inspect(bob.get_visible_items().length(), content="2")
  // Bob deletes at position 1 ('c') using the fresh cache correctly
  let _ = try! bob.delete(1)
  inspect(bob.to_text(), content="a")
}

///|
test "cache coherent after merge_remote: positions reflect merged state" {
  let alice = Document::new("alice")
  let bob = Document::new("bob")

  // Alice inserts "Hello"
  let _ = try! alice.insert(0, "Hello")

  // Bob inserts "World"
  let _ = try! bob.insert(0, "World")

  // Prime Alice's cache
  ignore(alice.get_visible_items())

  // Merge Bob's ops into Alice — must invalidate Alice's cache
  let bob_ops = bob.get_all_ops()
  let bob_frontier = try! bob.get_frontier_raw()
  try! alice.merge_remote(bob_ops, bob_frontier)

  // Both words appear (order depends on FugueMax conflict resolution)
  // With stale cache this would return 5 — directly exposes the invalidation bug
  inspect(alice.get_visible_items().length(), content="10")
  // Delete at position 6 (only reachable via fresh 10-item cache, not stale 5-item "Hello" cache)
  let _ = try! alice.delete(6)
  inspect(alice.get_visible_items().length(), content="9")
}

///|
test "multi-char insert at non-end position" {
  let doc = @document.Document::new("alice")
  for i = 0; i < 5; i = i + 1 {
    let ch = "hello"[i:i + 1].to_owned()
    ignore(try! doc.insert(i, ch))
  }
  inspect(doc.to_text(), content="hello")
  ignore(try! doc.insert(2, "X"))
  ignore(try! doc.insert(3, "Y"))
  inspect(doc.to_text(), content="heXYllo")
}

///|
test "delete: position cache incrementally updated" {
  let doc = @document.Document::new("test")
  let _ = doc.insert(0, "abc")
  inspect(doc.visible_count(), content="3")
  inspect(doc.to_text(), content="abc")

  // Delete middle character — cache should be incrementally updated
  let _ = doc.delete(1) // delete 'b'
  inspect(doc.to_text(), content="ac")
  inspect(doc.visible_count(), content="2")

  // Verify position lookups still work after incremental delete
  let _ = doc.delete(0) // delete 'a'
  inspect(doc.to_text(), content="c")
}

///|
test "cursor fast-path to non-sequential insert invalidates cache" {
  let doc = @document.Document::new("test")
  let _ = doc.insert(0, "abc")
  // Prime the position cache so the next insert actually tests stale-cache invalidation.
  // Without this, the indexed state is not ready and the invalidation path is never exercised.
  let _ = doc.lv_to_position(0)
  // Non-sequential insert (cursor miss) — must invalidate the warm cache
  let _ = doc.insert(1, "X")
  inspect(doc.to_text(), content="aXbc")
  let _ = doc.delete(2)
  inspect(doc.to_text(), content="aXc")
}

///|
test "delete_range across split VisibleRuns" {
  let doc = @document.Document::new("test")
  let _ = doc.insert(0, "abcde")
  inspect(doc.to_text(), content="abcde")
  let _ = doc.delete(2)
  inspect(doc.to_text(), content="abde")
  doc.delete_range(1, 3)
  inspect(doc.to_text(), content="ae")
}

///|
test "cache coherent: interleaved local and remote edits maintain consistency" {
  let alice = Document::new("alice")
  let bob = Document::new("bob")

  // Shared initial state: "ac"
  let _ = try! alice.insert(0, "ac")
  for op in alice.get_all_ops() {
    try! bob.apply_remote(op)
  }

  // Prime both caches
  ignore(alice.get_visible_items())
  ignore(bob.get_visible_items())

  // Alice inserts 'b' between 'a' and 'c' — invalidates Alice's cache
  let _ = try! alice.insert(1, "b")
  inspect(alice.to_text(), content="abc")

  // Re-prime Alice's cache after the local insert so the remote apply is what must invalidate it
  ignore(alice.get_visible_items())

  // Bob inserts 'X' at start — invalidates Bob's cache
  let _ = try! bob.insert(0, "X")
  inspect(bob.to_text().contains("X"), content="true")

  // Apply Bob's insert to Alice — must invalidate Alice's re-primed cache
  let bob_new_op = bob.get_all_ops()[bob.get_all_ops().length() - 1]
  try! alice.apply_remote(bob_new_op)
  // With stale cache this would return 3 — directly exposes the invalidation bug
  inspect(alice.get_visible_items().length(), content="4")

  // Alice's cache must allow correct further edits
  let _ = try! alice.delete(0) // delete whatever is at position 0 now
  inspect(alice.get_visible_items().length(), content="3")
}
