///|
/// Immutable AVL node used by one parent's ordered child set.
priv enum LocatorSiblings {
  Empty
  Branch(
    left~ : LocatorSiblings,
    lv~ : Int,
    right~ : LocatorSiblings,
    height~ : Int
  )
}

///|
/// Stable Euler-tour handles and Fugue sibling ownership for one LV.
priv struct LocatorItem {
  agent : @fugue.ReplicaId
  sequence : Int
  open_node : Int
  content_node : Int
  close_node : Int
  mut left_children : LocatorSiblings
  mut right_children : LocatorSiblings
}

///|
/// One stable implicit-treap node. Marker nodes have zero visible weight;
/// content nodes toggle between zero and one without changing their handle.
priv struct LocatorRankNode {
  priority : UInt64
  mut left : Int
  mut right : Int
  mut parent : Int
  mut size : Int
  mut visible : Bool
  mut visible_span : Int
}

///|
/// Same-generation inverse index for visible LV scalar positions.
///
/// Every Fugue subtree is represented by stable open/content/close Euler
/// markers in an implicit order-statistic treap. Balanced sibling indexes find
/// the next canonical child; insertion occurs before that child's open marker,
/// the parent's content marker, or the parent's close marker. Rank and
/// visibility updates follow treap height only and never traverse visible runs
/// or Fugue ancestors.
priv struct LvLocator {
  items : Map[Int, LocatorItem]
  nodes : Array[LocatorRankNode]
  mut rank_root : Int
  mut root_divider : Int
  mut root_close : Int
  mut root_left : LocatorSiblings
  mut root_right : LocatorSiblings
}

///|
/// SplitMix64 priority keeps sequential LV allocation from degenerating the
/// implicit treap while remaining deterministic across runtimes.
fn locator_priority(seed : Int) -> UInt64 {
  let mut value = seed.to_uint64() + 0x9E3779B97F4A7C15
  value = value.lxor(value >> 30) * 0xBF58476D1CE4E5B9
  value = value.lxor(value >> 27) * 0x94D049BB133111EB
  value.lxor(value >> 31)
}

///|
fn LvLocator::push_rank_node(self : LvLocator, visible : Bool) -> Int {
  let index = self.nodes.length()
  self.nodes.push({
    priority: locator_priority(index),
    left: -1,
    right: -1,
    parent: -1,
    size: 1,
    visible,
    visible_span: if visible {
      1
    } else {
      0
    },
  })
  index
}

///|
fn LvLocator::new() -> LvLocator {
  let locator : LvLocator = {
    items: Map([]),
    nodes: [],
    rank_root: -1,
    root_divider: -1,
    root_close: -1,
    root_left: Empty,
    root_right: Empty,
  }
  let divider = locator.push_rank_node(false)
  let close = locator.push_rank_node(false)
  locator.root_divider = divider
  locator.root_close = close
  locator.rank_root = locator.merge_rank(divider, close)
  locator
}

///|
fn LvLocator::rank_size(self : LvLocator, node : Int) -> Int {
  if node == -1 {
    0
  } else {
    self.nodes[node].size
  }
}

///|
fn LvLocator::rank_visible_span(self : LvLocator, node : Int) -> Int {
  if node == -1 {
    0
  } else {
    self.nodes[node].visible_span
  }
}

///|
fn LvLocator::set_rank_parent(
  self : LvLocator,
  node : Int,
  parent : Int,
) -> Unit {
  if node != -1 {
    self.nodes[node].parent = parent
  }
}

///|
fn LvLocator::refresh_rank_node(self : LvLocator, node : Int) -> Unit {
  if node == -1 {
    return
  }
  let rank = self.nodes[node]
  rank.size = self.rank_size(rank.left) + 1 + self.rank_size(rank.right)
  rank.visible_span = self.rank_visible_span(rank.left) +
    (if rank.visible { 1 } else { 0 }) +
    self.rank_visible_span(rank.right)
  self.set_rank_parent(rank.left, node)
  self.set_rank_parent(rank.right, node)
}

///|
/// Split by total marker count; both returned roots are detached.
fn LvLocator::split_rank(
  self : LvLocator,
  root : Int,
  left_count : Int,
) -> (Int, Int) {
  if root == -1 {
    return (-1, -1)
  }
  let node = self.nodes[root]
  let left_size = self.rank_size(node.left)
  if left_count <= left_size {
    let (left, next_left) = self.split_rank(node.left, left_count)
    node.left = next_left
    self.refresh_rank_node(root)
    self.set_rank_parent(left, -1)
    self.set_rank_parent(root, -1)
    (left, root)
  } else {
    let (next_right, right) = self.split_rank(
      node.right,
      left_count - left_size - 1,
    )
    node.right = next_right
    self.refresh_rank_node(root)
    self.set_rank_parent(root, -1)
    self.set_rank_parent(right, -1)
    (root, right)
  }
}

///|
/// Merge two marker sequences whose order is already established.
fn LvLocator::merge_rank(self : LvLocator, left : Int, right : Int) -> Int {
  if left == -1 {
    self.set_rank_parent(right, -1)
    return right
  }
  if right == -1 {
    self.set_rank_parent(left, -1)
    return left
  }
  if self.nodes[left].priority >= self.nodes[right].priority {
    self.nodes[left].right = self.merge_rank(self.nodes[left].right, right)
    self.refresh_rank_node(left)
    self.set_rank_parent(left, -1)
    left
  } else {
    self.nodes[right].left = self.merge_rank(left, self.nodes[right].left)
    self.refresh_rank_node(right)
    self.set_rank_parent(right, -1)
    right
  }
}

///|
/// Total-marker rank of a stable node handle.
fn LvLocator::marker_rank(self : LvLocator, node : Int) -> Int {
  let mut rank = self.rank_size(self.nodes[node].left)
  let mut current = node
  let mut parent = self.nodes[current].parent
  while parent != -1 {
    if self.nodes[parent].right == current {
      rank = rank + self.rank_size(self.nodes[parent].left) + 1
    }
    current = parent
    parent = self.nodes[current].parent
  }
  rank
}

///|
/// Insert one detached marker immediately before a stable anchor.
fn LvLocator::insert_marker_before(
  self : LvLocator,
  anchor : Int,
  marker : Int,
) -> Unit {
  let position = self.marker_rank(anchor)
  let (left, right) = self.split_rank(self.rank_root, position)
  self.rank_root = self.merge_rank(self.merge_rank(left, marker), right)
}

///|
/// Toggle a content marker and refresh only its treap ancestor path.
fn LvLocator::set_visible(self : LvLocator, node : Int, visible : Bool) -> Unit {
  self.nodes[node].visible = visible
  let mut current = node
  while current != -1 {
    self.refresh_rank_node(current)
    current = self.nodes[current].parent
  }
}

///|
/// Visible scalar prefix before one content marker.
fn LvLocator::visible_rank(self : LvLocator, node : Int) -> Int {
  let mut rank = self.rank_visible_span(self.nodes[node].left)
  let mut current = node
  let mut parent = self.nodes[current].parent
  while parent != -1 {
    if self.nodes[parent].right == current {
      rank = rank +
        self.rank_visible_span(self.nodes[parent].left) +
        (if self.nodes[parent].visible { 1 } else { 0 })
    }
    current = parent
    parent = self.nodes[current].parent
  }
  rank
}

///|
fn LocatorSiblings::height(self : LocatorSiblings) -> Int {
  match self {
    Empty => 0
    Branch(height~, ..) => height
  }
}

///|
/// Compare two siblings using the reference RawVersion `(agent, sequence)` order.
fn LvLocator::compare_lvs(self : LvLocator, a : Int, b : Int) -> Int {
  let a_item = self.items.get(a).unwrap()
  let b_item = self.items.get(b).unwrap()
  let agent = a_item.agent.0.lexical_compare(b_item.agent.0)
  if agent != 0 {
    return agent
  }
  Compare::compare(a_item.sequence, b_item.sequence)
}

///|
fn LvLocator::sibling_branch(
  self : LvLocator,
  left : LocatorSiblings,
  lv : Int,
  right : LocatorSiblings,
) -> LocatorSiblings {
  let _ = self
  Branch(left~, lv~, right~, height=1 + left.height().max(right.height()))
}

///|
fn LvLocator::balance_siblings(
  self : LvLocator,
  left : LocatorSiblings,
  lv : Int,
  right : LocatorSiblings,
) -> LocatorSiblings {
  let delta = left.height() - right.height()
  if delta > 1 {
    match left {
      Empty => self.sibling_branch(left, lv, right)
      Branch(left=ll, lv=left_lv, right=lr, ..) =>
        if ll.height() >= lr.height() {
          self.sibling_branch(ll, left_lv, self.sibling_branch(lr, lv, right))
        } else {
          match lr {
            Empty => self.sibling_branch(left, lv, right)
            Branch(left=lrl, lv=middle_lv, right=lrr, ..) =>
              self.sibling_branch(
                self.sibling_branch(ll, left_lv, lrl),
                middle_lv,
                self.sibling_branch(lrr, lv, right),
              )
          }
        }
    }
  } else if delta < -1 {
    match right {
      Empty => self.sibling_branch(left, lv, right)
      Branch(left=rl, lv=right_lv, right=rr, ..) =>
        if rr.height() >= rl.height() {
          self.sibling_branch(self.sibling_branch(left, lv, rl), right_lv, rr)
        } else {
          match rl {
            Empty => self.sibling_branch(left, lv, right)
            Branch(left=rll, lv=middle_lv, right=rlr, ..) =>
              self.sibling_branch(
                self.sibling_branch(left, lv, rll),
                middle_lv,
                self.sibling_branch(rlr, right_lv, rr),
              )
          }
        }
    }
  } else {
    self.sibling_branch(left, lv, right)
  }
}

///|
fn LvLocator::insert_sibling(
  self : LvLocator,
  tree : LocatorSiblings,
  target : Int,
) -> LocatorSiblings {
  match tree {
    Empty => self.sibling_branch(Empty, target, Empty)
    Branch(left~, lv~, right~, ..) => {
      let ordering = self.compare_lvs(target, lv)
      if ordering < 0 {
        self.balance_siblings(self.insert_sibling(left, target), lv, right)
      } else if ordering > 0 {
        self.balance_siblings(left, lv, self.insert_sibling(right, target))
      } else {
        self.sibling_branch(left, lv, right)
      }
    }
  }
}

///|
/// Find the least canonical sibling ordered after an uninserted target.
fn LvLocator::next_sibling(
  self : LvLocator,
  tree : LocatorSiblings,
  target : Int,
) -> Int? {
  match tree {
    Empty => None
    Branch(left~, lv~, right~, ..) =>
      if self.compare_lvs(target, lv) < 0 {
        match self.next_sibling(left, target) {
          Some(next) => Some(next)
          None => Some(lv)
        }
      } else {
        self.next_sibling(right, target)
      }
  }
}

///|
fn LvLocator::children(
  self : LvLocator,
  parent : Int,
  side : @fugue.Side,
) -> LocatorSiblings {
  if parent == -1 {
    match side {
      @fugue.Left => self.root_left
      @fugue.Right => self.root_right
    }
  } else {
    let owner = self.items.get(parent).unwrap()
    match side {
      @fugue.Left => owner.left_children
      @fugue.Right => owner.right_children
    }
  }
}

///|
fn LvLocator::set_children(
  self : LvLocator,
  parent : Int,
  side : @fugue.Side,
  children : LocatorSiblings,
) -> Unit {
  if parent == -1 {
    match side {
      @fugue.Left => self.root_left = children
      @fugue.Right => self.root_right = children
    }
  } else {
    let owner = self.items.get(parent).unwrap()
    match side {
      @fugue.Left => owner.left_children = children
      @fugue.Right => owner.right_children = children
    }
  }
}

///|
/// Add one Fugue subtree interval at its canonical sibling boundary.
fn LvLocator::add_item(self : LvLocator, item : @fugue.Item[String]) -> Bool {
  if self.items.contains(item.id.0) {
    return false
  }
  let parent = match item.parent {
    Some(parent) => parent.0
    None => -1
  }
  let open_node = self.push_rank_node(false)
  let content_node = self.push_rank_node(!item.deleted)
  let close_node = self.push_rank_node(false)
  self.items.set(item.id.0, {
    agent: item.agent,
    sequence: item.sequence,
    open_node,
    content_node,
    close_node,
    left_children: Empty,
    right_children: Empty,
  })
  let siblings = self.children(parent, item.side)
  let anchor = match self.next_sibling(siblings, item.id.0) {
    Some(next) => self.items.get(next).unwrap().open_node
    None =>
      if parent == -1 {
        match item.side {
          @fugue.Left => self.root_divider
          @fugue.Right => self.root_close
        }
      } else {
        let owner = self.items.get(parent).unwrap()
        match item.side {
          @fugue.Left => owner.content_node
          @fugue.Right => owner.close_node
        }
      }
  }
  self.insert_marker_before(anchor, open_node)
  self.insert_marker_before(anchor, content_node)
  self.insert_marker_before(anchor, close_node)
  self.set_children(parent, item.side, self.insert_sibling(siblings, item.id.0))
  true
}

///|
/// Build in causal LV order, where every structural parent precedes its child.
fn LvLocator::from_tree(tree : @fugue.FugueTree[String]) -> LvLocator {
  let locator = LvLocator::new()
  let items = tree.get_all_items()
  items.sort_by((a, b) => {
    let (a_lv, _) = a
    let (b_lv, _) = b
    a_lv.0.compare(b_lv.0)
  })
  for entry in items {
    let (_, item) = entry
    if !locator.add_item(item) {
      return LvLocator::new()
    }
  }
  locator
}

///|
fn LvLocator::contains(self : LvLocator, lv : Int) -> Bool {
  self.items.contains(lv)
}

///|
fn LvLocator::show(self : LvLocator, lv : Int) -> Bool {
  match self.items.get(lv) {
    Some(item) => {
      self.set_visible(item.content_node, true)
      true
    }
    None => false
  }
}

///|
fn LvLocator::hide(self : LvLocator, lv : Int) -> Bool {
  match self.items.get(lv) {
    Some(item) => {
      self.set_visible(item.content_node, false)
      true
    }
    None => false
  }
}

///|
/// Constant-handle lookup plus logarithmic visible-prefix rank.
fn LvLocator::position(self : LvLocator, lv : Int) -> Int? {
  match self.items.get(lv) {
    Some(item) if self.nodes[item.content_node].visible =>
      Some(self.visible_rank(item.content_node))
    _ => None
  }
}
