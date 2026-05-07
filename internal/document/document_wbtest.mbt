///| Whitebox tests for Document internal functions

///|
test "position_to_lv returns -1 at start of empty document" {
  let doc = Document::new("test")
  inspect(doc.position_to_lv(0), content="-1")
}

///|
test "position_to_lv returns correct LV for positions" {
  let doc = Document::new("test")
  let _ = try! doc.insert(0, "abc")

  // Position 0 is before all text
  inspect(doc.position_to_lv(0), content="-1")

  // Position 1 is after 'a' (LV 0)
  inspect(doc.position_to_lv(1), content="0")

  // Position 2 is after 'b' (LV 1)
  inspect(doc.position_to_lv(2), content="1")

  // Position 3 is after 'c' (LV 2)
  inspect(doc.position_to_lv(3), content="2")
}

///|
test "position_to_lv handles position beyond end" {
  let doc = Document::new("test")
  let _ = try! doc.insert(0, "ab")

  // Position 10 is beyond end, should return last item's LV (1)
  inspect(doc.position_to_lv(10), content="1")
}

// =============================================================================
// Cache coherency after mutations
// =============================================================================

///|
test "cache coherent after insert: position_to_lv reflects new character" {
  let doc = Document::new("alice")
  let _ = try! doc.insert(0, "ac")

  // Prime cache
  ignore(doc.get_visible_items())

  // Insert 'b' between 'a' (pos 1) and 'c' (pos 2) — invalidates cache
  let _ = try! doc.insert(1, "b")

  // Cache must be rebuilt: "abc" — LVs are 0='a', 1='c', 2='b'
  inspect(doc.to_text(), content="abc")
  // position 2 is now after 'b' (the newly inserted char, LV 2)
  inspect(doc.position_to_lv(2), content="2")
  // get_visible_items must also reflect updated state
  inspect(doc.get_visible_items().length(), content="3")
}

///|
test "cache coherent after delete: position_to_lv skips deleted character" {
  let doc = Document::new("alice")
  let _ = try! doc.insert(0, "abc")

  // Prime cache
  ignore(doc.get_visible_items())

  // Delete 'a' at position 0 — invalidates cache
  let _ = try! doc.delete(0)

  // Cache must be rebuilt: "bc"
  inspect(doc.to_text(), content="bc")
  // position 1 is now after 'b' (originally LV 1)
  inspect(doc.position_to_lv(1), content="1")
  inspect(doc.get_visible_items().length(), content="2")
}

///|
test "cache coherent after undelete: revived item appears in position_to_lv" {
  let doc = Document::new("alice")
  let _ = try! doc.insert(0, "ab")
  // Delete 'a' (LV 0)
  let _ = try! doc.delete(0)
  inspect(doc.to_text(), content="b")

  // Prime cache
  ignore(doc.get_visible_items())

  // Revive 'a' via undelete — invalidates cache
  let _ = try! doc.undelete(0)
  inspect(doc.to_text(), content="ab")

  // Cache must reflect revived item: 2 visible items
  inspect(doc.get_visible_items().length(), content="2")
  // position 1 returns LV of 'a' (LV 0)
  inspect(doc.position_to_lv(1), content="0")
}

///|
test "cache coherent after delete_by_lv: deleted item absent from positions" {
  let doc = Document::new("alice")
  let _ = try! doc.insert(0, "abc")

  // Prime cache
  ignore(doc.get_visible_items())

  // Delete 'b' (LV 1) directly by LV — invalidates cache
  let _ = try! doc.delete_by_lv(1)
  inspect(doc.to_text(), content="ac")

  // Cache must be rebuilt: 2 visible items
  inspect(doc.get_visible_items().length(), content="2")
  // position 1 now returns LV of 'a' (LV 0)
  inspect(doc.position_to_lv(1), content="0")
}

///|
test "cache coherent: position_to_lv matches get_visible_items after each op" {
  let doc = Document::new("alice")

  // Helper: verify position_to_lv(i) == LV at index i-1 in get_visible_items
  fn check_consistency(d : Document) -> Bool {
    let items = d.get_visible_items()
    let mut ok = true
    for i = 1; i <= items.length(); i = i + 1 {
      let (expected_lv, _) = items[i - 1]
      if d.position_to_lv(i) != expected_lv.0 {
        ok = false
      }
    }
    ok
  }

  let _ = try! doc.insert(0, "hello")
  inspect(check_consistency(doc), content="true")

  let _ = try! doc.delete(2) // delete 'l'
  inspect(check_consistency(doc), content="true")

  let _ = try! doc.insert(1, "X")
  inspect(check_consistency(doc), content="true")
}

///|
test "cursor fast-path: sequential append matches cache lookup" {
  let doc = Document::new("alice")
  for i = 0; i < 10; i = i + 1 {
    ignore(try! doc.insert(i, "x"))
  }
  inspect(doc.to_text(), content="xxxxxxxxxx")
  match doc.cursor {
    Some(c) => {
      inspect(c.position, content="9")
      inspect(c.at_end, content="true")
    }
    None => fail("Expected cursor to be set after sequential append")
  }
}

///|
test "cursor invalidated on delete" {
  let doc = Document::new("alice")
  for i = 0; i < 5; i = i + 1 {
    ignore(try! doc.insert(i, "x"))
  }
  @debug.debug_inspect(doc.cursor is Some(_), content="true")
  try! doc.delete_range(2, 3)
  inspect(doc.cursor is None, content="true")
}

///|
test "cursor partial hit: mid-document sequential insert" {
  let doc = Document::new("alice")
  ignore(try! doc.insert(0, "a"))
  ignore(try! doc.insert(1, "b"))
  ignore(try! doc.insert(2, "c"))
  ignore(try! doc.insert(3, "d"))
  ignore(try! doc.insert(4, "e"))
  inspect(doc.to_text(), content="abcde")
  try! doc.delete_range(3, 4)
  inspect(doc.to_text(), content="abce")
  ignore(try! doc.insert(2, "X"))
  inspect(doc.to_text(), content="abXce")
  ignore(try! doc.insert(3, "Y"))
  inspect(doc.to_text(), content="abXYce")
}

///|
test "incremental insert: sequential append preserves cache" {
  let doc = Document::new("test")
  // Insert first char (cursor miss -> builds cache during lookup, then invalidates)
  let _ = try! doc.insert(0, "a")
  // Build cache explicitly by reading a position
  @debug.debug_inspect(doc.lv_at_position(0), content=(
    #|Some(0)
  ))
  // Now cache exists
  assert_true(doc.position_cache is Some(_))
  // Sequential single-char insert at end — should use incremental path
  let _ = try! doc.insert(1, "b")
  // Cache should still exist (not invalidated) because incremental insert updated it
  assert_true(doc.position_cache is Some(_))
  // Verify correctness through the preserved cache
  @debug.debug_inspect(doc.lv_at_position(0), content=(
    #|Some(0)
  ))
  @debug.debug_inspect(doc.lv_at_position(1), content=(
    #|Some(1)
  ))
}

///|
test "incremental insert: non-sequential preserves cache" {
  let doc = Document::new("test")
  let _ = try! doc.insert(0, "abc")
  // Build cache by reading
  @debug.debug_inspect(doc.lv_at_position(0), content=(
    #|Some(0)
  ))
  assert_true(doc.position_cache is Some(_))
  // Insert at middle (not sequential append) — cache maintained incrementally
  // This is a cursor-miss: cursor was at position 2 (end), now inserting at 1
  let _ = try! doc.insert(1, "x")
  // Verify cache is preserved (incremental OrderTree.insert_at, not full rebuild)
  assert_true(doc.position_cache is Some(_))
  // Verify positions are correct after incremental update
  @debug.debug_inspect(doc.lv_at_position(0), content=(
    #|Some(0)
  ))
  @debug.debug_inspect(doc.lv_at_position(1), content=(
    #|Some(3)
  )) // 'x' has LV 3
  @debug.debug_inspect(doc.lv_at_position(2), content=(
    #|Some(1)
  ))
  @debug.debug_inspect(doc.lv_at_position(3), content=(
    #|Some(2)
  ))
  // Sequential insert after middle insertion — exercises the partial-hit branch:
  // cursor is at position 1 with at_end=false, so current_pos (2) == c.position + 1
  // but c.at_end is false → partial hit → looks up origin_right from cache
  let _ = try! doc.insert(2, "y")
  assert_true(doc.position_cache is Some(_))
  // doc is now "a x y b c" → positions: a(0) x(3) y(4) b(1) c(2)
  @debug.debug_inspect(doc.lv_at_position(0), content=(
    #|Some(0)
  ))
  @debug.debug_inspect(doc.lv_at_position(1), content=(
    #|Some(3)
  )) // x
  @debug.debug_inspect(doc.lv_at_position(2), content=(
    #|Some(4)
  )) // y
  @debug.debug_inspect(doc.lv_at_position(3), content=(
    #|Some(1)
  )) // b
  @debug.debug_inspect(doc.lv_at_position(4), content=(
    #|Some(2)
  )) // c
}

///|
test "incremental insert: multi-char non-sequential paste preserves cache" {
  let doc = Document::new("test")
  let _ = try! doc.insert(0, "hello")
  // Prime cache
  @debug.debug_inspect(doc.lv_at_position(0), content=(
    #|Some(0)
  ))
  assert_true(doc.position_cache is Some(_))
  // Paste "abc" at position 2 (non-sequential: cursor was at 4)
  let _ = try! doc.insert(2, "abc")
  // Cache should be preserved through all 3 chars of the paste
  assert_true(doc.position_cache is Some(_))
  // Verify text: "he" + "abc" + "llo" = "heabcllo"
  inspect(doc.to_text(), content="heabcllo")
  // Verify position→LV mapping:
  // pos 0→LV 0 (h), pos 1→LV 1 (e), pos 2→LV 5 (a), pos 3→LV 6 (b),
  // pos 4→LV 7 (c), pos 5→LV 2 (l), pos 6→LV 3 (l), pos 7→LV 4 (o)
  @debug.debug_inspect(doc.lv_at_position(0), content=(
    #|Some(0)
  ))
  @debug.debug_inspect(doc.lv_at_position(1), content=(
    #|Some(1)
  ))
  @debug.debug_inspect(doc.lv_at_position(2), content=(
    #|Some(5)
  ))
  @debug.debug_inspect(doc.lv_at_position(3), content=(
    #|Some(6)
  ))
  @debug.debug_inspect(doc.lv_at_position(4), content=(
    #|Some(7)
  ))
  @debug.debug_inspect(doc.lv_at_position(5), content=(
    #|Some(2)
  ))
  @debug.debug_inspect(doc.lv_at_position(6), content=(
    #|Some(3)
  ))
  @debug.debug_inspect(doc.lv_at_position(7), content=(
    #|Some(4)
  ))
}

///|
test "incremental insert: delete_range then non-sequential insert" {
  let doc = Document::new("test")
  let _ = try! doc.insert(0, "abcde")
  // Prime cache
  @debug.debug_inspect(doc.lv_at_position(0), content=(
    #|Some(0)
  ))
  assert_true(doc.position_cache is Some(_))
  // delete_range invalidates cache
  try! doc.delete_range(1, 3) // delete "bc"
  assert_true(doc.position_cache is None)
  // Non-sequential insert after delete — should lazy-build and maintain cache
  let _ = try! doc.insert(1, "xy")
  // Cache should be valid after the insert
  assert_true(doc.position_cache is Some(_))
  // Verify text: "a" + "xy" + "de" = "axyde"
  inspect(doc.to_text(), content="axyde")
}

///|
test "incremental insert: remote op between local inserts resets cache" {
  let doc_a = Document::new("alice")
  let doc_b = Document::new("bob")
  // Alice types "abc"
  let _ = try! doc_a.insert(0, "abc")
  // Prime Alice's cache
  @debug.debug_inspect(doc_a.lv_at_position(0), content=(
    #|Some(0)
  ))
  assert_true(doc_a.position_cache is Some(_))
  // Bob inserts "x" at position 0
  let _ = try! doc_b.insert(0, "x")
  // Export Bob's op and apply to Alice
  let bob_op = doc_b.oplog.get_all_ops()[0]
  try! doc_a.apply_remote(bob_op)
  // Small remote batch with warm cache: cache updated incrementally (not invalidated)
  assert_true(doc_a.position_cache is Some(_))
  assert_true(doc_a.cursor is None)
  // Verify cache content is correct: position queries return right LVs
  // Bob's "x" goes to the front (FugueMax ordering), so doc is "xabc"
  let text = doc_a.to_text()
  inspect(text.length(), content="4")
  // Position 0 should resolve to a valid LV (Bob's insert)
  assert_true(doc_a.lv_at_position(0) is Some(_))
  // Position 3 should resolve to a valid LV (Alice's 'c')
  assert_true(doc_a.lv_at_position(3) is Some(_))
  // Position 4 should be out of bounds
  assert_true(doc_a.lv_at_position(4) is None)
  // Alice does another non-sequential insert
  let _ = try! doc_a.insert(1, "y")
  assert_true(doc_a.position_cache is Some(_))
  // Verify total text length is correct (xabc + y = 5 chars)
  inspect(doc_a.to_text().length(), content="5")
}

///|
test "lv_to_position after incremental append" {
  let doc = Document::new("test")
  let _ = try! doc.insert(0, "a")
  // Prime cache so incremental path can fire
  @debug.debug_inspect(doc.lv_at_position(0), content=(
    #|Some(0)
  ))
  assert_true(doc.position_cache is Some(_))
  // Sequential append — incremental path preserves cache
  let _ = try! doc.insert(1, "b")
  assert_true(doc.position_cache is Some(_))
  // lv_to_position should work on the preserved cache
  @debug.debug_inspect(doc.lv_to_position(0), content=(
    #|Some(0)
  ))
  @debug.debug_inspect(doc.lv_to_position(1), content=(
    #|Some(1)
  ))
  inspect(doc.lv_to_position(99) is None, content="true")
}
