///| Tests for Document cache invalidation and position coherency

///|
test "apply_remote invalidates position cache on partial failure" {
  let doc = Document::new("local")

  // Seed local history so we have a known raw version that resolves in the graph
  // but is not a Fugue item ID (delete op lv), which will trigger FugueError.
  let _ = try! doc.insert(0, "x")
  let _ = try! doc.delete(0)

  // Prime cache with an empty snapshot. A stale cache here would break later
  // position-based operations after partial remote application.
  ignore(doc.get_visible_items())
  let parent_raw = @core.RawVersion::new("remote", 0)
  let bad_target = @core.RawVersion::new("local", 1) // seq 1 is the delete op above

  // Buffered first: waits for parent.
  let bad_delete = @core.Op::new_delete(
    -1,
    [parent_raw],
    "remote",
    1,
    Some(bad_target),
  )
  let parent_insert = @core.Op::new_insert(-1, [], "remote", 0, "A", None, None)
  try! doc.apply_remote(bad_delete)

  // Parent insert is applied, then buffered malformed delete raises.
  let result : Result[Unit, DocumentError] = try? doc.apply_remote(
    parent_insert,
  )
  inspect(result is Err(_), content="true")
  inspect(doc.to_text(), content="A")

  // Cache must reflect current tree after the failure path.
  inspect(doc.get_visible_items().length(), content="1")

  // Position-based operation should still work with fresh cache.
  let _ = try! doc.delete(0)
  inspect(doc.to_text(), content="")
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
  inspect(bob.visible_count(), content="2")
  // Bob can now correctly delete at position 0 ('a')
  let _ = try! bob.delete(0)
  inspect(bob.to_text(), content="c")
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
  inspect(alice.visible_count(), content="10")
  // Position-based delete should work after merge
  let _ = try! alice.delete(0)
  inspect(alice.visible_count(), content="9")
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

  // Bob inserts 'X' at start — invalidates Bob's cache
  let _ = try! bob.insert(0, "X")
  inspect(bob.to_text().contains("X"), content="true")

  // Apply Bob's insert to Alice
  let bob_new_op = bob.get_all_ops()[bob.get_all_ops().length() - 1]
  try! alice.apply_remote(bob_new_op)
  inspect(alice.visible_count(), content="4")

  // Alice's cache must allow correct further edits
  let _ = try! alice.delete(0) // delete whatever is at position 0 now
  inspect(alice.visible_count(), content="3")
}
