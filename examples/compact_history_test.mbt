///|
test "experimental compact restore example supports offline peer and fresh undo" {
  let original = @text.TextState::new("original-writer")
  original.insert(@text.Pos::at(0), "こんにちは 😀")
  let archive = original.export_compact_experimental()
  let expected = original.version().to_json_string()
  let restored = @text.TextState::restore_compact_direct_experimental(
    archive, "restored-writer", expected,
  )
  assert_eq(restored.version(), original.version())
  assert_eq(
    restored.sync().export_all().to_json_string(),
    original.sync().export_all().to_json_string(),
  )
  let base = original.version()
  let undo = @undo.UndoManager::new("restored-writer")
  assert_true(!undo.can_undo())
  restored.insert_and_record(@text.Pos::at(0), "追記\n", undo, timestamp_ms=1)
  original.insert(@text.Pos::at(original.len()), " old peer")
  let outgoing = restored.sync().export_since(base)
  let incoming = original.sync().export_since(base)
  ignore(restored.sync().apply(incoming))
  ignore(original.sync().apply(outgoing))
  assert_eq(restored.text(), original.text())
  assert_true(undo.undo(restored))
  ignore(
    original.sync().apply(restored.sync().export_since(original.version())),
  )
  assert_eq(restored.text(), original.text())
  assert_eq(restored.version(), original.version())
}
