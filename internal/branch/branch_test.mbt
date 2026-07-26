///| Tests for Branch system

///|
/// Branch wrapping seam: a pending identity conflict leaves every projection stable.
test "merge_remote_ops wraps pending OpLog ConflictingIdentity atomically" {
  let oplog = @oplog.OpLog::new("local")
  let seed = @core.Op::new_insert(-1, [], "local", 0, "seed", None, None)
  ignore(try! oplog.apply_remote(seed))
  let branch = try! Branch::checkout(oplog, oplog.get_frontier())
  let missing_parent = @core.RawVersion::new("branch-parent", 0)
  let pending = @core.Op::new_insert(
    11,
    [missing_parent],
    "branch-pending",
    1,
    "a",
    None,
    None,
  )
  let pending_branch = try! branch.merge_remote_ops([pending])
  let before_frontier = pending_branch.get_frontier()
  let before_count = oplog.op_count()
  let conflict = @core.Op::new_insert(
    23,
    [missing_parent],
    "branch-pending",
    1,
    "b",
    None,
    None,
  )
  let result : Result[Branch, BranchError] = Ok(
    pending_branch.merge_remote_ops([conflict]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(BranchError::OpLog(@oplog.OpLogError::ConflictingIdentity(raw~))) =>
      assert_eq(raw, @core.RawVersion::new("branch-pending", 1))
    _ => fail("expected wrapped identity conflict")
  }
  assert_eq(oplog.op_count(), before_count)
  assert_eq(oplog.get_frontier(), before_frontier)
  assert_true(oplog.has_pending())
  assert_eq(pending_branch.get_frontier(), before_frontier)
  assert_eq(pending_branch.to_text(), "s")

  // The retained pending payload, not the conflicting retransmission, drains.
  let parent = @core.Op::new_insert(
    -1,
    [],
    missing_parent.agent,
    missing_parent.seq,
    "p",
    None,
    None,
  )
  let drained = try! pending_branch.merge_remote_ops([parent])
  assert_true(!oplog.has_pending())
  assert_true(drained.to_text().contains("a"))
  assert_true(!drained.to_text().contains("b"))
  assert_eq(oplog.op_count(), 3)
}

///|
/// Helper: Insert string character-by-character like Document module
fn insert_string(oplog : @oplog.OpLog, text : String, start_lv : Int) -> Int {
  let mut last_lv = start_lv
  for i = 0; i < text.length(); i = i + 1 {
    let ch = text[i:i + 1].to_owned()
    let op = try! oplog.insert(ch, last_lv, -1)
    last_lv = op.lv()
  }
  last_lv
}

///|
test "create empty branch" {
  let oplog = @oplog.OpLog::new("agent-1")
  let branch = Branch::new(oplog)
  inspect(branch.to_text(), content="")
  inspect(branch.get_frontier().length(), content="0")
}

///|
test "checkout with single insert" {
  let oplog = @oplog.OpLog::new("agent-1")

  // Insert "hello" character-by-character
  let _ = insert_string(oplog, "hello", -1)
  let frontier = oplog.get_frontier()

  // Checkout at this frontier
  let branch = try! Branch::checkout(oplog, frontier)
  inspect(branch.to_text(), content="hello")
  inspect(branch.visible_count(), content="5")
}

///|
test "checkout with multiple inserts" {
  let oplog = @oplog.OpLog::new("agent-1")

  // Insert "hello"
  let last_lv = insert_string(oplog, "hello", -1)
  // Insert " world" after "hello"
  let _ = insert_string(oplog, " world", last_lv)
  let frontier = oplog.get_frontier()
  let branch = try! Branch::checkout(oplog, frontier)
  inspect(branch.to_text(), content="hello world")
  inspect(branch.visible_count(), content="11")
}

///|
test "checkout with delete" {
  let oplog = @oplog.OpLog::new("agent-1")

  // Insert "hello" character-by-character
  let _ = insert_string(oplog, "hello", -1)
  // Delete first character (lv 0 is 'h')
  let _ = try! oplog.delete(0)
  let frontier = oplog.get_frontier()
  let branch = try! Branch::checkout(oplog, frontier)
  inspect(branch.to_text(), content="ello")
  inspect(branch.visible_count(), content="4")
}

///|
test "advance branch with new operations" {
  let oplog = @oplog.OpLog::new("agent-1")

  // Insert "hello"
  let last_lv = insert_string(oplog, "hello", -1)
  let frontier1 = oplog.get_frontier()

  // Checkout at first frontier
  let branch1 = try! Branch::checkout(oplog, frontier1)
  inspect(branch1.to_text(), content="hello")

  // Add more operations
  let _ = insert_string(oplog, " world", last_lv)
  let frontier2 = oplog.get_frontier()

  // Advance branch to new frontier
  let branch2 = try! branch1.advance(frontier2)
  inspect(branch2.to_text(), content="hello world")
}

///|
test "checkout at different frontiers" {
  let oplog = @oplog.OpLog::new("agent-1")

  // Insert "a"
  let lv1 = try! oplog.insert("a", -1, -1).lv()
  let frontier1 = oplog.get_frontier()

  // Insert "b"
  let lv2 = try! oplog.insert("b", lv1, -1).lv()
  let frontier2 = oplog.get_frontier()

  // Insert "c"
  let _ = try! oplog.insert("c", lv2, -1)
  let frontier3 = oplog.get_frontier()

  // Checkout at different points
  let branch1 = try! Branch::checkout(oplog, frontier1)
  let branch2 = try! Branch::checkout(oplog, frontier2)
  let branch3 = try! Branch::checkout(oplog, frontier3)
  inspect(branch1.to_text(), content="a")
  inspect(branch2.to_text(), content="ab")
  inspect(branch3.to_text(), content="abc")
}

///|
test "at_frontier check" {
  let oplog = @oplog.OpLog::new("agent-1")
  let _ = insert_string(oplog, "hello", -1)
  let frontier1 = oplog.get_frontier()
  let branch = try! Branch::checkout(oplog, frontier1)
  inspect(branch.at_frontier(frontier1), content="true")
  inspect(
    branch.at_frontier(@core.Frontier::from_array([999])),
    content="false",
  )
  inspect(branch.at_frontier(@core.Frontier::from_array([])), content="false")
}

///|
test "at_frontier rejects canonical duplicate input" {
  let remote_a = @oplog.OpLog::new("agent-a")
  let remote_b = @oplog.OpLog::new("agent-b")
  let op_a = try! remote_a.insert("A", -1, -1)
  let op_b = try! remote_b.insert("B", -1, -1)
  let oplog = @oplog.OpLog::new("agent-1")
  ignore(try! oplog.apply_remote(op_a))
  ignore(try! oplog.apply_remote(op_b))
  let frontier = oplog.get_frontier()
  let branch = try! Branch::checkout(oplog, frontier)
  inspect(frontier.length(), content="2")
  inspect(branch.at_frontier(frontier), content="true")
  let values = frontier.to_array()
  inspect(
    branch.at_frontier(@core.Frontier::from_array([values[0], values[0]])),
    content="false",
  )
}

///|
test "concurrent inserts converge" {
  // Agent 1 creates operations
  let oplog1 = @oplog.OpLog::new("agent-1")
  let _op1a = try! oplog1.insert("A", -1, -1)

  // Agent 2 creates operations
  let oplog2 = @oplog.OpLog::new("agent-2")
  let _op2a = try! oplog2.insert("B", -1, -1)

  // Simulate merge: agent1 receives agent2's operation
  // (In real implementation, this would go through network)
  // For now, we manually add to the same oplog
  let oplog = @oplog.OpLog::new("agent-1")
  let _ = try! oplog.insert("A", -1, -1)
  let _ = try! oplog.insert("B", -1, -1)

  // Both operations have same parents (empty)
  // FugueMax should resolve deterministically

  let frontier = oplog.get_frontier()
  let branch = try! Branch::checkout(oplog, frontier)

  // The text should be deterministic (either "AB" or "BA")
  let text = branch.to_text()
  inspect(text.length(), content="2")
  inspect(text.contains("A"), content="true")
  inspect(text.contains("B"), content="true")
}

///|
test "advance with no changes" {
  let oplog = @oplog.OpLog::new("agent-1")
  let _ = insert_string(oplog, "hello", -1)
  let frontier = oplog.get_frontier()
  let branch1 = try! Branch::checkout(oplog, frontier)
  let branch2 = try! branch1.advance(frontier)
  inspect(branch2.to_text(), content="hello")
  inspect(branch2.at_frontier(frontier), content="true")
}

///|
test "checkout empty oplog" {
  let oplog = @oplog.OpLog::new("agent-1")
  let frontier = oplog.get_frontier()
  let branch = try! Branch::checkout(oplog, frontier)
  inspect(branch.to_text(), content="")
  inspect(branch.visible_count(), content="0")
}

///|
test "multiple advances" {
  let oplog = @oplog.OpLog::new("agent-1")

  // Insert "a"
  let lv1 = try! oplog.insert("a", -1, -1).lv()
  let f1 = oplog.get_frontier()

  // Insert "b"
  let lv2 = try! oplog.insert("b", lv1, -1).lv()
  let f2 = oplog.get_frontier()

  // Insert "c"
  let _ = try! oplog.insert("c", lv2, -1)
  let f3 = oplog.get_frontier()

  // Checkout at f1, then advance twice
  let branch = try! Branch::checkout(oplog, f1)
  inspect(branch.to_text(), content="a")
  let branch2 = try! branch.advance(f2)
  inspect(branch2.to_text(), content="ab")
  let branch3 = try! branch2.advance(f3)
  inspect(branch3.to_text(), content="abc")
}

///|
test "branch with complex operations" {
  let oplog = @oplog.OpLog::new("agent-1")

  // Build "hello world" with inserts and deletes
  let hello_last = insert_string(oplog, "hello", -1)
  let x_lv = try! oplog.insert("x", hello_last, -1).lv() // "hellox"
  let _ = try! oplog.delete(x_lv) // Delete 'x' -> "hello"
  let space_lv = try! oplog.insert(" ", hello_last, -1).lv() // "hello "
  let _ = insert_string(oplog, "world", space_lv) // "hello world"
  let frontier = oplog.get_frontier()
  let branch = try! Branch::checkout(oplog, frontier)
  inspect(branch.to_text(), content="hello world")
}
