///| Unit tests for FractionalIndex

///|
/// Test 1: Basic between — two keys with gap > 1
test "between: two keys with gap > 1" {
  let a = @fractional_index.FractionalIndex::new([100])
  let b = @fractional_index.FractionalIndex::new([200])
  let mid = @fractional_index.FractionalIndex::between(
    left=Some(a),
    right=Some(b),
  )
  inspect(mid, content="FractionalIndex([150])")
  // Verify ordering
  inspect(a < mid, content="true")
  inspect(mid < b, content="true")
}

///|
/// Test 2: None/None gives midpoint
test "between: None/None gives midpoint" {
  let mid = @fractional_index.FractionalIndex::between(left=None, right=None)
  inspect(mid, content="FractionalIndex([32768])")
}

///|
/// Test 3: None/right gives key before right
test "between: None/right gives key before right" {
  let r = @fractional_index.FractionalIndex::new([200])
  let mid = @fractional_index.FractionalIndex::between(left=None, right=Some(r))
  inspect(mid < r, content="true")
}

///|
/// Test 4: Left/None gives key after left
test "between: left/None gives key after left" {
  let l = @fractional_index.FractionalIndex::new([200])
  let mid = @fractional_index.FractionalIndex::between(left=Some(l), right=None)
  inspect(l < mid, content="true")
}

///|
/// Test 5: Adjacent integers — density! [5] and [6] MUST produce a valid key between them
test "between: adjacent integers [5] and [6] — density" {
  let a = @fractional_index.FractionalIndex::new([5])
  let b = @fractional_index.FractionalIndex::new([6])
  let mid = @fractional_index.FractionalIndex::between(
    left=Some(a),
    right=Some(b),
  )
  // mid must be strictly between a and b
  inspect(a < mid, content="true")
  inspect(mid < b, content="true")
  // The algorithm should emit [5, 32768] (lo=5, then right opens, mid at 32768)
  inspect(mid, content="FractionalIndex([5, 32768])")
}

///|
/// Test 6: Normalization — [5, 0] == [5]
test "normalization: trailing zeros stripped" {
  let a = @fractional_index.FractionalIndex::new([5, 0])
  let b = @fractional_index.FractionalIndex::new([5])
  inspect(a == b, content="true")
  inspect(a.length(), content="1")
}

///|
/// Test 7: Prefix case — [5] and [5, 100]
test "between: prefix case [5] and [5, 100]" {
  let a = @fractional_index.FractionalIndex::new([5])
  let b = @fractional_index.FractionalIndex::new([5, 100])
  let mid = @fractional_index.FractionalIndex::between(
    left=Some(a),
    right=Some(b),
  )
  // mid must be strictly between a and b
  inspect(a < mid, content="true")
  inspect(mid < b, content="true")
}

///|
/// Test 8: Minimal keys — None and [1]
test "between: minimal keys None and [1]" {
  let r = @fractional_index.FractionalIndex::new([1])
  let mid = @fractional_index.FractionalIndex::between(left=None, right=Some(r))
  inspect(mid < r, content="true")
  // [0] is the empty/normalized key, so between [] and [1] should give [0, 32768]
  inspect(mid, content="FractionalIndex([0, 32768])")
}

///|
/// Test 9: 20 sequential insertions stay ordered
test "sequential insertions: 20 items stay ordered" {
  let keys : Array[@fractional_index.FractionalIndex] = []
  // Insert at the end, one after another
  for i = 0; i < 20; i = i + 1 {
    let left = if keys.length() == 0 {
      None
    } else {
      Some(keys[keys.length() - 1])
    }
    let key = @fractional_index.FractionalIndex::between(left~, right=None)
    keys.push(key)
  }
  // Verify all keys are strictly ordered
  let mut all_ordered = true
  for i = 1; i < keys.length(); i = i + 1 {
    if !(keys[i - 1] < keys[i]) {
      all_ordered = false
    }
  }
  inspect(all_ordered, content="true")
  inspect(keys.length(), content="20")
}

///|
/// Test 10: Interleaving stays ordered
test "interleaving: insert between existing keys" {
  let a = @fractional_index.FractionalIndex::new([100])
  let b = @fractional_index.FractionalIndex::new([200])
  // Insert several keys between a and b
  let mut left = a
  let mut right = b
  let keys : Array[@fractional_index.FractionalIndex] = [a]
  for i = 0; i < 10; i = i + 1 {
    let mid = @fractional_index.FractionalIndex::between(
      left=Some(left),
      right=Some(right),
    )
    keys.push(mid)
    // Alternate: insert between left and mid, then between mid and right
    if i % 2 == 0 {
      right = mid
    } else {
      left = mid
    }
  }
  keys.push(b)
  // Sort and verify no duplicates
  keys.sort_by(fn(a, b) { a.compare(b) })
  let mut all_ordered = true
  for i = 1; i < keys.length(); i = i + 1 {
    if !(keys[i - 1] < keys[i]) {
      all_ordered = false
    }
  }
  inspect(all_ordered, content="true")
}

///|
/// Extra edge case: deeply adjacent keys can still produce midpoints
test "density: repeatedly bisect adjacent keys" {
  let mut a = @fractional_index.FractionalIndex::new([5])
  let mut b = @fractional_index.FractionalIndex::new([6])
  // Bisect 20 times — should always succeed
  for i = 0; i < 20; i = i + 1 {
    let mid = @fractional_index.FractionalIndex::between(
      left=Some(a),
      right=Some(b),
    )
    inspect(a < mid, content="true")
    inspect(mid < b, content="true")
    // Narrow the gap from alternating sides
    if i % 2 == 0 {
      b = mid
    } else {
      a = mid
    }
  }
}

///|
/// Edge case: left/None after a high-value key
test "between: left/None after max-ish key" {
  let l = @fractional_index.FractionalIndex::new([65535])
  let mid = @fractional_index.FractionalIndex::between(left=Some(l), right=None)
  inspect(l < mid, content="true")
  inspect(mid, content="FractionalIndex([65535, 32768])")
}

///|
/// Edge case: between [0] (which normalizes to []) and [1]
test "between: [0] and [1]" {
  let a = @fractional_index.FractionalIndex::new([0])
  let b = @fractional_index.FractionalIndex::new([1])
  // [0] normalizes to [], so this is between([], [1])
  let mid = @fractional_index.FractionalIndex::between(
    left=Some(a),
    right=Some(b),
  )
  inspect(a < mid, content="true")
  inspect(mid < b, content="true")
}

///|
/// Appending repeatedly should not grow the key depth while the current level
/// still has room.
test "between: append-heavy keys stay shallow" {
  let keys : Array[@fractional_index.FractionalIndex] = []
  let mut max_len = 0
  for i = 0; i < 20; i = i + 1 {
    let left = if keys.length() == 0 {
      None
    } else {
      Some(keys[keys.length() - 1])
    }
    let key = @fractional_index.FractionalIndex::between(left~, right=None)
    if key.length() > max_len {
      max_len = key.length()
    }
    keys.push(key)
  }
  inspect(max_len, content="1")
  inspect(keys[19], content="FractionalIndex([32787])")
}

///|
/// When the last component is saturated, appending can carry into an earlier
/// component instead of always growing deeper.
test "between: append can carry before growing deeper" {
  let l = @fractional_index.FractionalIndex::new([10, 65535])
  let mid = @fractional_index.FractionalIndex::between(left=Some(l), right=None)
  inspect(l < mid, content="true")
  inspect(mid, content="FractionalIndex([11])")
}
