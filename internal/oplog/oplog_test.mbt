///| Blackbox tests for OpLog error paths

///|
test "local delete and undelete reject the root sentinel before allocation" {
  let delete_log = OpLog::new("local")
  let delete_result : Result[Unit, OpLogError] = try {
    let _ = delete_log.delete(-1)
    Ok(())
  } catch {
    e => Err(e)
  }
  inspect(delete_result is Err(_), content="true")
  inspect(delete_log.op_count(), content="0")

  let undelete_log = OpLog::new("local")
  let undelete_result : Result[Unit, OpLogError] = try {
    let _ = undelete_log.undelete(-1)
    Ok(())
  } catch {
    e => Err(e)
  }
  inspect(undelete_result is Err(_), content="true")
  inspect(undelete_log.op_count(), content="0")
}

///|
test "remote plan is non-mutating and preserves drain order" {
  let oplog = OpLog::new("local")
  let parent_raw = @core.RawVersion::new("remote", 0)
  let child = @core.Op::new_insert(
    -1,
    [parent_raw],
    "remote",
    1,
    "B",
    Some(parent_raw),
    None,
  )
  let parent = @core.Op::new_insert(-1, [], "remote", 0, "A", None, None)
  let planned = oplog.plan_remote([child, parent])
  inspect(planned.length(), content="2")
  inspect(planned[0].seq(), content="0")
  inspect(planned[1].seq(), content="1")
  inspect(oplog.op_count(), content="0")
  inspect(oplog.has_pending(), content="false")

  ignore(try! oplog.apply_remote(child))
  ignore(try! oplog.apply_remote(parent))
  inspect(oplog.op_count(), content="2")
  inspect(oplog.has_pending(), content="false")
}

///|
test "local insert origin preflight leaves causal state unchanged" {
  let oplog = OpLog::new("local")
  let result : Result[Unit, OpLogError] = try {
    ignore(oplog.insert("ghost", 99, -1))
    Ok(())
  } catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
  inspect(oplog.causal_graph().op_count(), content="0")
  inspect(
    oplog.causal_graph().get_frontier().to_array().is_empty(),
    content="true",
  )

  let op = try! oplog.insert("ok", -1, -1)
  inspect(op.lv(), content="0")
  inspect(oplog.op_count(), content="1")

  let right_oplog = OpLog::new("right")
  let right_result : Result[Unit, OpLogError] = try {
    ignore(right_oplog.insert("ghost", -1, 99))
    Ok(())
  } catch {
    e => Err(e)
  }
  inspect(right_result is Err(_), content="true")
  inspect(right_oplog.causal_graph().op_count(), content="0")
  let right_op = try! right_oplog.insert("ok", -1, -1)
  inspect(right_op.lv(), content="0")
}

///|
test "local insert origin preflight preserves existing causal state" {
  let oplog = OpLog::new("local")
  let seed = try! oplog.insert("seed", -1, -1)
  let before_frontier = oplog.causal_graph().get_frontier().to_array()

  let bad_left : Result[Unit, OpLogError] = try {
    ignore(oplog.insert("ghost", 99, -1))
    Ok(())
  } catch {
    e => Err(e)
  }
  inspect(bad_left is Err(_), content="true")
  inspect(oplog.causal_graph().op_count(), content="1")
  inspect(
    oplog.causal_graph().get_frontier().to_array() == before_frontier,
    content="true",
  )

  let bad_right : Result[Unit, OpLogError] = try {
    ignore(oplog.insert("ghost", seed.lv(), 99))
    Ok(())
  } catch {
    e => Err(e)
  }
  inspect(bad_right is Err(_), content="true")
  inspect(oplog.causal_graph().op_count(), content="1")
  inspect(
    oplog.causal_graph().get_frontier().to_array() == before_frontier,
    content="true",
  )

  let next = try! oplog.insert("next", seed.lv(), -1)
  inspect(next.lv(), content="1")
  inspect(oplog.op_count(), content="2")
}

///|
/// OpLog primary seam: identical batch repeats collapse without weakening closure.
test "validate_remote_batch accepts identical repeated identity" {
  let oplog = OpLog::new("local")
  let op = @core.Op::new_insert(-1, [], "remote", 0, "a", None, None)
  let result : Result[Unit, OpLogError] = try {
    oplog.validate_remote_batch([op, op], [@core.RawVersion::new("remote", 0)])
    Ok(())
  } catch {
    e => Err(e)
  }
  inspect(result is Ok(_), content="true")
}

///|
/// OpLog primary seam: a repeated identity with a different payload is typed.
test "validate_remote_batch raises ConflictingIdentity for logical repeat" {
  let oplog = OpLog::new("local")
  let op1 = @core.Op::new_insert(-1, [], "remote", 0, "a", None, None)
  let op2 = @core.Op::new_insert(-1, [], "remote", 0, "b", None, None)
  let result : Result[Unit, OpLogError] = try {
    oplog.validate_remote_batch([op1, op2], [])
    Ok(())
  } catch {
    e => Err(e)
  }
  match result {
    Err(ConflictingIdentity(raw~)) => {
      inspect(raw.agent, content="remote")
      inspect(raw.seq, content="0")
    }
    _ => fail("expected ConflictingIdentity")
  }
}

///|
test "validate_remote_batch raises MissingRemoteParent for unknown parent" {
  let oplog = OpLog::new("local")
  let ghost_parent = @core.RawVersion::new("ghost", 0)
  let op = @core.Op::new_insert(
    -1,
    [ghost_parent],
    "remote",
    0,
    "a",
    None,
    None,
  )
  let result : Result[Unit, OpLogError] = try {
    oplog.validate_remote_batch([op], [])
    Ok(())
  } catch {
    e => Err(e)
  }
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
  let result : Result[Unit, OpLogError] = try {
    oplog.validate_remote_batch([op1, op2], [])
    Ok(())
  } catch {
    e => Err(e)
  }
  inspect(result is Ok(_), content="true")
}

///|
test "validate_remote_batch raises MissingRemoteFrontier for unknown frontier entry" {
  let oplog = OpLog::new("local")
  let op = @core.Op::new_insert(-1, [], "remote", 0, "a", None, None)
  // frontier claims ("ghost", 99) but that op is neither local nor in the batch
  let ghost = @core.RawVersion::new("ghost", 99)
  let result : Result[Unit, OpLogError] = try {
    oplog.validate_remote_batch([op], [ghost])
    Ok(())
  } catch {
    e => Err(e)
  }
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
  let result : Result[Unit, OpLogError] = try {
    oplog.validate_remote_batch([op], [op_raw])
    Ok(())
  } catch {
    e => Err(e)
  }
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
  let result : Result[Unit, OpLogError] = try {
    oplog.validate_remote_batch([new_op], [alice_raw])
    Ok(())
  } catch {
    e => Err(e)
  }
  inspect(result is Ok(_), content="true")
}

///|
test "apply_remote raises MissingOrigin for delete with no origin_left" {
  let oplog = OpLog::new("local")
  // A delete with origin_left=None is malformed (protocol error)
  let bad_delete = @core.Op::new_delete(-1, [], "remote", 0, None)
  let result : Result[Array[@core.Op], OpLogError] = try {
    let v = oplog.apply_remote(bad_delete)
    Ok(v)
  } catch {
    e => Err(e)
  }
  inspect(result is Err(_), content="true")
  match result {
    Err(MissingOrigin) => ()
    _ => fail("expected MissingOrigin")
  }
  let valid = @core.Op::new_insert(-1, [], "remote", 0, "ok", None, None)
  let applied = try! oplog.apply_remote(valid)
  inspect(applied.length(), content="1")
  inspect(oplog.op_count(), content="1")
}

///|
test "apply_remote is idempotent: already-applied op is silently skipped" {
  let oplog = OpLog::new("local")
  let op = @core.Op::new_insert(-1, [], "remote", 0, "a", None, None)
  let _ = try! oplog.apply_remote(op)
  // Applying the same op again must not raise and must not add a duplicate
  let result : Result[Array[@core.Op], OpLogError] = try {
    let v = oplog.apply_remote(op)
    Ok(v)
  } catch {
    e => Err(e)
  }
  inspect(result is Ok(_), content="true")
  inspect(oplog.op_count(), content="1")
}

///|
/// OpLog primary seam: admitted payload conflicts fail before planner/graph mutation.
test "apply_remote raises admitted ConflictingIdentity atomically" {
  let oplog = OpLog::new("local")
  let admitted = @core.Op::new_insert(
    -1,
    [],
    "admitted-conflict",
    0,
    "a",
    None,
    None,
  )
  ignore(try! oplog.apply_remote(admitted))
  let conflict = @core.Op::new_insert(
    99,
    [],
    "admitted-conflict",
    0,
    "b",
    None,
    None,
  )
  let before_frontier = oplog.get_frontier_raw()
  let before_ops = oplog.get_all_ops()
  let result : Result[Array[@core.Op], OpLogError] = Ok(
    oplog.apply_remote(conflict),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(ConflictingIdentity(raw~)) =>
      assert_eq(raw, @core.RawVersion::new("admitted-conflict", 0))
    _ => fail("expected admitted identity conflict")
  }
  assert_eq(oplog.op_count(), 1)
  assert_eq(oplog.get_frontier_raw(), before_frontier)
  let after_ops = oplog.get_all_ops()
  assert_eq(after_ops.length(), before_ops.length())
  assert_eq(after_ops[0].content(), before_ops[0].content())
  assert_eq(oplog.has_pending(), false)

  let logical_duplicate = @core.Op::new_insert(
    101,
    [],
    "admitted-conflict",
    0,
    "a",
    None,
    None,
  )
  let duplicate_result = oplog.apply_remote(logical_duplicate)
  assert_eq(duplicate_result.length(), 0)
  assert_eq(oplog.op_count(), 1)
}

///|
/// OpLog primary seam: a conflict after a ready candidate admits no prefix.
test "prepare_remote rejects conflict before ready prefix admission" {
  let oplog = OpLog::new("ready-prefix")
  let ready = @core.Op::new_insert(
    -1,
    [],
    "ready-prefix-op",
    0,
    "a",
    None,
    None,
  )
  let conflict = @core.Op::new_insert(
    5,
    [],
    "ready-prefix-op",
    0,
    "b",
    None,
    None,
  )
  let result : Result[RemoteAdmissionPlan, OpLogError] = Ok(
    oplog.prepare_remote([ready, conflict]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(ConflictingIdentity(raw~)) =>
      assert_eq(raw, @core.RawVersion::new("ready-prefix-op", 0))
    _ => fail("expected ready-prefix identity conflict")
  }
  assert_eq(oplog.op_count(), 0)
  assert_eq(oplog.has_pending(), false)
  assert_eq(oplog.get_frontier_raw().length(), 0)

  let admitted = try! oplog.apply_remote(ready)
  assert_eq(admitted.length(), 1)
  assert_eq(oplog.op_count(), 1)
}
