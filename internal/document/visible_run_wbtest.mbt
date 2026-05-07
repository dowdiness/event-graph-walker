///| Whitebox tests for VisibleRun type and trait implementations

///|
test "VisibleRun: span returns count" {
  let run : VisibleRun = { start_lv: 0, text: "hello", count: 5 }
  inspect(@rle.Spanning::span(run), content="5")
}

///|
test "VisibleRun: logical_length returns text length" {
  let run : VisibleRun = { start_lv: 0, text: "hello", count: 5 }
  inspect(@rle.Spanning::logical_length(run), content="5")
}

///|
test "VisibleRun: can_merge consecutive LVs" {
  let a : VisibleRun = { start_lv: 0, text: "ab", count: 2 }
  let b : VisibleRun = { start_lv: 2, text: "cd", count: 2 }
  inspect(@rle.Mergeable::can_merge(a, b), content="true")
}

///|
test "VisibleRun: cannot merge non-consecutive LVs" {
  let a : VisibleRun = { start_lv: 0, text: "ab", count: 2 }
  let b : VisibleRun = { start_lv: 5, text: "cd", count: 2 }
  inspect(@rle.Mergeable::can_merge(a, b), content="false")
}

///|
test "VisibleRun: merge concatenates text and counts" {
  let a : VisibleRun = { start_lv: 0, text: "ab", count: 2 }
  let b : VisibleRun = { start_lv: 2, text: "cd", count: 2 }
  let merged = @rle.Mergeable::merge(a, b)
  inspect(merged.start_lv, content="0")
  inspect(merged.text, content="abcd")
  inspect(merged.count, content="4")
}

///|
test "VisibleRun: slice extracts subrange" {
  let run : VisibleRun = { start_lv: 10, text: "abcde", count: 5 }
  let sliced = @rle.Sliceable::slice(run, start=1, end=4)
  inspect(sliced is Ok(_), content="true")
  match sliced {
    Ok(s) => {
      inspect(s.start_lv, content="11")
      inspect(s.text, content="bcd")
      inspect(s.count, content="3")
    }
    Err(_) => ()
  }
}

///|
test "VisibleRun: Rle append merges consecutive runs" {
  let rle : @rle.Rle[VisibleRun] = @rle.Rle::new()
  let _ = rle.append({ start_lv: 0, text: "a", count: 1 })
  let _ = rle.append({ start_lv: 1, text: "b", count: 1 })
  let _ = rle.append({ start_lv: 2, text: "c", count: 1 })
  // All three should merge into one run
  inspect(@rle.HasLength::length(rle), content="1")
  inspect(@rle.Spanning::span(rle), content="3")
}

///|
test "VisibleRun: Rle append keeps non-consecutive runs separate" {
  let rle : @rle.Rle[VisibleRun] = @rle.Rle::new()
  let _ = rle.append({ start_lv: 0, text: "ab", count: 2 })
  let _ = rle.append({ start_lv: 5, text: "cd", count: 2 })
  // Non-consecutive LVs — two separate runs
  inspect(@rle.HasLength::length(rle), content="2")
  inspect(@rle.Spanning::span(rle), content="4")
}

///|
test "VisibleRun: Rle find locates correct position" {
  let rle : @rle.Rle[VisibleRun] = @rle.Rle::new()
  let _ = rle.append({ start_lv: 0, text: "abc", count: 3 })
  let _ = rle.append({ start_lv: 10, text: "de", count: 2 })
  // Position 0 → run 0, offset 0
  @debug.debug_inspect(
    rle.find(0),
    content=(
      #|Some({ run: 0, offset: 0 })
    ),
  )
  // Position 2 → run 0, offset 2
  @debug.debug_inspect(
    rle.find(2),
    content=(
      #|Some({ run: 0, offset: 2 })
    ),
  )
  // Position 3 → run 1, offset 0
  @debug.debug_inspect(
    rle.find(3),
    content=(
      #|Some({ run: 1, offset: 0 })
    ),
  )
  // Position 4 → run 1, offset 1
  @debug.debug_inspect(
    rle.find(4),
    content=(
      #|Some({ run: 1, offset: 1 })
    ),
  )
}

///|
test "item_offset_to_utf16: basic ASCII" {
  inspect(item_offset_to_utf16("hello", 0), content="0")
  inspect(item_offset_to_utf16("hello", 3), content="3")
  inspect(item_offset_to_utf16("hello", 5), content="5")
}
