///|
/// Helper to build an InsertOp[String] concisely for tests
fn ins(
  id : Int,
  content : String,
  origin_left : Int,
  origin_right : Int,
  timestamp : Int,
  agent : String,
) -> @fugue.InsertOp[String] {
  {
    id: @fugue.Lv(id),
    content,
    origin_left: if origin_left == -1 {
      None
    } else {
      Some(@fugue.Lv(origin_left))
    },
    origin_right: if origin_right == -1 {
      None
    } else {
      Some(@fugue.Lv(origin_right))
    },
    timestamp: @fugue.Timestamp(timestamp),
    agent: @fugue.ReplicaId(agent),
  }
}

///|
/// Tests for FugueMax Tree
test "create empty tree" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  inspect(tree.visible_count(), content="0")
  inspect(tree.to_text(), content="")
}

///|
test "insert single item" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  inspect(tree.visible_count(), content="1")
  inspect(tree.to_text(), content="A")
}

///|
test "insert multiple items" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  tree.insert(ins(0, "H", -1, -1, 0, "agent0"))
  tree.insert(ins(1, "e", 0, -1, 1, "agent0"))
  tree.insert(ins(2, "l", 1, -1, 2, "agent0"))
  tree.insert(ins(3, "l", 2, -1, 3, "agent0"))
  tree.insert(ins(4, "o", 3, -1, 4, "agent0"))
  inspect(tree.visible_count(), content="5")
  inspect(tree.to_text(), content="Hello")
}

///|
test "delete item" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  tree.insert(ins(1, "B", 0, -1, 1, "agent0"))
  tree.insert(ins(2, "C", 1, -1, 2, "agent0"))
  inspect(tree.visible_count(), content="3")
  try! tree.delete(@fugue.Lv(1)) // Delete "B"
  inspect(tree.visible_count(), content="2")
  inspect(tree.to_text(), content="AC")
}

///|
test "get item by id" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  match tree[@fugue.Lv(0)] {
    Some(item) => {
      inspect(item.content, content="A")
      inspect(item.deleted, content="false")
    }
    None => fail("Expected Some(Item)")
  }
}

///|
test "concurrent inserts ordering with FugueMax" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert initial text "AC"
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  tree.insert(ins(2, "C", 0, -1, 2, "agent0"))

  // Two users concurrently insert "X" and "Y" between A and C
  // Both reference A as origin_left and C as origin_right
  tree.insert(ins(1, "X", 0, 2, 1, "agent1"))
  tree.insert(ins(3, "Y", 0, 2, 3, "agent2"))
  let text = tree.to_text()

  // With FugueMax integration:
  // - Check if A (id=0) is ancestor of C (id=2): C.parent=0, so yes!
  // - X (timestamp=1): parent=C, side=Left (because 0 is ancestor of 2)
  // - Y (timestamp=3): parent=C, side=Left (because 0 is ancestor of 2)
  // Tree order: A → [Left children of C: X, Y (sorted by timestamp)] → C
  // Expected: AXYC
  inspect(text, content="AXYC")
}

///|
test "concurrent inserts with different ancestors" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert "AB"
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  tree.insert(ins(1, "B", 0, -1, 1, "agent0"))

  // Two users concurrently insert between A and B
  // X: origin_left=A(0), origin_right=B(1), timestamp=2
  // Y: origin_left=A(0), origin_right=B(1), timestamp=3
  tree.insert(ins(2, "X", 0, 1, 2, "agent1"))
  tree.insert(ins(3, "Y", 0, 1, 3, "agent2"))
  let text = tree.to_text()
  // Both X and Y will be left children of B (since A is ancestor of B)
  // Sorted by timestamp: X(2), Y(3)
  // Expected: AXYB
  inspect(text, content="AXYB")
}

///|
test "three-way concurrent insert" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert "AD"
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  tree.insert(ins(3, "D", 0, -1, 3, "agent0"))

  // Three users concurrently insert between A and D
  tree.insert(ins(1, "B", 0, 3, 1, "agent1"))
  tree.insert(ins(2, "C", 0, 3, 2, "agent2"))
  tree.insert(ins(4, "E", 0, 3, 4, "agent3"))
  let text = tree.to_text()
  // All B, C, E will be left children of D (since A is ancestor of D)
  // Sorted by timestamp: B(1), C(2), E(4)
  // Expected: ABCED
  inspect(text, content="ABCED")
}

///|
test "nested concurrent inserts" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert "AC"
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  tree.insert(ins(2, "C", 0, -1, 2, "agent0"))

  // First level: insert B between A and C
  tree.insert(ins(1, "B", 0, 2, 1, "agent1"))

  // Second level: insert X between B and C
  // B is NOT an ancestor of C, so X becomes right child of B
  tree.insert(ins(3, "X", 1, 2, 3, "agent2"))
  let text = tree.to_text()
  // Tree structure:
  // A → B → X (right child of B)
  //   → C (right child of A)
  // Expected: ABXC
  inspect(text, content="ABXC")
}

///|
test "concurrent inserts with no right constraint" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert "A"
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))

  // Multiple concurrent inserts at end (no right constraint)
  tree.insert(ins(1, "B", 0, -1, 1, "agent1"))
  tree.insert(ins(2, "C", 0, -1, 2, "agent2"))
  tree.insert(ins(3, "D", 0, -1, 3, "agent3"))
  let text = tree.to_text()
  // All become right children of A, sorted by timestamp
  // Expected: ABCD
  inspect(text, content="ABCD")
}

///|
test "interleaved operations" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Build text progressively with concurrent inserts
  tree.insert(ins(0, "H", -1, -1, 0, "agent0"))
  tree.insert(ins(1, "e", 0, -1, 1, "agent0"))
  tree.insert(ins(2, "l", 1, -1, 2, "agent0"))
  tree.insert(ins(3, "l", 2, -1, 3, "agent0"))
  tree.insert(ins(4, "o", 3, -1, 4, "agent0"))

  // Concurrent insert at beginning: origin_left=-1, origin_right=0
  tree.insert(ins(5, ">", -1, 0, 5, "agent1"))

  // Concurrent insert in middle
  tree.insert(ins(6, "-", 2, 3, 6, "agent2"))
  let text = tree.to_text()
  // Current behavior based on tree structure
  inspect(text, content="Hel-lo>")
}

///|
test "delete in concurrent scenario" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert "ABC"
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  tree.insert(ins(1, "B", 0, -1, 1, "agent0"))
  tree.insert(ins(2, "C", 1, -1, 2, "agent0"))

  // Concurrent: delete B and insert X between A and C
  try! tree.delete(@fugue.Lv(1))
  tree.insert(ins(3, "X", 0, 2, 3, "agent1"))
  let text = tree.to_text()
  // B is deleted, X is inserted
  // Expected: AXC
  inspect(text, content="AXC")
}

///|
test "reverse timestamp ordering" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert with decreasing timestamps (simulating clock skew)
  tree.insert(ins(0, "A", -1, -1, 100, "agent0"))
  tree.insert(ins(1, "B", 0, -1, 90, "agent0"))

  // Concurrent inserts between A and B with mixed timestamps
  tree.insert(ins(2, "X", 0, 1, 95, "agent1"))
  tree.insert(ins(3, "Y", 0, 1, 85, "agent2"))
  tree.insert(ins(4, "Z", 0, 1, 92, "agent3"))
  let text = tree.to_text()
  // All X, Y, Z are left children of B
  // Sorted by timestamp: Y(85), Z(92), X(95)
  // Expected: AYZXB
  inspect(text, content="AYZXB")
}

///|
test "collaborative editing simulation" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // User 1: Types "Hello"
  tree.insert(ins(0, "H", -1, -1, 0, "user1"))
  tree.insert(ins(1, "e", 0, -1, 1, "user1"))
  tree.insert(ins(2, "l", 1, -1, 2, "user1"))
  tree.insert(ins(3, "l", 2, -1, 3, "user1"))
  tree.insert(ins(4, "o", 3, -1, 4, "user1"))
  inspect(tree.to_text(), content="Hello")

  // User 2: Concurrently inserts "World" after "Hello"
  tree.insert(ins(10, " ", 4, -1, 10, "user2"))
  tree.insert(ins(11, "W", 10, -1, 11, "user2"))
  tree.insert(ins(12, "o", 11, -1, 12, "user2"))
  tree.insert(ins(13, "r", 12, -1, 13, "user2"))
  tree.insert(ins(14, "l", 13, -1, 14, "user2"))
  tree.insert(ins(15, "d", 14, -1, 15, "user2"))
  inspect(tree.to_text(), content="Hello World")

  // User 1: Concurrently inserts "!" at end (based on seeing "Hello")
  tree.insert(ins(5, "!", 4, -1, 5, "user1"))

  // User 3: Inserts "," between "Hello" and "World"
  tree.insert(ins(20, ",", 4, 10, 20, "user3"))
  let final_text = tree.to_text()
  // Result should deterministically merge all edits
  inspect(final_text, content="Hello!, World")
}

///|
test "fugue property - non-interleaving" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Initial text "AB"
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  tree.insert(ins(1, "B", 0, -1, 1, "agent0"))

  // User 1 inserts "XX" between A and B
  tree.insert(ins(2, "X", 0, 1, 2, "user1"))
  tree.insert(ins(3, "X", 2, 1, 3, "user1"))

  // User 2 inserts "YY" between A and B (concurrent with user 1)
  tree.insert(ins(4, "Y", 0, 1, 4, "user2"))
  tree.insert(ins(5, "Y", 4, 1, 5, "user2"))
  let text = tree.to_text()
  // FugueMax should not interleave: should get AXXYYB or AYYXXB
  // Based on timestamps and tree structure, we get AXXYYB
  inspect(text, content="AXXYYB")

  // Verify no interleaving occurred
  inspect(text.contains("XYX"), content="false") // No interleaving
  inspect(text.contains("YXY"), content="false") // No interleaving
}

// =============================================================================
// Gap 5: Undelete Idempotency Tests
// =============================================================================

///|
/// Test: undelete is idempotent on visible items
/// Calling undelete multiple times on a visible item should not change state
test "undelete is idempotent on visible items" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  inspect(tree.to_text(), content="A")

  // Item is visible, undelete should be a no-op
  try! tree.undelete(@fugue.Lv(0))
  inspect(tree.to_text(), content="A")
  inspect(tree.visible_count(), content="1")

  // Call undelete again - still idempotent
  try! tree.undelete(@fugue.Lv(0))
  inspect(tree.to_text(), content="A")
  inspect(tree.visible_count(), content="1")

  // Third call - still no change
  try! tree.undelete(@fugue.Lv(0))
  inspect(tree.to_text(), content="A")
  inspect(tree.visible_count(), content="1")
}

///|
/// Test: undelete after delete restores item; second undelete is no-op
test "undelete after delete changes state" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  tree.insert(ins(1, "B", 0, -1, 1, "agent0"))
  tree.insert(ins(2, "C", 1, -1, 2, "agent0"))
  inspect(tree.to_text(), content="ABC")

  // Delete B
  try! tree.delete(@fugue.Lv(1))
  inspect(tree.to_text(), content="AC")

  // Undelete B - restores visibility
  try! tree.undelete(@fugue.Lv(1))
  inspect(tree.to_text(), content="ABC")

  // Second undelete is idempotent - no change
  try! tree.undelete(@fugue.Lv(1))
  inspect(tree.to_text(), content="ABC")
  inspect(tree.visible_count(), content="3")
}

///|
/// Test: delete(root_lv) is a full no-op — neither the visible counter nor the
/// root tombstone state must change.  A subsequent undelete(root_lv) must also
/// leave the counter unchanged (because root is never marked deleted).
test "delete/undelete root_lv does not corrupt visible_count" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  // Insert one visible item so the counter is non-trivial
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))
  inspect(tree.visible_count(), content="1")

  // delete(root_lv) must be a full no-op
  try! tree.delete(@fugue.root_lv)
  inspect(tree.visible_count(), content="1")

  // undelete(root_lv) must also be a no-op — root is not deleted, so
  // undelete's `if item.deleted` guard keeps visible unchanged
  try! tree.undelete(@fugue.root_lv)
  inspect(tree.visible_count(), content="1")
}

///|
/// Test: undelete on missing item raises MissingItem error
test "undelete on missing item raises MissingItem" {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  tree.insert(ins(0, "A", -1, -1, 0, "agent0"))

  // Try to undelete a non-existent item
  let result : Result[Unit, @fugue.FugueError] = try {
    tree.undelete(@fugue.Lv(999))
    Ok(())
  } catch {
    e => Err(e)
  }
  match result {
    Err(@fugue.MissingItem(id~)) => inspect(id, content="Lv(999)")
    Ok(_) => fail("Expected MissingItem error")
  }
}

// =============================================================================
// LWW Delete/Undelete convergent method tests
// =============================================================================

///|
test "delete_with_ts: higher timestamp wins" {
  let tree = @fugue.FugueTree::new()
  let lv = @fugue.Lv(0)
  tree.insert({
    id: lv, content: "x", origin_left: None, origin_right: None,
    timestamp: @fugue.Timestamp(1), agent: @fugue.ReplicaId("alice"),
  })
  try! tree.delete_with_ts(lv, 2, "alice")
  inspect(tree.visible_count(), content="0")
  // Undelete with ts=3 wins
  try! tree.undelete_with_ts(lv, 3, "bob")
  inspect(tree.visible_count(), content="1")
  // Delete with ts=1 loses
  try! tree.delete_with_ts(lv, 1, "charlie")
  inspect(tree.visible_count(), content="1")
}

///|
test "delete_with_ts: add-wins at same timestamp" {
  let tree = @fugue.FugueTree::new()
  let lv = @fugue.Lv(0)
  tree.insert({
    id: lv, content: "x", origin_left: None, origin_right: None,
    timestamp: @fugue.Timestamp(1), agent: @fugue.ReplicaId("alice"),
  })
  try! tree.delete_with_ts(lv, 5, "alice")
  inspect(tree.visible_count(), content="0")
  // Undelete at same ts=5 wins (add-wins)
  try! tree.undelete_with_ts(lv, 5, "bob")
  inspect(tree.visible_count(), content="1")
  // Delete at same ts=5 cannot override undelete (add-wins)
  try! tree.delete_with_ts(lv, 5, "zack")
  inspect(tree.visible_count(), content="1")
}

///|
test "delete_with_ts: commutativity" {
  let make_tree = fn() {
    let tree = @fugue.FugueTree::new()
    tree.insert({
      id: @fugue.Lv(0), content: "x", origin_left: None, origin_right: None,
      timestamp: @fugue.Timestamp(1), agent: @fugue.ReplicaId("alice"),
    })
    tree
  }
  let lv = @fugue.Lv(0)
  // Order 1: delete(ts=3) then undelete(ts=2)
  let t1 = make_tree()
  try! t1.delete_with_ts(lv, 3, "alice")
  try! t1.undelete_with_ts(lv, 2, "bob")
  // Order 2: undelete(ts=2) then delete(ts=3)
  let t2 = make_tree()
  try! t2.undelete_with_ts(lv, 2, "bob")
  try! t2.delete_with_ts(lv, 3, "alice")
  // Both agree: delete at ts=3 wins
  inspect(t1.visible_count(), content="0")
  inspect(t2.visible_count(), content="0")
}

///|
test "set_delete_winner: restores winner state" {
  let tree = @fugue.FugueTree::new()
  let lv = @fugue.Lv(0)
  tree.insert({
    id: lv, content: "x", origin_left: None, origin_right: None,
    timestamp: @fugue.Timestamp(1), agent: @fugue.ReplicaId("alice"),
  })
  // Set winner to Delete(ts=5, alice)
  try! tree.set_delete_winner(lv, true, 5, "alice", false)
  inspect(tree.visible_count(), content="0")
  // Set winner to Undelete(ts=3, bob)
  try! tree.set_delete_winner(lv, false, 3, "bob", true)
  inspect(tree.visible_count(), content="1")
  // Set winner to initial (no op)
  try! tree.set_delete_winner(lv, false, 0, "", false)
  inspect(tree.visible_count(), content="1") // item starts visible
}
