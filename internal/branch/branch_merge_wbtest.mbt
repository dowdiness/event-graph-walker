///|
test "merge_remote_ops preserves a retained branch after partial admission" {
  let oplog = @oplog.OpLog::new("local")
  let base = try! oplog.insert("b", -1, -1)
  let branch = try! Branch::checkout(oplog, oplog.get_frontier())
  let incoming = @core.Op::new_insert(-1, [], "remote", 0, "r", None, None)
  let commit : (@oplog.RemoteAdmissionPlan) -> Array[@core.Op] raise @oplog.OpLogError = _plan => {
    let committed = try! oplog.insert("p", base.lv(), -1)
    raise @oplog.OpLogError::PartialRemoteAdmission(
      committed=[committed],
      error=@causal_graph.CausalGraphError::MissingParent(lv=-86),
    )
  }
  let result : Result[Branch, BranchError] = Ok(
    branch.merge_remote_ops_with([incoming], commit),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(
      BranchError::OpLog(
        @oplog.OpLogError::PartialRemoteAdmission(committed~, error~)
      )
    ) => {
      assert_eq(committed.length(), 1)
      assert_eq(committed[0].agent(), "local")
      assert_eq(committed[0].seq(), 1)
      match committed[0].content() {
        @core.Insert(text) => assert_eq(text, "p")
        _ => fail("expected injected insert")
      }
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) => assert_eq(lv, -86)
        _ => fail("expected synthetic causal graph cause")
      }
    }
    _ => fail("expected partial remote admission")
  }
  // The original retained wrapper and shared tree both advanced through the
  // admitted local prefix exactly once.
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
