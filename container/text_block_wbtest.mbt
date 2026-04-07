///| TextBlock unit tests

///|
fn apply_insert(
  block : TextBlock,
  pos : Int,
  lv : Int,
  content : String,
  timestamp : Int,
  agent : String,
) -> Unit raise DocumentError {
  let op = block.make_insert_op_at(pos, lv, content, timestamp, agent)
  block.apply_op(op)
}

///|
fn apply_delete(
  block : TextBlock,
  pos : Int,
  timestamp : Int,
  agent : String,
) -> Unit raise DocumentError {
  let op = block.make_delete_op_at(pos, timestamp, agent)
  block.apply_op(op)
}

///|
test "text_block: insert and read" {
  let block = TextBlock::new()
  apply_insert(block, 0, 0, "H", 1, "alice")
  apply_insert(block, 1, 1, "i", 2, "alice")
  inspect(block.text(), content="Hi")
  inspect(block.len(), content="2")
}

///|
test "text_block: insert at middle" {
  let block = TextBlock::new()
  apply_insert(block, 0, 0, "A", 1, "alice")
  apply_insert(block, 1, 1, "C", 2, "alice")
  apply_insert(block, 1, 2, "B", 3, "alice")
  inspect(block.text(), content="ABC")
}

///|
test "text_block: delete" {
  let block = TextBlock::new()
  apply_insert(block, 0, 0, "A", 1, "alice")
  apply_insert(block, 1, 1, "B", 2, "alice")
  apply_insert(block, 2, 2, "C", 3, "alice")
  inspect(block.text(), content="ABC")
  apply_delete(block, 1, 4, "alice")
  inspect(block.text(), content="AC")
  inspect(block.len(), content="2")
}

///|
test "text_block: insert out of bounds" {
  let block = TextBlock::new()
  apply_insert(block, 0, 0, "A", 1, "alice")
  let result = try {
    apply_insert(block, 5, 1, "B", 2, "alice")
    Ok(())
  } catch {
    _ => Err(())
  }
  inspect(result, content="Err(())")
}

///|
test "text_block: delete out of bounds" {
  let block = TextBlock::new()
  apply_insert(block, 0, 0, "A", 1, "alice")
  let result = try {
    apply_delete(block, 5, 2, "alice")
    Ok(())
  } catch {
    _ => Err(())
  }
  inspect(result, content="Err(())")
}

///|
test "text_block: delete after tombstone exists" {
  let block = TextBlock::new()
  apply_insert(block, 0, 0, "A", 1, "alice")
  apply_insert(block, 1, 1, "B", 2, "alice")
  apply_insert(block, 2, 2, "C", 3, "alice")
  apply_delete(block, 1, 4, "alice")
  inspect(block.text(), content="AC")
  apply_delete(block, 1, 5, "alice")
  inspect(block.text(), content="A")
}

///|
test "text_block: empty" {
  let block = TextBlock::new()
  inspect(block.text(), content="")
  inspect(block.len(), content="0")
}

///|
test "text_block: replayable ops reconstruct block text" {
  let source = TextBlock::new()
  let op_a = source.make_insert_op_at(0, 0, "A", 1, "alice")
  source.apply_op(op_a)
  let op_b = source.make_insert_op_at(1, 1, "B", 2, "alice")
  source.apply_op(op_b)
  let op_c = source.make_insert_op_at(2, 2, "C", 3, "alice")
  source.apply_op(op_c)
  let op_del = source.make_delete_op_at(1, 4, "alice")
  source.apply_op(op_del)

  let replay = TextBlock::new()
  replay.apply_op(op_a)
  replay.apply_op(op_b)
  replay.apply_op(op_c)
  replay.apply_op(op_del)

  inspect(source.text(), content="AC")
  inspect(replay.text(), content="AC")
  inspect(replay.len(), content="2")
}
