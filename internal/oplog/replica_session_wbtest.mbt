///| Behavioral boundary tests for the retained-authority/fresh-writer prototype.

///|
test "prototype: sessions use fresh writer identities over one authority" {
  let authority = OpLog("coordinator")
  let page_a = ReplicaSession::attach(authority, "page-a")
  let first = try! page_a.insert("a", None, None)
  assert_eq(first.agent(), "page-a")
  assert_eq(first.seq(), 0)
  assert_eq(authority.op_count(), 1)

  let page_b = ReplicaSession::attach(authority, "page-b")
  let second = try! page_b.insert("b", None, None)
  assert_eq(second.agent(), "page-b")
  assert_eq(second.seq(), 0)
  assert_eq(second.parents(), [@core.RawVersion("page-a", 0)])
  assert_eq(authority.op_count(), 2)

  let delta = page_a.pull()
  assert_eq(delta.retreat.length(), 0)
  assert_eq(delta.advance.length(), 1)
  assert_eq(delta.advance[0].agent(), "page-b")
  assert_eq(page_a.frontier(), authority.get_frontier())
  assert_eq(delta.frontier, authority.get_frontier())
}

///|
test "prototype: pending delivery becomes visible only after admission" {
  let authority = OpLog("coordinator-pending")
  let page = ReplicaSession::attach(authority, "page-pending")
  let peer = OpLog("peer-pending")
  let parent = try! peer.insert("p", -1, -1)
  let child = try! peer.insert("c", 0, -1)

  assert_eq((try! authority.apply_remote(child)).length(), 0)
  assert_eq(authority.has_pending(), true)
  assert_eq(page.pull().advance.length(), 0)

  ignore(try! authority.apply_remote(parent))
  let delta = page.pull()
  assert_eq(delta.advance.length(), 2)
  assert_eq(delta.advance[0].agent(), "peer-pending")
  assert_eq(delta.advance[1].seq(), 1)
}

///|
test "prototype: duplicate delivery does not advance a session twice" {
  let authority = OpLog("coordinator-duplicate")
  let page = ReplicaSession::attach(authority, "page-duplicate")
  let peer = OpLog("peer-duplicate")
  let operation = try! peer.insert("x", -1, -1)

  ignore(try! authority.apply_remote(operation))
  assert_eq(page.pull().advance.length(), 1)
  ignore(try! authority.apply_remote(operation))
  assert_eq(page.pull().advance.length(), 0)
  assert_eq(authority.op_count(), 1)
}

///|
test "prototype: concurrent peer branches converge at a fresh session frontier" {
  let authority = OpLog("coordinator-merge")
  let left = ReplicaSession::attach(authority, "peer-left")
  let right = ReplicaSession::attach(authority, "peer-right")
  ignore(try! left.insert("l", None, None))
  ignore(try! right.insert("r", None, None))

  let left_delta = left.pull()
  let right_delta = right.pull()
  assert_eq(left_delta.retreat.length(), 0)
  assert_eq(right_delta.retreat.length(), 0)
  assert_eq(left_delta.advance.length(), 1)
  assert_eq(right_delta.advance.length(), 1)
  assert_eq(left.frontier(), right.frontier())

  let fresh = ReplicaSession::attach(authority, "page-fresh")
  let exported = fresh.export_since(@core.Frontier::from_array([]))
  assert_eq(exported.retreat.length(), 0)
  assert_eq(exported.advance.length(), 2)
  assert_eq(exported.frontier, authority.get_frontier())
}

///|
test "prototype: partial admission exposes only the committed prefix" {
  let authority = OpLog("coordinator-partial")
  let page = ReplicaSession::attach(authority, "page-partial")
  let first = @core.Op::insert(
    -1,
    [],
    "partial-first-session",
    0,
    "a",
    None,
    None,
  )
  let failed = @core.Op::insert(
    -1,
    [],
    "partial-failed-session",
    0,
    "b",
    None,
    None,
  )
  let suffix = @core.Op::insert(
    -1,
    [],
    "partial-suffix-session",
    0,
    "c",
    None,
    None,
  )
  let plan = try! authority.prepare_remote([first, failed, suffix])
  let failed_raw = remote_admission_raw(failed)
  let result : Result[Array[@core.Op], OpLogError] = Ok(
    authority.commit_remote_with(plan, op => {
      if remote_admission_raw(op) == failed_raw {
        raise OpLogError::CausalGraphError(
          error=@causal_graph.CausalGraphError::MissingParent(lv=-99),
        )
      }
      authority.commit_one_remote(op)
    }),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::PartialRemoteAdmission(committed~, error~)) => {
      ignore(error)
      assert_eq(committed.length(), 1)
      assert_eq(page.pull().advance.length(), 1)
    }
    _ => fail("expected partial remote admission")
  }

  ignore(
    try! authority.commit_remote(
      try! authority.prepare_remote([failed, suffix]),
    ),
  )
  assert_eq(page.pull().advance.length(), 2)
}
