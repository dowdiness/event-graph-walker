///|
test "Document properties returns current winning values in shortlex String order" {
  let document = try! @container.Document::new("alice")
  let node = try! document.create_node(parent=@container.root_id)
  document.set_property(node, "title", "last-old")
  document.set_property(node, "zeta", "middle")
  document.set_property(node, "alfa", "first")
  document.set_property(node, "title", "last")
  assert_eq(document.properties(node), [
    ("alfa", "first"),
    ("zeta", "middle"),
    ("title", "last"),
  ])
}

///|
test "Document property snapshots own their arrays" {
  let document = try! @container.Document::new("alice")
  let node = try! document.create_node(parent=@container.root_id)
  document.set_property(node, "title", "original")
  let snapshot = document.properties(node)
  snapshot[0] = ("title", "changed")
  assert_eq(document.properties(node), [("title", "original")])
  let empty = try! document.create_node(parent=@container.root_id)
  assert_eq(document.properties(empty), [])
  let missing = try! @container.TreeNodeId::TreeNodeId("missing", 99)
  assert_eq(document.properties(missing), [])
}

///|
test "Document property snapshots preserve Unicode exactly" {
  let document = try! @container.Document::new("unicode")
  let node = try! document.create_node(parent=@container.root_id)
  document.set_property(node, "記録", "雪と🌙")
  assert_eq(document.properties(node), [("記録", "雪と🌙")])
}

///|
test "Document property snapshots converge after concurrent sync" {
  let alice = try! @container.Document::new("alice")
  let bob = try! @container.Document::new("bob")
  let node = try! alice.create_node(parent=@container.root_id)
  let _ = try! bob.sync().apply(try! alice.sync().export_all())
  alice.set_property(node, "zeta", "from alice")
  alice.set_property(node, "title", "alice title")
  bob.set_property(node, "alfa", "from bob")
  bob.set_property(node, "title", "bob title")
  let alice_message = try! alice.sync().export_all()
  let bob_message = try! bob.sync().export_all()
  let _ = try! alice.sync().apply(bob_message)
  let _ = try! bob.sync().apply(alice_message)
  let alice_properties = alice.properties(node)
  assert_eq(alice_properties, bob.properties(node))
  assert_eq(alice_properties, [
    ("alfa", "from bob"),
    ("zeta", "from alice"),
    ("title", "alice title"),
  ])
}

///|
test "Document property snapshots retain trashed node properties" {
  let document = try! @container.Document::new("alice")
  let node = try! document.create_node(parent=@container.root_id)
  document.set_property(node, "status", "archived")
  try! document.delete_node(node)
  assert_eq(document.is_alive(node), false)
  assert_eq(document.properties(node), [("status", "archived")])
}
