///| Derive indexes from the canonical Fugue tree of a validated fresh archive.

///|
fn LvLocator::bulk_siblings_experimental(
  ordered : Array[Int],
  low : Int,
  high : Int,
) -> LocatorSiblings {
  if low >= high {
    Empty
  } else {
    let middle = low + (high - low) / 2
    let left = LvLocator::bulk_siblings_experimental(ordered, low, middle)
    let right = LvLocator::bulk_siblings_experimental(ordered, middle + 1, high)
    Branch(
      left~,
      lv=ordered[middle],
      right~,
      height=1 + left.height().max(right.height()),
    )
  }
}

///|
/// Build the exact Cartesian max-treap implied by the existing marker priorities.
/// Strict < popping retains the existing left-winning >= tie policy.
fn LvLocator::bulk_rank_experimental(
  self : LvLocator,
  ordered : Array[Int],
) -> Unit {
  for node in self.nodes {
    node.left = -1
    node.right = -1
    node.parent = -1
    node.size = 1
    node.visible_span = if node.visible { 1 } else { 0 }
  }
  self.rank_root = -1
  let stack : Array[Int] = []
  for current in ordered {
    let mut previous = -1
    while !stack.is_empty() &&
          self.nodes[stack[stack.length() - 1]].priority <
          self.nodes[current].priority {
      previous = stack.pop().unwrap()
    }
    self.nodes[current].left = previous
    if stack.is_empty() {
      self.rank_root = current
    } else {
      self.nodes[stack[stack.length() - 1]].right = current
    }
    stack.push(current)
  }
  // Iterative postorder avoids call-stack growth on adversarial marker shape.
  let reverse_postorder : Array[Int] = []
  stack.clear()
  if self.rank_root != -1 {
    stack.push(self.rank_root)
  }
  while !stack.is_empty() {
    let current = stack.pop().unwrap()
    reverse_postorder.push(current)
    let node = self.nodes[current]
    if node.left != -1 {
      stack.push(node.left)
    }
    if node.right != -1 {
      stack.push(node.right)
    }
  }
  for index = reverse_postorder.length() - 1; index >= 0; index = index - 1 {
    self.refresh_rank_node(reverse_postorder[index])
  }
  self.set_rank_parent(self.rank_root, -1)
}

///|
fn LvLocator::from_tree_bulk_experimental(
  tree : @fugue.FugueTree[String],
  canonical_items : Array[(@fugue.Lv, @fugue.Item[String])],
) -> LvLocator? {
  let locator = LvLocator::new()
  let causal_items = canonical_items.copy()
  causal_items.sort_by((a, b) => a.0.0.compare(b.0.0))
  let left_children : Map[Int, Array[Int]] = Map([])
  let right_children : Map[Int, Array[Int]] = Map([])
  // Same divider/close then LV-sorted open/content/close handles as the old builder.
  for (lv, item) in causal_items {
    if locator.items.contains(lv.0) {
      return None
    }
    let open_node = locator.push_rank_node(false)
    let content_node = locator.push_rank_node(!item.deleted)
    let close_node = locator.push_rank_node(false)
    locator.items[lv.0] = {
      agent: item.agent,
      sequence: item.sequence,
      open_node,
      content_node,
      close_node,
      left_children: Empty,
      right_children: Empty,
    }
    let parent = match item.parent {
      Some(parent) => parent.0
      None => -1
    }
    let children = match item.side {
      @fugue.Left => left_children
      @fugue.Right => right_children
    }
    let values = children.get(parent).unwrap_or([])
    values.push(lv.0)
    children[parent] = values
  }
  // Validate parent ownership, use the existing stable-identity comparator, and
  // build balanced sibling search trees whose shape need not depend on arrival.
  for (parent, children) in left_children {
    if parent != -1 && !locator.items.contains(parent) {
      return None
    }
    children.sort_by((a, b) => locator.compare_lvs(a, b))
    let siblings = LvLocator::bulk_siblings_experimental(
      children,
      0,
      children.length(),
    )
    if parent == -1 {
      locator.root_left = siblings
    } else {
      locator.items.get(parent).unwrap().left_children = siblings
    }
  }
  for (parent, children) in right_children {
    if parent != -1 && !locator.items.contains(parent) {
      return None
    }
    children.sort_by((a, b) => locator.compare_lvs(a, b))
    let siblings = LvLocator::bulk_siblings_experimental(
      children,
      0,
      children.length(),
    )
    if parent == -1 {
      locator.root_right = siblings
    } else {
      locator.items.get(parent).unwrap().right_children = siblings
    }
  }
  let ordered : Array[Int] = []
  let stack : Array[(Int, Int)] = [(-1, 0)]
  let mut content_index = 0
  let mut entered = 0
  while !stack.is_empty() {
    let top = stack.length() - 1
    let (lv, phase) = stack[top]
    if phase == 0 {
      if lv != -1 {
        entered = entered + 1
        if entered > canonical_items.length() {
          return None
        }
        ordered.push(locator.items.get(lv).unwrap().open_node)
      }
      stack[top] = (lv, 1)
      let children = left_children.get(lv).unwrap_or([])
      for index = children.length() - 1; index >= 0; index = index - 1 {
        stack.push((children[index], 0))
      }
    } else if phase == 1 {
      if lv == -1 {
        ordered.push(locator.root_divider)
      } else {
        // Prove the rebuilt Euler contents match canonical Fugue traversal.
        if content_index >= canonical_items.length() ||
          canonical_items[content_index].0.0 != lv {
          return None
        }
        ordered.push(locator.items.get(lv).unwrap().content_node)
        content_index = content_index + 1
      }
      stack[top] = (lv, 2)
      let children = right_children.get(lv).unwrap_or([])
      for index = children.length() - 1; index >= 0; index = index - 1 {
        stack.push((children[index], 0))
      }
    } else {
      ordered.push(
        if lv == -1 {
          locator.root_close
        } else {
          locator.items.get(lv).unwrap().close_node
        },
      )
      ignore(stack.pop())
    }
  }
  if content_index != canonical_items.length() ||
    ordered.length() != locator.nodes.length() {
    return None
  }
  locator.bulk_rank_experimental(ordered)
  if locator.rank_visible_span(locator.rank_root) != tree.visible_count() {
    return None
  }
  Some(locator)
}

///|
/// Build visible runs with a linear StringBuilder before the existing OrderTree bulk API.
/// Preserve positive-count legacy empty items as isolated runs, as the normal cache does.
fn IndexedState::from_tree_bulk_experimental(
  tree : @fugue.FugueTree[String],
) -> IndexedState? {
  let all = tree.get_all_items()
  let locator = LvLocator::from_tree_bulk_experimental(tree, all)
  guard locator is Some(locator) else { return None }
  let runs : Array[VisibleRun] = []
  let mut start_lv = -1
  let mut count = 0
  let builder = StringBuilder()
  for (lv, item) in all {
    if !item.state.is_visible(delete_count=item.delete_count) {
      continue
    }
    if count > 0 && (start_lv + count != lv.0 || item.content.is_empty()) {
      runs.push({ start_lv, count, text: builder.to_string(), })
      builder.reset()
      count = 0
    }
    if item.content.is_empty() {
      runs.push({ start_lv: lv.0, count: 1, text: "", })
    } else {
      if count == 0 {
        start_lv = lv.0
      }
      builder.write_string(item.content)
      count = count + 1
    }
  }
  if count > 0 {
    runs.push({ start_lv, count, text: builder.to_string(), })
  }
  Some({
    cache: Some(@order_tree.OrderTree::from_array(runs)),
    locator: Some(locator),
  })
}
