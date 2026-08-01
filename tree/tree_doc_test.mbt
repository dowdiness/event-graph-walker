///|
/// Tree façade integration and parity tests.
test "TreeState creates, moves, and deletes nodes" {
  let doc = TreeState::new("alice")
  let left = doc.create_node(parent=root_id)
  let right = doc.create_node(parent=root_id)
  let child = doc.create_node(parent=left)
  inspect(doc.children(root_id) == [left, right], content="true")
  doc.move_node(target=child, new_parent=right)
  inspect(doc.children(left).length(), content="0")
  inspect(doc.children(right) == [child], content="true")
  doc.delete_node(child)
  inspect(doc.is_alive(child), content="false")
}

///|
test "TreeState create_node_after preserves sibling order" {
  let doc = TreeState::new("alice")
  let first = doc.create_node(parent=root_id)
  let third = doc.create_node(parent=root_id)
  let second = doc.create_node_after(parent=root_id, after=first)
  let children = doc.children(root_id)
  inspect(children[0] == first, content="true")
  inspect(children[1] == second, content="true")
  inspect(children[2] == third, content="true")
}

///|
test "TreeState properties replicate" {
  let alice = TreeState::new("alice")
  let node = alice.create_node(parent=root_id)
  alice.set_property(node, "title", "hello")
  let bob = TreeState::new("bob")
  let report = bob.sync().apply(alice.sync().export_all())
  inspect(report.applied_operations(), content="2")
  inspect(bob.get_property(node, "title") == Some("hello"), content="true")
}

///|
test "TreeState exposes deterministic owning property snapshots" {
  let state = TreeState::new("alice")
  let node = state.create_node(parent=root_id)
  state.set_property(node, "zeta", "last")
  state.set_property(node, "alfa", "first")
  let snapshot = state.properties(node)
  assert_eq(snapshot, [("alfa", "first"), ("zeta", "last")])
  snapshot[0] = ("alfa", "changed")
  assert_eq(state.properties(node), [("alfa", "first"), ("zeta", "last")])
  let missing = TreeNodeId::TreeNodeId("missing", 99)
  assert_eq(state.properties(missing), [])
}

///|
test "TreeState full synchronization converges" {
  let alice = TreeState::new("alice")
  let bob = TreeState::new("bob")
  let a = alice.create_node(parent=root_id)
  let _ = bob.sync().apply(alice.sync().export_all())
  let _ = bob.create_node(parent=root_id)
  alice.move_node(target=a, new_parent=root_id)
  let alice_message = alice.sync().export_all()
  let bob_message = bob.sync().export_all()
  let _ = alice.sync().apply(bob_message)
  let _ = bob.sync().apply(alice_message)
  inspect(alice.children(root_id) == bob.children(root_id), content="true")
  inspect(alice.children(root_id).length(), content="2")
  inspect(alice.version() == bob.version(), content="true")
}

///|
test "TreeState export_since uses portable version vectors" {
  let alice = TreeState::new("alice")
  let bob = TreeState::new("bob")
  let first = alice.create_node(parent=root_id)
  let _ = bob.sync().apply(alice.sync().export_all())
  let bob_version = bob.version()
  let second = alice.create_node(parent=root_id)
  let report = bob.sync().apply(alice.sync().export_since(bob_version))
  inspect(report.applied_operations(), content="1")
  inspect(bob.children(root_id) == [first, second], content="true")
}

///|
test "TreeState duplicate messages are idempotent" {
  let alice = TreeState::new("alice")
  let bob = TreeState::new("bob")
  let _ = alice.create_node(parent=root_id)
  let message = alice.sync().export_all()
  let first = bob.sync().apply(message)
  let second = bob.sync().apply(message)
  inspect(first.applied_operations(), content="1")
  inspect(second.applied_operations(), content="0")
  inspect(second.duplicate_operations(), content="1")
}

///|
test "TreeNodeId custom constructor round trips fields" {
  let id = TreeNodeId::TreeNodeId("replica", 42)
  inspect(id.replica_id(), content="replica")
  inspect(id.sequence(), content="42")
  inspect(id.key(), content="7:replica:42")
}

///|
test "TreeState rejects empty replica ids" {
  let result : Result[TreeState, TreeError] = Ok(TreeState::new("")) catch {
    error => Err(error)
  }
  match result {
    Err(TreeError::EmptyReplicaId) => ()
    _ => fail("expected EmptyReplicaId")
  }
}

///|
test "TreeState rejects unknown parents" {
  let doc = TreeState::new("alice")
  let missing = TreeNodeId::TreeNodeId("missing", 99)
  let result : Result[TreeNodeId, TreeError] = Ok(
    doc.create_node(parent=missing),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(TreeError::ParentNotFound) => ()
    _ => fail("expected ParentNotFound")
  }
}

///|
test "TreeState rejects cycles without mutation" {
  let doc = TreeState::new("alice")
  let parent = doc.create_node(parent=root_id)
  let child = doc.create_node(parent~)
  let result : Result[Unit, TreeError] = Ok(
    doc.move_node(target=parent, new_parent=child),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(TreeError::CycleDetected) => ()
    _ => fail("expected CycleDetected")
  }
  inspect(doc.children(root_id) == [parent], content="true")
  inspect(doc.children(parent) == [child], content="true")
}
