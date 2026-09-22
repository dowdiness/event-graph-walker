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
pub impl @alga.VertexSet for CausalGraph with fn vertex_count(self) {
  self.next_lv
}

///|
pub impl @alga.VertexSet for CausalGraph with fn iter(self) {
  (0).until(self.next_lv)
}

///|
pub impl @alga.Successors for CausalGraph with fn successors(self, v) {
  if v >= 0 && v < self.next_lv {
    self.children[v].iter()
  } else {
    Iter::empty()
  }
}

///|
pub impl @alga.DirectedGraph for CausalGraph

// ---------------------------------------------------------------------------
// Explicit trait-method promotions (E0079).
// `#doc(hidden)` keeps these out of the generated interface while preserving
// dot-syntax and cross-package use.
// ---------------------------------------------------------------------------

///|
#doc(hidden)
pub extend CausalGraph with @alga.Successors::{
  each_successor,
  bfs_fold,
  dfs_fold,
  successors,
}

///|
#doc(hidden)
pub extend CausalGraph with @alga.VertexSet::{
  vertex_count,
  has_vertex,
  each_vertex,
  iter,
}
