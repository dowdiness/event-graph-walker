// Tests for Event Graph Walker

///|
test "walk empty frontier" {
  let graph = CausalGraph::new()
  let frontier = @core.Frontier::from_array([])
  let result = graph.walk_from_frontier(frontier)
  inspect(@rle.Spanning::span(result), content="0")
}

///|
test "walk single operation" {
  let graph = CausalGraph::new()

  // Add single operation with no parents
  let lv0 = try! graph.add_version([], "agent-1")
  let result = graph.walk_from_frontier(@core.Frontier::from_array([lv0]))
  let expanded = result.iter_units().collect()
  inspect(expanded.length(), content="1")
  inspect(expanded[0], content="0")
}

///|
test "walk linear history" {
  let graph = CausalGraph::new()

  // Create linear chain: 0 -> 1 -> 2 -> 3
  let lv0 = try! graph.add_version([], "agent-1")
  let lv1 = try! graph.add_version([lv0], "agent-1")
  let lv2 = try! graph.add_version([lv1], "agent-1")
  let lv3 = try! graph.add_version([lv2], "agent-1")
  let result = graph.walk_from_frontier(@core.Frontier::from_array([lv3]))

  // Linear history should compress to 1 run
  inspect(@rle.HasLength::length(result), content="1")
  inspect(@rle.Spanning::span(result), content="4")

  let expanded = result.iter_units().collect()
  inspect(expanded[0], content="0")
  inspect(expanded[1], content="1")
  inspect(expanded[2], content="2")
  inspect(expanded[3], content="3")
}

///|
test "walk diamond pattern (concurrent operations)" {
  let graph = CausalGraph::new()

  // Create diamond:
  //     0
  //    / \
  //   1   2
  //    \ /
  //     3
  let lv0 = try! graph.add_version([], "agent-1")
  let lv1 = try! graph.add_version([lv0], "agent-1")
  let lv2 = try! graph.add_version([lv0], "agent-2")
  let lv3 = try! graph.add_version([lv1, lv2], "agent-1")
  let result = graph.walk_from_frontier(@core.Frontier::from_array([lv3]))
  let expanded = result.iter_units().collect()

  // Should get all 4 operations
  inspect(expanded.length(), content="4")

  // lv0 must come first
  inspect(expanded[0], content="0")

  // lv1 and lv2 can be in any order (concurrent)
  // but both must come after lv0 and before lv3
  let has_lv1 = expanded.contains(1)
  let has_lv2 = expanded.contains(2)
  if !has_lv1 {
    abort("Result should contain lv1")
  }
  if !has_lv2 {
    abort("Result should contain lv2")
  }

  // lv3 must come last
  inspect(expanded[3], content="3")
}

///|
test "walk complex branching" {
  let graph = CausalGraph::new()

  // Create complex graph:
  //       0
  //      / \
  //     1   2
  //     |   |\
  //     3   4 5
  //      \ /
  //       6
  let lv0 = try! graph.add_version([], "agent-1")
  let lv1 = try! graph.add_version([lv0], "agent-1")
  let lv2 = try! graph.add_version([lv0], "agent-2")
  let lv3 = try! graph.add_version([lv1], "agent-1")
  let lv4 = try! graph.add_version([lv2], "agent-2")
  let _lv5 = try! graph.add_version([lv2], "agent-3")
  let lv6 = try! graph.add_version([lv3, lv4], "agent-1")
  let result = graph.walk_from_frontier(@core.Frontier::from_array([lv6]))
  let expanded = result.iter_units().collect()

  // Should get operations 0,1,2,3,4,6 (not 5, as it's not in the path to 6)
  inspect(expanded.length(), content="6")

  // Verify lv0 is first
  inspect(expanded[0], content="0")

  // Verify lv6 is last
  inspect(expanded[5], content="6")

  // Verify all expected versions are present
  if !expanded.contains(0) {
    abort("Should contain lv0")
  }
  if !expanded.contains(1) {
    abort("Should contain lv1")
  }
  if !expanded.contains(2) {
    abort("Should contain lv2")
  }
  if !expanded.contains(3) {
    abort("Should contain lv3")
  }
  if !expanded.contains(4) {
    abort("Should contain lv4")
  }

  // lv5 should NOT be present (not in path to lv6)
  if expanded.contains(5) {
    abort("Should NOT contain lv5")
  }
}

///|
test "walk with multiple frontier versions" {
  let graph = CausalGraph::new()

  // Create divergent branches:
  //     0
  //    / \
  //   1   2
  //   |   |
  //   3   4
  let lv0 = try! graph.add_version([], "agent-1")
  let lv1 = try! graph.add_version([lv0], "agent-1")
  let lv2 = try! graph.add_version([lv0], "agent-2")
  let lv3 = try! graph.add_version([lv1], "agent-1")
  let lv4 = try! graph.add_version([lv2], "agent-2")

  // Walk from frontier [3, 4] (both branches)
  let result = graph.walk_from_frontier(@core.Frontier::from_array([lv3, lv4]))
  let expanded = result.iter_units().collect()

  // Should get all operations
  inspect(expanded.length(), content="5")

  // lv0 should be first
  inspect(expanded[0], content="0")

  // All versions should be present
  for i = 0; i < 5; i = i + 1 {
    if !expanded.contains(i) {
      abort("Should contain lv\{i}")
    }
  }
}

///|
test "diff_frontiers_lvs for incremental update" {
  let graph = CausalGraph::new()

  // Create initial operations
  let _lv0 = try! graph.add_version([], "agent-1")
  let _lv1 = try! graph.add_version([0], "agent-1")
  let frontier1 = graph.get_frontier()

  // Add more operations
  let _lv2 = try! graph.add_version([1], "agent-1")
  let _lv3 = try! graph.add_version([2], "agent-1")
  let frontier2 = graph.get_frontier()

  // Calculate diff
  let (retreat_rle, advance_rle) = graph.diff_frontiers_lvs(
    frontier1, frontier2,
  )

  // No retreat LVs (moving forward)
  inspect(@rle.Spanning::span(retreat_rle), content="0")

  // Should have 2 advance LVs, compressed to 1 run (consecutive)
  inspect(@rle.HasLength::length(advance_rle), content="1")
  inspect(@rle.Spanning::span(advance_rle), content="2")

  // Verify advance LVs are correct (2 and 3)
  let advance_expanded = advance_rle.iter_units().collect()
  inspect(advance_expanded[0], content="2")
  inspect(advance_expanded[1], content="3")
}

///|
test "topological sort determinism" {
  // Test that concurrent operations have deterministic ordering
  let graph = CausalGraph::new()

  // Create concurrent operations with same parent
  let lv0 = try! graph.add_version([], "agent-1")
  let lv1 = try! graph.add_version([lv0], "agent-2")
  let lv2 = try! graph.add_version([lv0], "agent-3")
  let lv3 = try! graph.add_version([lv0], "agent-1")
  let result = graph.walk_from_frontier(
    @core.Frontier::from_array([lv1, lv2, lv3]),
  )
  let expanded = result.iter_units().collect()

  // lv0 must be first
  inspect(expanded[0], content="0")

  // Concurrent operations (1, 2, 3) should be sorted by LV for determinism
  inspect(expanded[1], content="1")
  inspect(expanded[2], content="2")
  inspect(expanded[3], content="3")
}

///|
test "walk_from_frontier linear compression" {
  let graph = CausalGraph::new()

  // Create linear chain: 0 -> 1 -> 2 -> ... -> 9
  let _lv0 = try! graph.add_version([], "agent-1")
  for i = 1; i < 10; i = i + 1 {
    let _ = try! graph.add_version([i - 1], "agent-1")
  }
  let result = graph.walk_from_frontier(graph.get_frontier())

  // 10 consecutive LVs should compress to exactly 1 run
  inspect(@rle.HasLength::length(result), content="1")
  inspect(@rle.Spanning::span(result), content="10")
}

///|
test "diff_frontiers_lvs compression ratio" {
  let graph = CausalGraph::new()

  // Build 100 linear operations
  let _lv0 = try! graph.add_version([], "agent-1")
  for i = 1; i < 100; i = i + 1 {
    let _ = try! graph.add_version([i - 1], "agent-1")
  }
  let empty = @core.Frontier::from_array([])
  let full = graph.get_frontier()
  let (retreat_rle, advance_rle) = graph.diff_frontiers_lvs(empty, full)

  // No retreat
  inspect(@rle.Spanning::span(retreat_rle), content="0")

  // 100 consecutive advance LVs -> 1 run
  inspect(@rle.HasLength::length(advance_rle), content="1")
  inspect(@rle.Spanning::span(advance_rle), content="100")
}
