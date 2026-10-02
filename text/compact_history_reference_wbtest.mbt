///|
/// Test-only ordinary admission oracle. Never a second public archive API.
fn compact_restore_replay_for_test(
  archive : String,
  writer : String,
  expected_json : String,
) -> TextState raise {
  let (message, expected) = compact_decode(
    archive,
    expected_json,
    writer,
    chain=true,
  )
  let doc = TextState::new(writer)
  let report = doc.sync().apply(message)
  guard report.pending_operations() == 0 &&
    doc.version() == expected &&
    sorted_raw(current_heads(doc)) == message.heads else {
    fail("incomplete reference archive")
  }
  ignore(doc.text())
  doc
}

///|
fn compact_check_ops(
  operations : Array[@core.Op],
  expected_text : String?,
) -> Unit raise {
  let parent_ids : Map[@core.RawVersion, Bool] = Map([])
  for op in operations {
    for parent in op.parents_iter() {
      parent_ids[parent] = true
    }
  }
  let heads : Array[@core.RawVersion] = []
  for op in operations {
    if !parent_ids.contains(op_identity(op)) {
      heads.push(op_identity(op))
    }
  }
  let source = TextState::new("source-peer")
  ignore(source.sync().apply(SyncMessage::SyncMessage(operations, heads, None)))
  if expected_text is Some(text) {
    assert_eq(source.text(), text)
  }
  let archive = source.export_compact_experimental()
  let expected = source.version().to_json_string()
  let direct = TextState::restore_compact_direct_experimental(
    archive, "fresh", expected,
  )
  let replay = compact_restore_replay_for_test(archive, "fresh", expected)
  assert_eq(direct.version(), replay.version())
  assert_eq(direct.text(), replay.text())
  assert_eq(
    direct.sync().export_all().to_json_string(),
    replay.sync().export_all().to_json_string(),
  )
  assert_eq(
    direct.sync().export_all().to_json_string(),
    source.sync().export_all().to_json_string(),
  )
  let undo = @undo.UndoManager::new("fresh")
  direct.insert_and_record(Pos::at(0), "🦉", undo, timestamp_ms=1)
  assert_true(undo.undo(direct))
  assert_true(undo.redo(direct))
  ignore(source.sync().apply(direct.sync().export_since(source.version())))
  assert_eq(direct.text(), source.text())
  assert_eq(direct.version(), source.version())
  let saved = direct.version()
  source.insert(Pos::at(source.len()), "old-peer")
  ignore(direct.sync().apply(source.sync().export_since(saved)))
  assert_eq(
    direct.sync().export_all().to_json_string(),
    source.sync().export_all().to_json_string(),
  )
}

///|
test "compact direct preserves separate comparators and origin-only causality" {
  compact_check_ops(
    [
      @core.Op::insert(-1, [], "a", 0, "A", None, None),
      @core.Op::insert(-1, [], "BB", 0, "B", None, None),
    ],
    Some("BA"),
  )
  let a = @core.RawVersion("seed", 0)
  compact_check_ops(
    [
      @core.Op::insert(-1, [], "seed", 0, "A", None, None),
      @core.Op::insert(-1, [], "outside", 0, "X", Some(a), Some(a)),
    ],
    Some("XA"),
  )
  compact_check_ops(
    [
      @core.Op::insert(-1, [], "sparse", 2, "Q", None, None),
      @core.Op::insert(
        -1,
        [@core.RawVersion("sparse", 2)],
        "sparse",
        0,
        "R",
        Some(@core.RawVersion("sparse", 2)),
        None,
      ),
    ],
    Some("QR"),
  )
  compact_check_ops(
    [@core.Op::insert(-1, [], "max", 2147483647, "😀", None, None)],
    Some("😀"),
  )
}

///|
test "compact direct preserves redundant parents reversed origins and LWW" {
  let a = @core.RawVersion("base", 0)
  let b = @core.RawVersion("base", 1)
  let c = @core.RawVersion("base", 2)
  compact_check_ops(
    [
      @core.Op::insert(-1, [], "base", 0, "A", None, None),
      @core.Op::insert(-1, [a], "base", 1, "B", Some(a), None),
      @core.Op::insert(-1, [b], "base", 2, "C", Some(b), None),
      @core.Op::insert(-1, [a, c], "other", 0, "X", Some(c), Some(a)),
    ],
    Some("ABCX"),
  )
  compact_check_ops(
    [
      @core.Op::insert(-1, [], "base", 0, "A", None, None),
      @core.Op::delete(-1, [], "a", 0, Some(a)),
      @core.Op::undelete(-1, [], "BB", 0, Some(a)),
    ],
    Some("A"),
  )
}
