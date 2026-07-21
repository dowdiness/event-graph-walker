///|
/// A frontier represents the "tips" of the causal graph - versions with no successors.
///
/// **Invariant**: Elements are unique and stored in first-occurrence order.
pub struct Frontier {
  priv values : Array[Int]
} derive(Eq)

///|
pub impl @debug.Debug for Frontier with fn to_repr(self) {
  @debug.Repr::literal("Frontier(" + @debug.to_string(self.values) + ")")
}

///|
pub impl Show for Frontier with fn output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
pub impl ToJson for Frontier with fn to_json(self) {
  self.values.to_json()
}

///|
pub impl @json.FromJson for Frontier with fn from_json(json, path) {
  let values : Array[Int] = @json.from_json(json, path~)
  Frontier::from_array(values)
}

///|
/// Create a frontier from an array of LVs, taking ownership of neither the input
/// nor any duplicate values.
pub fn Frontier::from_array(values : Array[Int]) -> Frontier {
  if values.length() == 0 {
    { values: [] }
  } else if values.length() == 1 {
    { values: [values[0]] }
  } else {
    let seen : @hashset.HashSet[Int] = @hashset.HashSet::default()
    let deduped : Array[Int] = []
    for v in values {
      if seen.add_and_check(v) {
        deduped.push(v)
      }
    }
    { values: deduped }
  }
}

///|
/// Create a frontier from an array of LVs, removing duplicates.
pub fn Frontier::from_array_dedup(values : Array[Int]) -> Frontier {
  Frontier::from_array(values)
}

///|
/// Check if this frontier contains duplicate elements (violates invariant).
pub fn Frontier::has_duplicates(self : Frontier) -> Bool {
  let seen : @hashset.HashSet[Int] = @hashset.HashSet::default()
  for v in self.values {
    if !seen.add_and_check(v) {
      return true
    }
  }
  false
}

///|
pub fn Frontier::length(self : Frontier) -> Int {
  self.values.length()
}

///|
pub fn Frontier::iter(self : Frontier) -> Iter[Int] {
  self.values.iter()
}

///|
pub fn Frontier::to_array(self : Frontier) -> Array[Int] {
  self.values.copy()
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
