// Whitebox tests for flat-array internals: children index, gen-counter,
// query buffer reuse, topological sort cleanup, and DirectedGraph trait.

// === Children index correctness ===

///|
test "children index: linear chain" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv1], "a")
  inspect(g.children[lv0], content="[1]")
  inspect(g.children[lv1], content="[2]")
  inspect(g.children[lv2], content="[]")
}

///|
test "children index: diamond" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv0], "b")
  let lv3 = try! g.add_version([lv1, lv2], "a")
  // lv0 has two children
  let c0 = g.children[lv0].copy()
  c0.sort()
  inspect(c0, content="[1, 2]")
  // lv1 and lv2 both have lv3 as child
  inspect(g.children[lv1], content="[3]")
  inspect(g.children[lv2], content="[3]")
  inspect(g.children[lv3], content="[]")
}

///|
test "children index: multiple roots" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([], "b")
  let lv2 = try! g.add_version([lv0, lv1], "a")
  inspect(g.children[lv0], content="[2]")
  inspect(g.children[lv1], content="[2]")
  inspect(g.children[lv2], content="[]")
}

// === Generation counter reuse ===

///|
test "is_ancestor: repeated calls reuse buffer" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv1], "a")
  let lv3 = try! g.add_version([lv2], "a")
  // Multiple calls should produce correct results via gen counter reuse
  inspect(g.is_ancestor(lv0, lv3), content="true")
  inspect(g.is_ancestor(lv3, lv0), content="false")
  inspect(g.is_ancestor(lv1, lv3), content="true")
  inspect(g.is_ancestor(lv2, lv0), content="false")
  inspect(g.is_ancestor(lv0, lv0), content="true")
  // gen should have been bumped for each non-trivial call
  inspect(g.query_gen > 0, content="true")
}

///|
test "is_ancestor: after adding more versions" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  inspect(g.is_ancestor(lv0, lv1), content="true")
  // Add more versions — buffer should grow
  let lv2 = try! g.add_version([lv1], "a")
  let lv3 = try! g.add_version([lv2], "a")
  // Old queries still work after buffer growth
  inspect(g.is_ancestor(lv0, lv3), content="true")
  inspect(g.is_ancestor(lv3, lv1), content="false")
}

// === graph_diff with two-buffer correctness ===

///|
test "graph_diff: disjoint branches" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a") // branch A
  let lv2 = try! g.add_version([lv0], "b") // branch B
  let from = @core.Frontier::from_array([lv1])
  let to = @core.Frontier::from_array([lv2])
  let (retreat, advance) = g.graph_diff(from, to)
  // retreat = lv1 (in from, not in to)
  inspect(retreat, content="[1]")
  // advance = lv2 (in to, not in from)
  inspect(advance, content="[2]")
}

///|
test "graph_diff: identical frontiers" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let frontier = @core.Frontier::from_array([lv1])
  let (retreat, advance) = g.graph_diff(frontier, frontier)
  inspect(retreat.length(), content="0")
  inspect(advance.length(), content="0")
}

///|
test "graph_diff: advance only" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv1], "a")
  let from = @core.Frontier::from_array([lv0])
  let to = @core.Frontier::from_array([lv2])
  let (retreat, advance) = g.graph_diff(from, to)
  inspect(retreat.length(), content="0")
  let sorted_advance = advance.copy()
  sorted_advance.sort()
  inspect(sorted_advance, content="[1, 2]")
}

///|
test "graph_diff: repeated calls" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv0], "b")
  let lv3 = try! g.add_version([lv1], "a")
  // Call graph_diff multiple times — gen counter must handle it
  let (r1, a1) = g.graph_diff(
    @core.Frontier::from_array([lv1]),
    @core.Frontier::from_array([lv2]),
  )
  inspect(r1, content="[1]")
  inspect(a1, content="[2]")
  let (r2, a2) = g.graph_diff(
    @core.Frontier::from_array([lv3]),
    @core.Frontier::from_array([lv2]),
  )
  let sorted_r2 = r2.copy()
  sorted_r2.sort()
  inspect(sorted_r2, content="[1, 3]")
  inspect(a2, content="[2]")
  // And again with same args — must not be confused by previous calls
  let (r3, a3) = g.graph_diff(
    @core.Frontier::from_array([lv1]),
    @core.Frontier::from_array([lv2]),
  )
  inspect(r3, content="[1]")
  inspect(a3, content="[2]")
}

// === topological_sort cleanup ===

///|
test "walk_from_frontier: repeated calls produce consistent results" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv1], "a")
  let frontier = @core.Frontier::from_array([lv2])
  // Call twice — int_buf cleanup must be correct for second call to work
  let r1 = g.walk_from_frontier(frontier)
  let r2 = g.walk_from_frontier(frontier)
  let e1 = r1.iter_units().collect()
  let e2 = r2.iter_units().collect()
  inspect(e1, content="[0, 1, 2]")
  inspect(e2, content="[0, 1, 2]")
}

///|
test "walk_from_frontier: different subsets reuse buffer correctly" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv0], "b")
  let lv3 = try! g.add_version([lv1], "a")
  // Walk from lv3 (should get lv0, lv1, lv3)
  let r1 = g.walk_from_frontier(@core.Frontier::from_array([lv3]))
  let e1 = r1.iter_units().collect()
  inspect(e1, content="[0, 1, 3]")
  // Walk from lv2 (should get lv0, lv2) — different subset, same buffers
  let r2 = g.walk_from_frontier(@core.Frontier::from_array([lv2]))
  let e2 = r2.iter_units().collect()
  inspect(e2, content="[0, 2]")
  // Walk from both (should get all 4)
  let r3 = g.walk_from_frontier(@core.Frontier::from_array([lv2, lv3]))
  let e3 = r3.iter_units().collect()
  inspect(e3, content="[0, 1, 2, 3]")
}

// === diff_frontiers_lvs: topological ordering ===

///|
test "diff_frontiers_lvs: advance is topologically ordered" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv1], "a")
  let lv3 = try! g.add_version([lv2], "a")
  let from = @core.Frontier::from_array([lv0])
  let to = @core.Frontier::from_array([lv3])
  let (retreat_rle, advance_rle) = g.diff_frontiers_lvs(from, to)
  inspect(@rle.Spanning::span(retreat_rle), content="0")
  let advance = advance_rle.iter_units().collect()
  // Must be in topological order: 1, 2, 3
  inspect(advance, content="[1, 2, 3]")
}

///|
test "diff_frontiers_lvs: retreat is reverse topologically ordered" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv1], "a")
  let lv3 = try! g.add_version([lv0], "b")
  let from = @core.Frontier::from_array([lv2])
  let to = @core.Frontier::from_array([lv3])
  let (retreat_rle, advance_rle) = g.diff_frontiers_lvs(from, to)
  let retreat = retreat_rle.iter_units().collect()
  // Retreat should be in reverse topo order: 2, 1 (undo newest first)
  inspect(retreat, content="[2, 1]")
  let advance = advance_rle.iter_units().collect()
  inspect(advance, content="[3]")
}

// === Large graph correctness ===

///|
test "large linear graph: is_ancestor + walk consistency" {
  let g = CausalGraph::new()
  let mut prev = try! g.add_version([], "a")
  for i = 1; i < 500; i = i + 1 {
    prev = try! g.add_version([prev], "a")
  }
  // 500 versions: 0..499
  inspect(g.is_ancestor(0, 499), content="true")
  inspect(g.is_ancestor(499, 0), content="false")
  inspect(g.is_ancestor(250, 499), content="true")
  inspect(g.is_ancestor(250, 100), content="false")
  // Walk should produce all 500 in order
  let result = g.walk_from_frontier(@core.Frontier::from_array([499]))
  inspect(@rle.Spanning::span(result), content="500")
  let units = result.iter_units().collect()
  inspect(units[0], content="0")
  inspect(units[499], content="499")
}

///|
test "large graph: repeated is_ancestor reuse" {
  let g = CausalGraph::new()
  let mut prev = try! g.add_version([], "a")
  for i = 1; i < 100; i = i + 1 {
    prev = try! g.add_version([prev], "a")
  }
  // Call is_ancestor many times — gen counter must not overflow or interfere
  for i = 0; i < 50; i = i + 1 {
    inspect(g.is_ancestor(i, 99), content="true")
  }
  for i = 50; i < 99; i = i + 1 {
    inspect(g.is_ancestor(99, i), content="false")
  }
}

// === DirectedGraph trait — alga generic algorithms ===

///|
test "alga: has_cycle on DAG" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let _lv2 = try! g.add_version([lv1], "a")
  // CausalGraph is always a DAG — no cycles
  inspect(@alga.has_cycle(g), content="false")
}

///|
test "alga: toposort matches walk_from_frontier" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv0], "b")
  let lv3 = try! g.add_version([lv1, lv2], "a")
  // alga toposort on the full graph
  match @alga.toposort(g) {
    Some(order) => {
      inspect(order.length(), content="4")
      // lv0 must come before lv1, lv2; lv1 and lv2 before lv3
      let pos = Array::make(4, 0)
      for i, v in order {
        pos[v] = i
      }
      inspect(pos[lv0] < pos[lv1], content="true")
      inspect(pos[lv0] < pos[lv2], content="true")
      inspect(pos[lv1] < pos[lv3], content="true")
      inspect(pos[lv2] < pos[lv3], content="true")
    }
    None => inspect(false, content="true")
  }
}

///|
test "alga: reachable from root" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let _lv2 = try! g.add_version([lv1], "a")
  // Forward reachable from root should find all vertices
  let r = @alga.reachable(g, lv0)
  let sorted = r.copy()
  sorted.sort()
  inspect(sorted, content="[0, 1, 2]")
}

///|
test "alga: reachable from middle" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv0], "b")
  let _lv3 = try! g.add_version([lv1], "a")
  // Forward reachable from lv0: all 4
  let r0 = @alga.reachable(g, lv0)
  inspect(r0.length(), content="4")
  // Forward reachable from lv2: only lv2 (no children)
  let r2 = @alga.reachable(g, lv2)
  inspect(r2, content="[2]")
}

///|
test "alga: dfs_fold counts vertices" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let _lv2 = try! g.add_version([lv1], "a")
  let count = @alga.dfs_fold(g, lv0, 0, fn(acc, _v) { (acc + 1, true) })
  inspect(count, content="3")
}

///|
test "alga: bfs_fold on diamond" {
  let g = CausalGraph::new()
  let lv0 = try! g.add_version([], "a")
  let lv1 = try! g.add_version([lv0], "a")
  let lv2 = try! g.add_version([lv0], "b")
  let _lv3 = try! g.add_version([lv1, lv2], "a")
  // BFS from root counts all 4 vertices
  let count = @alga.bfs_fold(g, lv0, 0, fn(acc, _v) { (acc + 1, true) })
  inspect(count, content="4")
}
