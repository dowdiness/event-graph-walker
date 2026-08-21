///|
/// Immutable AVL node used by one parent's ordered child set.
priv enum LocatorSiblings {
  Empty
  Branch(
    left~ : LocatorSiblings,
    lv~ : Int,
    right~ : LocatorSiblings,
    height~ : Int,
    span~ : Int
  )
}

///|
/// Fugue topology retained for one authority identity.
priv struct LocatorItem {
  lv : Int
  parent : Int
  side : @fugue.Side
  timestamp : @fugue.Timestamp
  agent : @fugue.ReplicaId
  mut visible : Bool
  mut subtree_span : Int
  mut left_children : LocatorSiblings
  mut right_children : LocatorSiblings
}

///|
/// Same-generation inverse index for visible LV scalar positions.
///
/// Child sets are AVL trees annotated with the visible span of each Fugue
/// subtree. A lookup follows the structural ancestor chain and logarithmic
/// sibling paths; it never walks the visible projection.
priv struct LvLocator {
  items : Map[Int, LocatorItem]
  mut root_left : LocatorSiblings
  mut root_right : LocatorSiblings
}

///|
fn LvLocator::new() -> LvLocator {
  { items: {}, root_left: Empty, root_right: Empty }
}

///|
fn LocatorSiblings::height(self : LocatorSiblings) -> Int {
  match self {
    Empty => 0
    Branch(height~, ..) => height
  }
}

///|
fn LocatorSiblings::span(self : LocatorSiblings) -> Int {
  match self {
    Empty => 0
    Branch(span~, ..) => span
  }
}

///|
/// Compare two siblings using Fugue's canonical timestamp/agent/LV order.
fn LvLocator::compare_lvs(self : LvLocator, a : Int, b : Int) -> Int {
  let a_item = self.items.get(a).unwrap()
  let b_item = self.items.get(b).unwrap()
  let timestamp = Compare::compare(a_item.timestamp, b_item.timestamp)
  if timestamp != 0 {
    return timestamp
  }
  let agent = Compare::compare(a_item.agent, b_item.agent)
  if agent != 0 {
    return agent
  }
  a.compare(b)
}

///|
fn LvLocator::branch(
  self : LvLocator,
  left : LocatorSiblings,
  lv : Int,
  right : LocatorSiblings,
) -> LocatorSiblings {
  Branch(
    left~,
    lv~,
    right~,
    height=1 + left.height().max(right.height()),
    span=left.span() + self.items.get(lv).unwrap().subtree_span + right.span(),
  )
}

///|
/// Rebalance one child-set node after an insertion or weight update.
fn LvLocator::balance(
  self : LvLocator,
  left : LocatorSiblings,
  lv : Int,
  right : LocatorSiblings,
) -> LocatorSiblings {
  let delta = left.height() - right.height()
  if delta > 1 {
    match left {
      Empty => self.branch(left, lv, right)
      Branch(left=ll, lv=left_lv, right=lr, ..) =>
        if ll.height() >= lr.height() {
          self.branch(ll, left_lv, self.branch(lr, lv, right))
        } else {
          match lr {
            Empty => self.branch(left, lv, right)
            Branch(left=lrl, lv=middle_lv, right=lrr, ..) =>
              self.branch(
                self.branch(ll, left_lv, lrl),
                middle_lv,
                self.branch(lrr, lv, right),
              )
          }
        }
    }
  } else if delta < -1 {
    match right {
      Empty => self.branch(left, lv, right)
      Branch(left=rl, lv=right_lv, right=rr, ..) =>
        if rr.height() >= rl.height() {
          self.branch(self.branch(left, lv, rl), right_lv, rr)
        } else {
          match rl {
            Empty => self.branch(left, lv, right)
            Branch(left=rll, lv=middle_lv, right=rlr, ..) =>
              self.branch(
                self.branch(left, lv, rll),
                middle_lv,
                self.branch(rlr, right_lv, rr),
              )
          }
        }
    }
  } else {
    self.branch(left, lv, right)
  }
}

///|
/// Insert a new sibling or refresh an existing sibling's subtree weight.
fn LvLocator::upsert_sibling(
  self : LvLocator,
  tree : LocatorSiblings,
  target : Int,
) -> LocatorSiblings {
  match tree {
    Empty => self.branch(Empty, target, Empty)
    Branch(left~, lv~, right~, ..) => {
      let ordering = self.compare_lvs(target, lv)
      if ordering < 0 {
        self.balance(self.upsert_sibling(left, target), lv, right)
      } else if ordering > 0 {
        self.balance(left, lv, self.upsert_sibling(right, target))
      } else {
        self.branch(left, lv, right)
      }
    }
  }
}

///|
/// Visible span of siblings ordered strictly before `target`.
fn LvLocator::prefix_before(
  self : LvLocator,
  tree : LocatorSiblings,
  target : Int,
) -> Int? {
  match tree {
    Empty => None
    Branch(left~, lv~, right~, ..) => {
      let ordering = self.compare_lvs(target, lv)
      if ordering < 0 {
        self.prefix_before(left, target)
      } else if ordering > 0 {
        match self.prefix_before(right, target) {
          Some(suffix) =>
            Some(
              left.span() + self.items.get(lv).unwrap().subtree_span + suffix,
            )
          None => None
        }
      } else {
        Some(left.span())
      }
    }
  }
}

///|
/// Return the child-set owned by `parent` on `side`.
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
/// Replace the child-set owned by `parent` on `side`.
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
/// Refresh one item and every ancestor whose subtree span changed.
fn LvLocator::refresh_ancestors(self : LvLocator, start : Int) -> Unit {
  let mut current = start
  while current != -1 {
    let item = self.items.get(current).unwrap()
    item.subtree_span = item.left_children.span() +
      (if item.visible { 1 } else { 0 }) +
      item.right_children.span()
    let siblings = self.children(item.parent, item.side)
    self.set_children(
      item.parent,
      item.side,
      self.upsert_sibling(siblings, current),
    )
    current = item.parent
  }
}

///|
/// Add the Fugue topology for a newly projected insertion.
fn LvLocator::add_item(self : LvLocator, item : @fugue.Item[String]) -> Bool {
  if self.items.contains(item.id.0) {
    return false
  }
  let parent = match item.parent {
    Some(parent) => parent.0
    None => -1
  }
  self.items.set(item.id.0, {
    lv: item.id.0,
    parent,
    side: item.side,
    timestamp: item.timestamp,
    agent: item.agent,
    visible: !item.deleted,
    subtree_span: if item.deleted {
      0
    } else {
      1
    },
    left_children: Empty,
    right_children: Empty,
  })
  let siblings = self.children(parent, item.side)
  self.set_children(parent, item.side, self.upsert_sibling(siblings, item.id.0))
  if parent != -1 {
    self.refresh_ancestors(parent)
  }
  true
}

///|
/// Build the topology index in causal LV order, where every parent precedes
/// its descendants.
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
/// Whether this locator already owns topology for an LV.
fn LvLocator::contains(self : LvLocator, lv : Int) -> Bool {
  self.items.contains(lv)
}

///|
/// Mark a tombstone visible and update annotated spans.
fn LvLocator::show(self : LvLocator, lv : Int) -> Bool {
  match self.items.get(lv) {
    Some(item) => {
      if !item.visible {
        item.visible = true
        self.refresh_ancestors(lv)
      }
      true
    }
    None => false
  }
}

///|
/// Mark a visible identity hidden and update annotated spans.
fn LvLocator::hide(self : LvLocator, lv : Int) -> Bool {
  match self.items.get(lv) {
    Some(item) => {
      if item.visible {
        item.visible = false
        self.refresh_ancestors(lv)
      }
      true
    }
    None => false
  }
}

///|
/// Derive the visible scalar position from structural prefix sums.
fn LvLocator::position(self : LvLocator, lv : Int) -> Int? {
  let target = match self.items.get(lv) {
    Some(item) if item.visible => item
    _ => return None
  }
  let chain : Array[Int] = []
  let mut current = lv
  while current != -1 {
    chain.push(current)
    current = self.items.get(current).unwrap().parent
  }
  let mut start = 0
  for index = chain.length() - 1; index >= 0; index = index - 1 {
    let item = self.items.get(chain[index]).unwrap()
    let siblings = self.children(item.parent, item.side)
    let prefix = match self.prefix_before(siblings, item.lv) {
      Some(prefix) => prefix
      None => return None
    }
    match item.side {
      @fugue.Left => start = start + prefix
      @fugue.Right =>
        if item.parent == -1 {
          start = start + self.root_left.span() + prefix
        } else {
          let parent = self.items.get(item.parent).unwrap()
          start = start +
            parent.left_children.span() +
            (if parent.visible { 1 } else { 0 }) +
            prefix
        }
    }
  }
  Some(start + target.left_children.span())
}
