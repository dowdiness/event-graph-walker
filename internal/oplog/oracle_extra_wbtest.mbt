///| Additional exact run ownership gates for the fresh-history constructor.

///|
test "closed history retained runs survive same actor append at packing boundaries" {
  for count in [1, 255, 256, 257, 513] {
    let operations = closed_log_chain(count)
    let (actual, _) = ClosedHistory::prepare_experimental(operations).consume_experimental(
      "seed",
    )
    let reference = OpLog("seed")
    ignore(reference.commit_admission(reference.prepare_remote(operations)))
    let retained = actual.get_all_runs()
    let retained_value = @debug.to_string(retained)
    let version = actual.graph.current_graph_version()
    let ranges = version.ranges()
    let frontier = version.frontier()
    let appended = actual.insert("🧭", count - 1, -1)
    let expected = reference.insert("🧭", count - 1, -1)
    assert_eq(appended.seq(), count)
    assert_eq(appended.seq(), expected.seq())
    closed_log_compare(actual, reference)
    // A same-actor, parent/left-chained append can merge into a partial tail.
    // The previously returned OpRun and its owned character array stay frozen.
    assert_eq(@debug.to_string(retained), retained_value)
    assert_eq(version.ranges(), ranges)
    assert_eq(version.frontier(), frontier)
    if count == 255 {
      assert_eq(actual.get_all_runs().length(), retained.length())
      assert_eq(actual.get_all_runs()[0].count, 256)
    } else if count == 256 {
      assert_eq(actual.get_all_runs().length(), retained.length() + 1)
    }
    ignore(actual.insert("X", count, -1))
    ignore(reference.insert("X", count, -1))
    closed_log_compare(actual, reference)
    assert_eq(@debug.to_string(retained), retained_value)
  }
}

///|
test "closed history mixed kind and sparse sequence packing matches replay" {
  let operations = closed_log_chain(257)
  let end = @core.RawVersion("seed", 256)
  let peer = @core.RawVersion("peer", 9)
  let deletion = @core.RawVersion("eraser", 4)
  let undeletion = @core.RawVersion("eraser", 1)
  operations.push(
    @core.Op::insert(
      -100,
      [end],
      "peer",
      9,
      "漢",
      Some(@core.RawVersion("seed", 1)),
      Some(@core.RawVersion("seed", 2)),
    ),
  )
  operations.push(
    @core.Op::delete(
      -100,
      [peer],
      "eraser",
      4,
      Some(@core.RawVersion("seed", 3)),
    ),
  )
  operations.push(
    @core.Op::undelete(
      -100,
      [deletion],
      "eraser",
      1,
      Some(@core.RawVersion("seed", 3)),
    ),
  )
  operations.push(
    @core.Op::insert(
      -100,
      [undeletion, peer],
      "seed",
      600,
      "🧭",
      Some(@core.RawVersion("seed", 0)),
      Some(peer),
    ),
  )
  let (actual, projection) = ClosedHistory::prepare_experimental(operations).consume_experimental(
    "eraser",
  )
  let reference = OpLog("eraser")
  ignore(reference.commit_admission(reference.prepare_remote(operations)))
  closed_log_compare(actual, reference)
  for lv = 0; lv < operations.length(); lv = lv + 1 {
    assert_true(
      planner_lifecycle_same_ops([actual.get_op(lv).unwrap()], [
        reference.get_op(lv).unwrap(),
      ]),
    )
  }
  projection.clear()
  let appended = actual.insert("!", operations.length() - 1, -1)
  let expected = reference.insert("!", operations.length() - 1, -1)
  // Maximum sequence is four from the Delete, not one from the later Undelete.
  assert_eq(appended.seq(), 5)
  assert_eq(appended.seq(), expected.seq())
  ignore(actual.delete(0))
  ignore(reference.delete(0))
  ignore(actual.undelete(0))
  ignore(reference.undelete(0))
  closed_log_compare(actual, reference)
}

///|
test "closed proof invalid writer is pre-adoption and successful adoption is one shot" {
  let proof = ClosedHistory::prepare_experimental(closed_log_chain(4))
  let version = proof.version_experimental()
  let heads = proof.heads_experimental()
  assert_true(
    try proof.consume_experimental("") catch {
      OpLogError::InvalidAdmission => true
      _ => false
    } noraise {
      _ => false
    },
  )
  assert_true(!proof.consumed)
  assert_eq(proof.version_experimental(), version)
  assert_eq(proof.heads_experimental(), heads)
  let (log, _) = proof.consume_experimental("fresh")
  assert_true(proof.consumed)
  assert_eq(log.graph.current_graph_version(), version)
  assert_true(
    try proof.heads_experimental() catch {
      OpLogError::ConsumedAdmission => true
      _ => false
    } noraise {
      _ => false
    },
  )
  assert_true(
    try proof.consume_experimental("fresh-again") catch {
      OpLogError::ConsumedAdmission => true
      _ => false
    } noraise {
      _ => false
    },
  )
}
