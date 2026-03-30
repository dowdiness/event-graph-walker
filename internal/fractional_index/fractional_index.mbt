///| Dense sibling ordering via fractional indices.
///
/// A `FractionalIndex` is a lexicographically ordered key that supports
/// generating a new key between any two existing keys (density property).
/// Elements are integers in `[0, 65536)` compared with implicit zero-padding.

///|
/// Maximum value for each element (exclusive upper bound).
let max_value : Int = 65536

///|
/// A fractional index for dense sibling ordering.
///
/// Internally an `Array[Int]` with elements in `[0, 65536)`,
/// compared lexicographically with implicit zero-padding for shorter arrays.
/// Trailing zeros are stripped on construction (normalization).
pub struct FractionalIndex {
  priv elements : Array[Int]
}

///|
/// Create a new FractionalIndex from raw elements.
/// Normalizes by stripping trailing zeros.
/// Aborts if any element is outside `[0, max_value)`.
pub fn FractionalIndex::new(elements : Array[Int]) -> FractionalIndex {
  for i = 0; i < elements.length(); i = i + 1 {
    if elements[i] < 0 || elements[i] >= max_value {
      abort("FractionalIndex::new: element out of range [0, 65536)")
    }
  }
  let normalized = normalize(elements)
  { elements: normalized }
}

///|
/// Return the underlying elements (read-only copy).
pub fn FractionalIndex::elements(self : FractionalIndex) -> Array[Int] {
  self.elements.copy()
}

///|
/// Length of the elements array.
pub fn FractionalIndex::length(self : FractionalIndex) -> Int {
  self.elements.length()
}

///|
/// Get element at position, defaulting to 0 for out-of-bounds (implicit zero-padding).
fn FractionalIndex::get_or_zero(self : FractionalIndex, i : Int) -> Int {
  if i < self.elements.length() {
    self.elements[i]
  } else {
    0
  }
}

///|
/// Normalize by stripping trailing zeros.
fn normalize(elements : Array[Int]) -> Array[Int] {
  let mut last_nonzero = -1
  for i = 0; i < elements.length(); i = i + 1 {
    if elements[i] != 0 {
      last_nonzero = i
    }
  }
  if last_nonzero < 0 {
    return []
  }
  elements[:last_nonzero + 1].to_array()
}

///|
/// Generate a compact successor after `left`.
///
/// Prefer incrementing an existing component so append-heavy workloads stay at
/// the same depth while there is still numeric space. Only fall back to a
/// deeper key when every existing component is saturated.
fn successor_after(left : FractionalIndex) -> FractionalIndex {
  let result = left.elements.copy()
  for i = result.length() - 1; i >= 0; i = i - 1 {
    if result[i] < max_value - 1 {
      result[i] = result[i] + 1
      return FractionalIndex::new(result[:i + 1].to_array())
    }
  }
  result.push(max_value / 2)
  FractionalIndex::new(result)
}

///|
/// Lexicographic comparison with implicit zero-padding.
pub impl Compare for FractionalIndex with compare(self, other) -> Int {
  let len = if self.elements.length() > other.elements.length() {
    self.elements.length()
  } else {
    other.elements.length()
  }
  for i = 0; i < len; i = i + 1 {
    let a = self.get_or_zero(i)
    let b = other.get_or_zero(i)
    if a < b {
      return -1
    }
    if a > b {
      return 1
    }
  }
  0
}

///|
pub impl Eq for FractionalIndex with equal(self, other) -> Bool {
  self.compare(other) == 0
}

///|
pub impl Show for FractionalIndex with output(self, logger) -> Unit {
  logger.write_string("FractionalIndex([")
  for i = 0; i < self.elements.length(); i = i + 1 {
    if i > 0 {
      logger.write_string(", ")
    }
    logger.write_string(self.elements[i].to_string())
  }
  logger.write_string("])")
}

///|
pub impl Debug for FractionalIndex with to_repr(self) -> Repr {
  Repr::literal(self.to_string())
}

///|
/// Generate a fractional index between two optional bounds.
///
/// - `between(None, None)` -- midpoint `[32768]`
/// - `between(Some(a), Some(b))` where `a < b` -- key strictly between a and b
/// - `between(None, Some(r))` -- key strictly before r
/// - `between(Some(l), None)` -- key strictly after l
///
/// The density invariant guarantees that between ANY two distinct keys,
/// a third key can always be constructed.
pub fn FractionalIndex::between(
  left~ : FractionalIndex?,
  right~ : FractionalIndex?,
) -> FractionalIndex {
  match (left, right) {
    (None, None) => FractionalIndex::new([max_value / 2])
    (Some(l), Some(r)) => between_impl(l, r)
    (None, Some(r)) => between_impl(FractionalIndex::new([]), r)
    (Some(l), None) => successor_after(l)
  }
}

///|
/// Core between algorithm.
///
/// Walk positions left-to-right:
/// 1. `lo = left[i] or 0`, `hi = right[i] or max_value` (when right not open)
/// 2. If `lo == hi`: emit lo, continue
/// 3. If `hi - lo > 1`: emit midpoint `lo + (hi - lo) / 2`, done
/// 4. If `hi - lo == 1`: emit lo, set right to "open" (hi = max_value hereafter), continue
fn between_impl(
  left : FractionalIndex,
  right : FractionalIndex,
) -> FractionalIndex {
  // Precondition: left < right. Violating this (e.g. passing the empty key as
  // `right` when it is already the minimum) produces a result equal to one of
  // the bounds and breaks the density invariant.
  if left.compare(right) >= 0 {
    abort("FractionalIndex::between: left must be strictly less than right")
  }
  let result : Array[Int] = []
  let max_len = if left.elements.length() > right.elements.length() {
    left.elements.length()
  } else {
    right.elements.length()
  }
  let mut right_is_open = false
  // We may need to go beyond max_len if both sides exhaust at the same values
  let limit = max_len + 64 // safety bound to prevent infinite loops
  for i = 0; i < limit; i = i + 1 {
    let lo = left.get_or_zero(i)
    let hi = if right_is_open { max_value } else { right.get_or_zero(i) }
    // When right is not open and we're past right's length, hi defaults to max_value
    let hi = if !right_is_open && i >= right.elements.length() {
      max_value
    } else {
      hi
    }
    if lo == hi {
      result.push(lo)
      continue i + 1
    }
    if hi - lo > 1 {
      result.push(lo + (hi - lo) / 2)
      break
    }
    // hi - lo == 1: emit lo, open the right side
    if hi - lo == 1 {
      result.push(lo)
      right_is_open = true
      continue i + 1
    }
  }
  FractionalIndex::new(result)
}
