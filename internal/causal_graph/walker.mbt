///| Event Graph Walker - Core eg-walker algorithm
/// Traverses the causal graph in topological order to replay operations

///|
/// Walk the event graph from a frontier, collecting all reachable operations
/// in topological (causal) order.
///
/// This is the core eg-walker algorithm that ensures operations are
/// replayed in an order that respects their causal dependencies.
pub fn CausalGraph::walk_from_frontier(
  self : CausalGraph,
  frontier : @core.Frontier,
) -> @rle.Rle[@core.LvRange] {
  let (gen, reachable_lvs) = self.transitive_closure_gen(frontier)
  topological_sort_subset(self, reachable_lvs, self.query_visited, gen)
}

///|
/// Topological sort of a subset of versions using Kahn's algorithm.
/// Uses the pre-built children index. Only iterates over reachable LVs
/// (not the full 0..n range).
///
/// `reachable_lvs` is the list of LVs in the subset.
/// `membership_buf[lv] == membership_gen` checks subset membership.
fn topological_sort_subset(
  graph : CausalGraph,
  reachable_lvs : Array[Int],
  membership_buf : Array[Int],
  membership_gen : Int,
) -> @rle.Rle[@core.LvRange] {
  let int_buf = graph.query_int_buf

  // Compute in-degrees — only for reachable vertices.
  // int_buf is reused; we zero entries before and clean up after.
  for lv in reachable_lvs {
    int_buf[lv] = 0
  }
  for lv in reachable_lvs {
    match graph.entries[lv] {
      Some(entry) =>
        for parent in entry.parents {
          if membership_buf[parent] == membership_gen {
            int_buf[lv] = int_buf[lv] + 1
          }
        }
      None => ()
    }
  }

  // Seed queue with zero-in-degree vertices in sorted order
  let queue : Array[Int] = []
  for lv in reachable_lvs {
    if int_buf[lv] == 0 {
      queue.push(lv)
    }
  }
  queue.sort()

  // Kahn's algorithm using pre-built children index
  let result : Array[Int] = []
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    result.push(current)
    // Collect newly-ready children in sorted order for determinism
    let ready : Array[Int] = []
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

  // Clean up int_buf for reuse
  for lv in reachable_lvs {
    int_buf[lv] = 0
  }

  @rle.Rle::from_sorted_ints(result)
}

///|
/// Calculate the difference between two frontiers and return LVs to apply
/// This is useful for fast-forwarding from one frontier to another
///
/// # Returns
/// (retreat_lvs, advance_lvs) - LVs to undo and redo
///
/// Note: retreat_lvs are in reverse topological order (for undo)
///       advance_lvs are in topological order (for redo)
pub fn CausalGraph::diff_frontiers_lvs(
  self : CausalGraph,
  from_frontier : @core.Frontier,
  to_frontier : @core.Frontier,
) -> (@rle.Rle[@core.LvRange], @rle.Rle[@core.LvRange]) {
  let (retreat_set, advance_set) = self.graph_diff(from_frontier, to_frontier)

  // Topological sort the retreat set, then reverse for undo order
  let retreat_rle = if retreat_set.length() > 0 {
    // Mark retreat set in query_visited for membership checks
    let gen = self.fresh_gen()
    let visited = self.query_visited
    for lv in retreat_set {
      visited[lv] = gen
    }
    let sorted = topological_sort_subset(self, retreat_set, visited, gen)
    // Reverse for undo order
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

  // Topological sort the advance set
  let advance_rle = if advance_set.length() > 0 {
    let gen = self.fresh_gen()
    let visited = self.query_visited
    for lv in advance_set {
      visited[lv] = gen
    }
    topological_sort_subset(self, advance_set, visited, gen)
  } else {
    @rle.Rle::new()
  }
  (retreat_rle, advance_rle)
}
