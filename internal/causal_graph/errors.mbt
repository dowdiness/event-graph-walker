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

// ---------------------------------------------------------------------------
// Explicit trait-method promotions (E0079).
// `#doc(hidden)` keeps these out of the generated interface while preserving
// dot-syntax and cross-package use.
// ---------------------------------------------------------------------------

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend CausalGraphError with @debug.Debug::{to_repr}
