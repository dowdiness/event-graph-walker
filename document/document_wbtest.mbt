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
