///| Opaque types for user-friendly API

///| Type-safe text position (0-indexed).

///|
/// Negative values are clamped to 0 during construction.
pub(all) struct Pos {
  priv value : Int
} derive(Show, Eq)

///| Create a position at the given index.

///|
/// Negative values are clamped to 0.
pub fn Pos::at(value : Int) -> Pos {
  { value: if value < 0 { 0 } else { value } }
}

///|
/// Get the underlying integer value.
pub fn Pos::value(self : Pos) -> Int {
  self.value
}

///| Text range representing a span of text.

///|
/// `start` is inclusive, `end` is exclusive.
pub(all) struct Range {
  /// Starting position (inclusive)
  start : Pos
  /// Ending position (exclusive)
  end : Pos
} derive(Show, Eq)

///|
/// Create a range from two positions.
pub fn Range::new(start : Pos, end : Pos) -> Range {
  { start, end }
}

///|
/// Create a range from two integers.
pub fn Range::from_ints(start : Int, end : Int) -> Range {
  { start: Pos::at(start), end: Pos::at(end) }
}

///| Opaque version identifier representing the document state at a point in time.

///|
/// Used for sync operations and historical checkouts.
pub(all) struct Version {
  priv frontier : @causal_graph.Frontier
} derive(Show, Eq)

///|
/// Create a Version from an internal Frontier (for advanced use).
pub fn Version::from_frontier(frontier : @causal_graph.Frontier) -> Version {
  { frontier, }
}

///|
/// Convert to internal Frontier (for advanced use).
pub fn Version::to_frontier(self : Version) -> @causal_graph.Frontier {
  self.frontier
}

///|
/// Create an empty version (represents initial state before any edits).
pub fn Version::empty() -> Version {
  { frontier: @causal_graph.Frontier::from_array([]) }
}

///|
/// Represents a local edit operation (insert or delete).
/// Returned from TextDoc::insert() and TextDoc::delete().
pub type Change = @core.Change
