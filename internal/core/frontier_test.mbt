///|
/// Tests for Frontier canonicalization and isolation
test "frontier without duplicates passes validation" {
  let frontier = Frontier::from_array([1, 2, 3])
  inspect(frontier.has_duplicates(), content="false")
}

///|
test "frontier debug and show rendering" {
  let frontier = Frontier::from_array([1, 2])
  inspect(@debug.to_string(frontier), content="Frontier([1, 2])")
  inspect(frontier.to_string(), content="Frontier([1, 2])")
}

///|
test "frontier with duplicates is canonicalized" {
  let frontier = Frontier::from_array([1, 2, 2, 3])
  inspect(frontier.has_duplicates(), content="false")
  @debug.debug_inspect(frontier.to_array(), content="[1, 2, 3]")
}

///|
test "frontier with all duplicates is canonicalized" {
  let frontier = Frontier::from_array([5, 5, 5])
  inspect(frontier.has_duplicates(), content="false")
  @debug.debug_inspect(frontier.to_array(), content="[5]")
}

///|
test "empty frontier has no duplicates" {
  let frontier = Frontier::from_array([])
  inspect(frontier.has_duplicates(), content="false")
  inspect(frontier.length(), content="0")
}

///|
test "single element frontier has no duplicates" {
  let frontier = Frontier::from_array([42])
  inspect(frontier.has_duplicates(), content="false")
  inspect(frontier.length(), content="1")
  @debug.debug_inspect(frontier.to_array(), content="[42]")
}

///|
test "from_array_dedup remains compatible" {
  let frontier = Frontier::from_array_dedup([1, 2, 2, 3, 1, 4])
  inspect(frontier.has_duplicates(), content="false")
  @debug.debug_inspect(frontier.to_array(), content="[1, 2, 3, 4]")
}

///|
test "from_array preserves order of first occurrence" {
  let frontier = Frontier::from_array([3, 1, 2, 1, 3])
  @debug.debug_inspect(frontier.to_array(), content="[3, 1, 2]")
}

///|
test "from_array_dedup on empty array" {
  let frontier = Frontier::from_array_dedup([])
  inspect(frontier.length(), content="0")
  inspect(frontier.has_duplicates(), content="false")
}

///|
test "from_array_dedup on unique array is identity" {
  let frontier = Frontier::from_array_dedup([1, 2, 3])
  @debug.debug_inspect(frontier.to_array(), content="[1, 2, 3]")
}

///|
test "from_array isolates source array mutations" {
  let source = [1, 2, 3]
  let frontier = Frontier::from_array(source)
  source[0] = 99
  source.push(4)
  @debug.debug_inspect(frontier.to_array(), content="[1, 2, 3]")
}

///|
test "from_array isolates empty source mutation" {
  let source : Array[Int] = []
  let frontier = Frontier::from_array(source)
  source.push(1)
  @debug.debug_inspect(frontier.to_array(), content="[]")
}

///|
test "from_array isolates singleton source mutation" {
  let source = [42]
  let frontier = Frontier::from_array(source)
  source[0] = 99
  source.push(1)
  @debug.debug_inspect(frontier.to_array(), content="[42]")
}

///|
test "to_array is a defensive copy" {
  let frontier = Frontier::from_array([1, 2, 3])
  let output = frontier.to_array()
  output[0] = 99
  output.push(4)
  @debug.debug_inspect(frontier.to_array(), content="[1, 2, 3]")
}

///|
test "frontier JSON is a bare array" {
  let frontier = Frontier::from_array([3, 1, 2, 1])
  inspect(frontier.to_json().stringify(), content="[3,1,2]")
}

///|
test "frontier JSON decoding canonicalizes duplicates" {
  let json = @json.parse("[3,1,3,2,1]")
  let frontier : Frontier = @json.from_json(json)
  @debug.debug_inspect(frontier.to_array(), content="[3, 1, 2]")
  inspect(frontier.to_json().stringify(), content="[3,1,2]")
}
