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
test "document: delete from nonexistent text block" {
  let doc = @container.Document::new("alice")
  let node = doc.create_node(parent=@container.root_id)
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
