///| Differential tests for inserting one detached open/content/close interval.
/// The reference below deliberately preserves the pre-optimization three-splice
/// implementation, so it must not call production add_item or its splice helper.

///|
fn LvLocator::splice_reference_insert_marker_before(
  self : LvLocator,
  anchor : Int,
  marker : Int,
) -> Unit {
  let position = self.marker_rank(anchor)
  let (left, right) = self.split_rank(self.rank_root, position)
  self.rank_root = self.merge_rank(self.merge_rank(left, marker), right)
}

///|
fn LvLocator::splice_reference_add_item(
  self : LvLocator,
  item : @fugue.Item[String],
) -> Bool {
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
  self.splice_reference_insert_marker_before(anchor, open_node)
  self.splice_reference_insert_marker_before(anchor, content_node)
  self.splice_reference_insert_marker_before(anchor, close_node)
  self.set_children(parent, item.side, self.insert_sibling(siblings, item.id.0))
  true
}

///|
fn splice_assert_siblings_equal(
  actual : LocatorSiblings,
  reference : LocatorSiblings,
) -> Unit raise {
  match (actual, reference) {
    (Empty, Empty) => ()
    (
      Branch(left=al, lv=av, right=ar, height=ah),
      Branch(left=rl, lv=rv, right=rr, height=rh),
    ) => {
      assert_eq(av, rv)
      assert_eq(ah, rh)
      splice_assert_siblings_equal(al, rl)
      splice_assert_siblings_equal(ar, rr)
    }
    _ => assert_true(false, msg="locator sibling shape changed")
  }
}

///|
/// Check parent links, heap order, cached sizes and spans independently.
fn splice_validate_rank_subtree(
  locator : LvLocator,
  node : Int,
  parent : Int,
  seen : Array[Bool],
  in_order : Array[Int],
) -> (Int, Int) raise {
  if node == -1 {
    return (0, 0)
  }
  assert_true(node >= 0 && node < locator.nodes.length())
  assert_true(!seen[node], msg="cycle or shared child in marker treap")
  seen[node] = true
  let current = locator.nodes[node]
  assert_eq(current.parent, parent)
  if current.left != -1 {
    assert_true(current.priority >= locator.nodes[current.left].priority)
  }
  if current.right != -1 {
    assert_true(current.priority >= locator.nodes[current.right].priority)
  }
  let (left_size, left_span) = splice_validate_rank_subtree(
    locator,
    current.left,
    node,
    seen,
    in_order,
  )
  in_order.push(node)
  let (right_size, right_span) = splice_validate_rank_subtree(
    locator,
    current.right,
    node,
    seen,
    in_order,
  )
  let size = left_size + 1 + right_size
  let span = left_span + (if current.visible { 1 } else { 0 }) + right_span
  assert_eq(current.size, size)
  assert_eq(current.visible_span, span)
  (size, span)
}

///|
fn splice_assert_rank_nodes_equal(
  actual : LvLocator,
  reference : LvLocator,
) -> Unit raise {
  assert_eq(actual.rank_root, reference.rank_root)
  assert_eq(actual.root_divider, reference.root_divider)
  assert_eq(actual.root_close, reference.root_close)
  assert_eq(actual.nodes.length(), reference.nodes.length())
  for index in 0..<actual.nodes.length() {
    let a = actual.nodes[index]
    let r = reference.nodes[index]
    assert_eq(a.priority, r.priority)
    assert_eq(a.left, r.left)
    assert_eq(a.right, r.right)
    assert_eq(a.parent, r.parent)
    assert_eq(a.size, r.size)
    assert_eq(a.visible, r.visible)
    assert_eq(a.visible_span, r.visible_span)
  }
  let seen = Array::make(actual.nodes.length(), false)
  let in_order : Array[Int] = []
  let (size, span) = splice_validate_rank_subtree(
    actual,
    actual.rank_root,
    -1,
    seen,
    in_order,
  )
  assert_eq(size, actual.nodes.length())
  let mut prefix = 0
  for position in 0..<in_order.length() {
    let node = in_order[position]
    assert_eq(actual.marker_rank(node), position)
    assert_eq(reference.marker_rank(node), position)
    assert_eq(actual.visible_rank(node), prefix)
    assert_eq(reference.visible_rank(node), prefix)
    if actual.nodes[node].visible {
      prefix = prefix + 1
    }
  }
  assert_eq(span, prefix)
  for reached in seen {
    assert_true(reached)
  }
}

///|
fn splice_assert_locators_equal(
  actual : LvLocator,
  reference : LvLocator,
  lvs : Array[Int],
) -> Unit raise {
  splice_assert_rank_nodes_equal(actual, reference)
  splice_assert_siblings_equal(actual.root_left, reference.root_left)
  splice_assert_siblings_equal(actual.root_right, reference.root_right)
  assert_eq(actual.items.length(), lvs.length())
  assert_eq(reference.items.length(), lvs.length())
  for insertion_index in 0..<lvs.length() {
    let lv = lvs[insertion_index]
    let a = actual.items.get(lv).unwrap()
    let r = reference.items.get(lv).unwrap()
    assert_eq(a.agent, r.agent)
    assert_eq(a.sequence, r.sequence)
    assert_eq(a.open_node, r.open_node)
    assert_eq(a.content_node, r.content_node)
    assert_eq(a.close_node, r.close_node)
    // Allocation order is part of stable-handle identity, not just relative order.
    assert_eq(a.open_node, 2 + 3 * insertion_index)
    assert_eq(a.content_node, 3 + 3 * insertion_index)
    assert_eq(a.close_node, 4 + 3 * insertion_index)
    assert_true(
      actual.marker_rank(a.open_node) < actual.marker_rank(a.content_node),
    )
    assert_true(
      actual.marker_rank(a.content_node) < actual.marker_rank(a.close_node),
    )
    splice_assert_siblings_equal(a.left_children, r.left_children)
    splice_assert_siblings_equal(a.right_children, r.right_children)
    assert_eq(actual.contains(lv), reference.contains(lv))
    assert_eq(actual.position(lv), reference.position(lv))
  }
  assert_eq(actual.position(-1000), None)
  assert_eq(reference.position(-1000), None)
}

///|
/// An independent, small Fugue traversal oracle for explicit structural items.
fn splice_collect_fixture_side(
  items : Array[@fugue.Item[String]],
  parent : @fugue.Lv?,
  left_side : Bool,
  output : Array[Int],
) -> Unit {
  let children = items.filter(item => {
    let matches_side = match item.side {
      @fugue.Left => left_side
      @fugue.Right => !left_side
    }
    item.parent == parent && matches_side
  })
  children.sort_by((a, b) => {
    let agent_order = a.agent.0.lexical_compare(b.agent.0)
    if agent_order != 0 {
      agent_order
    } else {
      a.sequence.compare(b.sequence)
    }
  })
  for item in children {
    splice_collect_fixture_side(items, Some(item.id), true, output)
    if !item.deleted {
      output.push(item.id.0)
    }
    splice_collect_fixture_side(items, Some(item.id), false, output)
  }
}

///|
fn splice_assert_fixture_positions(
  locator : LvLocator,
  items : Array[@fugue.Item[String]],
) -> Unit raise {
  let order : Array[Int] = []
  splice_collect_fixture_side(items, None, true, order)
  splice_collect_fixture_side(items, None, false, order)
  let positions : Map[Int, Int] = Map([])
  for index in 0..<order.length() {
    positions.set(order[index], index)
  }
  for item in items {
    assert_eq(locator.position(item.id.0), positions.get(item.id.0))
  }
  assert_eq(locator.rank_visible_span(locator.rank_root), order.length())
}

///|

///|
/// Fugue exposes side values read-only; obtain both through its public insertion API.
fn splice_fixture_sides() -> (@fugue.Side, @fugue.Side) {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  tree.insert(
    {
      id: @fugue.Lv(0),
      content: "a",
      origin_left: None,
      origin_right: None,
      timestamp: @fugue.Timestamp(0),
      agent: @fugue.ReplicaId("fixture"),
    },
    sequence=0,
  )
  tree.insert(
    {
      id: @fugue.Lv(1),
      content: "b",
      origin_left: None,
      origin_right: Some(@fugue.Lv(0)),
      timestamp: @fugue.Timestamp(1),
      agent: @fugue.ReplicaId("fixture"),
    },
    sequence=1,
  )
  (tree.get(@fugue.Lv(1)).unwrap().side, tree.get(@fugue.Lv(0)).unwrap().side)
}

///|
fn splice_fixture_item(
  lv : Int,
  parent : Int,
  side : @fugue.Side,
  agent : String,
  sequence : Int,
  content : String,
  deleted : Bool,
) -> @fugue.Item[String] {
  let initial_state : @fugue.ItemState = Default::default()
  {
    id: @fugue.Lv(lv),
    content,
    parent: if parent == -1 {
      None
    } else {
      Some(@fugue.Lv(parent))
    },
    side,
    deleted,
    deleted_ts: 0,
    deleted_agent: "",
    deleted_is_undelete: false,
    state: initial_state.update_from_delete_count(if deleted { 1 } else { 0 }),
    delete_count: if deleted {
      1
    } else {
      0
    },
    timestamp: @fugue.Timestamp(lv),
    agent: @fugue.ReplicaId(agent),
    sequence,
  }
}

///|
test "LV locator triplet splice preserves exact state across Fugue structural fixtures" {
  let (left_side, right_side) = splice_fixture_sides()
  let actual = LvLocator::new()
  let reference = LvLocator::new()
  let lvs : Array[Int] = []
  let added : Array[@fugue.Item[String]] = []
  let fixture = [
    splice_fixture_item(0, -1, right_side, "z", 9, "😀", false),
    splice_fixture_item(1, 0, right_side, "z", 9, "", true),
    splice_fixture_item(2, 0, left_side, "z", 9, "L", false),
    splice_fixture_item(3, -1, left_side, "z", 9, "R", false),
    splice_fixture_item(4, -1, right_side, "a", 9, "A", false),
    splice_fixture_item(5, -1, left_side, "a", 9, "😀", false),
    splice_fixture_item(6, 0, right_side, "a", 9, "", false),
    splice_fixture_item(7, 0, left_side, "a", 9, "é", true),
    splice_fixture_item(8, 1, left_side, "a", 9, "B", false),
    splice_fixture_item(9, 1, right_side, "a", 9, "C", false),
    splice_fixture_item(10, 2, left_side, "a", 9, "😀", false),
    splice_fixture_item(11, 2, right_side, "a", 9, "", true),
    splice_fixture_item(12, -1, right_side, "😀", 9, "D", false),
    splice_fixture_item(13, -1, right_side, "", 9, "E", false),
    splice_fixture_item(14, 11, left_side, "a", 9, "F", false),
    splice_fixture_item(15, 11, right_side, "a", 9, "G", false),
  ]
  // Same-agent reverse sequence arrival covers insertion before existing sibling
  // subtree intervals, while both root sides and both descendant sides grow.
  for index in 0..<32 {
    let parent = if index % 4 < 2 { -1 } else { 0 }
    let side = if index % 2 == 0 { left_side } else { right_side }
    fixture.push(
      splice_fixture_item(
        index + 16,
        parent,
        side,
        "middle",
        100 - index,
        if index % 3 == 0 {
          "😀"
        } else if index % 3 == 1 {
          ""
        } else {
          "x"
        },
        index % 5 == 0,
      ),
    )
  }
  splice_assert_locators_equal(actual, reference, lvs)
  for item in fixture {
    assert_true(actual.add_item(item))
    assert_true(reference.splice_reference_add_item(item))
    lvs.push(item.id.0)
    added.push(item)
    splice_assert_locators_equal(actual, reference, lvs)
    splice_assert_fixture_positions(actual, added)

    // Rejected duplicates must preserve node allocation, sibling ownership,
    // visibility, and stable handles even when every supplied field differs.
    let duplicate = splice_fixture_item(
      item.id.0,
      -1,
      left_side,
      "duplicate",
      -99,
      "changed",
      !item.deleted,
    )
    assert_true(!actual.add_item(duplicate))
    assert_true(!reference.splice_reference_add_item(duplicate))
    splice_assert_locators_equal(actual, reference, lvs)
    splice_assert_fixture_positions(actual, added)

    // Mutate an older item's visibility as the treap and sibling sets grow.
    let target = added[added.length() / 2]
    assert_true(actual.hide(target.id.0))
    assert_true(reference.hide(target.id.0))
    target.deleted = true
    splice_assert_locators_equal(actual, reference, lvs)
    splice_assert_fixture_positions(actual, added)
    assert_true(actual.hide(target.id.0))
    assert_true(reference.hide(target.id.0))
    splice_assert_locators_equal(actual, reference, lvs)
    splice_assert_fixture_positions(actual, added)
    assert_true(actual.show(target.id.0))
    assert_true(reference.show(target.id.0))
    target.deleted = false
    splice_assert_locators_equal(actual, reference, lvs)
    splice_assert_fixture_positions(actual, added)
    assert_true(actual.show(target.id.0))
    assert_true(reference.show(target.id.0))
    splice_assert_locators_equal(actual, reference, lvs)
    splice_assert_fixture_positions(actual, added)
  }
  assert_true(!actual.hide(-1000))
  assert_true(!reference.hide(-1000))
  splice_assert_locators_equal(actual, reference, lvs)
  assert_true(!actual.show(-1000))
  assert_true(!reference.show(-1000))
  splice_assert_locators_equal(actual, reference, lvs)
}

///|
/// Build detached nodes with controlled ties: SplitMix's regular priorities
/// are collision-free over these small fixture sizes, so ties need injection.
fn splice_push_tied_node(
  locator : LvLocator,
  priority : UInt64,
  visible : Bool,
) -> Int {
  let index = locator.nodes.length()
  locator.nodes.push({
    priority,
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
fn splice_tied_locator() -> LvLocator {
  let locator : LvLocator = {
    items: Map([]),
    nodes: [],
    rank_root: -1,
    root_divider: 0,
    root_close: 1,
    root_left: Empty,
    root_right: Empty,
  }
  let divider = splice_push_tied_node(locator, 1, false)
  let close = splice_push_tied_node(locator, 1, false)
  locator.rank_root = locator.merge_rank(divider, close)
  locator
}

///|
test "LV locator triplet merge preserves exact treap shape with equal priorities" {
  for pattern in 0..<3 {
    let actual = splice_tied_locator()
    let reference = splice_tied_locator()
    for step in 0..<24 {
      let anchor = if step % 3 == 0 {
        actual.root_divider
      } else if step % 3 == 1 {
        actual.root_close
      } else {
        // Insert before an existing content marker, including inside subtrees.
        3 + 3 * (step / 2)
      }
      let start = actual.nodes.length()
      for offset in 0..<3 {
        let priority : UInt64 = if pattern == 0 {
          1
        } else if pattern == 1 {
          ((step + offset) % 2).to_uint64()
        } else {
          ((step * 3 + offset) % 3).to_uint64()
        }
        let visible = offset == 1 && step % 4 != 0
        assert_eq(
          splice_push_tied_node(actual, priority, visible),
          splice_push_tied_node(reference, priority, visible),
        )
      }
      let triplet = actual.merge_rank(
        actual.merge_rank(start, start + 1),
        start + 2,
      )
      let position = actual.marker_rank(anchor)
      let (left, right) = actual.split_rank(actual.rank_root, position)
      actual.rank_root = actual.merge_rank(
        actual.merge_rank(left, triplet),
        right,
      )
      reference.splice_reference_insert_marker_before(anchor, start)
      reference.splice_reference_insert_marker_before(anchor, start + 1)
      reference.splice_reference_insert_marker_before(anchor, start + 2)
      splice_assert_rank_nodes_equal(actual, reference)
      actual.set_visible(start + 1, false)
      reference.set_visible(start + 1, false)
      splice_assert_rank_nodes_equal(actual, reference)
      actual.set_visible(start + 1, true)
      reference.set_visible(start + 1, true)
      splice_assert_rank_nodes_equal(actual, reference)
    }
  }
}
