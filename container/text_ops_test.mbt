///| Document text operation integration tests

///|
test "document: insert and read text" {
  let doc = @container.Document::new("alice")
  let node = doc.create_node(parent=@container.root_id)
  doc.insert_text(node, 0, "Hello")
  inspect(doc.get_text(node), content="Hello")
  inspect(doc.text_len(node), content="5")
}

///|
test "document: delete text" {
  let doc = @container.Document::new("alice")
  let node = doc.create_node(parent=@container.root_id)
  doc.insert_text(node, 0, "Hello")
  doc.delete_text(node, 1)
  inspect(doc.get_text(node), content="Hllo")
}

///|
test "document: text on deleted node fails" {
  let doc = @container.Document::new("alice")
  let node = doc.create_node(parent=@container.root_id)
  doc.delete_node(node)
  let result = try {
    doc.insert_text(node, 0, "x")
    Ok(())
  } catch {
    _ => Err(())
  }
  inspect(result, content="Err(())")
}

///|
test "document: multiple blocks independent" {
  let doc = @container.Document::new("alice")
  let n1 = doc.create_node(parent=@container.root_id)
  let n2 = doc.create_node(parent=@container.root_id)
  doc.insert_text(n1, 0, "AAA")
  doc.insert_text(n2, 0, "BBB")
  inspect(doc.get_text(n1), content="AAA")
  inspect(doc.get_text(n2), content="BBB")
}

///|
test "document: get_text on node without text returns empty" {
  let doc = @container.Document::new("alice")
  let node = doc.create_node(parent=@container.root_id)
  inspect(doc.get_text(node), content="")
  inspect(doc.text_len(node), content="0")
}

///|
test "document: tree and text ops share causal graph" {
  let doc = @container.Document::new("alice")
  let n1 = doc.create_node(parent=@container.root_id)
  doc.insert_text(n1, 0, "AB")
  inspect(doc.get_text(n1), content="AB")
  let n2 = doc.create_node(parent=@container.root_id)
  doc.insert_text(n2, 0, "X")
  inspect(doc.get_text(n2), content="X")
}

///|
test "document: delete from empty block fails" {
  let doc = @container.Document::new("alice")
  let node = doc.create_node(parent=@container.root_id)
  // No text inserted — delete at pos 0 of empty block is out of bounds
  let result = try {
    doc.delete_text(node, 0)
    Ok(())
  } catch {
    _ => Err(())
  }
  inspect(result, content="Err(())")
}

///|
test "document: insert at invalid position" {
  let doc = @container.Document::new("alice")
  let node = doc.create_node(parent=@container.root_id)
  doc.insert_text(node, 0, "AB")
  let result = try {
    doc.insert_text(node, 5, "X")
    Ok(())
  } catch {
    _ => Err(())
  }
  inspect(result, content="Err(())")
}

///|
test "document: interleaved LV gaps across blocks" {
  let doc = @container.Document::new("alice")
  let n1 = doc.create_node(parent=@container.root_id)
  let n2 = doc.create_node(parent=@container.root_id)
  doc.insert_text(n1, 0, "A")
  doc.insert_text(n2, 0, "X")
  doc.insert_text(n1, 1, "B")
  doc.insert_text(n2, 1, "Y")
  doc.insert_text(n1, 2, "C")
  inspect(doc.get_text(n1), content="ABC")
  inspect(doc.get_text(n2), content="XY")
}

///|
test "document: replace_text" {
  let doc = @container.Document::new("alice")
  let node = doc.create_node(parent=@container.root_id)
  doc.insert_text(node, 0, "Hello")
  doc.replace_text(node, "World")
  inspect(doc.get_text(node), content="World")
}

///|
test "document: replace_text on empty block" {
  let doc = @container.Document::new("alice")
  let node = doc.create_node(parent=@container.root_id)
  doc.replace_text(node, "New")
  inspect(doc.get_text(node), content="New")
}

///|
test "document: replace_text with empty string" {
  let doc = @container.Document::new("alice")
  let node = doc.create_node(parent=@container.root_id)
  doc.insert_text(node, 0, "Hello")
  doc.replace_text(node, "")
  inspect(doc.get_text(node), content="")
  inspect(doc.text_len(node), content="0")
}

///|
test "document: text after delete_node" {
  let doc = @container.Document::new("alice")
  let node = doc.create_node(parent=@container.root_id)
  doc.insert_text(node, 0, "Hello")
  inspect(doc.get_text(node), content="Hello")
  doc.delete_node(node)
  // Block data persists (for undo), but writes are rejected
  inspect(doc.get_text(node), content="Hello")
  let result = try {
    doc.insert_text(node, 0, "x")
    Ok(())
  } catch {
    _ => Err(())
  }
  inspect(result, content="Err(())")
}

///|
test "document: mixed two-block edits preserve sibling isolation" {
  let doc = @container.Document::new("alice")
  let left = doc.create_node(parent=@container.root_id)
  let right = doc.create_node(parent=@container.root_id)
  doc.insert_text(left, 0, "abc")
  doc.insert_text(right, 0, "XYZ")
  doc.delete_text(left, 1)
  doc.replace_text(right, "Q")
  doc.insert_text(left, 2, "d")
  inspect(doc.get_text(left), content="acd")
  inspect(doc.get_text(right), content="Q")
}

///|
test "document: sync message replays tree and text together" {
  let doc_a = @container.Document::new("alice")
  let doc_b = @container.Document::new("bob")
  let node = doc_a.create_node(parent=@container.root_id)
  let sibling = doc_a.create_node_after(parent=@container.root_id, after=node)

  doc_a.insert_text(node, 0, "ABC")
  doc_a.insert_text(sibling, 0, "Z")
  doc_a.delete_text(node, 1)

  let message = doc_a.export_sync_message()
  inspect(message.tree_ops.length(), content="2")
  inspect(message.text_ops.length(), content="5")
  doc_b.apply_remote_sync_message(message)

  inspect(doc_a.get_text(node), content="AC")
  inspect(doc_b.get_text(node), content="AC")
  inspect(doc_b.get_text(sibling), content="Z")
}

///|
test "document: sync message carries replace_text history" {
  let doc_a = @container.Document::new("alice")
  let doc_b = @container.Document::new("bob")
  let node = doc_a.create_node(parent=@container.root_id)

  doc_a.insert_text(node, 0, "Hello")
  doc_a.replace_text(node, "World")

  let message = doc_a.export_sync_message()
  doc_b.apply_remote_sync_message(message)

  inspect(doc_a.get_text(node), content="World")
  inspect(doc_b.get_text(node), content="World")
}

///|
test "document: remote text ops buffer until tree target exists" {
  let doc_a = @container.Document::new("alice")
  let doc_b = @container.Document::new("bob")
  let node = doc_a.create_node(parent=@container.root_id)

  doc_a.insert_text(node, 0, "AB")

  let text_ops = doc_a.export_text_ops()
  inspect(text_ops.length(), content="2")
  doc_b.apply_remote_text_op(text_ops[0])
  doc_b.apply_remote_text_op(text_ops[1])
  inspect(doc_b.get_text(node), content="")

  for op in doc_a.export_ops() {
    doc_b.apply_remote_op(op)
  }

  inspect(doc_b.get_text(node), content="AB")
}

///|
test "document: remote delete buffers until target insert arrives" {
  let doc_a = @container.Document::new("alice")
  let doc_b = @container.Document::new("bob")
  let node = doc_a.create_node(parent=@container.root_id)

  for op in doc_a.export_ops() {
    doc_b.apply_remote_op(op)
  }

  doc_a.insert_text(node, 0, "AB")
  doc_a.delete_text(node, 1)

  let text_ops = doc_a.export_text_ops()
  inspect(text_ops.length(), content="3")
  doc_b.apply_remote_text_op(text_ops[2])
  inspect(doc_b.get_text(node), content="")
  doc_b.apply_remote_text_op(text_ops[0])
  inspect(doc_b.get_text(node), content="A")
  doc_b.apply_remote_text_op(text_ops[1])

  inspect(doc_a.get_text(node), content="A")
  inspect(doc_b.get_text(node), content="A")
}
