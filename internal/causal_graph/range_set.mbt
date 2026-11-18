///|
/// An immutable canonical union of LV intervals. Storage order is always ascending.
#derive(Eq, @debug.Debug)
pub struct RangeSet {
  priv ranges : Array[@core.LvRange]
}

///|
pub extend RangeSet with Eq::{equal, not_equal}

///|
pub extend RangeSet with @debug.Debug::{to_repr}

///|
#derive(Eq)
pub(all) enum Direction {
  Forward
  Backward
}

///|
pub extend Direction with Eq::{equal, not_equal}

///|
pub fn RangeSet::new() -> RangeSet {
  { ranges: [], }
}

///|
/// Construct from valid, nonnegative LV ranges; copy and normalize their union.
pub fn RangeSet::from_array(input : Array[@core.LvRange]) -> RangeSet {
  let sorted = input.copy()
  sorted.sort_by((a, b) => a.start.compare(b.start))
  let ranges : Array[@core.LvRange] = []
  for range in sorted {
    guard range.start >= 0 && range.count >= 0 && range.end() >= range.start else {
      abort("invalid LV range")
    }
    if range.count == 0 {
      continue
    }
    if !ranges.is_empty() {
      let last = ranges[ranges.length() - 1]
      if range.start <= last.end() {
        if range.end() > last.end() {
          ranges[ranges.length() - 1] = {
            start: last.start,
            count: range.end() - last.start,
          }
        }
        continue
      }
    }
    ranges.push(range)
  }
  { ranges, }
}

///|
pub fn RangeSet::iter(
  self : RangeSet,
  direction~ : Direction = Forward,
) -> Iter[@core.LvRange] {
  if direction == Forward {
    self.ranges.iter()
  } else {
    self.ranges.rev_iter()
  }
}

///|
/// Expand only at the operation-execution boundary. Backward reverses both levels.
pub fn RangeSet::iter_units(
  self : RangeSet,
  direction~ : Direction = Forward,
) -> Iter[Int32] {
  self
  .iter(direction~)
  .flat_map(range => {
    let mut lv = if direction == Forward {
      range.start
    } else {
      range.end() - 1
    }
    Iter::new(fn() {
      if lv < range.start || lv >= range.end() {
        return None
      }
      let result = lv
      lv += if direction == Forward { 1 } else { -1 }
      Some(result)
    })
  })
}

///|
pub fn RangeSet::contains(self : RangeSet, lv : Int32) -> Bool {
  self.ranges.binary_search_by(range => {
    if lv < range.start {
      1
    } else if lv >= range.end() {
      -1
    } else {
      0
    }
  })
  is Ok(_)
}

///|
/// Linear interval subtraction. No operation enumeration or sorting is needed.
pub fn RangeSet::subtract(self : RangeSet, other : RangeSet) -> RangeSet {
  let ranges : Array[@core.LvRange] = []
  let mut j = 0
  for range in self.ranges {
    let mut cursor = range.start
    while j < other.ranges.length() && other.ranges[j].end() <= cursor {
      j += 1
    }
    while j < other.ranges.length() && other.ranges[j].start < range.end() {
      let covered = other.ranges[j]
      if covered.start > cursor {
        ranges.push({ start: cursor, count: covered.start - cursor, })
      }
      if covered.end() > cursor {
        cursor = covered.end()
      }
      if cursor >= range.end() {
        break
      }
      j += 1
    }
    if cursor < range.end() {
      ranges.push({ start: cursor, count: range.end() - cursor, })
    }
  }
  { ranges, }
}

///|
pub fn RangeSet::range_count(self : RangeSet) -> Int32 {
  self.ranges.length()
}

///|
pub fn RangeSet::cardinality(self : RangeSet) -> Int32 {
  self.ranges.fold(init=0, (sum, range) => sum + range.count)
}

///|
pub fn RangeSet::is_empty(self : RangeSet) -> Bool {
  self.ranges.is_empty()
}
