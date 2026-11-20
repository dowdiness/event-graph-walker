///|
test "Editor invalidates rather than publishing or reading after partial internal failure" {
  for deferred in [false, true] {
    let editor = Editor::new("writer")
    guard editor.edit(editor.version(), { start: 0, end: 0, text: "ab", })
      is Applied(_) else {
      fail("seed")
    }
    let empty = editor.export_since(editor.version())
    if deferred {
      assert_true(editor.accept_remote(empty).result is Ok(_))
    }
    // Corrupt only the test fixture's local history: reverse replay deletes a
    // real target first, then encounters a missing target. Assert public behavior.
    editor.undo_history.clear()
    editor.undo_history.record_insert(999, "writer", 0)
    editor.undo_history.record_insert(0, "writer", 0)
    let before = editor.version()
    assert_true(editor.undo() is Invalidated(_))
    assert_true(editor.version() != before)
    let snapshot = Ok(editor.snapshot()) catch { error => Err(error) }
    assert_true(snapshot is Err(EditError::Unavailable))
    assert_true(
      editor.edit(editor.version(), { start: 0, end: 0, text: "x", })
      is Invalidated(_),
    )
    assert_true(editor.redo() is Invalidated(_))
    assert_true(editor.receive(empty) is Invalidated(EditError::Unavailable))
    assert_true(!editor.can_undo())
    assert_true(!editor.can_redo())
    // Already-committed operations remain exportable; invalidation is not rollback.
    let receiver = Editor::new("receiver")
    assert_true(
      receiver.receive(editor.export_since(Version::empty())) is Applied(_),
    )
    assert_eq(receiver.snapshot().text, "b")
    assert_true(
      receiver.edit(receiver.version(), { start: 1, end: 1, text: "遠", })
      is Applied(_),
    )
    let admission = editor.accept_remote(
      receiver.export_since(editor.history_version()),
    )
    assert_true(admission.result is Ok(_))
    assert_true(admission.after != admission.before)
    assert_eq(editor.history_version(), admission.after)
    assert_true(
      editor.edit(editor.version(), { start: 0, end: 0, text: "x", })
      is Invalidated(_),
    )
    assert_eq(editor.reopen_view().text, "b遠")
    assert_true(!editor.can_undo())
    assert_true(
      editor.edit(editor.version(), { start: 2, end: 2, text: "L", })
      is Applied(_),
    )
    assert_eq(editor.snapshot().text, "b遠L")
  }
}

///|
test "failed receive does not infer rejection from an unchanged view version" {
  let editor = Editor::new("same-author")
  let imposter = Editor::new("same-author")
  assert_true(
    editor.edit(editor.version(), { start: 0, end: 0, text: "a", })
    is Applied(_),
  )
  assert_true(
    imposter.edit(imposter.version(), { start: 0, end: 0, text: "b", })
    is Applied(_),
  )
  let before = editor.version()
  let message = imposter.export_since(Version::empty())
  let admission = editor.accept_remote(message)
  assert_true(admission.result is Err(_))
  assert_eq(editor.snapshot().text, "a")
  assert_true(editor.can_undo())
  assert_true(editor.receive(message) is Invalidated(_))
  assert_eq(editor.version(), before)
  assert_true(!editor.can_undo())
  assert_true(
    editor.edit(before, { start: 1, end: 1, text: "!", }) is Invalidated(_),
  )
  assert_eq(editor.reopen_view().text, "a")
  assert_true(!editor.can_undo())
}

///|
test "application failures invalidate regardless of error type or origin" {
  for origin in [Local(None), Undo, Redo, Remote] {
    let editor = Editor::new("failure")
    let outcome = editor.change(origin, _ => {
      raise Engine(SyncFailed(@sync.Failure::InvalidContent(detail="injected")))
    })
    assert_true(outcome is Invalidated(_))
    assert_true(editor.undo() is Invalidated(_))
  }
}

///|
test "TextUpdate derivation agrees with replay for descending overlapping and ascending edits" {
  let source = "a🙂b"
  for start in [0, 1, 3, 4] {
    for end in [0, 1, 3, 4] {
      if end < start {
        continue
      }
      for text in ["", "XY", "🚀"] {
        let middle = source[:start].to_owned() + text + source[end:].to_owned()
        let offsets = [0]
        for ch in middle {
          offsets.push(offsets.last().unwrap() + ch.to_string().length())
        }
        for a in offsets {
          for z in offsets {
            if z < a {
              continue
            }
            for inserted in ["", "Q", "漢🙂"] {
              let expected = middle[:a].to_owned() +
                inserted +
                middle[z:].to_owned()
              let update : TextUpdate = {
                before: Version::empty(),
                after: Version::empty(),
                before_len: source.length(),
                origin: Local(None),
                sync_report: None,
                changes: [
                  { start, end, text, },
                  { start: a, end: z, text: inserted, },
                ],
                composed: None,
              }
              let result = StringBuilder()
              let mut position = 0
              for section in update.change_set().sections() {
                match section {
                  Keep(n) => {
                    result.write_string(
                      source[position:position + n].to_owned(),
                    )
                    position += n
                  }
                  Replace(n, text) => {
                    result.write_string(text)
                    position += n
                  }
                }
              }
              assert_eq(position, source.length())
              assert_eq(result.to_string(), expected)
            }
          }
        }
      }
    }
  }
}
