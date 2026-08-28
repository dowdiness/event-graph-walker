///| Causal graph error types

///|
pub(all) suberror CausalGraphError {
  /// An operation identity has an empty agent or negative sequence.
  InvalidIdentity(raw~ : @core.RawVersion)
  /// A parent LV was not found in the graph.
  /// Parents must be added before their children.
  MissingParent(lv~ : Int)
  /// An operation identity was already assigned to another local version.
  DuplicateVersion(raw~ : @core.RawVersion)
  /// A graph entry was not found for the given LV.
  /// Indicates a consistency bug — LV was referenced but never registered.
  MissingEntry(lv~ : Int)
} derive(Debug)
