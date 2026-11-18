///| Both coordinate systems belong to the same projection and treap generation.

///|
fn LvLocator::rank_utf16_span(self : LvLocator, node : Int32) -> Int32 {
  if node == -1 {
    0
  } else {
    self.nodes[node].utf16_span
  }
}

///|
fn LvLocator::convert_boundary(
  self : LvLocator,
  offset : Int32,
  from_utf16 : Bool,
) -> Int32? {
  let scalar_total = self.rank_visible_span(self.rank_root)
  let utf16_total = self.rank_utf16_span(self.rank_root)
  let total = if from_utf16 { utf16_total } else { scalar_total }
  if offset < 0 || offset > total {
    return None
  }
  if offset == total {
    return Some(if from_utf16 { scalar_total } else { utf16_total })
  }
  let mut node = self.rank_root
  let mut remaining = offset
  let mut converted = 0
  while node != -1 {
    let rank = self.nodes[node]
    let left_scalar = self.rank_visible_span(rank.left)
    let left_utf16 = self.rank_utf16_span(rank.left)
    let left = if from_utf16 { left_utf16 } else { left_scalar }
    let other_left = if from_utf16 { left_scalar } else { left_utf16 }
    if remaining < left {
      node = rank.left
    } else {
      remaining -= left
      converted += other_left
      if remaining == 0 {
        return Some(converted)
      }
      let width = if !rank.visible {
        0
      } else if from_utf16 {
        rank.utf16_width
      } else {
        1
      }
      if remaining < width {
        return None
      } // Inside a surrogate pair.
      remaining -= width
      converted += if !rank.visible {
        0
      } else if from_utf16 {
        1
      } else {
        rank.utf16_width
      }
      node = rank.right
    }
  }
  None
}

///|
fn IndexedState::utf16_at(self : IndexedState, position : Int32) -> Int32 {
  self.locator.unwrap().convert_boundary(position, false).unwrap()
}

///|
pub fn Document::scalar_at_utf16(
  self : Document,
  offset : Int32,
) -> Int32? raise DocumentError {
  self.ensure_projection_ready()
  ignore(self.indexed_state.ensure(self.tree))
  self.indexed_state.locator.unwrap().convert_boundary(offset, true)
}

///|
/// Length from the same index used for boundary conversion; no text snapshot.
pub fn Document::utf16_len(self : Document) -> Int32 raise DocumentError {
  self.ensure_projection_ready()
  ignore(self.indexed_state.ensure(self.tree))
  let locator = self.indexed_state.locator.unwrap()
  locator.rank_utf16_span(locator.rank_root)
}
