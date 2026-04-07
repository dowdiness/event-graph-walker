///| Causal graph error types

///|
pub(all) suberror CausalGraphError {
  /// A parent LV was not found in the graph.
  /// Parents must be added before their children.
  MissingParent(lv~ : Int)
  /// A graph entry was not found for the given LV.
  /// Indicates a consistency bug — LV was referenced but never registered.
  MissingEntry(lv~ : Int)
} derive(Debug)
