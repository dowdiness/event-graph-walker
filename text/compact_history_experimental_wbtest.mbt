///|
test "compact archive preserves accepted operations and subsequent collaborative undo" {
  let source = TextState::new("source")
  source.insert(Pos::at(0), "😀漢e\u{301}\nMarkdown")
  source.delete(Pos::at(1))
  let expected = source.version().to_json_string()
  let archive = source.export_compact_experimental()
  let restored = TextState::restore_compact_direct_experimental(
    archive, "fresh", expected,
  )
  assert_eq(restored.text(), source.text())
  assert_eq(restored.version(), source.version())
  assert_eq(
    restored.sync().export_all().to_json_string(),
    source.sync().export_all().to_json_string(),
  )
  let undo = @undo.UndoManager::new("fresh")
  restored.insert_and_record(Pos::at(0), "X", undo, timestamp_ms=1)
  assert_true(undo.undo(restored))
  assert_eq(restored.text(), source.text())
  assert_true(undo.redo(restored))
  let delta = restored.sync().export_since(source.version())
  ignore(source.sync().apply(delta))
  assert_eq(restored.text(), source.text())
  assert_eq(
    restored.sync().export_all().to_json_string(),
    source.sync().export_all().to_json_string(),
  )
}

///|
test "compact strict integer and amplification budgets" {
  assert_true(
    try compact_integer(Json::number(0.5)) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try compact_integer(Json::number(2147483648.0)) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try
      compact_mul_budget(1000000, 100000, compact_max_expanded_identity_bytes)
    catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try compact_add_budget(compact_max_ops, 1, compact_max_ops) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_eq(compact_integer(Json::number(2147483647.0)), 2147483647)
}

///|
test "compact writer and external version are required" {
  let source = TextState::new("source")
  source.insert(Pos::at(0), "ab")
  let archive = source.export_compact_experimental()
  let expected = source.version().to_json_string()
  assert_true(
    try
      TextState::restore_compact_direct_experimental(
        archive, "source", expected,
      )
    catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try
      TextState::restore_compact_direct_experimental(
        archive,
        "fresh",
        Version::empty().to_json_string(),
      )
    catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try
      TextState::restore_compact_direct_experimental(
        archive + "x",
        "fresh",
        expected,
      )
    catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}

///|
test "compact single chain proof preserves original message and rejects near chains" {
  let operations : Array[@core.Op] = [
    @core.Op::insert(0, [], "sparse-start", 10, "😀", None, None),
    @core.Op::insert(
      0,
      [@core.RawVersion("sparse-start", 10)],
      "sparse-start",
      11,
      "漢",
      Some(@core.RawVersion("sparse-start", 10)),
      None,
    ),
  ]
  let heads = [@core.RawVersion("sparse-start", 11)]
  assert_true(compact_is_single_chain(operations, heads))
  assert_eq(
    compact_chain_message(operations, heads, 100).to_json_string(),
    SyncMessage::SyncMessage(operations, heads, Some(100)).to_json_string(),
  )
  assert_true(!compact_is_single_chain([operations[1], operations[0]], heads))
  assert_true(!compact_is_single_chain([operations[0], operations[0]], heads))
  assert_true(!compact_is_single_chain(operations, heads + heads))
  let malformed = [
    operations[0],
    @core.Op::insert(
      0,
      [@core.RawVersion("sparse-start", 10)],
      "sparse-start",
      11,
      "bad",
      Some(@core.RawVersion("sparse-start", 10)),
      None,
    ),
  ]
  assert_true(compact_is_single_chain(malformed, heads))
  assert_true(
    try compact_chain_message(malformed, heads, 100) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  let fork = [
    operations[0],
    @core.Op::insert(
      0,
      [@core.RawVersion("sparse-start", 10)],
      "other",
      5,
      "x",
      Some(@core.RawVersion("sparse-start", 10)),
      None,
    ),
  ]
  let fork_heads = [@core.RawVersion("other", 5)]
  assert_true(!compact_is_single_chain(fork, fork_heads))
  assert_eq(
    compact_chain_message(fork, fork_heads, 100).to_json_string(),
    SyncMessage::SyncMessage(fork, fork_heads, Some(100)).to_json_string(),
  )
}
