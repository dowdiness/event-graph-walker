///| Property-based tests for CausalGraph walker and frontier diffs.

///|
/// These properties use a generated model DAG as the oracle, rather than
/// reusing the production walker implementation to compute expected results.

///|
struct GraphScenario {
  parents_by_lv : Array[Array[Int]]
  frontier_a : Array[Int]
  frontier_b : Array[Int]
} derive(Debug)

///|
fn graph_property_agent(lv : Int) -> String {
  let agents : Array[String] = ["alice", "bob", "carol", "dave"]
  agents[lv % agents.length()]
}

///|
fn random_lv_subset(count : Int, rs : @splitmix.RandomState) -> Array[Int] {
  let result : Array[Int] = []
  for lv in 0..<count {
    if rs.split().next_uint64() % 2 == 0 {
      result.push(lv)
    }
  }
  result
}

///|
fn trim_lvs(values : Array[Int], count : Int) -> Array[Int] {
  values.filter(fn(lv) { lv < count })
}

///|
fn GraphScenario::trim(self : GraphScenario, count : Int) -> GraphScenario {
  let parents_by_lv = self.parents_by_lv[:count].to_owned()
  {
    parents_by_lv,
    frontier_a: trim_lvs(self.frontier_a, count),
    frontier_b: trim_lvs(self.frontier_b, count),
  }
}

///|
impl @quickcheck.Arbitrary for GraphScenario with fn arbitrary(size, rs) {
  let size_cap = if size < 0 { 0 } else { size }
  let max_count = if size_cap < 1 {
    1
  } else if size_cap > 24 {
    24
  } else {
    size_cap
  }
  let count = rs.split().next_uint64().to_int().abs() % (max_count + 1)
  let parents_by_lv : Array[Array[Int]] = []
  for lv in 0..<count {
    let max_parents = if lv < 3 { lv } else { 3 }
    let parent_count = if max_parents == 0 {
      0
    } else {
      rs.split().next_uint64().to_int().abs() % (max_parents + 1)
    }
    let parents : Array[Int] = []
    for candidate in 0..<lv {
      let needed = parent_count - parents.length()
      if needed > 0 {
        let remaining = lv - candidate
        if remaining <= needed || rs.split().next_uint64() % 2 == 0 {
          parents.push(candidate)
        }
      }
    }
    parents_by_lv.push(parents)
  }
  {
    parents_by_lv,
    frontier_a: random_lv_subset(count, rs.split()),
    frontier_b: random_lv_subset(count, rs.split()),
  }
}

///|
impl @qc.Shrink for GraphScenario with fn shrink(self) {
  let results : Array[GraphScenario] = []
  let count = self.parents_by_lv.length()
  if count > 0 {
    results.push(self.trim(0))
    let half = count / 2
    if half > 0 {
      results.push(self.trim(half))
    }
    results.push(self.trim(count - 1))
  }
  results.iter()
}

///|
fn GraphScenario::to_graph(
  self : GraphScenario,
) -> CausalGraph raise CausalGraphError {
  let graph = CausalGraph::new()
  for lv, parents in self.parents_by_lv {
    let _ = graph.add_version(parents, graph_property_agent(lv))
  }
  graph
}

///|
fn model_timestamps(parents_by_lv : Array[Array[Int]]) -> Array[Int] {
  let timestamps : Array[Int] = []
  for parents in parents_by_lv {
    let timestamp = if parents is [] {
      0
    } else {
      for parent in parents; max_ts = 0 {
        let parent_ts = timestamps[parent]
        continue if parent_ts > max_ts { parent_ts } else { max_ts }
      } nobreak {
        max_ts + 1
      }
    }
    timestamps.push(timestamp)
  }
  timestamps
}

///|
fn model_closure(
  parents_by_lv : Array[Array[Int]],
  frontier : Array[Int],
) -> Array[Bool] {
  let count = parents_by_lv.length()
  let seen = Array::make(count, false)
  let queue : Array[Int] = []
  for lv in frontier {
    if lv >= 0 && lv < count {
      queue.push(lv)
    }
  }
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    if seen[current] {
      continue
    }
    seen[current] = true
    for parent in parents_by_lv[current] {
      if !seen[parent] {
        queue.push(parent)
      }
    }
  }
  seen
}

///|
fn membership_from_lvs(count : Int, lvs : Array[Int]) -> Array[Bool]? {
  let seen = Array::make(count, false)
  for lv in lvs {
    if lv < 0 || lv >= count || seen[lv] {
      return None
    }
    seen[lv] = true
  }
  Some(seen)
}

///|
fn matches_expected_delta(
  actual : Array[Bool],
  from_seen : Array[Bool],
  to_seen : Array[Bool],
  retreat~ : Bool,
) -> Bool {
  for i in 0..<actual.length() {
    let expected = if retreat {
      from_seen[i] && !to_seen[i]
    } else {
      to_seen[i] && !from_seen[i]
    }
    if actual[i] != expected {
      return false
    }
  }
  true
}

///|
fn transformed_frontier_matches(
  from_seen : Array[Bool],
  to_seen : Array[Bool],
  retreat_seen : Array[Bool],
  advance_seen : Array[Bool],
) -> Bool {
  let transformed = from_seen.copy()
  for i in 0..<transformed.length() {
    if retreat_seen[i] {
      if advance_seen[i] {
        return false
      }
      transformed[i] = false
    }
    if advance_seen[i] {
      transformed[i] = true
    }
  }
  transformed == to_seen
}

///|
fn diff_matches_model(
  parents_by_lv : Array[Array[Int]],
  from_frontier : Array[Int],
  to_frontier : Array[Int],
  retreat : Array[Int],
  advance : Array[Int],
) -> Bool {
  let count = parents_by_lv.length()
  let from_seen = model_closure(parents_by_lv, from_frontier)
  let to_seen = model_closure(parents_by_lv, to_frontier)
  match
    (membership_from_lvs(count, retreat), membership_from_lvs(count, advance)) {
    (Some(retreat_seen), Some(advance_seen)) =>
      matches_expected_delta(retreat_seen, from_seen, to_seen, retreat=true) &&
      matches_expected_delta(advance_seen, from_seen, to_seen, retreat=false) &&
      transformed_frontier_matches(
        from_seen, to_seen, retreat_seen, advance_seen,
      )
    _ => false
  }
}

///|
fn positions_from_lvs(count : Int, lvs : Array[Int]) -> Array[Int]? {
  let positions = Array::make(count, -1)
  for position, lv in lvs {
    if lv < 0 || lv >= count || positions[lv] != -1 {
      return None
    }
    positions[lv] = position
  }
  Some(positions)
}

///|
fn respects_parent_order(
  parents_by_lv : Array[Array[Int]],
  lvs : Array[Int],
  reverse~ : Bool,
) -> Bool {
  let count = parents_by_lv.length()
  match positions_from_lvs(count, lvs) {
    None => false
    Some(positions) => {
      for lv in lvs {
        for parent in parents_by_lv[lv] {
          let parent_position = positions[parent]
          if parent_position >= 0 {
            if reverse {
              if positions[lv] >= parent_position {
                return false
              }
            } else if parent_position >= positions[lv] {
              return false
            }
          }
        }
      }
      true
    }
  }
}

///|
fn prop_lamport_timestamps(scenario : GraphScenario) -> Bool {
  let graph = scenario.to_graph() catch { _ => return false }
  let expected = model_timestamps(scenario.parents_by_lv)
  for lv in 0..<expected.length() {
    match graph.get_entry(lv) {
      Some(entry) => if entry.timestamp != expected[lv] { return false }
      None => return false
    }
  }
  true
}

///|
test "property: causal graph Lamport timestamps respect parents" {
  @qc.quick_check_fn(prop_lamport_timestamps)
}

///|
fn prop_walk_from_frontier_matches_model_closure(
  scenario : GraphScenario,
) -> Bool {
  let graph = scenario.to_graph() catch { _ => return false }
  let walked = graph
    .walk_from_frontier(@core.Frontier::from_array(scenario.frontier_a))
    .iter_units()
    .collect()
  match membership_from_lvs(scenario.parents_by_lv.length(), walked) {
    None => false
    Some(actual) => {
      let expected = model_closure(scenario.parents_by_lv, scenario.frontier_a)
      actual == expected
    }
  }
}

///|
test "property: walk_from_frontier returns exactly model closure" {
  @qc.quick_check_fn(prop_walk_from_frontier_matches_model_closure)
}

///|
fn prop_walk_from_frontier_is_topological(scenario : GraphScenario) -> Bool {
  let graph = scenario.to_graph() catch { _ => return false }
  let walked = graph
    .walk_from_frontier(@core.Frontier::from_array(scenario.frontier_a))
    .iter_units()
    .collect()
  respects_parent_order(scenario.parents_by_lv, walked, reverse=false)
}

///|
test "property: walk_from_frontier output is topological" {
  @qc.quick_check_fn(prop_walk_from_frontier_is_topological)
}

///|
fn prop_graph_diff_matches_model_delta(scenario : GraphScenario) -> Bool {
  let graph = scenario.to_graph() catch { _ => return false }
  let from_frontier = @core.Frontier::from_array(scenario.frontier_a)
  let to_frontier = @core.Frontier::from_array(scenario.frontier_b)
  let (retreat, advance) = graph.graph_diff(from_frontier, to_frontier)
  diff_matches_model(
    scenario.parents_by_lv,
    scenario.frontier_a,
    scenario.frontier_b,
    retreat,
    advance,
  )
}

///|
test "property: graph_diff matches model partition and coverage" {
  @qc.quick_check_fn(prop_graph_diff_matches_model_delta)
}

///|
fn prop_diff_frontiers_rle_matches_model_delta(
  scenario : GraphScenario,
) -> Bool {
  let graph = scenario.to_graph() catch { _ => return false }
  let from_frontier = @core.Frontier::from_array(scenario.frontier_a)
  let to_frontier = @core.Frontier::from_array(scenario.frontier_b)
  let (retreat_rle, advance_rle) = graph.diff_frontiers_lvs(
    from_frontier, to_frontier,
  )
  let retreat = retreat_rle.iter_units().collect()
  let advance = advance_rle.iter_units().collect()
  diff_matches_model(
    scenario.parents_by_lv,
    scenario.frontier_a,
    scenario.frontier_b,
    retreat,
    advance,
  ) &&
  respects_parent_order(scenario.parents_by_lv, retreat, reverse=true) &&
  respects_parent_order(scenario.parents_by_lv, advance, reverse=false)
}

///|
test "property: diff_frontiers_lvs RLE matches model delta" {
  @qc.quick_check_fn(prop_diff_frontiers_rle_matches_model_delta)
}
