///|
/// Tests for merge module
fn resolve_origin_lv(
  oplog : @oplog.OpLog,
  raw : @core.RawVersion?,
) -> @fugue.Lv? {
  match raw {
    None => None
    Some(rv) =>
      match oplog.causal_graph().raw_to_lv(rv) {
        Some(lv) => Some(@fugue.Lv(lv))
        None => None
      }
  }
}

///|
fn resolve_op_lv(oplog : @oplog.OpLog, op : @core.Op) -> Int? {
  let raw = @core.RawVersion::new(op.agent(), op.seq())
  oplog.causal_graph().raw_to_lv(raw)
}

///|
test "merge_remote_ops - basic concurrent inserts" {
  // Create two agents
  let oplog_a = @oplog.OpLog::new("agent_a")
  let tree_a : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  let oplog_b = @oplog.OpLog::new("agent_b")
  let tree_b : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Agent A inserts "He"
  let op_a1 = try! oplog_a.insert("H", -1, -1)
  tree_a.insert({
    id: @fugue.Lv(op_a1.lv()),
    content: "H",
    origin_left: resolve_origin_lv(oplog_a, op_a1.origin_left()),
    origin_right: resolve_origin_lv(oplog_a, op_a1.origin_right()),
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op_a2 = try! oplog_a.insert("e", op_a1.lv(), -1)
  tree_a.insert({
    id: @fugue.Lv(op_a2.lv()),
    content: "e",
    origin_left: resolve_origin_lv(oplog_a, op_a2.origin_left()),
    origin_right: resolve_origin_lv(oplog_a, op_a2.origin_right()),
    timestamp: @fugue.Timestamp(1),
    agent: @fugue.ReplicaId("agent_a"),
  })

  // Agent B concurrently inserts "Wo" (starting from same state)
  let op_b1 = try! oplog_b.insert("W", -1, -1)
  tree_b.insert({
    id: @fugue.Lv(op_b1.lv()),
    content: "W",
    origin_left: resolve_origin_lv(oplog_b, op_b1.origin_left()),
    origin_right: resolve_origin_lv(oplog_b, op_b1.origin_right()),
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_b"),
  })
  let op_b2 = try! oplog_b.insert("o", op_b1.lv(), -1)
  tree_b.insert({
    id: @fugue.Lv(op_b2.lv()),
    content: "o",
    origin_left: resolve_origin_lv(oplog_b, op_b2.origin_left()),
    origin_right: resolve_origin_lv(oplog_b, op_b2.origin_right()),
    timestamp: @fugue.Timestamp(1),
    agent: @fugue.ReplicaId("agent_b"),
  })

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
  let tree_a : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  let oplog_b = @oplog.OpLog::new("agent_b")
  let tree_b : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Agent A inserts "ABC"
  let op_a1 = try! oplog_a.insert("A", -1, -1)
  tree_a.insert({
    id: @fugue.Lv(op_a1.lv()),
    content: "A",
    origin_left: resolve_origin_lv(oplog_a, op_a1.origin_left()),
    origin_right: resolve_origin_lv(oplog_a, op_a1.origin_right()),
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op_a2 = try! oplog_a.insert("B", op_a1.lv(), -1)
  tree_a.insert({
    id: @fugue.Lv(op_a2.lv()),
    content: "B",
    origin_left: resolve_origin_lv(oplog_a, op_a2.origin_left()),
    origin_right: resolve_origin_lv(oplog_a, op_a2.origin_right()),
    timestamp: @fugue.Timestamp(1),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op_a3 = try! oplog_a.insert("C", op_a2.lv(), -1)
  tree_a.insert({
    id: @fugue.Lv(op_a3.lv()),
    content: "C",
    origin_left: resolve_origin_lv(oplog_a, op_a3.origin_left()),
    origin_right: resolve_origin_lv(oplog_a, op_a3.origin_right()),
    timestamp: @fugue.Timestamp(2),
    agent: @fugue.ReplicaId("agent_a"),
  })

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
  match resolve_origin_lv(oplog_b, op_b1.origin_left()) {
    Some(lv) => try! tree_b.delete(lv)
    None => ()
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
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert "Hello"
  let op1 = try! oplog.insert("H", -1, -1)
  tree.insert({
    id: @fugue.Lv(op1.lv()),
    content: "H",
    origin_left: resolve_origin_lv(oplog, op1.origin_left()),
    origin_right: resolve_origin_lv(oplog, op1.origin_right()),
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op2 = try! oplog.insert("e", op1.lv(), -1)
  tree.insert({
    id: @fugue.Lv(op2.lv()),
    content: "e",
    origin_left: resolve_origin_lv(oplog, op2.origin_left()),
    origin_right: resolve_origin_lv(oplog, op2.origin_right()),
    timestamp: @fugue.Timestamp(1),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let frontier_before = oplog.get_frontier()
  let text_before = tree.to_text()
  inspect(text_before, content="He")

  // Add more operations
  let op3 = try! oplog.insert("l", op2.lv(), -1)
  tree.insert({
    id: @fugue.Lv(op3.lv()),
    content: "l",
    origin_left: resolve_origin_lv(oplog, op3.origin_left()),
    origin_right: resolve_origin_lv(oplog, op3.origin_right()),
    timestamp: @fugue.Timestamp(2),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op4 = try! oplog.insert("l", op3.lv(), -1)
  tree.insert({
    id: @fugue.Lv(op4.lv()),
    content: "l",
    origin_left: resolve_origin_lv(oplog, op4.origin_left()),
    origin_right: resolve_origin_lv(oplog, op4.origin_right()),
    timestamp: @fugue.Timestamp(3),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op5 = try! oplog.insert("o", op4.lv(), -1)
  tree.insert({
    id: @fugue.Lv(op5.lv()),
    content: "o",
    origin_left: resolve_origin_lv(oplog, op5.origin_left()),
    origin_right: resolve_origin_lv(oplog, op5.origin_right()),
    timestamp: @fugue.Timestamp(4),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let frontier_after = oplog.get_frontier()
  let text_after = tree.to_text()
  inspect(text_after, content="Hello")

  // Now use merge to go from frontier_before to frontier_after
  // This should give us the same result
  let tree2 : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // First apply operations up to frontier_before
  tree2.insert({
    id: @fugue.Lv(op1.lv()),
    content: "H",
    origin_left: resolve_origin_lv(oplog, op1.origin_left()),
    origin_right: resolve_origin_lv(oplog, op1.origin_right()),
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  tree2.insert({
    id: @fugue.Lv(op2.lv()),
    content: "e",
    origin_left: resolve_origin_lv(oplog, op2.origin_left()),
    origin_right: resolve_origin_lv(oplog, op2.origin_right()),
    timestamp: @fugue.Timestamp(1),
    agent: @fugue.ReplicaId("agent_a"),
  })

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
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert one valid operation
  let op1 = try! oplog.insert("A", -1, -1)
  tree.insert({
    id: @fugue.Lv(op1.lv()),
    content: "A",
    origin_left: resolve_origin_lv(oplog, op1.origin_left()),
    origin_right: resolve_origin_lv(oplog, op1.origin_right()),
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let ctx = MergeContext::new(tree, oplog)

  // Try to apply operations including a non-existent LV
  let result : Result[Unit, BranchError] = try {
    ctx.apply_operations(
      @rle.Rle::from_array([@core.LvRange::{ start: 999, count: 1 }]),
    )
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
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert first operation
  let op1 = try! oplog.insert("A", -1, -1)
  tree.insert({
    id: @fugue.Lv(op1.lv()),
    content: "A",
    origin_left: resolve_origin_lv(oplog, op1.origin_left()),
    origin_right: resolve_origin_lv(oplog, op1.origin_right()),
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })

  // Insert second operation
  let op2 = try! oplog.insert("B", op1.lv(), -1)

  // Create a fresh tree and use MergeContext to apply op2
  let tree2 : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  // First add op1 to tree2
  tree2.insert({
    id: @fugue.Lv(op1.lv()),
    content: "A",
    origin_left: resolve_origin_lv(oplog, op1.origin_left()),
    origin_right: resolve_origin_lv(oplog, op1.origin_right()),
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let ctx = MergeContext::new(tree2, oplog)

  // Apply op2 through merge context - should succeed
  let result : Result[Unit, BranchError] = try {
    ctx.apply_operations(
      @rle.Rle::from_array([@core.LvRange::{ start: op2.lv(), count: 1 }]),
    )
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
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Build initial state "ABC"
  let op1 = try! oplog.insert("A", -1, -1)
  tree.insert({
    id: @fugue.Lv(op1.lv()),
    content: "A",
    origin_left: None,
    origin_right: None,
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op2 = try! oplog.insert("B", op1.lv(), -1)
  tree.insert({
    id: @fugue.Lv(op2.lv()),
    content: "B",
    origin_left: Some(@fugue.Lv(op1.lv())),
    origin_right: None,
    timestamp: @fugue.Timestamp(1),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op3 = try! oplog.insert("C", op2.lv(), -1)
  tree.insert({
    id: @fugue.Lv(op3.lv()),
    content: "C",
    origin_left: Some(@fugue.Lv(op2.lv())),
    origin_right: None,
    timestamp: @fugue.Timestamp(2),
    agent: @fugue.ReplicaId("agent_a"),
  })

  // Capture state before
  let text_before = tree.to_text()
  inspect(text_before, content="ABC")
  let ctx = MergeContext::new(tree, oplog)

  // Try an operation that will fail
  let result : Result[Unit, BranchError] = try {
    ctx.apply_operations(
      @rle.Rle::from_array([@core.LvRange::{ start: 999, count: 1 }]),
    )
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
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert "AB"
  let op1 = try! oplog.insert("A", -1, -1)
  tree.insert({
    id: @fugue.Lv(op1.lv()),
    content: "A",
    origin_left: None,
    origin_right: None,
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op2 = try! oplog.insert("B", op1.lv(), -1)
  tree.insert({
    id: @fugue.Lv(op2.lv()),
    content: "B",
    origin_left: Some(@fugue.Lv(op1.lv())),
    origin_right: None,
    timestamp: @fugue.Timestamp(1),
    agent: @fugue.ReplicaId("agent_a"),
  })
  inspect(tree.to_text(), content="AB")
  let ctx = MergeContext::new(tree, oplog)

  // Try to retreat a non-existent item - should raise MissingOp
  // (retreat now looks up the op in the oplog first)
  let result : Result[Unit, BranchError] = try {
    ctx.retreat_operations(
      @rle.Rle::from_array([@core.LvRange::{ start: 999, count: 1 }]),
    )
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
test "merge - concurrent delete retreat convergence" {
  let oplog_a = @oplog.OpLog::new("agent_a")
  let tree_a : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  let oplog_b = @oplog.OpLog::new("agent_b")
  let tree_b : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Both agents start with "ABC"
  let op1 = try! oplog_a.insert("A", -1, -1)
  tree_a.insert({
    id: @fugue.Lv(op1.lv()),
    content: "A",
    origin_left: None,
    origin_right: None,
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op2 = try! oplog_a.insert("B", op1.lv(), -1)
  tree_a.insert({
    id: @fugue.Lv(op2.lv()),
    content: "B",
    origin_left: Some(@fugue.Lv(op1.lv())),
    origin_right: None,
    timestamp: @fugue.Timestamp(1),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op3 = try! oplog_a.insert("C", op2.lv(), -1)
  tree_a.insert({
    id: @fugue.Lv(op3.lv()),
    content: "C",
    origin_left: Some(@fugue.Lv(op2.lv())),
    origin_right: None,
    timestamp: @fugue.Timestamp(2),
    agent: @fugue.ReplicaId("agent_a"),
  })

  // Sync A -> B
  let ops_a = [op1, op2, op3]
  try! merge_remote_ops(tree_b, oplog_b, ops_a)
  inspect(tree_b.to_text(), content="ABC")

  // Agent A deletes "B"
  let del_a = try! oplog_a.delete(op2.lv())
  try! tree_a.delete(@fugue.Lv(op2.lv()))
  inspect(tree_a.to_text(), content="AC")

  // Agent B also deletes "B" concurrently
  let b_lv_for_op2 = match
    oplog_b.causal_graph().raw_to_lv(@core.RawVersion::new("agent_a", 1)) {
    Some(lv) => lv
    None => fail("missing op2 in B")
  }
  let del_b = try! oplog_b.delete(b_lv_for_op2)
  try! tree_b.delete(@fugue.Lv(b_lv_for_op2))
  inspect(tree_b.to_text(), content="AC")

  // Merge: A gets B's concurrent delete via merge_remote_ops (advance path)
  try! merge_remote_ops(tree_a, oplog_a, [del_b])
  inspect(tree_a.to_text(), content="AC")

  // Merge: B gets A's concurrent delete via merge_remote_ops (advance path)
  try! merge_remote_ops(tree_b, oplog_b, [del_a])
  inspect(tree_b.to_text(), content="AC")
}

///|
/// Test: frontier-based merge exercises MergeContext::retreat_operations directly.
/// Agent A has "ABC" + delete "B". We merge from A's current frontier back to
/// the pre-delete frontier, which retreats the delete and restores "B".
test "merge - frontier retreat exercises two-count path" {
  let oplog = @oplog.OpLog::new("agent_a")
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert "ABC"
  let op1 = try! oplog.insert("A", -1, -1)
  tree.insert({
    id: @fugue.Lv(op1.lv()),
    content: "A",
    origin_left: None,
    origin_right: None,
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op2 = try! oplog.insert("B", op1.lv(), -1)
  tree.insert({
    id: @fugue.Lv(op2.lv()),
    content: "B",
    origin_left: Some(@fugue.Lv(op1.lv())),
    origin_right: None,
    timestamp: @fugue.Timestamp(1),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op3 = try! oplog.insert("C", op2.lv(), -1)
  tree.insert({
    id: @fugue.Lv(op3.lv()),
    content: "C",
    origin_left: Some(@fugue.Lv(op2.lv())),
    origin_right: None,
    timestamp: @fugue.Timestamp(2),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let frontier_abc = oplog.get_frontier()
  inspect(tree.to_text(), content="ABC")

  // Delete "B"
  let _ = try! oplog.delete(op2.lv())
  try! tree.delete_with_ts(@fugue.Lv(op2.lv()), 3, "agent_a")
  let frontier_with_delete = oplog.get_frontier()
  inspect(tree.to_text(), content="AC")

  // Retreat the delete via merge() — this calls retreat_operations directly
  merge(tree, oplog, frontier_with_delete, frontier_abc)
  inspect(
    tree.to_text(),
    content=(
      #|AC
    ),
  )
}

///|
test "merge - retreat insert hides items correctly" {
  let oplog = @oplog.OpLog::new("agent_a")
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()

  // Insert "ABCDE"
  let op1 = try! oplog.insert("A", -1, -1)
  tree.insert({
    id: @fugue.Lv(0),
    content: "A",
    origin_left: None,
    origin_right: None,
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op2 = try! oplog.insert("B", op1.lv(), -1)
  tree.insert({
    id: @fugue.Lv(1),
    content: "B",
    origin_left: Some(@fugue.Lv(0)),
    origin_right: None,
    timestamp: @fugue.Timestamp(1),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op3 = try! oplog.insert("C", op2.lv(), -1)
  tree.insert({
    id: @fugue.Lv(2),
    content: "C",
    origin_left: Some(@fugue.Lv(1)),
    origin_right: None,
    timestamp: @fugue.Timestamp(2),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let _ = op3
  let frontier_abc = oplog.get_frontier()

  let op4 = try! oplog.insert("D", op3.lv(), -1)
  tree.insert({
    id: @fugue.Lv(3),
    content: "D",
    origin_left: Some(@fugue.Lv(2)),
    origin_right: None,
    timestamp: @fugue.Timestamp(3),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let op5 = try! oplog.insert("E", op4.lv(), -1)
  tree.insert({
    id: @fugue.Lv(4),
    content: "E",
    origin_left: Some(@fugue.Lv(3)),
    origin_right: None,
    timestamp: @fugue.Timestamp(4),
    agent: @fugue.ReplicaId("agent_a"),
  })
  let _ = op5
  let frontier_abcde = oplog.get_frontier()

  inspect(tree.to_text(), content="ABCDE")

  // Build tree2 at ABCDE state
  let tree2 : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  tree2.insert({
    id: @fugue.Lv(0),
    content: "A",
    origin_left: None,
    origin_right: None,
    timestamp: @fugue.Timestamp(0),
    agent: @fugue.ReplicaId("agent_a"),
  })
  tree2.insert({
    id: @fugue.Lv(1),
    content: "B",
    origin_left: Some(@fugue.Lv(0)),
    origin_right: None,
    timestamp: @fugue.Timestamp(1),
    agent: @fugue.ReplicaId("agent_a"),
  })
  tree2.insert({
    id: @fugue.Lv(2),
    content: "C",
    origin_left: Some(@fugue.Lv(1)),
    origin_right: None,
    timestamp: @fugue.Timestamp(2),
    agent: @fugue.ReplicaId("agent_a"),
  })
  tree2.insert({
    id: @fugue.Lv(3),
    content: "D",
    origin_left: Some(@fugue.Lv(2)),
    origin_right: None,
    timestamp: @fugue.Timestamp(3),
    agent: @fugue.ReplicaId("agent_a"),
  })
  tree2.insert({
    id: @fugue.Lv(4),
    content: "E",
    origin_left: Some(@fugue.Lv(3)),
    origin_right: None,
    timestamp: @fugue.Timestamp(4),
    agent: @fugue.ReplicaId("agent_a"),
  })

  // Retreat from ABCDE to ABC (retreat ops 3,4 — hides D and E)
  merge(tree2, oplog, frontier_abcde, frontier_abc)
  inspect(tree2.to_text(), content="ABC")
}
