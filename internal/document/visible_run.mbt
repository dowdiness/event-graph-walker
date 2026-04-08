///| VisibleRun — compressed representation of consecutive visible items
/// in document order. Used as the element type for OrderTree[VisibleRun]
/// in the position cache.

///|
/// A run of consecutive visible items in document order.
///
/// **Merge condition:** Two runs merge when they are adjacent in document
/// order AND have consecutive LVs (`a.start_lv + a.count == b.start_lv`).
/// Document-order adjacency is guaranteed by the build order (tree
/// traversal emits items in document order, so two successive visible
/// items that also have consecutive LVs must be adjacent).
struct VisibleRun {
  start_lv : Int // First LV in this visible run
  text : String // Concatenated visible text
  count : Int // Number of items in run
} derive(Debug, Eq)

///|
pub impl @rle.HasLength for VisibleRun with length(self) -> Int {
  self.count
}

///|
/// span = count (one item per position in the item space).
/// This is the coordinate space for OrderTree::find — position-based lookup.
pub impl @rle.Spanning for VisibleRun with span(self) -> Int {
  self.count
}

///|
/// logical_length = text.length() (visible character count in UTF-16 code units).
pub impl @rle.Spanning for VisibleRun with logical_length(self) -> Int {
  self.text.length()
}

///|
/// Two runs can merge when they have consecutive LVs.
/// Safety: this merge condition is valid only when runs are appended in
/// document order (tree traversal). Do not use with arbitrary insertion.
pub impl @rle.Mergeable for VisibleRun with can_merge(self, other) -> Bool {
  self.start_lv + self.count == other.start_lv
}

///|
pub impl @rle.Mergeable for VisibleRun with merge(self, other) -> VisibleRun {
  {
    start_lv: self.start_lv,
    text: self.text + other.text,
    count: self.count + other.count,
  }
}

///|
/// Sliceable enables split/insert/delete on OrderTree[VisibleRun].
pub impl @rle.Sliceable for VisibleRun with slice(
  self,
  start~ : Int,
  end~ : Int,
) -> Result[VisibleRun, @rle.RleError] {
  if start < 0 || end > self.count || start > end {
    return Err(
      @rle.RleError::InvalidSlice(reason=@rle.SliceError::IndexOutOfBounds),
    )
  }
  let text_start = item_offset_to_utf16(self.text, start)
  let text_end = item_offset_to_utf16(self.text, end)
  match @rle.slice_string_view(self.text, start=text_start, end=text_end) {
    Ok(sliced_text) =>
      Ok({
        start_lv: self.start_lv + start,
        text: sliced_text,
        count: end - start,
      })
    Err(e) => Err(@rle.RleError::InvalidSlice(reason=e))
  }
}

///|
impl @btree.BTreeElem for VisibleRun

///|
/// Convert an item offset (0-based character index) to a UTF-16 code unit offset.
///
/// Each CRDT item is one character. Characters may be 1 or 2 UTF-16 code units.
fn item_offset_to_utf16(text : String, item_offset : Int) -> Int {
  if item_offset == 0 {
    return 0
  }
  let mut chars_seen = 0
  let mut utf16_pos = 0
  while utf16_pos < text.length() && chars_seen < item_offset {
    let code_unit = text[utf16_pos].to_int()
    if code_unit >= 0xD800 && code_unit <= 0xDBFF {
      // Surrogate pair: 2 UTF-16 code units = 1 character
      utf16_pos = utf16_pos + 2
    } else {
      utf16_pos = utf16_pos + 1
    }
    chars_seen = chars_seen + 1
  }
  utf16_pos
}
