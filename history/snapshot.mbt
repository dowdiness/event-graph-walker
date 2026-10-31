///| CausalView - live, read-only view of a Document's causal DAG.
///
/// Public, narrow surface over a document's causal graph. Designed so
/// downstream consumers (e.g. canopy's history visualization) can walk the
/// DAG without depending on its storage representation.
///
/// Views are aliases of the live graph: they are cheap to construct,
/// but reflect future mutations of the underlying document. Callers that
/// need a frozen result should retain the owning values returned by the view.

///|
pub struct CausalView {
  priv op_count_fn : () -> Int
  priv entry_fn : (Int) -> SnapshotEntry?
  priv frontier_fn : () -> Array[Int]
  priv children_counts_fn : () -> Array[Int]
}

///|
/// Construct a live view from façade-owned read capabilities.
///
/// Each callback invocation must return owning values, never mutable graph
/// storage or arrays shared with another invocation. The view forwards them
/// without an additional copy.
pub fn CausalView::CausalView(
  op_count_fn : () -> Int,
  entry_fn : (Int) -> SnapshotEntry?,
  frontier_fn : () -> Array[Int],
  children_counts_fn : () -> Array[Int],
) -> CausalView {
  { op_count_fn, entry_fn, frontier_fn, children_counts_fn, }
}

///|
/// Total number of operations recorded. LVs are valid in `0..<op_count()`.
pub fn CausalView::op_count(self : CausalView) -> Int {
  (self.op_count_fn)()
}

///|
/// Look up the entry at a given local version. Returns `None` for
/// out-of-range LVs.
pub fn CausalView::entry(self : CausalView, lv : Int) -> SnapshotEntry? {
  (self.entry_fn)(lv)
}

///|
/// Current frontier (DAG tips) as an array of LVs. Returns a fresh array;
/// callers may mutate it without affecting the view or graph.
pub fn CausalView::frontier(self : CausalView) -> Array[Int] {
  (self.frontier_fn)()
}

///|
/// Capture direct-successor counts for all currently recorded LVs in one pass.
/// The owning array is indexed by LV and does not change after later edits.
/// Request it once per diagnostic refresh, then index it for individual entries.
pub fn CausalView::children_counts(self : CausalView) -> Array[Int] {
  (self.children_counts_fn)()
}

///|
/// Read-only view of a single causal-graph entry. Opaque: fields are
/// reached through accessor methods so the backing representation may
/// change without breaking downstream consumers.
pub struct SnapshotEntry {
  priv parent_lvs : Array[Int]
  priv replica_id : String
  priv sequence : Int
}

///|
/// Construct an owning snapshot entry.
pub fn SnapshotEntry::SnapshotEntry(
  parents : Array[Int],
  replica_id : String,
  sequence : Int,
) -> SnapshotEntry {
  { parent_lvs: parents.copy(), replica_id, sequence, }
}

///|
/// LVs of the operations this one directly depends on (its causal parents).
/// Returned as a borrowed view to avoid copying; the underlying array is
/// owned by the snapshot.
pub fn SnapshotEntry::parents(self : SnapshotEntry) -> ArrayView[Int] {
  self.parent_lvs[:]
}

///|
/// Identifier of the agent that produced this operation.
pub fn SnapshotEntry::agent(self : SnapshotEntry) -> String {
  self.replica_id
}

///|
/// Per-agent sequence number for this operation.
pub fn SnapshotEntry::seq(self : SnapshotEntry) -> Int {
  self.sequence
}
