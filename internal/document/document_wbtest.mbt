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
  inspect(doc.cursor is Some(_), content="true")
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
