///|
/// CausalGraph implementation
pub(all) struct Frontier(Array[Int]) derive(Eq, Show, ToJson, FromJson)

///|
/// Create a frontier from an array of LVs
pub fn Frontier::from_array(values : Array[Int]) -> Frontier {
  Frontier(values)
}

///|
/// Graph entry storing causal information for an operation
pub(all) struct GraphEntry {
  parents : Array[Int] // Causal dependencies (LVs)
  agent : String // Agent that created this operation
  seq : Int // Sequence number for this agent
  timestamp : Int // Lamport timestamp for total ordering
} derive(Show)
