///| CausalSnapshot - read-only view of a Document's causal DAG.
///
/// Public, narrow surface over the internal `CausalGraph`. Designed so
/// downstream consumers (e.g. canopy's history visualization) can walk the
/// DAG without depending on egw's internal storage representation, alga
/// trait impls, or `GraphEntry` field shape.
///
/// Snapshots are aliases of the live graph: they are cheap to construct,
/// but reflect future mutations of the underlying document. Callers that
/// need a frozen view should copy the data they care about.

///|
pub struct CausalSnapshot {
  priv graph : @causal_graph.CausalGraph
}

///|
/// Internal construction primitive — wraps a `CausalGraph` reference into a
/// snapshot. Exposed publicly only because MoonBit visibility is
/// package-strict and cross-package callers (`internal/document`, `text`)
/// have no other way to build the wrapper. Not callable from outside this
/// module: `@causal_graph.CausalGraph` lives in `internal/causal_graph`,
/// which downstream consumers cannot import. The supported public entry
/// points remain `Document::causal_snapshot` and `TextState::causal_snapshot`.
pub fn CausalSnapshot::from_graph(
  graph : @causal_graph.CausalGraph,
) -> CausalSnapshot {
  { graph, }
}

///|
/// Total number of operations recorded. LVs are valid in `0..<op_count()`.
pub fn CausalSnapshot::op_count(self : CausalSnapshot) -> Int {
  self.graph.op_count()
}

///|
/// Look up the entry at a given local version. Returns `None` for
/// out-of-range LVs.
pub fn CausalSnapshot::entry(self : CausalSnapshot, lv : Int) -> SnapshotEntry? {
  match self.graph.get_entry(lv) {
    Some(e) => Some({ inner: e })
    None => None
  }
}

///|
/// Current frontier (DAG tips) as an array of LVs. Returns a fresh array;
/// callers may mutate it without affecting the snapshot or graph.
pub fn CausalSnapshot::frontier(self : CausalSnapshot) -> Array[Int] {
  self.graph.get_frontier().0.copy()
}

///|
/// Outdegree (number of direct successors) of an LV. Returns 0 for
/// out-of-range LVs.
pub fn CausalSnapshot::children_count(self : CausalSnapshot, lv : Int) -> Int {
  self.graph.children_count(lv)
}

///|
/// Read-only view of a single causal-graph entry. Opaque: fields are
/// reached through accessor methods so the backing representation may
/// change without breaking downstream consumers.
pub struct SnapshotEntry {
  priv inner : @core.GraphEntry
}

///|
/// LVs of the operations this one directly depends on (its causal parents).
/// Returned as a borrowed view to avoid copying; the underlying array is
/// owned by the snapshot.
pub fn SnapshotEntry::parents(self : SnapshotEntry) -> ArrayView[Int] {
  self.inner.parents[:]
}

///|
/// Identifier of the agent that produced this operation.
pub fn SnapshotEntry::agent(self : SnapshotEntry) -> String {
  self.inner.agent
}

///|
/// Per-agent sequence number for this operation.
pub fn SnapshotEntry::seq(self : SnapshotEntry) -> Int {
  self.inner.seq
}
