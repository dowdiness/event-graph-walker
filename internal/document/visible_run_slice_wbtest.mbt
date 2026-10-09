///|
test "VisibleRun slice scalar bounds agree for BMP and astral mixtures" {
  for
    text in [
      "", "abcdef", "日本語", "e\u{301}café", "😀abc", "a😀bc", "abc😀",
      "👩‍💻x",
    ] {
    let chars = text.to_array()
    let run : VisibleRun = { start_lv: 17, text, count: chars.length(), }
    for start = 0; start <= chars.length(); start = start + 1 {
      for end = start; end <= chars.length(); end = end + 1 {
        match @rle.Sliceable::slice(run, start~, end~) {
          Ok(slice) => {
            assert_eq(
              slice.text,
              String::from_array(chars[start:end].to_owned()),
            )
            assert_eq(slice.count, end - start)
            assert_eq(slice.start_lv, 17 + start)
          }
          Err(_) => fail("valid scalar interval rejected")
        }
      }
    }
    assert_true(@rle.Sliceable::slice(run, start=-1, end=0) is Err(_))
    assert_true(
      @rle.Sliceable::slice(run, start=0, end=chars.length() + 1) is Err(_),
    )
  }
}

///|
test "legacy empty insert and astral neighbor preserve indexed edit semantics" {
  for cold in [false, true] {
    let doc = Document::new("legacy-empty-receiver")
    let empty = @core.Op::insert(0, [], "legacy-empty", 0, "", None, None)
    let astral = @core.Op::insert(
      1,
      [@core.RawVersion("legacy-empty", 0)],
      "legacy-empty",
      1,
      "😀",
      Some(@core.RawVersion("legacy-empty", 0)),
      None,
    )
    ignore(try! doc.apply_changes([empty, astral]))
    if cold {
      doc.invalidate_cache()
    }
    assert_eq(doc.to_text(), "😀")
    ignore(try! doc.insert(1, "X"))
    assert_eq(doc.to_text(), doc.tree.to_text())
    assert_eq(doc.to_text(), "X😀")
  }
}

///|
test "visible scalar packing agrees across warm cold and remote boundary edits" {
  for count in [255, 256, 257, 513, 1025] {
    let builder = StringBuilder()
    for i = 0; i < count; i = i + 1 {
      builder.write_string(if i % 3 == 0 { "😀" } else { "漢" })
    }
    let text = builder.to_string()
    let warm = Document::new("bounded-visible")
    let cold = Document::new("bounded-visible")
    let remote = Document::new("bounded-remote")
    ignore(try! warm.insert(0, text))
    ignore(try! cold.insert(0, text))
    ignore(try! remote.apply_changes(warm.get_all_ops()))
    cold.invalidate_cache()
    for doc in [warm, cold, remote] {
      assert_eq(doc.to_text(), text)
      assert_indexed_state_matches_tree(doc)
      ignore(try! doc.insert(254, "Z😀"))
      try! doc.delete_range(253, 257)
      assert_indexed_state_matches_tree(doc)
      // Compensation crosses the same physical run boundary without losing IDs.
      ignore(try! doc.undelete_if_deleted(254))
      assert_indexed_state_matches_tree(doc)
    }
    assert_eq(warm.to_text(), cold.to_text())
    assert_eq(warm.to_text(), remote.to_text())
  }
}
