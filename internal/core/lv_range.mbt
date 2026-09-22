///|
/// A contiguous range of local versions [start, start+count).
///
/// Used to compress graph traversal results (topological_sort,
/// walk_from_frontier, diff_frontiers_lvs) where consecutive LVs
/// are common in linear editing sessions.
pub(all) struct LvRange {
  start : Int
  count : Int
} derive(Eq, Debug)

///|
pub impl @rle.HasLength for LvRange with fn length(self) {
  self.count
}

///|
pub impl @rle.Spanning for LvRange with fn span(self) {
  self.count
}

///|
pub impl @rle.Spanning for LvRange with fn logical_length(self) {
  self.count
}

///|
pub impl @rle.Mergeable for LvRange with fn can_merge(a, b) {
  a.start + a.count == b.start
}

///|
pub impl @rle.Mergeable for LvRange with fn merge(a, b) {
  { start: a.start, count: a.count + b.count, }
}

///|
pub impl @rle.FromRange for LvRange with fn from_range(start, count) {
  { start, count, }
}

///|
pub impl @rle.Addressable for LvRange with fn address(
  self,
  _global_start,
  offset,
) {
  self.start + offset
}

///|
/// Check if a given LV falls within this range.
pub fn LvRange::contains(self : LvRange, lv : Int) -> Bool {
  lv >= self.start && lv < self.end()
}

///|
/// Get the end (exclusive) of this range.
pub fn LvRange::end(self : LvRange) -> Int {
  self.start + self.count
}

// ---------------------------------------------------------------------------
// Explicit trait-method promotions (E0079).
// `#doc(hidden)` keeps these out of the generated interface while preserving
// dot-syntax and cross-package use.
// ---------------------------------------------------------------------------

///|
#doc(hidden)
pub extend LvRange with @rle.Addressable::{address}

///|
#doc(hidden)
pub extend LvRange with @rle.FromRange::{from_range}

///|
#doc(hidden)
pub extend LvRange with @rle.HasLength::{length, is_empty}

///|
#doc(hidden)
pub extend LvRange with @rle.Mergeable::{can_merge, merge}

///|
#doc(hidden)
pub extend LvRange with @rle.Spanning::{logical_length, span}

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend LvRange with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend LvRange with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend LvRange with Eq::{not_equal}
