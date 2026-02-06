///|
/// Prefix sums for O(log n) position lookup
pub(all) struct PrefixSums {
  spans : Array[Int] // cumulative span lengths
  content : Array[Int] // cumulative content lengths
} derive(Show, Eq)

///|
pub fn PrefixSums::new() -> PrefixSums {
  { spans: [], content: [] }
}

///|
/// Total span length - O(1)
pub fn PrefixSums::len(self : PrefixSums) -> Int {
  match self.spans.last() {
    Some(total) => total
    None => 0
  }
}

///|
/// Total content length - O(1)
pub fn PrefixSums::content_len(self : PrefixSums) -> Int {
  match self.content.last() {
    Some(total) => total
    None => 0
  }
}

///|
/// Number of runs
pub fn PrefixSums::count(self : PrefixSums) -> Int {
  self.spans.length()
}

///|
/// Get span offset at run index (end of run i)
pub fn PrefixSums::span_at(self : PrefixSums, index : Int) -> Int? {
  if index < 0 || index >= self.spans.length() {
    None
  } else {
    Some(self.spans[index])
  }
}

///|
/// Get span offset before run index (start of run i)
pub fn PrefixSums::span_before(self : PrefixSums, index : Int) -> Int {
  if index <= 0 {
    0
  } else {
    self.spans[index - 1]
  }
}
