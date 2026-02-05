///|
/// A frontier represents the "tips" of the causal graph - versions with no successors.
///
/// **Invariant**: Elements must be unique. Duplicate LVs violate the frontier semantics
/// (a version cannot be a tip twice) and may cause incorrect diff calculations.
pub(all) struct Frontier(Array[Int]) derive(Eq, Show, ToJson, FromJson)

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
    if not(seen.contains(v)) {
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
/// Graph entry storing causal information for an operation
pub(all) struct GraphEntry {
  parents : Array[Int] // Causal dependencies (LVs)
  agent : String // Agent that created this operation
  seq : Int // Sequence number for this agent
  timestamp : Int // Lamport timestamp for total ordering
} derive(Show)
