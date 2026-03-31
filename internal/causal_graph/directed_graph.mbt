///|
/// DirectedGraph trait implementation for CausalGraph.
///
/// Uses the children index for forward-edge traversal (parent → children).
/// This enables all generic alga algorithms: toposort, dfs_fold, bfs_fold,
/// has_cycle, reachable, etc.
///
/// Note: The causal graph also supports backward traversal (child → parents)
/// via the entries array. The DirectedGraph trait only exposes the forward
/// direction. Backward traversal uses the dedicated methods (is_ancestor,
/// transitive_closure_gen, graph_diff).
pub impl @alga.DirectedGraph for CausalGraph with vertex_count(self) {
  self.next_lv
}

///|
pub impl @alga.DirectedGraph for CausalGraph with for_each_vertex(self, f) {
  for v = 0; v < self.next_lv; v = v + 1 {
    f(v)
  }
}

///|
pub impl @alga.DirectedGraph for CausalGraph with for_each_successor(self, v, f) {
  if v >= 0 && v < self.next_lv {
    for w in self.children[v] {
      f(w)
    }
  }
}
