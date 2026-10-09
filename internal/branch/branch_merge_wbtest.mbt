///|
test "merge_remote_ops preserves a retained branch after partial change application" {
  let oplog = @oplog.OpLog("local")
  ignore(try! oplog.insert("b", -1, -1))
  let branch = try! Branch::checkout(oplog, oplog.get_frontier())
  let base = @core.RawVersion("local", 0)
  let prefix = @core.Op::insert(-1, [base], "remote", 0, "p", Some(base), None)
  let prefix_id = @core.RawVersion("remote", 0)
  let incoming = @core.Op::insert(
    -1,
    [prefix_id],
    "remote",
    1,
    "r",
    Some(prefix_id),
    None,
  )
  let apply = action => {
    oplog.apply_changes_with_failure(action, op => {
      if op.seq() == 1 {
        Some(@causal_graph.CausalGraphError::MissingParent(lv=-86))
      } else {
        None
      }
    })
  }
  let result : Result[Branch, BranchError] = Ok(
    branch.merge_remote_ops_with([prefix, incoming], apply),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(
      BranchError::OpLog(
        @oplog.OpLogError::PartialApplyChanges(committed~, error~)
      )
    ) => {
      assert_eq(committed.length(), 1)
      assert_eq(committed[0].agent(), "remote")
      assert_eq(committed[0].seq(), 0)
      match committed[0].content() {
        @core.Insert(text) => assert_eq(text, "p")
        _ => fail("expected injected insert")
      }
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) => assert_eq(lv, -86)
        _ => fail("expected synthetic causal graph cause")
      }
    }
    _ => fail("expected partial remote change application")
  }
  // The retained branch reflects the committed remote prefix.
  assert_true(branch.at_frontier(oplog.get_frontier()))
  assert_eq(branch.visible_count(), 2)
  assert_eq(branch.to_text().length(), 2)
  assert_true(branch.to_text().contains("p"))
  assert_true(!branch.to_text().contains("r"))

  let merged = try! branch.merge_remote_ops([incoming])
  let fresh = try! Branch::checkout(oplog, oplog.get_frontier())
  assert_eq(merged.to_text(), fresh.to_text())
  assert_eq(merged.visible_count(), fresh.visible_count())
  assert_true(merged.at_frontier(oplog.get_frontier()))
  assert_eq(oplog.op_count(), 3)
}
