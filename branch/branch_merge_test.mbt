///|
/// Tests for merge module
fn resolve_origin(oplog : @oplog.OpLog, raw : @core.RawVersion?) -> Int {
  match raw {
    None => -1
    Some(rv) =>
      match oplog.graph.raw_to_lv(rv) {
        Some(lv) => lv
        None => -1
      }
  }
}

///|
fn resolve_op_lv(oplog : @oplog.OpLog, op : @core.Op) -> Int? {
  let raw = @core.RawVersion::new(op.agent, op.seq)
  oplog.graph.raw_to_lv(raw)
}

///|
test "merge_remote_ops - basic concurrent inserts" {
  // Create two agents
  let oplog_a = @oplog.OpLog::new("agent_a")
  let tree_a = @fugue.FugueTree::new()
  let oplog_b = @oplog.OpLog::new("agent_b")
  let tree_b = @fugue.FugueTree::new()

  // Agent A inserts "He"
  let op_a1 = try! oplog_a.insert("H", -1, -1)
  tree_a.insert(
    op_a1.lv,
    "H",
    resolve_origin(oplog_a, op_a1.origin_left),
    resolve_origin(oplog_a, op_a1.origin_right),
    0,
    "agent_a",
  )
  let op_a2 = try! oplog_a.insert("e", op_a1.lv, -1)
  tree_a.insert(
    op_a2.lv,
    "e",
    resolve_origin(oplog_a, op_a2.origin_left),
    resolve_origin(oplog_a, op_a2.origin_right),
    1,
    "agent_a",
  )

  // Agent B concurrently inserts "Wo" (starting from same state)
  let op_b1 = try! oplog_b.insert("W", -1, -1)
  tree_b.insert(
    op_b1.lv,
    "W",
    resolve_origin(oplog_b, op_b1.origin_left),
    resolve_origin(oplog_b, op_b1.origin_right),
    0,
    "agent_b",
  )
  let op_b2 = try! oplog_b.insert("o", op_b1.lv, -1)
  tree_b.insert(
    op_b2.lv,
    "o",
    resolve_origin(oplog_b, op_b2.origin_left),
    resolve_origin(oplog_b, op_b2.origin_right),
    1,
    "agent_b",
  )

  // Now merge B's operations into A
  let ops_from_b = [op_b1, op_b2]
  try! merge_remote_ops(tree_a, oplog_a, ops_from_b)

  // Both agents should converge
  let text_a = tree_a.to_text()
  inspect(text_a, content="HeWo") // FugueMax ordering: agent_a comes before agent_b

  // Merge A's operations into B
  let ops_from_a = [op_a1, op_a2]
  try! merge_remote_ops(tree_b, oplog_b, ops_from_a)
  let text_b = tree_b.to_text()
  inspect(text_b, content="HeWo") // Should converge to same result
}

///|
test "merge_remote_ops - insert and delete" {
  let oplog_a = @oplog.OpLog::new("agent_a")
  let tree_a = @fugue.FugueTree::new()
  let oplog_b = @oplog.OpLog::new("agent_b")
  let tree_b = @fugue.FugueTree::new()

  // Agent A inserts "ABC"
  let op_a1 = try! oplog_a.insert("A", -1, -1)
  tree_a.insert(
    op_a1.lv,
    "A",
    resolve_origin(oplog_a, op_a1.origin_left),
    resolve_origin(oplog_a, op_a1.origin_right),
    0,
    "agent_a",
  )
  let op_a2 = try! oplog_a.insert("B", op_a1.lv, -1)
  tree_a.insert(
    op_a2.lv,
    "B",
    resolve_origin(oplog_a, op_a2.origin_left),
    resolve_origin(oplog_a, op_a2.origin_right),
    1,
    "agent_a",
  )
  let op_a3 = try! oplog_a.insert("C", op_a2.lv, -1)
  tree_a.insert(
    op_a3.lv,
    "C",
    resolve_origin(oplog_a, op_a3.origin_left),
    resolve_origin(oplog_a, op_a3.origin_right),
    2,
    "agent_a",
  )

  // Agent B gets A's state
  let ops_from_a = [op_a1, op_a2, op_a3]
  try! merge_remote_ops(tree_b, oplog_b, ops_from_a)
  inspect(tree_b.to_text(), content="ABC")

  // Agent B deletes "B"
  let local_a2_lv = match resolve_op_lv(oplog_b, op_a2) {
    Some(lv) => lv
    None => fail("missing op_a2 in oplog_b")
  }
  let op_b1 = try! oplog_b.delete(local_a2_lv)
  let delete_target = resolve_origin(oplog_b, op_b1.origin_left)
  if delete_target != -1 {
    tree_b.delete(delete_target)
  }
  inspect(tree_b.to_text(), content="AC")

  // Merge B's delete back to A
  let ops_from_b = [op_b1]
  try! merge_remote_ops(tree_a, oplog_a, ops_from_b)
  inspect(tree_a.to_text(), content="AC")

  // Verify both converged
  inspect(tree_b.to_text(), content="AC")
}

///|
test "merge - simple merge using graph_diff" {
  let oplog = @oplog.OpLog::new("agent_a")
  let tree = @fugue.FugueTree::new()

  // Insert "Hello"
  let op1 = try! oplog.insert("H", -1, -1)
  tree.insert(
    op1.lv,
    "H",
    resolve_origin(oplog, op1.origin_left),
    resolve_origin(oplog, op1.origin_right),
    0,
    "agent_a",
  )
  let op2 = try! oplog.insert("e", op1.lv, -1)
  tree.insert(
    op2.lv,
    "e",
    resolve_origin(oplog, op2.origin_left),
    resolve_origin(oplog, op2.origin_right),
    1,
    "agent_a",
  )
  let frontier_before = oplog.get_frontier()
  let text_before = tree.to_text()
  inspect(text_before, content="He")

  // Add more operations
  let op3 = try! oplog.insert("l", op2.lv, -1)
  tree.insert(
    op3.lv,
    "l",
    resolve_origin(oplog, op3.origin_left),
    resolve_origin(oplog, op3.origin_right),
    2,
    "agent_a",
  )
  let op4 = try! oplog.insert("l", op3.lv, -1)
  tree.insert(
    op4.lv,
    "l",
    resolve_origin(oplog, op4.origin_left),
    resolve_origin(oplog, op4.origin_right),
    3,
    "agent_a",
  )
  let op5 = try! oplog.insert("o", op4.lv, -1)
  tree.insert(
    op5.lv,
    "o",
    resolve_origin(oplog, op5.origin_left),
    resolve_origin(oplog, op5.origin_right),
    4,
    "agent_a",
  )
  let frontier_after = oplog.get_frontier()
  let text_after = tree.to_text()
  inspect(text_after, content="Hello")

  // Now use merge to go from frontier_before to frontier_after
  // This should give us the same result
  let tree2 = @fugue.FugueTree::new()

  // First apply operations up to frontier_before
  tree2.insert(
    op1.lv,
    "H",
    resolve_origin(oplog, op1.origin_left),
    resolve_origin(oplog, op1.origin_right),
    0,
    "agent_a",
  )
  tree2.insert(
    op2.lv,
    "e",
    resolve_origin(oplog, op2.origin_left),
    resolve_origin(oplog, op2.origin_right),
    1,
    "agent_a",
  )

  // Then merge to frontier_after
  merge(tree2, oplog, frontier_before, frontier_after)
  let merged_text = tree2.to_text()
  inspect(merged_text, content="Hello")
}

// =============================================================================
// Gap 4: Cascading Error Propagation in Mid-Merge Tests
// =============================================================================

///|
/// Test: MergeContext::apply_operations with invalid LV raises MissingOp
test "merge error - missing op during apply" {
  let oplog = @oplog.OpLog::new("agent_a")
  let tree = @fugue.FugueTree::new()

  // Insert one valid operation
  let op1 = try! oplog.insert("A", -1, -1)
  tree.insert(
    op1.lv,
    "A",
    resolve_origin(oplog, op1.origin_left),
    resolve_origin(oplog, op1.origin_right),
    0,
    "agent_a",
  )

  let ctx = MergeContext::new(tree, oplog)

  // Try to apply operations including a non-existent LV
  let result : Result[Unit, BranchError] = try {
    ctx.apply_operations([999])
    Ok(())
  } catch {
    e => Err(e)
  }

  match result {
    Err(MissingOp(lv~)) => inspect(lv, content="999")
    _ => fail("Expected MissingOp error")
  }
}

///|
/// Test: apply_operations with valid op works, demonstrates error path exists
test "merge error - apply operations succeeds for valid ops" {
  let oplog = @oplog.OpLog::new("agent_a")
  let tree = @fugue.FugueTree::new()

  // Insert first operation
  let op1 = try! oplog.insert("A", -1, -1)
  tree.insert(
    op1.lv,
    "A",
    resolve_origin(oplog, op1.origin_left),
    resolve_origin(oplog, op1.origin_right),
    0,
    "agent_a",
  )

  // Insert second operation
  let op2 = try! oplog.insert("B", op1.lv, -1)

  // Create a fresh tree and use MergeContext to apply op2
  let tree2 = @fugue.FugueTree::new()
  // First add op1 to tree2
  tree2.insert(
    op1.lv,
    "A",
    resolve_origin(oplog, op1.origin_left),
    resolve_origin(oplog, op1.origin_right),
    0,
    "agent_a",
  )

  let ctx = MergeContext::new(tree2, oplog)

  // Apply op2 through merge context - should succeed
  let result : Result[Unit, BranchError] = try {
    ctx.apply_operations([op2.lv])
    Ok(())
  } catch {
    e => Err(e)
  }

  match result {
    Ok(_) => inspect(tree2.to_text(), content="AB")
    Err(_) => fail("Expected success but got error")
  }
}

///|
/// Test: Capture state before failed merge, verify unchanged after
test "merge error - state unchanged after failure" {
  let oplog = @oplog.OpLog::new("agent_a")
  let tree = @fugue.FugueTree::new()

  // Build initial state "ABC"
  let op1 = try! oplog.insert("A", -1, -1)
  tree.insert(op1.lv, "A", -1, -1, 0, "agent_a")
  let op2 = try! oplog.insert("B", op1.lv, -1)
  tree.insert(op2.lv, "B", op1.lv, -1, 1, "agent_a")
  let op3 = try! oplog.insert("C", op2.lv, -1)
  tree.insert(op3.lv, "C", op2.lv, -1, 2, "agent_a")

  // Capture state before
  let text_before = tree.to_text()
  inspect(text_before, content="ABC")

  let ctx = MergeContext::new(tree, oplog)

  // Try an operation that will fail
  let result : Result[Unit, BranchError] = try {
    ctx.apply_operations([999])
    Ok(())
  } catch {
    e => Err(e)
  }

  // Verify error occurred
  match result {
    Err(_) => {
      // State should be unchanged after failed operation
      // Note: The tree state may have been partially modified depending on
      // where in the operation list the failure occurred. With a single
      // invalid op at the start, the tree should remain unchanged.
      let text_after = tree.to_text()
      let count_after = tree.visible_count()
      inspect(text_after, content="ABC")
      inspect(count_after, content="3")
    }
    Ok(_) => fail("Expected error")
  }
}

///|
/// Test: Retreat then apply with missing item propagates Fugue error
test "retreat then apply with missing item" {
  let oplog = @oplog.OpLog::new("agent_a")
  let tree = @fugue.FugueTree::new()

  // Insert "AB"
  let op1 = try! oplog.insert("A", -1, -1)
  tree.insert(op1.lv, "A", -1, -1, 0, "agent_a")
  let op2 = try! oplog.insert("B", op1.lv, -1)
  tree.insert(op2.lv, "B", op1.lv, -1, 1, "agent_a")

  inspect(tree.to_text(), content="AB")

  let ctx = MergeContext::new(tree, oplog)

  // Try to retreat a non-existent item - should raise Fugue(MissingItem)
  let result : Result[Unit, BranchError] = try {
    ctx.retreat_operations([999])
    Ok(())
  } catch {
    e => Err(e)
  }

  match result {
    Err(Fugue(@fugue.MissingItem(id~))) => inspect(id, content="999")
    _ => fail("Expected Fugue(MissingItem) error")
  }
}
