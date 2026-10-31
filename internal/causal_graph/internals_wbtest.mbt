///|
/// Queries own their state; retaining one result cannot affect another query.
test "interval queries preserve branches and previously returned coverage" {
  let g = CausalGraph::new()
  let a = g.add_version([], "a")
  let b = g.add_version([a], "a")
  let c = g.add_version([a], "b")
  let d = g.add_version([b], "a")
  let left = @core.Frontier::from_array([d])
  let right = @core.Frontier::from_array([c])
  let saved = g.walk_from_frontier(left)
  for _ in 0..<3 {
    assert_eq(g.walk_from_frontier(right).iter_units().collect(), [a, c])
    assert_eq(saved.iter_units().collect(), [a, b, d])
    let (retreat, advance) = g.diff_frontiers_lvs(left, right)
    assert_eq(retreat.iter_units(direction=Backward).collect(), [d, b])
    assert_eq(advance.iter_units().collect(), [c])
    let (empty_a, empty_b) = g.diff_frontiers_lvs(left, left)
    assert_true(empty_a.is_empty())
    assert_true(empty_b.is_empty())
    assert_true(g.is_ancestor(a, d))
    assert_false(g.is_ancestor(d, a))
    assert_false(g.is_ancestor(c, d))
    assert_true(g.is_ancestor(a, a))
  }
  ignore(g.add_version([d, c], "merged"))
  assert_eq(saved.iter_units().collect(), [a, b, d])
  assert_eq(g.walk_from_frontier(g.get_frontier()).iter_units().collect(), [
    0, 1, 2, 3, 4,
  ])
}

///|
test "diagnostic children counts include implicit edges and duplicate head edges" {
  let g = CausalGraph::new()
  let a = g.add_version([], "a")
  let b = g.add_version([a], "a")
  let c = g.add_version([a], "b")
  let d = g.add_version([b, c, c], "c")
  assert_eq(g.children_counts(), [2, 1, 2, 0])
  assert_eq(d, 3)
}

///|
test "large linear coverage and partial retreat stay compressed" {
  let g = CausalGraph::new()
  for i in 0..<500 {
    ignore(g.add_version(if i == 0 { [] } else { [i - 1] }, "a"))
  }
  let all = g.walk_from_frontier(g.get_frontier())
  assert_eq(all.iter().collect(), [{ start: 0, count: 500, }])
  assert_eq(all.cardinality(), 500)
  for i in 0..<50 {
    assert_true(g.is_ancestor(i, 499))
  }
  assert_false(g.is_ancestor(499, 0))
  assert_false(g.is_ancestor(250, 100))
  let (retreat, advance) = g.diff_frontiers_lvs(
    g.get_frontier(),
    @core.Frontier::from_array([249]),
  )
  assert_eq(retreat.iter().collect(), [{ start: 250, count: 250, }])
  assert_eq(retreat.iter_units(direction=Backward).take(3).collect(), [
    499, 498, 497,
  ])
  assert_true(advance.is_empty())
}

///|
test "coverage chooses greatest run prefixes regardless of frontier order" {
  let g = CausalGraph::new()
  for i in 0..<100 {
    ignore(g.add_version(if i == 0 { [] } else { [i - 1] }, "a"))
  }
  let branch = g.add_version([37], "b")
  for heads in [[99, branch], [branch, 99]] {
    assert_eq(
      g.walk_from_frontier(@core.Frontier::from_array(heads)).iter().collect(),
      [{ start: 0, count: 101, }],
    )
  }
  assert_eq(
    g.walk_from_frontier(@core.Frontier::from_array([branch])).iter().collect(),
    [{ start: 0, count: 38, }, { start: 100, count: 1, }],
  )
}
