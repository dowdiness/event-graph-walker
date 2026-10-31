///|
test "Editor invalidates rather than publishing or reading after partial internal failure" {
  let editor = Editor::new("writer")
  guard editor.edit(editor.version(), { start: 0, end: 0, text: "ab", })
    is Applied(_) else {
    fail("seed")
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
  assert_true(!editor.can_undo())
  assert_true(!editor.can_redo())
  // Already-committed operations remain exportable; invalidation is not rollback.
  let receiver = Editor::new("receiver")
  assert_true(
    receiver.receive(editor.export_since(Version::empty())) is Applied(_),
  )
  assert_eq(receiver.snapshot().text, "b")
}

///|
test "SyncFailed is rejectable only during remote admission" {
  for origin in [Local(None), Undo, Redo, Remote] {
    let editor = Editor::new("failure")
    let outcome = editor.change(origin, _ => {
      raise Engine(SyncFailed(@sync.Failure::InvalidContent(detail="injected")))
    })
    if origin is Remote {
      assert_true(outcome is Rejected(_))
      assert_eq(editor.snapshot().text, "")
    } else {
      assert_true(outcome is Invalidated(_))
      assert_true(editor.undo() is Invalidated(_))
    }
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
