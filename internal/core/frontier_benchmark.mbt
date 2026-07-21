///| Microbenchmarks for Frontier canonical construction.

///|
fn frontier_from_array_linear_for_benchmark(values : Array[Int]) -> Frontier {
  let deduped : Array[Int] = []
  for value in values {
    if !deduped.contains(value) {
      deduped.push(value)
    }
  }
  { values: deduped }
}

///|
fn frontier_from_array_preallocated_hashset_for_benchmark(
  values : Array[Int],
) -> Frontier {
  let seen : @hashset.HashSet[Int] = @hashset.HashSet(
    [],
    capacity=values.length(),
  )
  let deduped : Array[Int] = []
  for value in values {
    if seen.add_and_check(value) {
      deduped.push(value)
    }
  }
  { values: deduped }
}

///|
test "frontier construction - production hybrid - 5 unique" (b : @bench.T) {
  let values = [1, 2, 3, 4, 5]
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear - 5 unique" (b : @bench.T) {
  let values = [1, 2, 3, 4, 5]
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - production hybrid - 5 with duplicates" (
  b : @bench.T,
) {
  let values = [1, 2, 1, 3, 2]
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear - 5 with duplicates" (b : @bench.T) {
  let values = [1, 2, 1, 3, 2]
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - production hybrid - 20 unique" (b : @bench.T) {
  let values = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
  ]
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear - 20 unique" (b : @bench.T) {
  let values = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
  ]
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - production hybrid - 50 unique" (b : @bench.T) {
  let values = Array::makei(50, i => i)
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear - 50 unique" (b : @bench.T) {
  let values = Array::makei(50, i => i)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - production hybrid - 100 unique" (b : @bench.T) {
  let values = Array::makei(100, i => i)
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear - 100 unique" (b : @bench.T) {
  let values = Array::makei(100, i => i)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - production hybrid - 500 unique" (b : @bench.T) {
  let values = Array::makei(500, i => i)
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear - 500 unique" (b : @bench.T) {
  let values = Array::makei(500, i => i)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - linear - 64 unique" (b : @bench.T) {
  let values = Array::makei(64, i => i)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - preallocated hash set - 64 unique" (b : @bench.T) {
  let values = Array::makei(64, i => i)
  b.bench(() => {
    b.keep(frontier_from_array_preallocated_hashset_for_benchmark(values))
  })
}

///|
test "frontier construction - preallocated hash set - 65 unique" (b : @bench.T) {
  let values = Array::makei(65, i => i)
  b.bench(() => {
    b.keep(frontier_from_array_preallocated_hashset_for_benchmark(values))
  })
}

///|
test "frontier construction - linear - 65 unique" (b : @bench.T) {
  let values = Array::makei(65, i => i)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - preallocated hash set - 80 unique" (b : @bench.T) {
  let values = Array::makei(80, i => i)
  b.bench(() => {
    b.keep(frontier_from_array_preallocated_hashset_for_benchmark(values))
  })
}

///|
test "frontier construction - linear - 80 unique" (b : @bench.T) {
  let values = Array::makei(80, i => i)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - preallocated hash set - 96 unique" (b : @bench.T) {
  let values = Array::makei(96, i => i)
  b.bench(() => {
    b.keep(frontier_from_array_preallocated_hashset_for_benchmark(values))
  })
}

///|
test "frontier construction - linear - 96 unique" (b : @bench.T) {
  let values = Array::makei(96, i => i)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - preallocated hash set - 100 unique" (b : @bench.T) {
  let values = Array::makei(100, i => i)
  b.bench(() => {
    b.keep(frontier_from_array_preallocated_hashset_for_benchmark(values))
  })
}

///|
test "frontier construction - preallocated hash set - 500 unique" (b : @bench.T) {
  let values = Array::makei(500, i => i)
  b.bench(() => {
    b.keep(frontier_from_array_preallocated_hashset_for_benchmark(values))
  })
}

///|
test "frontier construction - production hybrid - 100 duplicate-heavy" (
  b : @bench.T,
) {
  let values = Array::makei(100, i => i % 8)
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear - 100 duplicate-heavy" (b : @bench.T) {
  let values = Array::makei(100, i => i % 8)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - preallocated hash set - 100 duplicate-heavy" (
  b : @bench.T,
) {
  let values = Array::makei(100, i => i % 8)
  b.bench(() => {
    b.keep(frontier_from_array_preallocated_hashset_for_benchmark(values))
  })
}
