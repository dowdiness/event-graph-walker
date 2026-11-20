///|
/// Canonical sequence intervals in one AVL tree, with no second endpoint index.
/// Range values are immutable: updates replace them, so snapshots can share
/// unchanged intervals without copying them or exposing mutable tree nodes.
priv struct SequenceNode {
  mut range : SequenceRange
  mut height : Int32
  mut left : SequenceNode?
  mut right : SequenceNode?
}

///|
priv struct SequenceIndex {
  mut root : SequenceNode?
}

///|
fn sequence_height(node : SequenceNode?) -> Int32 {
  match node {
    None => 0
    Some(node) => node.height
  }
}

///|
fn SequenceNode::update_height(self : SequenceNode) -> Unit {
  self.height = 1 +
    Int32::max(sequence_height(self.left), sequence_height(self.right))
}

///|
fn SequenceNode::rotate_left(self : SequenceNode) -> SequenceNode {
  let right = self.right.unwrap()
  self.right = right.left
  right.left = Some(self)
  self.update_height()
  right.update_height()
  right
}

///|
fn SequenceNode::rotate_right(self : SequenceNode) -> SequenceNode {
  let left = self.left.unwrap()
  self.left = left.right
  left.right = Some(self)
  self.update_height()
  left.update_height()
  left
}

///|
fn SequenceNode::balance(self : SequenceNode) -> SequenceNode {
  self.update_height()
  let difference = sequence_height(self.left) - sequence_height(self.right)
  if difference > 1 {
    let left = self.left.unwrap()
    if sequence_height(left.left) < sequence_height(left.right) {
      self.left = Some(left.rotate_left())
    }
    self.rotate_right()
  } else if difference < -1 {
    let right = self.right.unwrap()
    if sequence_height(right.right) < sequence_height(right.left) {
      self.right = Some(right.rotate_right())
    }
    self.rotate_left()
  } else {
    self
  }
}

///|
fn SequenceNode::remove_first(self : SequenceNode) -> SequenceNode? {
  match self.left {
    None => self.right
    Some(left) => {
      self.left = left.remove_first()
      Some(self.balance())
    }
  }
}

///|
fn SequenceNode::remove_last(self : SequenceNode) -> SequenceNode? {
  match self.right {
    None => self.left
    Some(right) => {
      self.right = right.remove_last()
      Some(self.balance())
    }
  }
}

///|
/// Every identity in the range is absent. Join adjacent intervals, absorbing
/// the other neighbor when this range closes a gap. Single inserts use the same path.
fn sequence_insert(root : SequenceNode?, range : SequenceRange) -> SequenceNode {
  guard root is Some(node) else {
    return { range, height: 1, left: None, right: None, }
  }
  if range.end < node.range.start {
    node.left = Some(sequence_insert(node.left, range))
  } else if range.start > node.range.end {
    node.right = Some(sequence_insert(node.right, range))
  } else if range.start < node.range.start {
    let mut start = range.start
    if node.left is Some(left) {
      let mut last = left
      while last.right is Some(right) {
        last = right
      }
      if last.range.end == range.start {
        start = last.range.start
        node.left = left.remove_last()
      }
    }
    node.range = { start, end: node.range.end, }
  } else {
    let mut end = range.end
    if node.right is Some(right) {
      let mut first = right
      while first.left is Some(left) {
        first = left
      }
      if first.range.start == end {
        end = first.range.end
        node.right = right.remove_first()
      }
    }
    node.range = { start: node.range.start, end, }
  }
  node.balance()
}

///|
fn SequenceIndex::insert(self : SequenceIndex, sequence : UInt32) -> Unit {
  self.insert_range({ start: sequence, end: sequence + 1U, })
}

///|
fn SequenceIndex::insert_range(
  self : SequenceIndex,
  range : SequenceRange,
) -> Unit {
  self.root = Some(sequence_insert(self.root, range))
}

///|
/// Input is already canonical. Build by median partition in O(intervals),
/// rather than reinserting sorted keys through the incremental update path.
fn SequenceIndex::from_ranges(ranges : Array[SequenceRange]) -> SequenceIndex {
  fn build(start : Int32, end : Int32) -> SequenceNode? {
    if start == end {
      return None
    }
    let middle = start + (end - start) / 2
    let node = SequenceNode::{
      range: ranges[middle],
      height: 1,
      left: build(start, middle),
      right: build(middle + 1, end),
    }
    node.update_height()
    Some(node)
  }
  { root: build(0, ranges.length()), }
}

///|
/// Own the array, share only immutable interval values with the tree.
fn SequenceIndex::snapshot(self : SequenceIndex) -> Array[SequenceRange] {
  let ranges : Array[SequenceRange] = []
  fn visit(node : SequenceNode?) -> Unit {
    if node is Some(node) {
      visit(node.left)
      ranges.push(node.range)
      visit(node.right)
    }
  }
  visit(self.root)
  ranges
}
