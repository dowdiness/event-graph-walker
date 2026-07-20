///| CausalSnapshot - read-only view of a Document's causal DAG.
///
/// Public, narrow surface over a document's causal graph. Designed so
/// downstream consumers (e.g. canopy's history visualization) can walk the
/// DAG without depending on its storage representation.
///
/// Snapshots are aliases of the live graph: they are cheap to construct,
/// but reflect future mutations of the underlying document. Callers that
/// need a frozen view should copy the data they care about.

///|
pub struct CausalSnapshot {
  priv op_count_fn : () -> Int
  priv entry_fn : (Int) -> SnapshotEntry?
  priv frontier_fn : () -> Array[Int]
  priv children_count_fn : (Int) -> Int
}

///|
/// Construct a live snapshot from façade-owned read capabilities.
///
/// The callbacks must return owning values. In particular, `entry_fn` and
/// `frontier_fn` must not expose mutable graph storage.
pub fn CausalSnapshot::CausalSnapshot(
  op_count_fn : () -> Int,
  entry_fn : (Int) -> SnapshotEntry?,
  frontier_fn : () -> Array[Int],
  children_count_fn : (Int) -> Int,
) -> CausalSnapshot {
  { op_count_fn, entry_fn, frontier_fn, children_count_fn }
}

///|
/// Total number of operations recorded. LVs are valid in `0..<op_count()`.
pub fn CausalSnapshot::op_count(self : CausalSnapshot) -> Int {
  (self.op_count_fn)()
}

///|
/// Look up the entry at a given local version. Returns `None` for
/// out-of-range LVs.
pub fn CausalSnapshot::entry(self : CausalSnapshot, lv : Int) -> SnapshotEntry? {
  (self.entry_fn)(lv)
}

///|
/// Current frontier (DAG tips) as an array of LVs. Returns a fresh array;
/// callers may mutate it without affecting the snapshot or graph.
pub fn CausalSnapshot::frontier(self : CausalSnapshot) -> Array[Int] {
  (self.frontier_fn)().copy()
}

///|
/// Outdegree (number of direct successors) of an LV. Returns 0 for
/// out-of-range LVs.
pub fn CausalSnapshot::children_count(self : CausalSnapshot, lv : Int) -> Int {
  (self.children_count_fn)(lv)
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
  { parent_lvs: parents.copy(), replica_id, sequence }
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
