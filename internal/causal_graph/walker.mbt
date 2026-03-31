///| Event Graph Walker - Core eg-walker algorithm

///|
pub fn CausalGraph::walk_from_frontier(
  self : CausalGraph,
  frontier : @core.Frontier,
) -> @rle.Rle[@core.LvRange] {
  let (gen, reachable_lvs) = self.transitive_closure_gen(frontier)
  topological_sort_subset(self, reachable_lvs, self.query_visited, gen)
}

///|
/// Kahn's algorithm on a subset. Only iterates reachable LVs.
/// `membership_buf[lv] == membership_gen` checks subset membership.
fn topological_sort_subset(
  graph : CausalGraph,
  reachable_lvs : Array[Int],
  membership_buf : Array[Int],
  membership_gen : Int,
) -> @rle.Rle[@core.LvRange] {
  let int_buf = graph.query_int_buf
  for lv in reachable_lvs {
    int_buf[lv] = 0
  }
  for lv in reachable_lvs {
    for parent in graph.entries[lv].parents {
      if membership_buf[parent] == membership_gen {
        int_buf[lv] = int_buf[lv] + 1
      }
    }
  }
  let queue : Array[Int] = []
  for lv in reachable_lvs {
    if int_buf[lv] == 0 {
      queue.push(lv)
    }
  }
  queue.sort()
  let result : Array[Int] = []
  let ready : Array[Int] = []
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    result.push(current)
    ready.clear()
    for child in graph.children[current] {
      if membership_buf[child] != membership_gen {
        continue
      }
      int_buf[child] = int_buf[child] - 1
      if int_buf[child] == 0 {
        ready.push(child)
      }
    }
    ready.sort()
    for child in ready {
      queue.push(child)
    }
  }
  for lv in reachable_lvs {
    int_buf[lv] = 0
  }
  @rle.Rle::from_sorted_ints(result)
}

///|
pub fn CausalGraph::diff_frontiers_lvs(
  self : CausalGraph,
  from_frontier : @core.Frontier,
  to_frontier : @core.Frontier,
) -> (@rle.Rle[@core.LvRange], @rle.Rle[@core.LvRange]) {
  let (retreat_set, advance_set) = self.graph_diff(from_frontier, to_frontier)
  let retreat_rle = if retreat_set.length() > 0 {
    let sorted = self.toposort_lv_set(retreat_set)
    let expanded = sorted.iter_units().collect()
    let reversed : Array[Int] = []
    for i = expanded.length() - 1; i >= 0; i = i - 1 {
      reversed.push(expanded[i])
    }
    @rle.Rle::from_array(
      reversed.map(fn(lv) { @core.LvRange::{ start: lv, count: 1 } }),
    )
  } else {
    @rle.Rle::new()
  }
  let advance_rle = if advance_set.length() > 0 {
    self.toposort_lv_set(advance_set)
  } else {
    @rle.Rle::new()
  }
  (retreat_rle, advance_rle)
}
