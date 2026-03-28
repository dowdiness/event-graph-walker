///| Quickcheck property tests for FractionalIndex

///|
/// Wrapper for generating valid FractionalIndex pairs where a < b.
pub(all) struct OrderedPair {
  left : @fractional_index.FractionalIndex
  right : @fractional_index.FractionalIndex
} derive(Show)

///|
pub impl @quickcheck.Arbitrary for OrderedPair with arbitrary(size, rs) {
  // Generate 1-4 elements in [0, 65535]
  let len_a = rs.next_uint64().to_int().abs() % 4 + 1
  let elems_a : Array[Int] = []
  for i = 0; i < len_a; i = i + 1 {
    let _ = i
    elems_a.push(rs.next_uint64().to_int().abs() % 65536)
  }
  let a = @fractional_index.FractionalIndex::new(elems_a)
  // Generate b by taking a and adding a positive offset at some position
  let len_b = rs.next_uint64().to_int().abs() % 4 + 1
  let elems_b : Array[Int] = []
  for i = 0; i < len_b; i = i + 1 {
    let _ = i
    elems_b.push(rs.next_uint64().to_int().abs() % 65536)
  }
  let b = @fractional_index.FractionalIndex::new(elems_b)
  let _ = size
  // Ensure a < b by swapping if needed, skip if equal
  if a < b {
    { left: a, right: b }
  } else if b < a {
    { left: b, right: a }
  } else {
    // Equal — offset b by appending 1
    let elems_b2 : Array[Int] = a.elements()
    elems_b2.push(1)
    { left: a, right: @fractional_index.FractionalIndex::new(elems_b2) }
  }
}

///|
/// Shrink instance for OrderedPair — try smaller element values.
pub impl @qc.Shrink for OrderedPair with shrink(self) {
  let results : Array[OrderedPair] = []
  // Try reducing elements of left
  let left_elems = self.left.elements()
  if left_elems.length() > 1 {
    let shorter = left_elems[:left_elems.length() - 1].to_array()
    let candidate = @fractional_index.FractionalIndex::new(shorter)
    if candidate < self.right {
      results.push({ left: candidate, right: self.right })
    }
  }
  // Try reducing elements of right
  let right_elems = self.right.elements()
  if right_elems.length() > 1 {
    let shorter = right_elems[:right_elems.length() - 1].to_array()
    let candidate = @fractional_index.FractionalIndex::new(shorter)
    if self.left < candidate {
      results.push({ left: self.left, right: candidate })
    }
  }
  results.iter()
}

///|
/// Wrapper for generating a single valid FractionalIndex.
pub(all) struct SingleKey {
  key : @fractional_index.FractionalIndex
} derive(Show)

///|
/// Shrink instance for SingleKey — try shorter element lists.
pub impl @qc.Shrink for SingleKey with shrink(self) {
  let results : Array[SingleKey] = []
  let elems = self.key.elements()
  if elems.length() > 1 {
    let shorter = elems[:elems.length() - 1].to_array()
    results.push({ key: @fractional_index.FractionalIndex::new(shorter) })
  }
  results.iter()
}

///|
pub impl @quickcheck.Arbitrary for SingleKey with arbitrary(size, rs) {
  let len = rs.next_uint64().to_int().abs() % 4 + 1
  let elems : Array[Int] = []
  let _ = size
  for i = 0; i < len; i = i + 1 {
    let _ = i
    elems.push(rs.next_uint64().to_int().abs() % 65536)
  }
  { key: @fractional_index.FractionalIndex::new(elems) }
}

///|
/// Property 1: between(a, b) is always strictly between a and b when a < b.
test "property: between(a, b) is strictly between a and b" {
  @qc.quick_check_fn(fn(pair : OrderedPair) -> Bool {
    let mid = @fractional_index.FractionalIndex::between(
      left=Some(pair.left),
      right=Some(pair.right),
    )
    pair.left < mid && mid < pair.right
  })
}

///|
/// Property 2: between(None, b) is always < b.
///
/// Skip when b normalizes to the empty key (length 0) because the empty key
/// is already the minimum — there is no valid key strictly less than it.
test "property: between(None, b) is always < b" {
  @qc.quick_check_fn(fn(sk : SingleKey) -> Bool {
    if sk.key.length() == 0 {
      return true
    }
    let mid = @fractional_index.FractionalIndex::between(
      left=None,
      right=Some(sk.key),
    )
    mid < sk.key
  })
}

///|
/// Property 3: between(a, None) is always > a.
test "property: between(a, None) is always > a" {
  @qc.quick_check_fn(fn(sk : SingleKey) -> Bool {
    let mid = @fractional_index.FractionalIndex::between(
      left=Some(sk.key),
      right=None,
    )
    sk.key < mid
  })
}
