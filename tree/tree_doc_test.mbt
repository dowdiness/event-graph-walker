///| Integration tests for TreeDoc

///|
/// Test 1: Create nodes and query tree structure
test "TreeDoc: create nodes and query structure" {
  let doc = @tree.TreeDoc::new("alice")
  // Create two nodes under root
  let a = doc.create_node(parent=@tree.root_id)
  let b = doc.create_node(parent=@tree.root_id)
  // Both should be alive
  inspect(doc.is_alive(a), content="true")
  inspect(doc.is_alive(b), content="true")
  // Root should have two children
  let children = doc.children(@tree.root_id)
  inspect(children.length(), content="2")
  // a was created first, b second — a should come before b
  inspect(children[0] == a, content="true")
  inspect(children[1] == b, content="true")
}

///|
/// Test 2: Create nested nodes and query children
test "TreeDoc: nested children" {
  let doc = @tree.TreeDoc::new("alice")
  let parent = doc.create_node(parent=@tree.root_id)
  let child1 = doc.create_node(parent~)
  let child2 = doc.create_node(parent~)
  let children = doc.children(parent)
  inspect(children.length(), content="2")
  inspect(children[0] == child1, content="true")
  inspect(children[1] == child2, content="true")
  // Root should have exactly one child (the parent node)
  inspect(doc.children(@tree.root_id).length(), content="1")
}

///|
/// Test 3: Properties — set and get
test "TreeDoc: properties" {
  let doc = @tree.TreeDoc::new("alice")
  let node = doc.create_node(parent=@tree.root_id)
  inspect(doc.get_property(node, "color"), content="None")
  doc.set_property(node, "color", "red")
  inspect(doc.get_property(node, "color"), content="Some(\"red\")")
  doc.set_property(node, "color", "blue")
  inspect(doc.get_property(node, "color"), content="Some(\"blue\")")
}

///|
/// Test 4: Move a node to a different parent
test "TreeDoc: move node" {
  let doc = @tree.TreeDoc::new("alice")
  let a = doc.create_node(parent=@tree.root_id)
  let b = doc.create_node(parent=@tree.root_id)
  // Move b under a
  doc.move_node(target=b, new_parent=a)
  inspect(doc.children(@tree.root_id).length(), content="1")
  inspect(doc.children(a).length(), content="1")
  inspect(doc.children(a)[0] == b, content="true")
}

///|
/// Test 5: Delete a node (move to trash)
test "TreeDoc: delete node" {
  let doc = @tree.TreeDoc::new("alice")
  let node = doc.create_node(parent=@tree.root_id)
  inspect(doc.is_alive(node), content="true")
  doc.delete_node(node)
  inspect(doc.is_alive(node), content="false")
  inspect(doc.children(@tree.root_id).length(), content="0")
}

///|
/// Test 6: Two peers converge after exchanging ops
test "TreeDoc: two peers converge" {
  let doc_a = @tree.TreeDoc::new("alice")
  let doc_b = @tree.TreeDoc::new("bob")
  // Alice creates a node
  let a1 = doc_a.create_node(parent=@tree.root_id)
  doc_a.set_property(a1, "label", "A1")
  // Bob creates a node
  let b1 = doc_b.create_node(parent=@tree.root_id)
  doc_b.set_property(b1, "label", "B1")
  // Exchange ops: Alice -> Bob
  let alice_ops = doc_a.export_ops()
  for op in alice_ops {
    doc_b.apply_remote_op(op)
  }
  // Exchange ops: Bob -> Alice
  let bob_ops = doc_b.export_ops()
  for op in bob_ops {
    doc_a.apply_remote_op(op)
  }
  // Both should see 2 children of root
  inspect(doc_a.children(@tree.root_id).length(), content="2")
  inspect(doc_b.children(@tree.root_id).length(), content="2")
  // Both should recognize the nodes as alive
  inspect(doc_a.is_alive(a1), content="true")
  inspect(doc_a.is_alive(b1), content="true")
  inspect(doc_b.is_alive(a1), content="true")
  inspect(doc_b.is_alive(b1), content="true")
}

///|
/// Test 7: Children order is consistent across peers after sync
test "TreeDoc: consistent children order across peers" {
  let doc_a = @tree.TreeDoc::new("alice")
  let doc_b = @tree.TreeDoc::new("bob")
  // Alice creates three nodes
  let a1 = doc_a.create_node(parent=@tree.root_id)
  let a2 = doc_a.create_node(parent=@tree.root_id)
  let a3 = doc_a.create_node(parent=@tree.root_id)
  // Sync alice -> bob
  let ops = doc_a.export_ops()
  for op in ops {
    doc_b.apply_remote_op(op)
  }
  // Both should see same order: a1, a2, a3
  let children_a = doc_a.children(@tree.root_id)
  let children_b = doc_b.children(@tree.root_id)
  inspect(children_a.length(), content="3")
  inspect(children_b.length(), content="3")
  // Verify same order
  inspect(children_a[0] == children_b[0], content="true")
  inspect(children_a[1] == children_b[1], content="true")
  inspect(children_a[2] == children_b[2], content="true")
  // Verify it's a1, a2, a3
  inspect(children_a[0] == a1, content="true")
  inspect(children_a[1] == a2, content="true")
  inspect(children_a[2] == a3, content="true")
}

///|
/// Test 8: Move and delete across peers
test "TreeDoc: move and delete across peers" {
  let doc_a = @tree.TreeDoc::new("alice")
  let doc_b = @tree.TreeDoc::new("bob")
  // Alice creates a parent and child
  let parent = doc_a.create_node(parent=@tree.root_id)
  let child = doc_a.create_node(parent~)
  // Sync to Bob
  let ops = doc_a.export_ops()
  for op in ops {
    doc_b.apply_remote_op(op)
  }
  // Alice deletes the child, Bob moves it to root
  doc_a.delete_node(child)
  doc_b.move_node(target=child, new_parent=@tree.root_id)
  // Exchange operations
  let alice_ops = doc_a.export_ops()
  let bob_ops = doc_b.export_ops()
  for op in bob_ops {
    doc_a.apply_remote_op(op)
  }
  for op in alice_ops {
    doc_b.apply_remote_op(op)
  }
  // Both peers should converge to the same state
  let alive_a = doc_a.is_alive(child)
  let alive_b = doc_b.is_alive(child)
  inspect(alive_a == alive_b, content="true")
}

///|
/// Test 9: Export ops returns operations in timestamp order
test "TreeDoc: export ops in order" {
  let doc = @tree.TreeDoc::new("alice")
  let _ = doc.create_node(parent=@tree.root_id)
  let _ = doc.create_node(parent=@tree.root_id)
  let _ = doc.create_node(parent=@tree.root_id)
  let ops = doc.export_ops()
  inspect(ops.length(), content="3")
  // Timestamps should be monotonically non-decreasing
  let mut prev_ts = -1
  for op in ops {
    inspect(op.timestamp >= prev_ts, content="true")
    prev_ts = op.timestamp
  }
}

///|
/// Test 10: Node ids are unique per agent
test "TreeDoc: unique node ids" {
  let doc = @tree.TreeDoc::new("alice")
  let a = doc.create_node(parent=@tree.root_id)
  let b = doc.create_node(parent=@tree.root_id)
  let c = doc.create_node(parent=@tree.root_id)
  inspect(a == b, content="false")
  inspect(b == c, content="false")
  inspect(a == c, content="false")
}
