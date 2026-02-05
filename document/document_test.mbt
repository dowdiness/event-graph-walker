///| Regression tests for Document cache invalidation behavior

///|
test "apply_remote invalidates position cache on partial failure" {
  let doc = Document::new("local")

  // Seed local history so we have a known raw version that resolves in the graph
  // but is not a Fugue item ID (delete op lv), which will trigger FugueError.
  let _ = try! doc.insert(0, "x")
  let _ = try! doc.delete(0)

  // Prime cache with an empty snapshot. A stale cache here would break later
  // position-based operations after partial remote application.
  ignore(doc.get_visible_items())
  let parent_raw = @core.RawVersion::new("remote", 0)
  let bad_target = @core.RawVersion::new("local", 1) // seq 1 is the delete op above

  // Buffered first: waits for parent.
  let bad_delete = @core.Op::new_delete(
    -1,
    [parent_raw],
    "remote",
    1,
    Some(bad_target),
  )
  let parent_insert = @core.Op::new_insert(-1, [], "remote", 0, "A", None, None)
  try! doc.apply_remote(bad_delete)

  // Parent insert is applied, then buffered malformed delete raises.
  let result : Result[Unit, DocumentError] = try? doc.apply_remote(
    parent_insert,
  )
  inspect(result is Err(_), content="true")
  inspect(doc.to_text(), content="A")

  // Cache must reflect current tree after the failure path.
  inspect(doc.get_visible_items().length(), content="1")

  // Position-based operation should still work with fresh cache.
  let _ = try! doc.delete(0)
  inspect(doc.to_text(), content="")
}
