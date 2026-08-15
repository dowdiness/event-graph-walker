///| Whitebox tests for OpRun compression/decompression

///|
test "roundtrip: insert op -> OpRun -> Op" {
  let op = Op::insert(
    5,
    [RawVersion("alice", 3)],
    "alice",
    4,
    "x",
    Some(RawVersion("alice", 3)),
    Some(RawVersion("bob", 0)),
  )
  let run = OpRun::from_op(op)
  inspect(run.count, content="1")
  inspect(run.start_lv, content="5")
  inspect(run.agent, content="alice")
  inspect(run.start_seq, content="4")
  let decompressed = run.decompress(0)
  guard decompressed is Some(d) else { fail("expected Some") }
  inspect(d.lv(), content="5")
  inspect(d.agent(), content="alice")
  inspect(d.seq(), content="4")
  inspect(d.content(), content="Insert(\"x\")")
  @debug.debug_inspect(
    d.origin_left(),
    content=(
      #|Some({ agent: "alice", seq: 3 })
    ),
  )
  @debug.debug_inspect(
    d.origin_right(),
    content=(
      #|Some({ agent: "bob", seq: 0 })
    ),
  )
  @debug.debug_inspect(
    d.parents(),
    content=(
      #|[{ agent: "alice", seq: 3 }]
    ),
  )
}

///|
test "roundtrip: empty insert op -> OpRun -> Op" {
  let op = Op::insert(0, [], "legacy", 0, "", None, None)
  let run = OpRun::from_op(op)
  let decompressed = run.decompress(0)
  guard decompressed is Some(d) else { fail("expected Some") }
  inspect(d.content(), content="Insert(\"\")")
}

///|
test "multi-character singleton insert roundtrips without truncation" {
  let op = Op::insert(0, [], "multi", 0, "ab", None, None)
  let run = OpRun::from_op(op)
  let decompressed = run.decompress(0)
  guard decompressed is Some(d) else { fail("expected Some") }
  inspect(d.content(), content="Insert(\"ab\")")
}

///|
test "empty insert runs do not merge with non-empty insert runs" {
  let empty = OpRun::from_op(Op::insert(0, [], "legacy", 0, "", None, None))
  let next = OpRun::from_op(
    Op::insert(
      1,
      [RawVersion("legacy", 0)],
      "legacy",
      1,
      "x",
      Some(RawVersion("legacy", 0)),
      None,
    ),
  )
  inspect(@rle.Mergeable::can_merge(empty, next), content="false")
  inspect(@rle.Mergeable::can_merge(next, empty), content="false")
}

///|
test "delete runs do not merge when origin_right differs" {
  let left = RawVersion("left", 0)
  let first = OpRun::from_op(
    Op(
      lv=0,
      parents=[],
      agent="delete",
      seq=0,
      content=Delete,
      origin_left=Some(left),
      origin_right=Some(RawVersion("right-a", 0)),
    ),
  )
  let second = OpRun::from_op(
    Op(
      lv=1,
      parents=[RawVersion("delete", 0)],
      agent="delete",
      seq=1,
      content=Delete,
      origin_left=Some(RawVersion("delete-target", 1)),
      origin_right=Some(RawVersion("right-b", 0)),
    ),
  )
  inspect(@rle.Mergeable::can_merge(first, second), content="false")
}

///|
test "roundtrip: delete op -> OpRun -> Op" {
  let op = Op::delete(
    10,
    [RawVersion("bob", 5)],
    "bob",
    6,
    Some(RawVersion("alice", 2)),
  )
  let run = OpRun::from_op(op)
  let decompressed = run.decompress(0)
  guard decompressed is Some(d) else { fail("expected Some") }
  inspect(d.lv(), content="10")
  inspect(d.agent(), content="bob")
  inspect(d.seq(), content="6")
  inspect(d.content(), content="Delete")
  @debug.debug_inspect(
    d.origin_left(),
    content=(
      #|Some({ agent: "alice", seq: 2 })
    ),
  )
  inspect(d.origin_right() is None, content="true")
}

///|
test "roundtrip: undelete op -> OpRun -> Op" {
  let op = Op::undelete(
    20,
    [RawVersion("carol", 10)],
    "carol",
    11,
    Some(RawVersion("alice", 5)),
  )
  let run = OpRun::from_op(op)
  let decompressed = run.decompress(0)
  guard decompressed is Some(d) else { fail("expected Some") }
  inspect(d.lv(), content="20")
  inspect(d.content(), content="Undelete")
  @debug.debug_inspect(
    d.origin_left(),
    content=(
      #|Some({ agent: "alice", seq: 5 })
    ),
  )
}

///|
test "decompress: offset out of bounds returns None" {
  let op = Op::insert(0, [], "a", 0, "x", None, None)
  let run = OpRun::from_op(op)
  inspect(run.decompress(-1) is None, content="true")
  inspect(run.decompress(1) is None, content="true")
}

///|
test "can_merge: linear insert typing run merges" {
  let run_a = OpRun::from_op(
    Op::insert(0, [], "alice", 0, "a", None, Some(RawVersion("bob", 0))),
  )
  let run_b = OpRun::from_op(
    Op::insert(
      1,
      [RawVersion("alice", 0)],
      "alice",
      1,
      "b",
      Some(RawVersion("alice", 0)),
      Some(RawVersion("bob", 0)),
    ),
  )
  inspect(@rle.Mergeable::can_merge(run_a, run_b), content="true")
  let merged = @rle.Mergeable::merge(run_a, run_b)
  inspect(merged.count, content="2")
  inspect(merged.start_lv, content="0")
  match merged.content {
    Inserts(chars) => {
      let text = String::from_array(chars)
      inspect(text, content="ab")
    }
    _ => fail("expected Inserts")
  }
}

///|
test "can_merge: different agents do not merge" {
  let run_a = OpRun::from_op(Op::insert(0, [], "alice", 0, "a", None, None))
  let run_b = OpRun::from_op(
    Op::insert(
      1,
      [RawVersion("alice", 0)],
      "bob",
      0,
      "b",
      Some(RawVersion("alice", 0)),
      None,
    ),
  )
  inspect(@rle.Mergeable::can_merge(run_a, run_b), content="false")
}

///|
test "can_merge: non-sequential seq does not merge" {
  let run_a = OpRun::from_op(Op::insert(0, [], "alice", 0, "a", None, None))
  let run_b = OpRun::from_op(
    Op::insert(
      1,
      [RawVersion("alice", 0)],
      "alice",
      2,
      "b",
      Some(RawVersion("alice", 0)),
      None,
    ),
  )
  inspect(@rle.Mergeable::can_merge(run_a, run_b), content="false")
}

///|
test "can_merge: different content types do not merge" {
  let run_a = OpRun::from_op(Op::insert(0, [], "alice", 0, "a", None, None))
  let run_b = OpRun::from_op(
    Op::delete(
      1,
      [RawVersion("alice", 0)],
      "alice",
      1,
      Some(RawVersion("bob", 0)),
    ),
  )
  inspect(@rle.Mergeable::can_merge(run_a, run_b), content="false")
}

///|
test "can_merge: insert with different origin_right does not merge" {
  let run_a = OpRun::from_op(
    Op::insert(0, [], "alice", 0, "a", None, Some(RawVersion("bob", 0))),
  )
  let run_b = OpRun::from_op(
    Op::insert(
      1,
      [RawVersion("alice", 0)],
      "alice",
      1,
      "b",
      Some(RawVersion("alice", 0)),
      Some(RawVersion("carol", 0)),
    ),
  )
  inspect(@rle.Mergeable::can_merge(run_a, run_b), content="false")
}

///|
test "can_merge: multiple parents does not merge" {
  let run_a = OpRun::from_op(Op::insert(0, [], "alice", 0, "a", None, None))
  let run_b = OpRun::from_op(
    Op::insert(
      1,
      [RawVersion("alice", 0), RawVersion("bob", 0)],
      "alice",
      1,
      "b",
      Some(RawVersion("alice", 0)),
      None,
    ),
  )
  inspect(@rle.Mergeable::can_merge(run_a, run_b), content="false")
}

///|
test "can_merge: consecutive deletes with sequential origin_left merge" {
  // Deletes of consecutive items (origin_left chains sequentially)
  let run_a = OpRun::from_op(
    Op::delete(0, [], "alice", 0, Some(RawVersion("bob", 0))),
  )
  // origin_left must be RawVersion("alice", 0) — the previous op in the run
  let run_b = OpRun::from_op(
    Op::delete(
      1,
      [RawVersion("alice", 0)],
      "alice",
      1,
      Some(RawVersion("alice", 0)),
    ),
  )
  inspect(@rle.Mergeable::can_merge(run_a, run_b), content="true")
}

///|
test "can_merge: consecutive deletes with non-sequential origin_left do not merge" {
  // Undo deletes target different items — origin_left doesn't chain
  let run_a = OpRun::from_op(
    Op::delete(0, [], "alice", 0, Some(RawVersion("bob", 0))),
  )
  let run_b = OpRun::from_op(
    Op::delete(
      1,
      [RawVersion("alice", 0)],
      "alice",
      1,
      Some(RawVersion("bob", 1)),
    ),
  )
  inspect(@rle.Mergeable::can_merge(run_a, run_b), content="false")
}

///|
test "decompress: multi-op insert run at various offsets" {
  let run : OpRun = {
    start_lv: 10,
    agent: "alice",
    start_seq: 5,
    content: Inserts(['a', 'b', 'c']),
    parents: [RawVersion("bob", 3)],
    origin_left: Some(RawVersion("bob", 3)),
    origin_right: Some(RawVersion("carol", 0)),
    count: 3,
  }
  let d0 = run.decompress(0)
  guard d0 is Some(op0) else { fail("expected Some") }
  inspect(op0.lv(), content="10")
  inspect(op0.seq(), content="5")
  @debug.debug_inspect(
    op0.parents(),
    content=(
      #|[{ agent: "bob", seq: 3 }]
    ),
  )
  @debug.debug_inspect(
    op0.origin_left(),
    content=(
      #|Some({ agent: "bob", seq: 3 })
    ),
  )
  @debug.debug_inspect(
    op0.origin_right(),
    content=(
      #|Some({ agent: "carol", seq: 0 })
    ),
  )
  inspect(op0.content(), content="Insert(\"a\")")
  let d1 = run.decompress(1)
  guard d1 is Some(op1) else { fail("expected Some") }
  inspect(op1.lv(), content="11")
  inspect(op1.seq(), content="6")
  @debug.debug_inspect(
    op1.parents(),
    content=(
      #|[{ agent: "alice", seq: 5 }]
    ),
  )
  @debug.debug_inspect(
    op1.origin_left(),
    content=(
      #|Some({ agent: "alice", seq: 5 })
    ),
  )
  @debug.debug_inspect(
    op1.origin_right(),
    content=(
      #|Some({ agent: "carol", seq: 0 })
    ),
  )
  inspect(op1.content(), content="Insert(\"b\")")
  let d2 = run.decompress(2)
  guard d2 is Some(op2) else { fail("expected Some") }
  inspect(op2.lv(), content="12")
  inspect(op2.seq(), content="7")
  @debug.debug_inspect(
    op2.parents(),
    content=(
      #|[{ agent: "alice", seq: 6 }]
    ),
  )
  @debug.debug_inspect(
    op2.origin_left(),
    content=(
      #|Some({ agent: "alice", seq: 6 })
    ),
  )
  @debug.debug_inspect(
    op2.origin_right(),
    content=(
      #|Some({ agent: "carol", seq: 0 })
    ),
  )
  inspect(op2.content(), content="Insert(\"c\")")
}

///|
test "Rle[OpRun]: append auto-merges linear typing" {
  let rle : @rle.Rle[OpRun] = @rle.Rle::Rle()
  let op0 = Op::insert(0, [], "alice", 0, "h", None, Some(RawVersion("bob", 0)))
  let op1 = Op::insert(
    1,
    [RawVersion("alice", 0)],
    "alice",
    1,
    "i",
    Some(RawVersion("alice", 0)),
    Some(RawVersion("bob", 0)),
  )
  let _ = rle.append(OpRun::from_op(op0))
  let _ = rle.append(OpRun::from_op(op1))
  inspect(rle.length(), content="1")
  inspect(rle.span(), content="2")
}

///|
test "Rle[OpRun]: non-mergeable ops stay separate" {
  let rle : @rle.Rle[OpRun] = @rle.Rle::Rle()
  let op0 = Op::insert(0, [], "alice", 0, "a", None, None)
  let op1 = Op::insert(1, [], "bob", 0, "b", None, None)
  let _ = rle.append(OpRun::from_op(op0))
  let _ = rle.append(OpRun::from_op(op1))
  inspect(rle.length(), content="2")
  inspect(rle.span(), content="2")
}
