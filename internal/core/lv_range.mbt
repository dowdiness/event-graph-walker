///|
/// A contiguous range of local versions [start, start+count).
///
/// Used to compress graph traversal results (topological_sort,
/// walk_from_frontier, diff_frontiers_lvs) where consecutive LVs
/// are common in linear editing sessions.
pub(all) struct LvRange {
  start : Int
  count : Int
} derive(Eq, Show)

///|
pub impl @rle.HasLength for LvRange with length(self) {
  self.count
}

///|
pub impl @rle.Spanning for LvRange with span(self) {
  self.count
}

///|
pub impl @rle.Spanning for LvRange with logical_length(self) {
  self.count
}

///|
pub impl @rle.Mergeable for LvRange with can_merge(a, b) {
  a.start + a.count == b.start
}

///|
pub impl @rle.Mergeable for LvRange with merge(a, b) {
  { start: a.start, count: a.count + b.count }
}

///|
pub impl @rle.FromRange for LvRange with from_range(start, count) {
  { start, count }
}

///|
pub impl @rle.Addressable for LvRange with address(self, _global_start, offset) {
  self.start + offset
}

///|
/// Check if a given LV falls within this range.
pub fn LvRange::contains(self : LvRange, lv : Int) -> Bool {
  lv >= self.start && lv < self.start + self.count
}

///|
/// Get the end (exclusive) of this range.
pub fn LvRange::end(self : LvRange) -> Int {
  self.start + self.count
}
