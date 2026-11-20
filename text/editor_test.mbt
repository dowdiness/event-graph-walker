///|
fn apply_editor_update(
  before : String,
  outcome : @text.Edit,
) -> (String, @text.TextUpdate) raise {
  guard outcome is Applied(update) else { fail("expected applied update") }
  let mut text = before
  for edit in update.edits() {
    text = text[:edit.start].to_owned() + edit.text + text[edit.end:].to_owned()
  }
  assert_eq(update.before_len, before.length())
  assert_eq(update.sync_report is Some(_), update.origin is Remote)
  assert_eq(apply_change_set(before, update.change_set()), text)
  assert_eq(apply_change_set(before, update.change_set()), text)
  (text, update)
}

///|
test "Editor owns Unicode coordinates and publishes edits for local undo and remote changes" {
  let alice = @text.Editor::new("alice")
  let bob = @text.Editor::new("bob")
  let seed = "# 日🙂本 é 👩‍💻\n"
  let (text, initial) = apply_editor_update(
    "",
    alice.edit(alice.version(), { start: 0, end: 0, text: seed, }),
  )
  assert_eq(text, seed)
  assert_eq(initial.edits().length(), 1)
  let (_, received) = apply_editor_update(
    "",
    bob.receive(alice.export_since(@text.Version::empty())),
  )
  assert_eq(received.edits().length(), 1)
  let shared = alice.version()
  let (local_text, _) = apply_editor_update(
    seed,
    alice.edit(shared, { start: 5, end: 5, text: "私", }),
  )
  assert_eq(local_text, "# 日🙂私本 é 👩‍💻\n")
  let (remote, _) = apply_editor_update(
    seed,
    bob.edit(shared, { start: 0, end: 0, text: "遠", }),
  )
  let a_delta = alice.export_since(shared)
  let b_delta = bob.export_since(shared)
  let (merged_a, _) = apply_editor_update(local_text, alice.receive(b_delta))
  let (merged_b, _) = apply_editor_update(remote, bob.receive(a_delta))
  assert_eq(merged_a, "遠# 日🙂私本 é 👩‍💻\n")
  assert_eq(merged_a, merged_b)
  let (undone, _) = apply_editor_update(merged_a, alice.undo())
  assert_eq(undone, "遠# 日🙂本 é 👩‍💻\n")
  let (redone, _) = apply_editor_update(undone, alice.redo())
  assert_eq(redone, merged_a)
  assert_eq(alice.snapshot().text, redone)
  assert_eq(bob.snapshot().text, merged_b)
}

///|
test "Editor rejects invalid and stale UTF16 ranges without changing text version or undo" {
  let editor = @text.Editor::new("writer")
  ignore(
    apply_editor_update(
      "",
      editor.edit(editor.version(), { start: 0, end: 0, text: "a🙂b", }),
    ),
  )
  let version = editor.version()
  for (start, end, offset) in [(2, 2, 2), (-1, 0, -1), (0, 5, 5)] {
    for text in ["", "X"] {
      assert_true(
        editor.edit(version, { start, end, text, })
        is Rejected(
          @text.EditError::InvalidChange(
            @text.ChangeError::InvalidBoundary(offset=actual),
          ),
        ) &&
        actual == offset,
      )
    }
  }
  assert_true(
    editor.edit(version, { start: 3, end: 1, text: "X", })
    is Rejected(@text.EditError::ReversedRange),
  )
  for bytes in [b"\x00\xD8", b"\x00\xDC"] {
    assert_true(
      editor.edit(version, {
        start: 0,
        end: 0,
        text: bytes.to_unchecked_string(),
      })
      is Rejected(@text.EditError::InvalidText),
    )
  }
  assert_true(
    editor.edit(@text.Version::empty(), { start: 0, end: 0, text: "X", })
    is Rejected(@text.EditError::StaleVersion),
  )
  assert_eq(editor.version(), version)
  assert_eq(editor.snapshot().text, "a🙂b")
  assert_true(editor.can_undo())
  assert_true(!editor.can_redo())
  let (text, _) = apply_editor_update("a🙂b", editor.undo())
  assert_eq(text, "")
  assert_true(!editor.can_undo())
  assert_true(editor.can_redo())
}

///|
test "Editor batches a large paste and reverse-order undo into range edits" {
  let editor = @text.Editor::new("writer")
  let builder = StringBuilder()
  for _ in 0..<1000 {
    builder.write_string("漢🙂")
  }
  let content = builder.to_string()
  let (pasted, update) = apply_editor_update(
    "",
    editor.edit(editor.version(), { start: 0, end: 0, text: content, }),
  )
  assert_eq(update.edits().length(), 1)
  assert_eq(pasted, content)
  let (empty, undo) = apply_editor_update(content, editor.undo())
  assert_eq(empty, "")
  assert_eq(undo.edits().length(), 1)
  let (again, redo) = apply_editor_update("", editor.redo())
  assert_eq(again, content)
  assert_eq(redo.edits().length(), 1)
}

///|
test "Editor remote batches preserve disjoint deletes and following Unicode insertions" {
  let writer = @text.Editor::new("writer")
  let reader = @text.Editor::new("reader")
  ignore(
    apply_editor_update(
      "",
      writer.edit(writer.version(), {
        start: 0,
        end: 0,
        text: "A🙂BC漢DE🚀F",
      }),
    ),
  )
  let (before, _) = apply_editor_update(
    "",
    reader.receive(writer.export_since(@text.Version::empty())),
  )
  let version = writer.version()
  let (step, _) = apply_editor_update(
    before,
    writer.edit(writer.version(), { start: 3, end: 5, text: "", }),
  )
  let (step, _) = apply_editor_update(
    step,
    writer.edit(writer.version(), { start: 4, end: 6, text: "", }),
  )
  ignore(
    apply_editor_update(
      step,
      writer.edit(writer.version(), { start: 3, end: 3, text: "é🙂", }),
    ),
  )
  let (received, _) = apply_editor_update(
    before,
    reader.receive(writer.export_since(version)),
  )
  assert_eq(received, "A🙂é🙂漢🚀F")
  assert_eq(reader.snapshot().text, received)
  assert_eq(reader.version(), writer.version())
  let version = writer.version()
  ignore(apply_editor_update(received, writer.undo()))
  let (undone, _) = apply_editor_update(
    received,
    reader.receive(writer.export_since(version)),
  )
  assert_eq(undone, "A🙂漢🚀F")
  assert_eq(reader.snapshot().text, undone)
}

///|
test "Editor drains pending changes and treats duplicate delivery as an empty update" {
  let alice = @text.Editor::new("alice")
  let bob = @text.Editor::new("bob")
  ignore(
    apply_editor_update(
      "",
      alice.edit(alice.version(), { start: 0, end: 0, text: "始終", }),
    ),
  )
  ignore(
    apply_editor_update(
      "",
      bob.receive(alice.export_since(@text.Version::empty())),
    ),
  )
  let version = alice.version()
  ignore(
    apply_editor_update(
      "始終",
      alice.edit(version, { start: 1, end: 1, text: "🙂", }),
    ),
  )
  let first = alice.export_since(version)
  let version = alice.version()
  ignore(
    apply_editor_update(
      "始🙂終",
      alice.edit(version, { start: 3, end: 3, text: "後", }),
    ),
  )
  let second = alice.export_since(version)
  let (blocked, pending) = apply_editor_update("始終", bob.receive(second))
  assert_eq(blocked, "始終")
  assert_eq(pending.sync_report.unwrap().applied_operations(), 0)
  assert_eq(pending.sync_report.unwrap().pending_operations(), 1)
  let (drained, received) = apply_editor_update(blocked, bob.receive(first))
  assert_eq(drained, "始🙂後終")
  assert_eq(received.sync_report.unwrap().applied_operations(), 2)
  assert_eq(received.sync_report.unwrap().pending_operations(), 0)
  assert_eq(bob.snapshot().text, drained)
  let (_, duplicate) = apply_editor_update(drained, bob.receive(second))
  assert_eq(duplicate.before, duplicate.after)
  assert_eq(duplicate.edits().length(), 0)
  assert_eq(duplicate.sync_report.unwrap().duplicate_operations(), 1)
}

///|
test "Editor range updates agree with independent scalar string edits across Unicode boundaries" {
  let editor = @text.Editor::new("unicode")
  let mut expected = ""
  let texts = [
    "日本語", "🙂", "é", "👩‍💻", "\n# 見出し\n", "", "abc",
  ]
  for i in 0..<200 {
    let offsets = [0]
    for ch in expected {
      offsets.push(offsets[offsets.length() - 1] + ch.to_string().length())
    }
    let a = i * 13 % offsets.length()
    let b = (a + i % 4).min(offsets.length() - 1)
    let start = offsets[a]
    let end = offsets[b]
    let text = texts[i % texts.length()]
    let next = expected[:start].to_owned() + text + expected[end:].to_owned()
    let (actual, update) = apply_editor_update(
      expected,
      editor.edit(editor.version(), { start, end, text, }),
    )
    assert_eq(actual, next)
    assert_eq(update.after, editor.version())
    assert_eq(editor.snapshot().text, next)
    if start != end || text != "" {
      let (undone, _) = apply_editor_update(next, editor.undo())
      assert_eq(undone, expected)
      let (redone, _) = apply_editor_update(undone, editor.redo())
      assert_eq(redone, next)
    }
    expected = next
  }
}

///|
test "Editor batch normalizes updates and undoes all spans across a remote edit" {
  let a = @text.Editor::new("batch-a")
  let b = @text.Editor::new("batch-b")
  let base = "a🙂bc漢de"
  ignore(
    apply_editor_update(
      "",
      a.edit(a.version(), { start: 0, end: 0, text: base, }, undo=NoHistory),
    ),
  )
  assert_true(!a.can_undo())
  ignore(
    apply_editor_update("", b.receive(a.export_since(@text.Version::empty()))),
  )
  let version = a.version()
  let changes = @text.ChangeSet::new([
    Keep(1),
    Replace(2, "XY"),
    Keep(2),
    Replace(1, "語🙂"),
    Keep(2),
  ])
  let (changed, update) = apply_editor_update(
    base,
    a.edit_many(version, changes, label="mark.add"),
  )
  assert_eq(changed, "aXYbc語🙂de")
  assert_eq(update.origin, @text.UpdateOrigin::Local(Some("mark.add")))
  assert_eq(update.change_set(), changes)
  assert_eq(update.before, version)
  // Concurrent edit occurs outside either replacement, and is not undone by a.
  ignore(
    apply_editor_update(
      base,
      b.edit(version, { start: 0, end: 0, text: "遠", }),
    ),
  )
  let (merged, remote) = apply_editor_update(
    changed,
    a.receive(b.export_since(version)),
  )
  assert_eq(remote.origin, @text.UpdateOrigin::Remote)
  assert_eq(merged, "遠aXYbc語🙂de")
  let (undone, undo) = apply_editor_update(merged, a.undo())
  assert_eq(undo.origin, @text.UpdateOrigin::Undo)
  assert_eq(undone, "遠" + base)
  assert_true(!a.can_undo())
  let (redone, redo) = apply_editor_update(undone, a.redo())
  assert_eq(redo.origin, @text.UpdateOrigin::Redo)
  assert_eq(redone, merged)
  let (other, _) = apply_editor_update(
    "遠" + base,
    b.receive(a.export_since(version)),
  )
  assert_eq(other, merged)
}

///|
test "Editor batch validates all boundaries before mutation and preserves redo on rejection" {
  let editor = @text.Editor::new("validation")
  ignore(
    apply_editor_update(
      "",
      editor.edit(
        editor.version(),
        { start: 0, end: 0, text: "a🙂bc", },
        undo=NoHistory,
      ),
    ),
  )
  ignore(
    apply_editor_update(
      "a🙂bc",
      editor.edit(editor.version(), { start: 5, end: 5, text: "!", }),
    ),
  )
  ignore(apply_editor_update("a🙂bc!", editor.undo()))
  let version = editor.version()
  let bad_length = @text.ChangeSet::new([Keep(4)])
  assert_true(
    editor.edit_many(@text.Version::empty(), bad_length)
    is Rejected(@text.EditError::StaleVersion),
  )
  assert_true(
    editor.edit_many(version, bad_length)
    is Rejected(
      @text.EditError::InvalidChange(@text.ChangeError::LengthMismatch),
    ),
  )
  // A reverse-order apply-before-validation would change the last character
  // before discovering the earlier boundary inside the emoji.
  let bad_boundary = @text.ChangeSet::new([
    Keep(2),
    Replace(0, "X"),
    Keep(2),
    Replace(1, "Z"),
  ])
  assert_true(
    editor.edit_many(version, bad_boundary)
    is Rejected(
      @text.EditError::InvalidChange(
        @text.ChangeError::InvalidBoundary(offset=2),
      ),
    ),
  )
  assert_true(
    editor.edit(version, { start: 2, end: 2, text: "", }) is Rejected(_),
  )
  // Forward application must not mutate the first range before validating a
  // later boundary inside the emoji either.
  let later_bad_boundary = @text.ChangeSet::new([
    Replace(1, "Q"),
    Keep(1),
    Replace(0, "R"),
    Keep(3),
  ])
  assert_true(
    editor.edit_many(version, later_bad_boundary)
    is Rejected(
      @text.EditError::InvalidChange(
        @text.ChangeError::InvalidBoundary(offset=2),
      ),
    ),
  )
  assert_eq(editor.snapshot().text, "a🙂bc")
  assert_eq(editor.version(), version)
  assert_true(!editor.can_undo())
  assert_true(editor.can_redo())
  let (restored, _) = apply_editor_update("a🙂bc", editor.redo())
  assert_eq(restored, "a🙂bc!")
}

///|
test "Editor explicit joins and barriers do not depend on time" {
  for
    barrier in [
      "none", "remote", "duplicate", "pending", "undo", "redo", "no-history",
    ] {
    let editor = @text.Editor::new("joins")
    ignore(
      apply_editor_update(
        "",
        editor.edit(
          editor.version(),
          { start: 0, end: 0, text: "[]", },
          undo=NoHistory,
        ),
      ),
    )
    ignore(
      apply_editor_update(
        "[]",
        editor.edit(
          editor.version(),
          { start: 1, end: 1, text: "A", },
          undo=JoinPrevious,
        ),
      ),
    )
    let mut before = "[A]"
    match barrier {
      "pending" => {
        let peer = @text.Editor::new("pending-peer")
        ignore(peer.edit(peer.version(), { start: 0, end: 0, text: "p", }))
        let v = peer.version()
        ignore(peer.edit(v, { start: 1, end: 1, text: "q", }))
        let (_, update) = apply_editor_update(
          before,
          editor.receive(peer.export_since(v)),
        )
        assert_eq(update.edits().length(), 0)
        assert_eq(update.sync_report.unwrap().pending_operations(), 1)
      }
      "remote" => {
        let peer = @text.Editor::new("peer")
        ignore(
          apply_editor_update(
            "",
            peer.receive(editor.export_since(@text.Version::empty())),
          ),
        )
        let v = peer.version()
        ignore(
          apply_editor_update(
            before,
            peer.edit(v, { start: 3, end: 3, text: "!", }),
          ),
        )
        let (text, _) = apply_editor_update(
          before,
          editor.receive(peer.export_since(v)),
        )
        before = text
      }
      "duplicate" =>
        ignore(
          apply_editor_update(
            before,
            editor.receive(editor.export_since(@text.Version::empty())),
          ),
        )
      "undo" => {
        ignore(
          apply_editor_update(
            before,
            editor.edit(editor.version(), { start: 2, end: 2, text: "x", }),
          ),
        )
        ignore(apply_editor_update("[Ax]", editor.undo()))
      }
      "redo" => {
        ignore(apply_editor_update(before, editor.undo()))
        ignore(apply_editor_update("[]", editor.redo()))
      }
      "no-history" => {
        let (text, _) = apply_editor_update(
          before,
          editor.edit(
            editor.version(),
            { start: 3, end: 3, text: "!", },
            undo=NoHistory,
          ),
        )
        before = text
      }
      _ => {
        assert_true(
          editor.edit_many(editor.version(), @text.ChangeSet::new([]))
          is Rejected(_),
        )
        ignore(
          apply_editor_update(
            before,
            editor.edit_many(editor.version(), @text.ChangeSet::new([Keep(3)])),
          ),
        )
      }
    }
    let (changed, _) = apply_editor_update(
      before,
      editor.edit(
        editor.version(),
        { start: 2, end: 2, text: "B", },
        undo=JoinPrevious,
      ),
    )
    let (undone, _) = apply_editor_update(changed, editor.undo())
    assert_eq(
      undone,
      if barrier == "none" || barrier == "duplicate" || barrier == "pending" {
        "[]"
      } else {
        before
      },
    )
  }
}

///|
test "Editor joined edits on the same target survive repeated undo redo and sync" {
  for replacement in ["", "🙂"] {
    let editor = @text.Editor::new("joined-writer")
    let peer = @text.Editor::new("joined-reader")
    let (inserted, _) = apply_editor_update(
      "",
      editor.edit(editor.version(), { start: 0, end: 0, text: "a", }),
    )
    let (changed, _) = apply_editor_update(
      inserted,
      editor.edit(
        editor.version(),
        { start: 0, end: 1, text: replacement, },
        undo=JoinPrevious,
      ),
    )
    assert_eq(changed, replacement)
    let mut peer_text = ""
    for _ in 0..<3 {
      let (undone, _) = apply_editor_update(replacement, editor.undo())
      assert_eq(undone, "")
      assert_eq(editor.snapshot().text, "")
      assert_true(!editor.can_undo())
      let (redone, _) = apply_editor_update(undone, editor.redo())
      assert_eq(redone, replacement)
      assert_eq(editor.snapshot().text, replacement)
      assert_true(!editor.can_redo())
      let (received, _) = apply_editor_update(
        peer_text,
        peer.receive(editor.export_since(peer.version())),
      )
      peer_text = received
      assert_eq(peer_text, replacement)
      assert_eq(peer.snapshot().text, replacement)
      assert_eq(peer.version(), editor.version())
    }
  }
}

///|
test "Editor empty updates and NoHistory preserve redo without recording groups" {
  let editor = @text.Editor::new("preserve-redo")
  ignore(
    apply_editor_update(
      "",
      editor.edit(
        editor.version(),
        { start: 0, end: 0, text: "[]", },
        undo=NoHistory,
      ),
    ),
  )
  ignore(
    apply_editor_update(
      "[]",
      editor.edit(editor.version(), { start: 1, end: 1, text: "A", }),
    ),
  )
  ignore(apply_editor_update("[A]", editor.undo()))
  let version = editor.version()
  let (_, empty) = apply_editor_update(
    "[]",
    editor.edit_many(version, @text.ChangeSet::new([Keep(2)])),
  )
  assert_eq(empty.edits().length(), 0)
  assert_eq(editor.version(), version)
  assert_true(editor.can_redo())
  ignore(
    apply_editor_update(
      "[]",
      editor.edit(version, { start: 2, end: 2, text: "!", }, undo=NoHistory),
    ),
  )
  assert_true(!editor.can_undo())
  assert_true(editor.can_redo())
  let (redone, _) = apply_editor_update("[]!", editor.redo())
  assert_eq(redone, "[A]!")
  let (undone, _) = apply_editor_update(redone, editor.undo())
  assert_eq(undone, "[]!")
  ignore(
    apply_editor_update(
      undone,
      editor.edit(editor.version(), { start: 1, end: 1, text: "B", }),
    ),
  )
  assert_true(!editor.can_redo())
}

///|
test "deferred admission preserves the editing cut and converges after local edits" {
  let a = @text.Editor::new("a")
  let b = @text.Editor::new("b")
  ignore(
    apply_editor_update(
      "",
      a.edit(
        a.version(),
        { start: 0, end: 0, text: "日🙂本", },
        undo=NoHistory,
      ),
    ),
  )
  ignore(
    apply_editor_update("", b.receive(a.export_since(@text.Version::empty()))),
  )
  let base = a.version()
  ignore(
    apply_editor_update(
      "日🙂本",
      b.edit(b.version(), { start: 1, end: 3, text: "遠", }, undo=NoHistory),
    ),
  )
  let packet = b.export_since(base)
  assert_true(a.accept_remote(packet).result is Ok(_))
  assert_eq(a.version(), base)
  assert_true(a.history_version() != base)
  assert_eq(a.snapshot().text, "日🙂本")
  let (local_text, _) = apply_editor_update(
    "日🙂本",
    a.edit(base, { start: 3, end: 3, text: "近", }, undo=NoHistory),
  )
  assert_eq(local_text, "日🙂近本")
  assert_true(a.accept_remote(packet).result is Ok(_))
  assert_eq(a.snapshot().text, local_text)
  ignore(
    apply_editor_update(
      "日遠本",
      b.receive(a.export_since(b.history_version())),
    ),
  )
  assert_eq(a.reopen_view().text, b.snapshot().text)
  assert_eq(a.snapshot().text, "日近遠本")
  assert_eq(a.version(), a.history_version())
  assert_eq(a.version(), b.version())
}

///|
test "pinned edits match an independent writer that receives nothing until integration" {
  for trial in 0..<12 {
    let pinned = @text.Editor::new("writer")
    let independent = @text.Editor::new("writer")
    let peer = @text.Editor::new("peer")
    let seed = "abc\n日本"
    for editor in [pinned, independent] {
      assert_true(
        editor.edit(
          editor.version(),
          { start: 0, end: 0, text: seed, },
          undo=NoHistory,
        )
        is Applied(_),
      )
    }
    assert_true(
      peer.receive(pinned.export_since(@text.Version::empty())) is Applied(_),
    )
    let base = peer.version()
    for step in 0..<40 {
      let remote_text = peer.snapshot().text
      let pos = (step * 7 + trial) % remote_text.length()
      assert_true(
        peer.edit(
          peer.version(),
          { start: pos, end: pos + 1, text: "遠", },
          undo=NoHistory,
        )
        is Applied(_),
      )
      assert_true(pinned.accept_remote(peer.export_since(base)).result is Ok(_))
      let text = independent.snapshot().text
      let pos = (step * 3 + trial) % text.length()
      let change : @text.Utf16Edit = { start: pos, end: pos + 1, text: "近", }
      for editor in [pinned, independent] {
        assert_true(
          editor.edit(editor.version(), change, undo=NoHistory) is Applied(_),
        )
      }
      assert_eq(pinned.snapshot().text, independent.snapshot().text)
      assert_eq(pinned.version(), independent.version())
    }
    assert_true(independent.receive(peer.export_since(base)) is Applied(_))
    assert_eq(pinned.reopen_view().text, independent.snapshot().text)
    assert_eq(pinned.version(), independent.version())
  }
}

///|
test "undo and redo stay on the displayed branch during hidden admission" {
  let a = @text.Editor::new("a")
  let b = @text.Editor::new("b")
  assert_true(
    a.edit(a.version(), { start: 0, end: 0, text: "abc", }, undo=NoHistory)
    is Applied(_),
  )
  assert_true(b.receive(a.export_since(@text.Version::empty())) is Applied(_))
  let base = a.version()
  assert_true(b.edit(base, { start: 1, end: 2, text: "R", }) is Applied(_))
  assert_true(a.accept_remote(b.export_since(base)).result is Ok(_))
  assert_true(a.edit(base, { start: 2, end: 2, text: "L", }) is Applied(_))
  assert_eq(a.snapshot().text, "abLc")
  assert_true(a.undo() is Applied(_))
  assert_eq(a.snapshot().text, "abc")
  assert_true(a.redo() is Applied(_))
  assert_eq(a.snapshot().text, "abLc")
  assert_true(b.receive(a.export_since(b.version())) is Applied(_))
  assert_eq(a.reopen_view().text, b.snapshot().text)
  assert_true(!a.can_undo())
  assert_true(!a.can_redo())
}

///|
test "deferred admission retains missing dependencies without changing input version" {
  let a = @text.Editor::new("a")
  let b = @text.Editor::new("b")
  assert_true(
    b.edit(b.version(), { start: 0, end: 0, text: "x", }, undo=NoHistory)
    is Applied(_),
  )
  let prefix = b.export_since(@text.Version::empty())
  let cut = b.version()
  assert_true(
    b.edit(cut, { start: 1, end: 1, text: "y", }, undo=NoHistory) is Applied(_),
  )
  let admission = a.accept_remote(b.export_since(cut))
  assert_true(admission.result is Ok(_))
  assert_eq(admission.pending_operations, 1)
  assert_eq(a.version(), @text.Version::empty())
  assert_true(
    a.edit(a.version(), { start: 0, end: 0, text: "L", }, undo=NoHistory)
    is Applied(_),
  )
  let displayed = a.version()
  let admission = a.accept_remote(prefix)
  assert_true(admission.result is Ok(_))
  assert_eq(admission.pending_operations, 0)
  assert_eq(a.version(), displayed)
  assert_eq(a.snapshot().text, "L")
  assert_true(b.receive(a.export_since(b.version())) is Applied(_))
  assert_eq(a.reopen_view().text, b.snapshot().text)
}

///|
test "explicit advance preserves selective undo and receive works after hidden admission" {
  let a = @text.Editor::new("a")
  let b = @text.Editor::new("b")
  assert_true(
    a.edit(a.version(), { start: 0, end: 0, text: "ab", }, undo=NoHistory)
    is Applied(_),
  )
  assert_true(b.receive(a.export_since(@text.Version::empty())) is Applied(_))
  let base = a.version()
  assert_true(b.edit(base, { start: 0, end: 0, text: "R", }) is Applied(_))
  let packet = b.export_since(base)
  assert_true(a.accept_remote(packet).result is Ok(_))
  assert_true(a.edit(base, { start: 1, end: 1, text: "L", }) is Applied(_))
  guard a.advance_view() is Applied(update) else { fail("advance failed") }
  assert_eq(update.origin, @text.UpdateOrigin::Remote)
  assert_true(update.sync_report is None)
  assert_eq(apply_change_set("aLb", update.change_set()), "RaLb")
  assert_eq(a.snapshot().text, "RaLb")
  assert_eq(a.version(), a.history_version())
  assert_true(a.undo() is Applied(_))
  assert_eq(a.snapshot().text, "Rab")
  assert_true(a.redo() is Applied(_))
  assert_eq(a.snapshot().text, "RaLb")
  assert_true(
    b.edit(b.version(), { start: 3, end: 3, text: "X", }) is Applied(_),
  )
  let later = b.export_since(base)
  assert_true(a.accept_remote(later).result is Ok(_))
  assert_eq(a.snapshot().text, "RaLb")
  let (text, _) = apply_editor_update("RaLb", a.receive(later))
  assert_eq(text, "RaLbX")
  assert_eq(a.snapshot().text, text)
}

///|
test "same text with different accepted history still advances the view version" {
  let a = @text.Editor::new("a")
  let b = @text.Editor::new("z-parent")
  let child = @text.Editor::new("a-child")
  let initial = a.version()
  assert_true(
    b.edit(b.version(), { start: 0, end: 0, text: "x", }) is Applied(_),
  )
  assert_true(child.receive(b.export_since(initial)) is Applied(_))
  assert_true(
    child.edit(child.version(), { start: 0, end: 1, text: "", }) is Applied(_),
  )
  // Actor-sorted export places the deletion before its insertion dependency.
  let admission = a.accept_remote(child.export_since(initial))
  assert_true(admission.result is Ok(_))
  assert_eq(admission.before, initial)
  assert_true(admission.after != initial)
  assert_eq(a.version(), initial)
  assert_eq(a.snapshot().text, "")
  assert_true(a.advance_view() is Applied(_))
  assert_eq(a.snapshot().text, "")
  assert_eq(a.version(), admission.after)
  assert_eq(a.version(), child.version())
  assert_true(
    a.edit(initial, { start: 0, end: 0, text: "stale", })
    is Rejected(StaleVersion),
  )
}
