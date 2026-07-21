///| Microbenchmarks for Frontier canonical construction.

///|
/// Reference implementation used to expose the cost of quadratic deduplication.
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
test "frontier construction - canonical - 5 unique" (b : @bench.T) {
  let values = [1, 2, 3, 4, 5]
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear reference - 5 unique" (b : @bench.T) {
  let values = [1, 2, 3, 4, 5]
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - canonical - 5 with duplicates" (b : @bench.T) {
  let values = [1, 2, 1, 3, 2]
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear reference - 5 with duplicates" (
  b : @bench.T,
) {
  let values = [1, 2, 1, 3, 2]
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - canonical - 20 unique" (b : @bench.T) {
  let values = Array::makei(20, i => i)
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear reference - 20 unique" (b : @bench.T) {
  let values = Array::makei(20, i => i)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - canonical - 50 unique" (b : @bench.T) {
  let values = Array::makei(50, i => i)
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear reference - 50 unique" (b : @bench.T) {
  let values = Array::makei(50, i => i)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - canonical - 100 unique" (b : @bench.T) {
  let values = Array::makei(100, i => i)
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear reference - 100 unique" (b : @bench.T) {
  let values = Array::makei(100, i => i)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - canonical - 500 unique" (b : @bench.T) {
  let values = Array::makei(500, i => i)
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear reference - 500 unique" (b : @bench.T) {
  let values = Array::makei(500, i => i)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier construction - canonical - 100 duplicate-heavy" (b : @bench.T) {
  let values = Array::makei(100, i => i % 8)
  b.bench(() => b.keep(Frontier::from_array(values)))
}

///|
test "frontier construction - linear reference - 100 duplicate-heavy" (
  b : @bench.T,
) {
  let values = Array::makei(100, i => i % 8)
  b.bench(() => b.keep(frontier_from_array_linear_for_benchmark(values)))
}

///|
test "frontier advance - 5 tips, 2 parents" (b : @bench.T) {
  let frontier = Frontier::from_array([1, 2, 3, 4, 5])
  let parents = [2, 4]
  b.bench(() => b.keep(frontier.advance(6, parents)))
}

///|
test "frontier advance - rebuild reference - 5 tips, 2 parents" (b : @bench.T) {
  let frontier = Frontier::from_array([1, 2, 3, 4, 5])
  let parents = [2, 4]
  b.bench(() => {
    let next = frontier.to_array().filter(value => !parents.contains(value))
    next.push(6)
    b.keep(Frontier::from_array(next))
  })
}
