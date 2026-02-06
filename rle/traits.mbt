///|
/// **Mergeable** - "Can two adjacent things become one?"
///
/// Think of it like train cars coupling together. Two runs can merge only if:
/// - They are logically adjacent (e.g., consecutive characters from same author)
/// - Merging preserves meaning (the merged result equals the concatenation)
///
/// Example: "hel" + "lo" → "hello" (same author, consecutive positions)
/// Counter-example: "hello" + "world" from different authors → cannot merge
pub(open) trait Mergeable {
  can_merge(Self, Self) -> Bool
  merge(Self, Self) -> Self
}

///|
/// **Sliceable** - "Can I cut a piece out of this?"
///
/// Like slicing a loaf of bread. Given a run, extract a sub-range without
/// needing to decompress the entire structure. Essential for RLE efficiency:
/// instead of storing each character separately, we store runs and slice
/// only when we need a specific portion.
///
/// Uses half-open interval [start, end) — start is inclusive, end is exclusive.
/// Example: slice("hello", start=1, end=4) → "ell"
pub(open) trait Sliceable {
  slice(Self, start~ : Int, end~ : Int) -> Self
}

///|
/// **HasLength** - "Plain size"
///
/// Basic length for a value.
pub(open) trait HasLength {
  length(Self) -> Int
}

///|
/// **Spanning** - "Two notions of size"
///
/// Many data structures need two different notions of "length":
///
/// - `span`: The total size in the position/index space.
///   This is the space used for indexing and lookups.
///   Always positive; includes all elements regardless of state.
///   Think: "how many slots does this occupy in the index space?"
///
/// - `content_len`: The size of the useful/visible payload.
///   May be less than `span` if some elements are hidden, filtered, or deleted.
///   Think: "how much content is actually meaningful to the consumer?"
///
/// Examples:
/// - In a CRDT: span = structural length (incl. tombstones),
///   content_len = visible length (excl. tombstones)
/// - In a gap buffer: span = total (incl. gap), content_len = actual text
/// - In plain text: span = content_len = character count
///
/// Note: `span` defaults to `HasLength::length` unless overridden.
pub(open) trait Spanning: HasLength {
  span(Self) -> Int = _
  content_len(Self) -> Int
}

///|
/// Default span delegates to plain length.
impl Spanning with span(self) {
  HasLength::length(self)
}
