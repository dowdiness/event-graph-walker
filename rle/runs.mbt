///|
/// Array of mergeable runs - core RLE data structure
pub struct Runs[T](Array[T]) derive(Show, Eq)

///|
pub fn[T] Runs::new() -> Runs[T] {
  Runs([])
}

///|
/// Batch construction - single-pass stack merge, avoids repeated normalize_tail
pub fn[T : Mergeable + Spanning] Runs::from_array_batch(
  arr : Array[T],
) -> Runs[T] {
  let out : Array[T] = []
  for item in arr {
    if T::span(item) <= 0 {
      continue
    }
    if out.is_empty() {
      out.push(item)
      continue
    }
    // Stack-merge: fold into tail and cascade as needed
    let mut cur = item
    while not(out.is_empty()) {
      let last = out[out.length() - 1]
      if T::can_merge(last, cur) {
        let _ = out.pop()
        cur = T::merge(last, cur)
      } else {
        break
      }
    }
    out.push(cur)
  }
  Runs(out)
}

///|
pub fn[T : Mergeable + Spanning] Runs::from_array(
  arr : Array[T],
) -> Runs[T] {
  Runs::from_array_batch(arr)
}

///|
pub fn[T] Runs::is_empty(self : Runs[T]) -> Bool {
  self.0.is_empty()
}

///|
pub fn[T] Runs::count(self : Runs[T]) -> Int {
  self.0.length()
}

///|
pub fn[T] Runs::get(self : Runs[T], index : Int) -> T? {
  if index < 0 || index >= self.0.length() {
    None
  } else {
    Some(self.0[index])
  }
}

///|
pub fn[T] Runs::iter(self : Runs[T]) -> Iter[T] {
  self.0.iter()
}

///|
pub fn[T] Runs::to_array(self : Runs[T]) -> Array[T] {
  self.0.copy()
}

///|
/// Total span length - O(n)
pub fn[T : Spanning] Runs::len(self : Runs[T]) -> Int {
  self.0.fold(init=0, fn(acc, item) { acc + T::span(item) })
}

///|
/// Total content length - O(n)
pub fn[T : Spanning] Runs::content_len(self : Runs[T]) -> Int {
  self.0.fold(init=0, fn(acc, item) { acc + T::content_len(item) })
}

///|
/// Append an element to the runs, merging with the last run if possible.
///
/// This is the primary insertion method for RLE-compressed sequences. If the
/// new element is contiguous with the last run (determined by `can_merge`),
/// they are combined into a single run. Otherwise, a new run is created.
///
/// **Complexity**: O(1) amortized. Merge check and append are constant time,
/// with occasional O(k) normalization where k = number of cascading merges.
///
/// **Invariant**: After append, no two adjacent runs are mergeable.
pub fn[T : Mergeable + Spanning] Runs::append(
  self : Runs[T],
  elem : T,
) -> Result[Unit, RleError] {
  if T::span(elem) <= 0 {
    return Err(RleError::Internal(InternalError::EmptyElement))
  }
  match self.0.last() {
    Some(last) =>
      if T::can_merge(last, elem) {
        self.0[self.0.length() - 1] = T::merge(last, elem)
        self.normalize_tail()
      } else {
        self.0.push(elem)
      }
    None => self.0.push(elem)
  }
  Ok(())
}

///|
/// Cascade merging leftward after append to maintain RLE invariants.
///
/// After merging the last two runs, the resulting run may now be mergeable
/// with its predecessor. This function iteratively merges backward until
/// no more merges are possible.
///
/// **Complexity**: O(k) where k = number of consecutive mergeable runs.
/// In practice, k is typically 1-2 for well-distributed insertions.
///
/// **Invariant**: After normalization, no two adjacent runs satisfy `can_merge`.
fn[T : Mergeable] Runs::normalize_tail(self : Runs[T]) -> Unit {
  while self.0.length() >= 2 {
    let last = self.0.length() - 1
    let prev = last - 1
    let a = self.0[prev]
    let b = self.0[last]
    if T::can_merge(a, b) {
      self.0[prev] = T::merge(a, b)
      let _ = self.0.pop()

    } else {
      break
    }
  }
}

///|
/// Find position in runs - O(n) linear scan
/// Prefer `Runs::find_fast` with cached prefix sums for repeated lookups.
pub fn[T : Spanning] Runs::find(self : Runs[T], pos : Int) -> RunPos? {
  if pos < 0 {
    return None
  }
  let mut prefix = 0
  for i = 0; i < self.0.length(); i = i + 1 {
    let run_len = T::span(self.0[i])
    if pos < prefix + run_len {
      return Some({ run: i, offset: pos - prefix })
    }
    prefix = prefix + run_len
  }
  None
}

///|
/// Find position using prefix sums - O(log n) binary search
/// Caller manages `PrefixSums` (use `Runs::prefix_sums()` and keep it in sync).
pub fn[T] Runs::find_fast(
  self : Runs[T],
  sums : PrefixSums,
  pos : Int,
) -> RunPos? {
  if pos < 0 || self.is_empty() {
    return None
  }
  let total = match sums.spans.last() {
    Some(t) => t
    None => return None
  }
  if pos >= total {
    return None
  }
  // Binary search: find smallest i where spans[i] > pos
  let mut lo = 0
  let mut hi = self.0.length()
  while lo < hi {
    let mid = lo + (hi - lo) / 2
    if sums.spans[mid] <= pos {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo == 0 {
    Some({ run: 0, offset: pos })
  } else {
    Some({ run: lo, offset: pos - sums.spans[lo - 1] })
  }
}

///|
/// Build prefix sums from runs
pub fn[T : Spanning] Runs::prefix_sums(self : Runs[T]) -> PrefixSums {
  let spans : Array[Int] = []
  let content : Array[Int] = []
  let mut span_sum = 0
  let mut content_sum = 0
  for item in self.0 {
    span_sum = span_sum + T::span(item)
    content_sum = content_sum + T::content_len(item)
    spans.push(span_sum)
    content.push(content_sum)
  }
  { spans, content }
}

///|
/// Iterate slices in range [start, end)
pub fn[T : Spanning] Runs::range(
  self : Runs[T],
  start~ : Int,
  end~ : Int,
) -> Result[Iter[Slice[T]], RleError] {
  let total = self.len()
  if start < 0 {
    return Err(
      RleError::InvalidRange(start~, end~, length=total, reason=NegativeStart),
    )
  }
  if end < 0 {
    return Err(
      RleError::InvalidRange(start~, end~, length=total, reason=NegativeEnd),
    )
  }
  if start > end {
    return Err(
      RleError::InvalidRange(start~, end~, length=total, reason=StartAfterEnd),
    )
  }
  if end > total {
    return Err(
      RleError::InvalidRange(start~, end~, length=total, reason=ExceedsLength),
    )
  }
  if start == end {
    return Ok(Iter::empty())
  }
  let result : Array[Slice[T]] = []
  let mut pos = 0
  for item in self.0 {
    let run_len = T::span(item)
    let item_end = pos + run_len
    if item_end > start && pos < end {
      let slice_start = if pos < start { start - pos } else { 0 }
      let slice_end = if item_end > end { end - pos } else { run_len }
      result.push({ value: item, start: slice_start, end: slice_end })
    }
    pos = item_end
    if pos >= end {
      break
    }
  }
  Ok(result.iter())
}

///|
/// Iterate slices with clamped bounds
pub fn[T : Spanning] Runs::range_clamped(
  self : Runs[T],
  start~ : Int,
  end~ : Int,
) -> Iter[Slice[T]] {
  let total = self.len()
  let s = if start < 0 { 0 } else { start }
  let e = if end > total { total } else { end }
  if s >= e {
    return Iter::empty()
  }
  match self.range(start=s, end=e) {
    Ok(it) => it
    Err(_) => Iter::empty()
  }
}

///|
/// Split at position into two Runs
pub fn[T : Sliceable + Spanning + Mergeable] Runs::split(
  self : Runs[T],
  pos : Int,
) -> Result[(Runs[T], Runs[T]), RleError] {
  let total = self.len()
  if pos < 0 || pos > total {
    return Err(RleError::PositionOutOfBounds(position=pos, length=total))
  }
  if pos == 0 {
    return Ok((Runs::new(), self))
  }
  if pos == total {
    return Ok((self, Runs::new()))
  }
  let left : Runs[T] = Runs::new()
  let right : Runs[T] = Runs::new()
  let mut cur = 0
  for item in self.0 {
    let run_len = T::span(item)
    let item_end = cur + run_len
    if item_end <= pos {
      match left.append(item) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    } else if cur >= pos {
      match right.append(item) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    } else {
      let offset = pos - cur
      if offset > 0 {
        match left.append(T::slice(item, start=0, end=offset)) {
          Err(e) => return Err(e)
          Ok(_) => ()
        }
      }
      if offset < run_len {
        match right.append(T::slice(item, start=offset, end=run_len)) {
          Err(e) => return Err(e)
          Ok(_) => ()
        }
      }
    }
    cur = item_end
  }
  Ok((left, right))
}

///|
/// Clear all runs
pub fn[T] Runs::clear(self : Runs[T]) -> Unit {
  self.0.clear()
}

///|
/// Concatenate two Runs - batch optimized, single boundary merge
/// Delegates to from_array_batch when self is empty to avoid code duplication.
pub fn[T : Mergeable + Spanning] Runs::concat(
  self : Runs[T],
  other : Runs[T],
) -> Runs[T] {
  if self.is_empty() {
    return Runs::from_array_batch(other.0)
  }
  if other.is_empty() {
    return Runs(self.0.copy())
  }
  let out : Array[T] = self.0.copy()
  for item in other.0 {
    if T::span(item) <= 0 {
      continue
    }
    let mut cur = item
    while not(out.is_empty()) {
      let last = out[out.length() - 1]
      if T::can_merge(last, cur) {
        let _ = out.pop()
        cur = T::merge(last, cur)
      } else {
        break
      }
    }
    out.push(cur)
  }
  Runs(out)
}

///|
/// Extend in-place from another Runs - batch optimized
pub fn[T : Mergeable + Spanning] Runs::extend(
  self : Runs[T],
  other : Runs[T],
) -> Unit {
  if other.is_empty() {
    return
  }
  for item in other.0 {
    if T::span(item) <= 0 {
      continue
    }
    let mut cur = item
    while not(self.0.is_empty()) {
      let last = self.0[self.0.length() - 1]
      if T::can_merge(last, cur) {
        let _ = self.0.pop()
        cur = T::merge(last, cur)
      } else {
        break
      }
    }
    self.0.push(cur)
  }
}
