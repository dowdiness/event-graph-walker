///| Unit tests for MovableTree

///|
/// Test 1: Create single node under root
test "create: single node under root" {
  let tree = @movable_tree.MovableTree::new()
  let pos = @fi.FractionalIndex::between(left=None, right=None)
  let id : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  tree.apply_create(id, @movable_tree.root_id, pos)
  inspect(tree.contains(id), content="true")
  inspect(tree.is_alive(id), content="true")
  @debug.debug_inspect(
    tree.parent(id),
    content=(
      #|Some({ agent: "__ROOT__", counter: -1 })
    ),
  )
  let children = tree.children(@movable_tree.root_id)
  inspect(children.length(), content="1")
  inspect(children[0] == id, content="true")
}

///|
/// Test 2: Move — reparent a node
test "move: reparent a node" {
  let tree = @movable_tree.MovableTree::new()
  let pos1 = @fi.FractionalIndex::between(left=None, right=None)
  let parent_id : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let child_id : @movable_tree.TreeNodeId = { agent: "alice", counter: 1 }
  tree.apply_create(parent_id, @movable_tree.root_id, pos1)
  let pos2 = @fi.FractionalIndex::between(left=None, right=None)
  tree.apply_create(child_id, @movable_tree.root_id, pos2)
  // Both should be children of root
  inspect(tree.children(@movable_tree.root_id).length(), content="2")
  // Move child under parent
  let new_pos = @fi.FractionalIndex::between(left=None, right=None)
  tree.apply_move(child_id, parent_id, new_pos)
  @debug.debug_inspect(
    tree.parent(child_id),
    content=(
      #|Some({ agent: "alice", counter: 0 })
    ),
  )
  inspect(tree.children(@movable_tree.root_id).length(), content="1")
  inspect(tree.children(parent_id).length(), content="1")
}

///|
/// Test 3: Delete — move to trash
test "delete: move to trash" {
  let tree = @movable_tree.MovableTree::new()
  let pos = @fi.FractionalIndex::between(left=None, right=None)
  let id : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  tree.apply_create(id, @movable_tree.root_id, pos)
  inspect(tree.is_alive(id), content="true")
  // Move to trash
  let trash_pos = @fi.FractionalIndex::between(left=None, right=None)
  tree.apply_move(id, @movable_tree.trash_id, trash_pos)
  inspect(tree.is_alive(id), content="false")
  inspect(tree.contains(id), content="true")
  @debug.debug_inspect(
    tree.parent(id),
    content=(
      #|Some({ agent: "__TRASH__", counter: -2 })
    ),
  )
}

///|
/// Test 4: Deleting a subtree hides all descendants
test "delete: descendants of trashed nodes are not alive" {
  let tree = @movable_tree.MovableTree::new()
  let pos = @fi.FractionalIndex::between(left=None, right=None)
  let parent_id : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let child_id : @movable_tree.TreeNodeId = { agent: "alice", counter: 1 }
  tree.apply_create(parent_id, @movable_tree.root_id, pos)
  tree.apply_create(child_id, parent_id, pos)
  tree.apply_move(parent_id, @movable_tree.trash_id, pos)
  inspect(tree.is_alive(parent_id), content="false")
  inspect(tree.is_alive(child_id), content="false")
}

///|
/// Test 5: Cycle detection — parent under child rejected
test "cycle: parent under child rejected" {
  let tree = @movable_tree.MovableTree::new()
  let pos1 = @fi.FractionalIndex::between(left=None, right=None)
  let parent_id : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let child_id : @movable_tree.TreeNodeId = { agent: "alice", counter: 1 }
  tree.apply_create(parent_id, @movable_tree.root_id, pos1)
  let pos2 = @fi.FractionalIndex::between(left=None, right=None)
  tree.apply_create(child_id, parent_id, pos2)
  // Moving parent under child would create a cycle
  inspect(tree.would_create_cycle(parent_id, child_id), content="true")
  // Moving child under root would not create a cycle
  inspect(
    tree.would_create_cycle(child_id, @movable_tree.root_id),
    content="false",
  )
  // Moving a node under itself is also a cycle
  inspect(tree.would_create_cycle(parent_id, parent_id), content="true")
}

///|
/// Test 6: Children sorted by fractional index
test "children: sorted by fractional index" {
  let tree = @movable_tree.MovableTree::new()
  // Create three nodes with specific positions: high, low, mid
  let id_a : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let id_b : @movable_tree.TreeNodeId = { agent: "alice", counter: 1 }
  let id_c : @movable_tree.TreeNodeId = { agent: "alice", counter: 2 }
  let pos_high = @fi.FractionalIndex::new([300])
  let pos_low = @fi.FractionalIndex::new([100])
  let pos_mid = @fi.FractionalIndex::new([200])
  // Insert in non-sorted order
  tree.apply_create(id_a, @movable_tree.root_id, pos_high)
  tree.apply_create(id_b, @movable_tree.root_id, pos_low)
  tree.apply_create(id_c, @movable_tree.root_id, pos_mid)
  let children = tree.children(@movable_tree.root_id)
  inspect(children.length(), content="3")
  // Should be sorted: low (b), mid (c), high (a)
  inspect(children[0] == id_b, content="true")
  inspect(children[1] == id_c, content="true")
  inspect(children[2] == id_a, content="true")
}

///|
/// Test 7: remove_node completely removes (for undo of create)
test "remove_node: completely removes node" {
  let tree = @movable_tree.MovableTree::new()
  let pos = @fi.FractionalIndex::between(left=None, right=None)
  let id : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  tree.apply_create(id, @movable_tree.root_id, pos)
  inspect(tree.contains(id), content="true")
  inspect(tree.children(@movable_tree.root_id).length(), content="1")
  // Remove the node entirely
  tree.remove_node(id)
  inspect(tree.contains(id), content="false")
  inspect(tree.parent(id) is None, content="true")
  inspect(tree.children(@movable_tree.root_id).length(), content="0")
}

///|
/// Test 8: is_ancestor_of — deep chain
test "is_ancestor_of: deep chain" {
  let tree = @movable_tree.MovableTree::new()
  let pos = @fi.FractionalIndex::between(left=None, right=None)
  // Create a chain: root -> a -> b -> c -> d
  let id_a : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  let id_b : @movable_tree.TreeNodeId = { agent: "alice", counter: 1 }
  let id_c : @movable_tree.TreeNodeId = { agent: "alice", counter: 2 }
  let id_d : @movable_tree.TreeNodeId = { agent: "alice", counter: 3 }
  tree.apply_create(id_a, @movable_tree.root_id, pos)
  tree.apply_create(id_b, id_a, pos)
  tree.apply_create(id_c, id_b, pos)
  tree.apply_create(id_d, id_c, pos)
  // a is ancestor of d (through b and c)
  inspect(tree.is_ancestor_of(id_a, id_d), content="true")
  // root is ancestor of d
  inspect(tree.is_ancestor_of(@movable_tree.root_id, id_d), content="true")
  // d is NOT ancestor of a
  inspect(tree.is_ancestor_of(id_d, id_a), content="false")
  // b is ancestor of d
  inspect(tree.is_ancestor_of(id_b, id_d), content="true")
  // c is ancestor of d
  inspect(tree.is_ancestor_of(id_c, id_d), content="true")
}

///|
/// Test 9: is_ancestor_of — node is not its own ancestor
test "is_ancestor_of: node is not its own ancestor" {
  let tree = @movable_tree.MovableTree::new()
  let pos = @fi.FractionalIndex::between(left=None, right=None)
  let id : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  tree.apply_create(id, @movable_tree.root_id, pos)
  inspect(tree.is_ancestor_of(id, id), content="false")
}

///|
/// Test 10: Properties — set and get
test "properties: set and get" {
  let tree = @movable_tree.MovableTree::new()
  let pos = @fi.FractionalIndex::between(left=None, right=None)
  let id : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  tree.apply_create(id, @movable_tree.root_id, pos)
  // No property yet
  inspect(tree.get_property(id, "color") is None, content="true")
  // Set property
  tree.set_property(id, "color", "red")
  @debug.debug_inspect(tree.get_property(id, "color"), content="Some(\"red\")")
  // Overwrite property
  tree.set_property(id, "color", "blue")
  @debug.debug_inspect(tree.get_property(id, "color"), content="Some(\"blue\")")
}

///|
/// Test 11: Equal positions break ties by node id
test "children: equal positions break ties by node id" {
  let tree_a = @movable_tree.MovableTree::new()
  let tree_b = @movable_tree.MovableTree::new()
  let pos = @fi.FractionalIndex::between(left=None, right=None)
  let bob : @movable_tree.TreeNodeId = { agent: "bob", counter: 0 }
  let alice : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  tree_a.apply_create(bob, @movable_tree.root_id, pos)
  tree_a.apply_create(alice, @movable_tree.root_id, pos)
  tree_b.apply_create(alice, @movable_tree.root_id, pos)
  tree_b.apply_create(bob, @movable_tree.root_id, pos)
  let children_a = tree_a.children(@movable_tree.root_id)
  let children_b = tree_b.children(@movable_tree.root_id)
  inspect(children_a.length(), content="2")
  inspect(children_b.length(), content="2")
  inspect(children_a[0] == children_b[0], content="true")
  inspect(children_a[1] == children_b[1], content="true")
}

///|
/// Test 12: get_position returns correct fractional index
test "get_position: returns correct position" {
  let tree = @movable_tree.MovableTree::new()
  let pos = @fi.FractionalIndex::new([42])
  let id : @movable_tree.TreeNodeId = { agent: "alice", counter: 0 }
  tree.apply_create(id, @movable_tree.root_id, pos)
  @debug.debug_inspect(tree.get_position(id), content="Some(FractionalIndex([42]))")
  inspect(tree.get_position({ agent: "nobody", counter: 99 }) is None, content="true")
}
