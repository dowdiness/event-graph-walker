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
pub struct Range {
  priv start : Pos
  priv end : Pos
} derive(Debug, Eq)

///|
/// Create a range from two ordered positions.
pub fn Range::new(start : Pos, end : Pos) -> Range raise TextError {
  if start.value() > end.value() {
    raise TextError::InvalidRange(start=start.value(), end=end.value())
  }
  { start, end }
}

///|
/// Create a range from two ordered integers.
pub fn Range::from_ints(start : Int, end : Int) -> Range raise TextError {
  if start > end {
    raise TextError::InvalidRange(start~, end~)
  }
  Range::new(Pos::at(start), Pos::at(end))
}

///|
/// Get the starting position (inclusive).
pub fn Range::start(self : Range) -> Pos {
  self.start
}

///|
/// Get the ending position (exclusive).
pub fn Range::end(self : Range) -> Pos {
  self.end
}

///|
/// Opaque version identifier representing a document state at a point in time.
/// Exact checkpoint and sparse membership semantics are owned by the causal
/// graph; this façade only preserves the public text type.
pub(all) struct Version {
  priv graph_version : @causal_graph.GraphVersion
} derive(Debug, Eq, Hash)

///|
pub impl Show for Version with fn output(self, logger) {
  logger.write_string("Version(")
  let frontier = self.graph_version.frontier()
  for i = 0; i < frontier.length(); i = i + 1 {
    if i > 0 {
      logger.write_string(", ")
    }
    let raw = frontier[i]
    logger.write_string(raw.agent)
    logger.write_string(":")
    logger.write_string(raw.seq.to_string())
  }
  logger.write_string(")")
}

///|
pub fn Version::empty() -> Version {
  Version::{
    graph_version: @causal_graph.GraphVersion::from_parts([], []) catch {
      _ => abort("empty graph version must be valid")
    },
  }
}

///|
fn Version::from_graph_version(
  graph_version : @causal_graph.GraphVersion,
) -> Version {
  { graph_version, }
}

///|
fn Version::graph(self : Version) -> @causal_graph.GraphVersion {
  self.graph_version
}
