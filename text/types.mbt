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
/// The exact operation-DAG frontier is kept separately from the compact
/// per-agent membership summary. Both are private implementation details of
/// the opaque public Version.
priv struct VersionRange {
  start : UInt
  end : UInt
} derive(Debug, Eq)

///|
priv struct VersionRangeEntry {
  replica_id : String
  ranges : Array[VersionRange]
} derive(Debug, Eq)

///|
/// Opaque version identifier representing a document state at a point in time.
pub(all) struct Version {
  priv frontier : Array[@core.RawVersion]
  priv ranges : Array[VersionRangeEntry]
} derive(Debug, Eq)

///|
pub impl Show for Version with fn output(self, logger) {
  logger.write_string("Version(")
  for i = 0; i < self.frontier.length(); i = i + 1 {
    if i > 0 {
      logger.write_string(", ")
    }
    logger.write_string(self.frontier[i].agent)
    logger.write_string(":")
    logger.write_string(self.frontier[i].seq.to_string())
  }
  logger.write_string(")")
}

///|
fn compare_raw_version(a : @core.RawVersion, b : @core.RawVersion) -> Int {
  match a.agent.compare(b.agent) {
    0 => a.seq.compare(b.seq)
    other => other
  }
}

///|
fn Version::from_ops(ops : Array[@core.Op]) -> Version {
  let frontier : Map[@core.RawVersion, @core.RawVersion] = Map([])
  let ranges : Map[String, Array[VersionRange]] = Map([])
  for op in ops {
    let raw = @core.RawVersion(op.agent(), op.seq())
    frontier[raw] = raw
    for parent in op.parents() {
      frontier.remove(parent)
    }
    let current = ranges.get(raw.agent).unwrap_or([]).copy()
    let next : Array[VersionRange] = []
    let sequence = raw.seq.reinterpret_as_uint()
    let mut inserted = false
    for range in current {
      if sequence + 1U < range.start {
        if !inserted {
          next.push({ start: sequence, end: sequence + 1U })
          inserted = true
        }
        next.push(range)
      } else if range.end < sequence {
        next.push(range)
      } else {
        let start = if range.start < sequence { range.start } else { sequence }
        let end = if range.end > sequence + 1U {
          range.end
        } else {
          sequence + 1U
        }
        let mut merged : VersionRange = { start, end }
        while next.length() > 0 && next[next.length() - 1].end >= merged.start {
          let previous = next[next.length() - 1]
          let _ = next.pop()
          merged = VersionRange::{
            start: if previous.start < merged.start {
              previous.start
            } else {
              merged.start
            },
            end: if previous.end > merged.end {
              previous.end
            } else {
              merged.end
            },
          }
        }
        next.push(merged)
        inserted = true
      }
    }
    if !inserted {
      next.push({ start: sequence, end: sequence + 1U })
    }
    ranges[raw.agent] = next
  }
  let frontier_values = frontier.values().to_array()
  frontier_values.sort_by(fn(a, b) { compare_raw_version(a, b) })
  let ids = ranges.keys().to_array()
  ids.sort()
  let range_values : Array[VersionRangeEntry] = []
  for id in ids {
    range_values.push({ replica_id: id, ranges: ranges.get(id).unwrap().copy() })
  }
  let result : Version = { frontier: frontier_values, ranges: range_values }
  result
}

///|
fn version_ranges_advance(
  source : Array[VersionRangeEntry],
  replica_id : String,
  sequence : Int,
) -> Array[VersionRangeEntry] {
  let result = source.copy()
  let sequence_uint = sequence.reinterpret_as_uint()
  for i = 0; i < result.length(); i = i + 1 {
    if result[i].replica_id == replica_id {
      let ranges = result[i].ranges.copy()
      let next : Array[VersionRange] = []
      let mut start = sequence_uint
      let mut end = sequence_uint + 1U
      let mut placed = false
      for range in ranges {
        if range.end < start {
          next.push(range)
        } else if end < range.start {
          if !placed {
            next.push({ start, end })
            placed = true
          }
          next.push(range)
        } else {
          start = if range.start < start { range.start } else { start }
          end = if range.end > end { range.end } else { end }
        }
      }
      if !placed {
        next.push({ start, end })
      }
      result[i] = { replica_id, ranges: next }
      return result
    }
  }
  result.push({
    replica_id,
    ranges: [{ start: sequence_uint, end: sequence_uint + 1U }],
  })
  result.sort_by(fn(a, b) { a.replica_id.compare(b.replica_id) })
  result
}

///|
fn Version::advance_op(self : Version, op : @core.Op) -> Version {
  let next = self.frontier.copy()
  for parent in op.parents() {
    for i = 0; i < next.length(); i = i + 1 {
      if next[i] == parent {
        let _ = next.remove(i)
        break
      }
    }
  }
  next.push(@core.RawVersion(op.agent(), op.seq()))
  next.sort_by(compare_raw_version)
  let ranges = version_ranges_advance(self.ranges, op.agent(), op.seq())
  let result : Version = { frontier: next, ranges }
  result
}

///|
priv enum VersionCache {
  Ready(Version)
  Invalid
}

///|
fn VersionCache::empty() -> VersionCache {
  Ready(Version::empty())
}

///|
fn VersionCache::advance(self : VersionCache, op : @core.Op) -> VersionCache {
  match self {
    Ready(version) => Ready(version.advance_op(op))
    Invalid => Invalid
  }
}

///|
/// Advance a local insert batch without rescanning history. Document emits one
/// contiguous same-agent operation per Unicode scalar and returns the last one.
fn Version::advance_local_insert(
  self : Version,
  last_op : @core.Op,
  operation_count : Int,
) -> Version {
  let mut ranges = self.ranges
  let first_sequence = last_op.seq() - operation_count + 1
  for offset in 0..<operation_count {
    ranges = version_ranges_advance(
      ranges,
      last_op.agent(),
      first_sequence + offset,
    )
  }
  let result : Version = {
    frontier: [@core.RawVersion(last_op.agent(), last_op.seq())],
    ranges,
  }
  result
}

///|
fn VersionCache::advance_local_insert(
  self : VersionCache,
  last_op : @core.Op,
  operation_count : Int,
) -> VersionCache {
  match self {
    Ready(version) =>
      Ready(version.advance_local_insert(last_op, operation_count))
    Invalid => Invalid
  }
}

///|
fn VersionCache::invalidate(self : VersionCache) -> VersionCache {
  match self {
    Ready(_) | Invalid => Invalid
  }
}

///|
fn Version::includes(
  self : Version,
  replica_id : String,
  sequence : Int,
) -> Bool {
  let sequence_uint = sequence.reinterpret_as_uint()
  for entry in self.ranges {
    if entry.replica_id == replica_id {
      for range in entry.ranges {
        if sequence_uint >= range.start && sequence_uint < range.end {
          return true
        }
      }
      return false
    }
  }
  false
}

///|
/// Validate that this summary names exactly the resident closure of a local
/// frontier. This is receiver-context validation for decoded Version values.
fn Version::matches_snapshot_closure(
  self : Version,
  snapshot : @history.CausalSnapshot,
  frontier : Array[Int],
) -> Bool {
  let pending = frontier.copy()
  let seen : Map[Int, Bool] = Map([])
  let mut index = 0
  while index < pending.length() {
    let lv = pending[index]
    index += 1
    if seen.get(lv) is Some(_) {
      continue
    }
    let entry = match snapshot.entry(lv) {
      Some(entry) => entry
      None => return false
    }
    if !self.includes(entry.agent(), entry.seq()) {
      return false
    }
    seen[lv] = true
    for parent in entry.parents() {
      pending.push(parent)
    }
  }
  let mut summarized_count = 0L
  for entry in self.ranges {
    for range in entry.ranges {
      summarized_count += (range.end - range.start).to_int64()
    }
  }
  summarized_count == seen.length().to_int64()
}

///|
/// Create an empty version.
pub fn Version::empty() -> Version {
  let result : Version = { frontier: [], ranges: [] }
  result
}
