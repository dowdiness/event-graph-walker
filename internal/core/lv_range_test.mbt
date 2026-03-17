///|
test "LvRange - basic construction" {
  let r = @core.LvRange::{ start: 0, count: 5 }
  inspect(r.start, content="0")
  inspect(r.count, content="5")
  inspect(r.end(), content="5")
}

///|
test "LvRange - contains" {
  let r = @core.LvRange::{ start: 3, count: 4 }
  // Contains 3, 4, 5, 6
  inspect(r.contains(2), content="false")
  inspect(r.contains(3), content="true")
  inspect(r.contains(6), content="true")
  inspect(r.contains(7), content="false")
}

///|
test "LvRange - HasLength and Spanning" {
  let r = @core.LvRange::{ start: 10, count: 3 }
  inspect(@rle.HasLength::length(r), content="3")
  inspect(@rle.Spanning::span(r), content="3")
  inspect(@rle.Spanning::logical_length(r), content="3")
}

///|
test "LvRange - Mergeable contiguous ranges" {
  let a = @core.LvRange::{ start: 0, count: 3 }
  let b = @core.LvRange::{ start: 3, count: 2 }
  inspect(@rle.Mergeable::can_merge(a, b), content="true")
  let merged = @rle.Mergeable::merge(a, b)
  inspect(merged.start, content="0")
  inspect(merged.count, content="5")
}

///|
test "LvRange - Mergeable non-contiguous ranges" {
  let a = @core.LvRange::{ start: 0, count: 3 }
  let b = @core.LvRange::{ start: 5, count: 2 }
  inspect(@rle.Mergeable::can_merge(a, b), content="false")
}

///|
test "LvRange - FromRange" {
  let r : @core.LvRange = @rle.FromRange::from_range(10, 5)
  inspect(r.start, content="10")
  inspect(r.count, content="5")
}

///|
test "LvRange - Addressable" {
  let r = @core.LvRange::{ start: 10, count: 5 }
  // global_start is ignored for index-carrying types
  inspect(@rle.Addressable::address(r, 0, 0), content="10")
  inspect(@rle.Addressable::address(r, 0, 2), content="12")
  inspect(@rle.Addressable::address(r, 0, 4), content="14")
}

///|
test "LvRange - Rle from_sorted_ints" {
  let rle : @rle.Rle[@core.LvRange] = @rle.Rle::from_sorted_ints([
    0, 1, 2, 5, 6, 7,
  ])
  // 2 runs: [0..3) and [5..8)
  inspect(@rle.HasLength::length(rle), content="2")
  inspect(@rle.Spanning::span(rle), content="6")
}

///|
test "LvRange - Rle from_sorted_ints consecutive" {
  let rle : @rle.Rle[@core.LvRange] = @rle.Rle::from_sorted_ints([0, 1, 2, 3, 4])
  // 1 run: [0..5)
  inspect(@rle.HasLength::length(rle), content="1")
  inspect(@rle.Spanning::span(rle), content="5")
}

///|
test "LvRange - Rle iter_units roundtrip" {
  let ints = [0, 1, 2, 5, 6, 7]
  let rle : @rle.Rle[@core.LvRange] = @rle.Rle::from_sorted_ints(ints)
  let expanded = rle.iter_units().collect()
  inspect(expanded, content="[0, 1, 2, 5, 6, 7]")
}

///|
test "LvRange - Rle from_sorted_ints empty" {
  let rle : @rle.Rle[@core.LvRange] = @rle.Rle::from_sorted_ints([])
  inspect(@rle.HasLength::is_empty(rle), content="true")
  inspect(@rle.Spanning::span(rle), content="0")
}

///|
test "LvRange - Rle from_sorted_ints single" {
  let rle : @rle.Rle[@core.LvRange] = @rle.Rle::from_sorted_ints([42])
  inspect(@rle.HasLength::length(rle), content="1")
  inspect(@rle.Spanning::span(rle), content="1")
  let expanded = rle.iter_units().collect()
  inspect(expanded, content="[42]")
}
