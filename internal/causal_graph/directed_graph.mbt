///|
/// DirectedGraph trait implementation for CausalGraph.
///
/// Uses the children index for forward-edge traversal (parent → children).
/// This enables all generic alga algorithms: toposort, dfs_fold, bfs_fold,
/// has_cycle, reachable, tarjan_scc, etc.
///
/// Note: The causal graph also supports backward traversal (child → parents)
/// via the entries array. The DirectedGraph trait only exposes the forward
/// direction. Backward traversal uses the dedicated methods (is_ancestor,
/// transitive_closure_gen, graph_diff).
pub impl @alga.DirectedGraph for CausalGraph with vertex_count(self) {
  self.next_lv
}

///|
pub impl @alga.DirectedGraph for CausalGraph with iter(self) {
  (0).until(self.next_lv)
}

///|
pub impl @alga.DirectedGraph for CausalGraph with successors(self, v) {
  if v >= 0 && v < self.next_lv {
    self.children[v].iter()
  } else {
    Iter::empty()
  }
}
