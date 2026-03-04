///|
/// Tests for Frontier duplicate validation
test "frontier without duplicates passes validation" {
  let frontier = Frontier::from_array([1, 2, 3])
  inspect(frontier.has_duplicates(), content="false")
}

///|
test "frontier with duplicates detected" {
  let frontier = Frontier::from_array([1, 2, 2, 3])
  inspect(frontier.has_duplicates(), content="true")
}

///|
test "frontier with all duplicates detected" {
  let frontier = Frontier::from_array([5, 5, 5])
  inspect(frontier.has_duplicates(), content="true")
}

///|
test "empty frontier has no duplicates" {
  let frontier = Frontier::from_array([])
  inspect(frontier.has_duplicates(), content="false")
}

///|
test "single element frontier has no duplicates" {
  let frontier = Frontier::from_array([42])
  inspect(frontier.has_duplicates(), content="false")
}

///|
test "from_array_dedup removes duplicates" {
  let frontier = Frontier::from_array_dedup([1, 2, 2, 3, 1, 4])
  inspect(frontier.has_duplicates(), content="false")
  inspect(frontier.0.length(), content="4")
  inspect(frontier.0.contains(1), content="true")
  inspect(frontier.0.contains(2), content="true")
  inspect(frontier.0.contains(3), content="true")
  inspect(frontier.0.contains(4), content="true")
}

///|
test "from_array_dedup preserves order of first occurrence" {
  let frontier = Frontier::from_array_dedup([3, 1, 2, 1, 3])
  inspect(frontier.0[0], content="3")
  inspect(frontier.0[1], content="1")
  inspect(frontier.0[2], content="2")
}

///|
test "from_array_dedup on empty array" {
  let frontier = Frontier::from_array_dedup([])
  inspect(frontier.0.length(), content="0")
  inspect(frontier.has_duplicates(), content="false")
}

///|
test "from_array_dedup on unique array is identity" {
  let frontier = Frontier::from_array_dedup([1, 2, 3])
  inspect(frontier.0, content="[1, 2, 3]")
}
