///| TextBlock unit tests

///|
test "text_block: insert and read" {
  let block = TextBlock::new()
  block.insert_at(0, 0, "H", 1, "alice")
  block.insert_at(1, 1, "i", 2, "alice")
  inspect(block.text(), content="Hi")
  inspect(block.len(), content="2")
}

///|
test "text_block: insert at middle" {
  let block = TextBlock::new()
  block.insert_at(0, 0, "A", 1, "alice")
  block.insert_at(1, 1, "C", 2, "alice")
  block.insert_at(1, 2, "B", 3, "alice")
  inspect(block.text(), content="ABC")
}

///|
test "text_block: delete" {
  let block = TextBlock::new()
  block.insert_at(0, 0, "A", 1, "alice")
  block.insert_at(1, 1, "B", 2, "alice")
  block.insert_at(2, 2, "C", 3, "alice")
  inspect(block.text(), content="ABC")
  block.delete_at(1, 4, "alice")
  inspect(block.text(), content="AC")
  inspect(block.len(), content="2")
}

///|
test "text_block: insert out of bounds" {
  let block = TextBlock::new()
  block.insert_at(0, 0, "A", 1, "alice")
  let result = try {
    block.insert_at(5, 1, "B", 2, "alice")
    Ok(())
  } catch {
    _ => Err(())
  }
  inspect(result, content="Err(())")
}

///|
test "text_block: delete out of bounds" {
  let block = TextBlock::new()
  block.insert_at(0, 0, "A", 1, "alice")
  let result = try {
    block.delete_at(5, 2, "alice")
    Ok(())
  } catch {
    _ => Err(())
  }
  inspect(result, content="Err(())")
}

///|
test "text_block: delete after tombstone exists" {
  let block = TextBlock::new()
  block.insert_at(0, 0, "A", 1, "alice")
  block.insert_at(1, 1, "B", 2, "alice")
  block.insert_at(2, 2, "C", 3, "alice")
  block.delete_at(1, 4, "alice")
  inspect(block.text(), content="AC")
  block.delete_at(1, 5, "alice")
  inspect(block.text(), content="A")
}

///|
test "text_block: empty" {
  let block = TextBlock::new()
  inspect(block.text(), content="")
  inspect(block.len(), content="0")
}
