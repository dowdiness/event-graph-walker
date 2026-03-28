///|
/// Integration tests for TreeDoc
fn op_timestamp(op : @mt.TreeOp) -> Int {
  match op {
    @mt.Move(move_op) => move_op.timestamp
    @mt.SetProperty(prop_op) => prop_op.timestamp
  }
}

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
  inspect(doc_a.get_property(a1, "label"), content="Some(\"A1\")")
  inspect(doc_a.get_property(b1, "label"), content="Some(\"B1\")")
  inspect(doc_b.get_property(a1, "label"), content="Some(\"A1\")")
  inspect(doc_b.get_property(b1, "label"), content="Some(\"B1\")")
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
/// Test 8: Concurrent equal positions converge to the same sibling order
test "TreeDoc: concurrent equal positions converge" {
  let doc_a = @tree.TreeDoc::new("alice")
  let doc_b = @tree.TreeDoc::new("bob")
  let a1 = doc_a.create_node(parent=@tree.root_id)
  let b1 = doc_b.create_node(parent=@tree.root_id)
  let alice_ops = doc_a.export_ops()
  let bob_ops = doc_b.export_ops()
  for op in alice_ops {
    doc_b.apply_remote_op(op)
  }
  for op in bob_ops {
    doc_a.apply_remote_op(op)
  }
  let children_a = doc_a.children(@tree.root_id)
  let children_b = doc_b.children(@tree.root_id)
  inspect(children_a.length(), content="2")
  inspect(children_b.length(), content="2")
  inspect(children_a[0] == children_b[0], content="true")
  inspect(children_a[1] == children_b[1], content="true")
  inspect(children_a[0] == a1 || children_a[1] == a1, content="true")
  inspect(children_a[0] == b1 || children_a[1] == b1, content="true")
}

///|
/// Test 9: Property ops survive out-of-order delivery
test "TreeDoc: property ops replay after out-of-order create" {
  let doc_a = @tree.TreeDoc::new("alice")
  let doc_b = @tree.TreeDoc::new("bob")
  let node = doc_a.create_node(parent=@tree.root_id)
  doc_a.set_property(node, "label", "ready")
  let ops = doc_a.export_ops()
  doc_b.apply_remote_op(ops[1])
  doc_b.apply_remote_op(ops[0])
  inspect(doc_b.is_alive(node), content="true")
  inspect(doc_b.get_property(node, "label"), content="Some(\"ready\")")
}

///|
/// Test 10: Remote timestamps seed subsequent local timestamps
test "TreeDoc: local timestamps advance past remote history" {
  let doc_b = @tree.TreeDoc::new("bob")
  let doc_c = @tree.TreeDoc::new("carol")
  let remote_id : @mt.TreeNodeId = { agent: "alice", counter: 0 }
  let remote_create : @mt.TreeOp = @mt.Move({
    timestamp: 10,
    target: remote_id,
    new_parent: @tree.root_id,
    position: @fi.FractionalIndex::between(left=None, right=None),
    agent: "alice",
  })
  doc_b.apply_remote_op(remote_create)
  doc_b.delete_node(remote_id)
  let ops = doc_b.export_ops()
  inspect(ops.length(), content="2")
  inspect(op_timestamp(ops[1]) > 10, content="true")
  for op in ops {
    doc_c.apply_remote_op(op)
  }
  inspect(doc_c.is_alive(remote_id), content="false")
}

///|
/// Test 11: Move and delete across peers
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
/// Test 12: Export ops returns operations in timestamp order
test "TreeDoc: export ops in order" {
  let doc = @tree.TreeDoc::new("alice")
  let node = doc.create_node(parent=@tree.root_id)
  doc.set_property(node, "color", "red")
  let _ = doc.create_node(parent=@tree.root_id)
  doc.delete_node(node)
  let ops = doc.export_ops()
  inspect(ops.length(), content="4")
  // Timestamps should be monotonically non-decreasing
  let mut prev_ts = -1
  for op in ops {
    let current_ts = op_timestamp(op)
    inspect(current_ts >= prev_ts, content="true")
    prev_ts = current_ts
  }
}

///|
/// Test 13: create_node rejects missing local parent ids
test "panic TreeDoc: create node with missing parent" {
  let doc = @tree.TreeDoc::new("alice")
  ignore(doc.create_node(parent={ agent: "missing", counter: 99 }))
}

///|
/// Test 14: move_node rejects unknown targets
test "panic TreeDoc: move missing target" {
  let doc = @tree.TreeDoc::new("alice")
  let parent = doc.create_node(parent=@tree.root_id)
  doc.move_node(target={ agent: "missing", counter: 99 }, new_parent=parent)
}

///|
/// Test 15: move_node rejects missing local parent ids
test "panic TreeDoc: move to missing parent" {
  let doc = @tree.TreeDoc::new("alice")
  let node = doc.create_node(parent=@tree.root_id)
  doc.move_node(target=node, new_parent={ agent: "missing", counter: 99 })
}

///|
/// Test 16: move_node rejects cycle-forming local moves
test "panic TreeDoc: move would create a cycle" {
  let doc = @tree.TreeDoc::new("alice")
  let parent = doc.create_node(parent=@tree.root_id)
  let child = doc.create_node(parent=parent)
  doc.move_node(target=parent, new_parent=child)
}

///|
/// Test 17: Empty replica_id is rejected
test "panic TreeDoc: empty replica_id" {
  ignore(@tree.TreeDoc::new(""))
}

///|
/// Test 18: create_node rejects a deleted node as parent
test "panic TreeDoc: create node under deleted parent" {
  let doc = @tree.TreeDoc::new("alice")
  let node = doc.create_node(parent=@tree.root_id)
  doc.delete_node(node)
  // node is now in trash — creating a child under it should abort
  ignore(doc.create_node(parent=node))
}

///|
/// Test 19: move_node rejects a deleted node as new parent
test "panic TreeDoc: move node to deleted parent" {
  let doc = @tree.TreeDoc::new("alice")
  let a = doc.create_node(parent=@tree.root_id)
  let b = doc.create_node(parent=@tree.root_id)
  doc.delete_node(a)
  // a is now in trash — moving b under it should abort
  doc.move_node(target=b, new_parent=a)
}

///|
/// Test 20: Node ids are unique per agent
test "TreeDoc: unique node ids" {
  let doc = @tree.TreeDoc::new("alice")
  let a = doc.create_node(parent=@tree.root_id)
  let b = doc.create_node(parent=@tree.root_id)
  let c = doc.create_node(parent=@tree.root_id)
  inspect(a == b, content="false")
  inspect(b == c, content="false")
  inspect(a == c, content="false")
}
