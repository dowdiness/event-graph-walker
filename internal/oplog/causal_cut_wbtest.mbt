///| Whitebox prototype tests for the internal causal-cut evidence store.

///|
test "prototype: causal cut is immutable and rebuildable" {
  let source = OpLog::new("source")
  ignore(try! source.insert("a", -1, -1))
  ignore(try! source.insert("b", 0, -1))

  let baseline = source.causal_cut()
  let rebuilt = CausalCut::from_operations(source.get_all_ops())
  inspect(baseline.op_count(), content="2")
  inspect(baseline.frontier().length(), content="1")
  inspect(baseline.equal(rebuilt), content="true")

  ignore(try! source.insert("c", 1, -1))
  inspect(baseline.op_count(), content="2")
  inspect(source.causal_cut().op_count(), content="3")
  inspect(
    source.causal_cut().equal(CausalCut::from_operations(source.get_all_ops())),
    content="true",
  )
}

///|
test "prototype: equivalent causal cuts ignore destination-local LVs" {
  let source = OpLog::new("source")
  ignore(try! source.insert("a", -1, -1))
  ignore(try! source.insert("b", 0, -1))

  let replica = OpLog::new("replica")
  for operation in source.get_all_ops() {
    ignore(try! replica.apply_remote(operation))
  }

  inspect(source.causal_cut().equal(replica.causal_cut()), content="true")
  inspect(source.causal_cut().op_count(), content="2")
  inspect(replica.causal_cut().op_count(), content="2")
}

///|
test "prototype: concurrent fresh writers converge on one causal cut" {
  let source = OpLog::new("source")
  ignore(try! source.insert("a", -1, -1))
  ignore(try! source.insert("b", 0, -1))

  let replica = OpLog::new("replica")
  for operation in source.get_all_ops() {
    ignore(try! replica.apply_remote(operation))
  }

  let source_edit = try! source.insert("S", 1, -1)
  let replica_edit = try! replica.insert("R", 1, -1)
  ignore(try! source.apply_remote(replica_edit))
  ignore(try! replica.apply_remote(source_edit))

  inspect(source.causal_cut().equal(replica.causal_cut()), content="true")
  inspect(
    source.causal_cut().equal(CausalCut::from_operations(source.get_all_ops())),
    content="true",
  )
  inspect(
    replica
    .causal_cut()
    .equal(CausalCut::from_operations(replica.get_all_ops())),
    content="true",
  )
  inspect(source.causal_cut().op_count(), content="4")
}

///|
test "prototype: legacy empty inserts remain rebuildable" {
  let log = OpLog::new("legacy-empty")
  ignore(try! log.insert("", -1, -1))
  inspect(log.causal_cut().op_count(), content="1")
  inspect(
    log.causal_cut().equal(CausalCut::from_operations(log.get_all_ops())),
    content="true",
  )
}

///|
test "prototype: pending remote operations enter the cut only after drain" {
  let source = OpLog::new("pending-source")
  let parent = try! source.insert("a", -1, -1)
  let child = try! source.insert("b", parent.lv(), -1)
  let target = OpLog::new("pending-target")

  inspect((try! target.apply_remote(child)).length(), content="0")
  inspect(target.causal_cut().op_count(), content="0")
  inspect((try! target.apply_remote(parent)).length(), content="2")
  inspect(target.causal_cut().op_count(), content="2")
  inspect(
    target.causal_cut().equal(CausalCut::from_operations(target.get_all_ops())),
    content="true",
  )
}

///|
test "prototype: partial remote admission leaves an exact cut prefix" {
  let log = OpLog::new("partial-cut")
  let first = @core.Op::new_insert(-1, [], "partial-first", 0, "a", None, None)
  let failed = @core.Op::new_insert(
    -1,
    [],
    "partial-failed",
    0,
    "b",
    None,
    None,
  )
  let suffix = @core.Op::new_insert(
    -1,
    [],
    "partial-suffix",
    0,
    "c",
    None,
    None,
  )
  let plan = try! log.prepare_remote([first, failed, suffix])
  let failed_raw = remote_admission_raw(failed)
  let result : Result[Array[@core.Op], OpLogError] = Ok(
    log.commit_remote_with(plan, op => {
      if remote_admission_raw(op) == failed_raw {
        raise OpLogError::CausalGraphError(
          error=@causal_graph.CausalGraphError::MissingParent(lv=-99),
        )
      }
      log.commit_one_remote(op)
    }),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(OpLogError::PartialRemoteAdmission(committed~, error~)) => {
      ignore(error)
      inspect(committed.length(), content="1")
      inspect(log.causal_cut().op_count(), content="1")
      inspect(
        log.causal_cut().equal(CausalCut::from_operations(log.get_all_ops())),
        content="true",
      )
    }
    _ => fail("expected partial remote admission")
  }
  ignore(try! log.commit_remote(try! log.prepare_remote([failed, suffix])))
  inspect(log.causal_cut().op_count(), content="3")
  inspect(
    log.causal_cut().equal(CausalCut::from_operations(log.get_all_ops())),
    content="true",
  )
}
