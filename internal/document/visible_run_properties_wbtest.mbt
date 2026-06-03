///| QuickCheck properties for VisibleRun slice/merge invariants.

///|
fn single_codepoint_chunk(rs : @splitmix.RandomState) -> String {
  match rs.next_uint64().to_int().abs() % 5 {
    0 => "a"
    1 => "b"
    2 => "c"
    3 => "\u{1F600}" // 😀
    _ => "你"
  }
}

///|
fn join_chunks(chunks : Array[String]) -> String {
  let sb = StringBuilder::new()
  for chunk in chunks {
    sb.write_string(chunk)
  }
  sb.to_string()
}

///|
struct VisibleRunModel {
  start_lv : Int
  chunks : Array[String]
  text : String
} derive(Debug)

///|
impl @quickcheck.Arbitrary for VisibleRunModel with fn arbitrary(
  _size,
  random_state,
) {
  let rs = random_state.split()
  let chunk_count = rs.next_uint64().to_int().abs() % 6 + 1
  let chunks : Array[String] = []
  if rs.next_uint64().to_int().abs() % 2 == 0 {
    chunks.push("\u{1F600}")
  }
  for _ in chunks.length()..<chunk_count {
    chunks.push(single_codepoint_chunk(rs))
  }
  let start_lv = rs.next_uint64().to_int().abs() % 20
  { start_lv, chunks, text: join_chunks(chunks) }
}

///|

///|
fn model_to_run(model : VisibleRunModel) -> VisibleRun {
  { start_lv: model.start_lv, text: model.text, count: model.chunks.length() }
}

///|
struct VisibleRunSlice {
  model : VisibleRunModel
  start : Int
  end : Int
} derive(Debug)

///|
impl @quickcheck.Arbitrary for VisibleRunSlice with fn arbitrary(
  _size,
  random_state,
) {
  let rs = random_state.split()
  let model : VisibleRunModel = @quickcheck.Arbitrary::arbitrary(0, rs)
  let max = model.chunks.length()
  let a = rs.next_uint64().to_int().abs() % (max + 1)
  let b = rs.next_uint64().to_int().abs() % (max + 1)
  let start = if a <= b { a } else { b }
  let end = if a <= b { b } else { a }
  { model, start, end }
}

///|

///|
struct VisibleRunSplit {
  model : VisibleRunModel
  split : Int
} derive(Debug)

///|
impl @quickcheck.Arbitrary for VisibleRunSplit with fn arbitrary(
  _size,
  random_state,
) {
  let rs = random_state.split()
  let model : VisibleRunModel = @quickcheck.Arbitrary::arbitrary(0, rs)
  let count = model.chunks.length()
  let split = if count <= 1 {
    0
  } else {
    rs.next_uint64().to_int().abs() % (count - 1) + 1
  }
  { model, split }
}

///|

///|
fn prop_visible_slice_metadata(query : VisibleRunSlice) -> Bool {
  let run = model_to_run(query.model)
  match run.slice(start=query.start, end=query.end) {
    Ok(segment) =>
      segment.start_lv == run.start_lv + query.start &&
      segment.count == query.end - query.start
    Err(_) => false
  }
}

///|
test "property: VisibleRun::slice preserves start_lv and count" {
  let samples : Array[VisibleRunSlice] = @quickcheck.samples(32)
  for sample in samples {
    inspect(prop_visible_slice_metadata(sample), content="true")
  }
}

///|
fn prop_visible_slice_full_run(model : VisibleRunModel) -> Bool {
  let run = model_to_run(model)
  match run.slice(start=0, end=run.count) {
    Ok(all) => all == run
    Err(_) => false
  }
}

///|
test "property: slicing full visible run returns original" {
  let samples : Array[VisibleRunModel] = @quickcheck.samples(32)
  for sample in samples {
    inspect(prop_visible_slice_full_run(sample), content="true")
  }
}

///|
fn prop_visible_logical_length(model : VisibleRunModel) -> Bool {
  let run = model_to_run(model)
  @rle.Spanning::logical_length(run) == run.text.length()
}

///|
test "property: logical_length matches UTF-16 text length" {
  let samples : Array[VisibleRunModel] = @quickcheck.samples(32)
  for sample in samples {
    inspect(prop_visible_logical_length(sample), content="true")
  }
}

///|
fn prop_visible_slice_singletons_round_trip(model : VisibleRunModel) -> Bool {
  let run = model_to_run(model)
  if run.count == 0 {
    return true
  }
  for offset in 0..<run.count {
    let segment = match run.slice(start=offset, end=offset + 1) {
      Ok(seg) => seg
      Err(_) => return false
    }
    if segment.text != model.chunks[offset] {
      return false
    }
    if segment.start_lv != run.start_lv + offset {
      return false
    }
    if segment.count != 1 {
      return false
    }
  }
  true
}

///|
test "property: one-item VisibleRun slice returns exact generated chunk" {
  let samples : Array[VisibleRunModel] = @quickcheck.samples(32)
  for sample in samples {
    inspect(prop_visible_slice_singletons_round_trip(sample), content="true")
  }
}

///|
fn prop_visible_adjacent_slices_merge_back(
  split_query : VisibleRunSplit,
) -> Bool {
  let run = model_to_run(split_query.model)
  let split = split_query.split
  let left = match run.slice(start=0, end=split) {
    Ok(left) => left
    Err(_) => return false
  }
  let right = match run.slice(start=split, end=run.count) {
    Ok(right) => right
    Err(_) => return false
  }
  @rle.Mergeable::can_merge(left, right) &&
  @rle.Mergeable::merge(left, right) == run
}

///|
test "property: adjacent slice merges reconstruct original run" {
  let samples : Array[VisibleRunSplit] = @quickcheck.samples(32)
  for sample in samples {
    inspect(prop_visible_adjacent_slices_merge_back(sample), content="true")
  }
}

///|
fn prop_visible_slice_invalid_bounds(model : VisibleRunModel) -> Bool {
  let run = model_to_run(model)
  let too_long = run.slice(start=0, end=run.count + 1)
  let negative_start = run.slice(start=-1, end=0)
  let reversed = run.slice(start=run.count, end=0)
  too_long is Err(_) && negative_start is Err(_) && reversed is Err(_)
}

///|
test "property: invalid slice bounds return errors" {
  let samples : Array[VisibleRunModel] = @quickcheck.samples(16)
  for sample in samples {
    inspect(prop_visible_slice_invalid_bounds(sample), content="true")
  }
}
