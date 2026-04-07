///| Opaque types for user-friendly API

///| Type-safe text position (0-indexed).

///|
/// Negative values are clamped to 0 during construction.
pub(all) struct Pos {
  priv value : Int
} derive(Debug, Eq)

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

///|
/// Text range representing a contiguous span of text.
///
/// `start` is inclusive, `end` is exclusive (half-open interval).
pub(all) struct Range {
  /// Starting position (inclusive)
  start : Pos
  /// Ending position (exclusive)
  end : Pos
} derive(Debug, Eq)

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
  priv frontier : @core.Frontier
} derive(Debug, Eq)

///|
pub impl Show for Version with output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
fn Version::from_frontier(frontier : @core.Frontier) -> Version {
  { frontier, }
}

///|
fn Version::to_frontier(self : Version) -> @core.Frontier {
  self.frontier
}

///|
/// Create an empty version (represents initial state before any edits).
pub fn Version::empty() -> Version {
  { frontier: @core.Frontier::from_array([]) }
}

///|
/// Encode this version as a JSON string for cross-boundary transport (e.g. JS FFI).
pub fn Version::to_json_string(self : Version) -> String {
  self.frontier.to_json().stringify()
}

///|
/// Decode a Version from a JSON string produced by `to_json_string`.
pub fn Version::from_json_string(json_str : String) -> Version raise TextError {
  try {
    let json = @json.parse(json_str)
    let frontier : @core.Frontier = @json.from_json(json)
    { frontier, }
  } catch {
    _ => raise TextError::Internal(detail="Invalid Version JSON")
  }
}
