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
/// One validated version-vector entry.
priv struct VersionEntry {
  replica_id : String
  sequence : Int
} derive(Debug, Eq)

///|
/// Opaque version identifier representing the document state at a point in time.
///
/// Versions are validated version vectors keyed by stable replica ID.
pub(all) struct Version {
  priv entries : Array[VersionEntry]
} derive(Debug, Eq)

///|
pub impl Show for Version with fn output(self, logger) {
  logger.write_string("Version(")
  for i = 0; i < self.entries.length(); i = i + 1 {
    if i > 0 {
      logger.write_string(", ")
    }
    logger.write_string(self.entries[i].replica_id)
    logger.write_string(":")
    logger.write_string(self.entries[i].sequence.to_string())
  }
  logger.write_string(")")
}

///|
/// Internal validated constructor. Entries must already be sorted and unique.
fn Version::Version(entries : Array[VersionEntry]) -> Version {
  { entries, }
}

///|
fn Version::from_ops(ops : Array[@core.Op]) -> Version {
  let maxima : Map[String, Int] = Map([])
  for op in ops {
    match maxima.get(op.agent()) {
      Some(sequence) => if op.seq() > sequence { maxima[op.agent()] = op.seq() }
      None => maxima[op.agent()] = op.seq()
    }
  }
  let replica_ids = maxima.keys().to_array()
  replica_ids.sort()
  let entries : Array[VersionEntry] = []
  for replica_id in replica_ids {
    match maxima.get(replica_id) {
      Some(sequence) => entries.push({ replica_id, sequence })
      None => ()
    }
  }
  Version(entries)
}

///|
/// Advance one cached version-vector entry without rescanning the operation log.
///
/// The copied array keeps `Version` values immutable to callers. The linear
/// scan is over replica entries rather than operations, which is the hot-path
/// trade-off for local edits.
fn Version::advance(
  self : Version,
  replica_id : String,
  sequence : Int,
) -> Version {
  let entries = self.entries.copy()
  for i = 0; i < entries.length(); i = i + 1 {
    if entries[i].replica_id == replica_id {
      if sequence > entries[i].sequence {
        entries[i] = { replica_id, sequence }
      }
      return Version(entries)
    }
  }
  entries.push({ replica_id, sequence })
  entries.sort_by((a, b) => a.replica_id.compare(b.replica_id))
  Version(entries)
}

///|
fn Version::includes(
  self : Version,
  replica_id : String,
  sequence : Int,
) -> Bool {
  for entry in self.entries {
    if entry.replica_id == replica_id {
      return sequence <= entry.sequence
    }
  }
  false
}

///|
/// Create an empty version (represents initial state before any edits).
pub fn Version::empty() -> Version {
  Version([])
}
