///| Blackbox tests for OpLog error paths

///|
test "validate_remote_batch raises DuplicateOperation for same agent:seq" {
  let oplog = OpLog::new("local")
  let op1 = @core.Op::new_insert(-1, [], "remote", 0, "a", None, None)
  // op2 reuses ("remote", 0) — same identity as op1
  let op2 = @core.Op::new_insert(-1, [], "remote", 0, "b", None, None)
  let result : Result[Unit, OpLogError] = try? oplog.validate_remote_batch(
    [op1, op2],
    [],
  )
  inspect(result is Err(_), content="true")
  match result {
    Err(DuplicateOperation(raw~)) => {
      inspect(raw.agent, content="remote")
      inspect(raw.seq, content="0")
    }
    _ => fail("expected DuplicateOperation")
  }
}

///|
test "validate_remote_batch raises MissingRemoteParent for unknown parent" {
  let oplog = OpLog::new("local")
  let ghost_parent = @core.RawVersion::new("ghost", 0)
  let op = @core.Op::new_insert(-1, [ghost_parent], "remote", 0, "a", None, None)
  let result : Result[Unit, OpLogError] = try? oplog.validate_remote_batch(
    [op],
    [],
  )
  inspect(result is Err(_), content="true")
  match result {
    Err(MissingRemoteParent(raw~)) => {
      inspect(raw.agent, content="ghost")
      inspect(raw.seq, content="0")
    }
    _ => fail("expected MissingRemoteParent")
  }
}

///|
test "validate_remote_batch accepts parent present in the batch" {
  let oplog = OpLog::new("local")
  // op1 has no parents; op2 declares op1 as its parent — both in the same batch
  let op1 = @core.Op::new_insert(-1, [], "remote", 0, "a", None, None)
  let op1_raw = @core.RawVersion::new("remote", 0)
  let op2 = @core.Op::new_insert(-1, [op1_raw], "remote", 1, "b", None, None)
  let result : Result[Unit, OpLogError] = try? oplog.validate_remote_batch(
    [op1, op2],
    [],
  )
  inspect(result is Ok(_), content="true")
}

///|
test "validate_remote_batch raises MissingRemoteFrontier for unknown frontier entry" {
  let oplog = OpLog::new("local")
  let op = @core.Op::new_insert(-1, [], "remote", 0, "a", None, None)
  // frontier claims ("ghost", 99) but that op is neither local nor in the batch
  let ghost = @core.RawVersion::new("ghost", 99)
  let result : Result[Unit, OpLogError] = try? oplog.validate_remote_batch(
    [op],
    [ghost],
  )
  inspect(result is Err(_), content="true")
  match result {
    Err(MissingRemoteFrontier(raw~)) => {
      inspect(raw.agent, content="ghost")
      inspect(raw.seq, content="99")
    }
    _ => fail("expected MissingRemoteFrontier")
  }
}

///|
test "validate_remote_batch accepts frontier op present in the batch" {
  let oplog = OpLog::new("local")
  let op = @core.Op::new_insert(-1, [], "remote", 0, "a", None, None)
  // frontier entry ("remote", 0) matches op in the batch — should be ok
  let op_raw = @core.RawVersion::new("remote", 0)
  let result : Result[Unit, OpLogError] = try? oplog.validate_remote_batch(
    [op],
    [op_raw],
  )
  inspect(result is Ok(_), content="true")
}

///|
test "validate_remote_batch accepts frontier op already present in oplog" {
  let oplog = OpLog::new("local")
  // Apply an op locally first so it exists in the graph
  let local_op = @core.Op::new_insert(-1, [], "alice", 0, "x", None, None)
  let _ = try! oplog.apply_remote(local_op)
  let alice_raw = @core.RawVersion::new("alice", 0)
  // A new batch from "remote" with alice's already-applied op in the frontier
  let new_op = @core.Op::new_insert(-1, [], "remote", 0, "y", None, None)
  let result : Result[Unit, OpLogError] = try? oplog.validate_remote_batch(
    [new_op],
    [alice_raw],
  )
  inspect(result is Ok(_), content="true")
}

///|
test "apply_remote raises MissingOrigin for delete with no origin_left" {
  let oplog = OpLog::new("local")
  // A delete with origin_left=None is malformed (protocol error)
  let bad_delete = @core.Op::new_delete(-1, [], "remote", 0, None)
  let result : Result[Array[@core.Op], OpLogError] = try? oplog.apply_remote(
    bad_delete,
  )
  inspect(result is Err(_), content="true")
  match result {
    Err(MissingOrigin) => ()
    _ => fail("expected MissingOrigin")
  }
}

///|
test "apply_remote is idempotent: already-applied op is silently skipped" {
  let oplog = OpLog::new("local")
  let op = @core.Op::new_insert(-1, [], "remote", 0, "a", None, None)
  let _ = try! oplog.apply_remote(op)
  // Applying the same op again must not raise and must not add a duplicate
  let result : Result[Array[@core.Op], OpLogError] = try? oplog.apply_remote(op)
  inspect(result is Ok(_), content="true")
  inspect(oplog.op_count(), content="1")
}
