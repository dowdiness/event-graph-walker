///|
/// A frontier represents the "tips" of the causal graph - versions with no successors.
///
/// **Invariant**: Elements must be unique. Duplicate LVs violate the frontier semantics
/// (a version cannot be a tip twice) and may cause incorrect diff calculations.
pub(all) struct Frontier(Array[Int]) derive(Eq, Debug, ToJson, FromJson)

///|
pub impl Show for Frontier with output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
/// Create a frontier from an array of LVs.
///
/// **Note**: This does not validate uniqueness for performance. Use `from_array_dedup`
/// when the input may contain duplicates (e.g., from untrusted sources).
pub fn Frontier::from_array(values : Array[Int]) -> Frontier {
  Frontier(values)
}

///|
/// Create a frontier from an array of LVs, removing duplicates.
///
/// Use this when constructing a frontier from potentially untrusted input
/// or when merging multiple frontiers.
pub fn Frontier::from_array_dedup(values : Array[Int]) -> Frontier {
  let seen : @hashset.HashSet[Int] = @hashset.new()
  let deduped : Array[Int] = []
  for v in values {
    if !seen.contains(v) {
      seen.add(v)
      deduped.push(v)
    }
  }
  Frontier(deduped)
}

///|
/// Check if this frontier contains duplicate elements (violates invariant).
pub fn Frontier::has_duplicates(self : Frontier) -> Bool {
  // Short-circuit: 0 or 1 elements can never have duplicates
  if self.0.length() <= 1 {
    return false
  }
  let seen : @hashset.HashSet[Int] = @hashset.new()
  for v in self.0 {
    if seen.contains(v) {
      return true
    }
    seen.add(v)
  }
  false
}

///|
/// Causal metadata for a single operation in the CausalGraph.
///
/// Each operation in the graph has one `GraphEntry` stored at its local
/// version (LV). Fields use local LVs internally; the globally stable
/// identifiers (`agent` + `seq`) are stored here so entries can be
/// serialized and sent to peers.
pub(all) struct GraphEntry {
  /// LVs of the operations this one directly depends on (its causal parents).
  /// All parent LVs must already exist in the graph before this entry is added.
  /// An empty array means this is a root operation with no dependencies.
  parents : Array[Int]
  /// Globally stable agent ID — does not change across peers or restarts.
  agent : String
  /// Agent-local sequence number, monotonically increasing per agent.
  /// Together with `agent`, forms the globally unique `RawVersion` for this op.
  seq : Int
  /// Lamport timestamp: always `max(parents' timestamps) + 1`, or 0 for roots.
  /// Used for deterministic total ordering when causal order alone is ambiguous.
  timestamp : Int
} derive(Debug)
