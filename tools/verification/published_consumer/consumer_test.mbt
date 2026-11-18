///|
fn apply_changes(before : String, changes : @text.ChangeSet) -> String raise {
  assert_eq(changes.length(), before.length())
  let result = StringBuilder()
  let mut offset = 0
  for section in changes.sections() {
    match section {
      Keep(n) => {
        result.write_string(before[offset:offset + n].to_owned())
        offset += n
      }
      Replace(n, text) => {
        result.write_string(text)
        offset += n
      }
    }
  }
  assert_eq(offset, before.length())
  let text = result.to_string()
  assert_eq(changes.new_length(), text.length())
  text
}

///|
fn replay(before : String, result : @text.Edit) -> String raise {
  guard result is Applied(update) else { fail("expected accepted update") }
  assert_eq(update.before_len, before.length())
  let mut text = before
  for edit in update.edits() {
    text = text[:edit.start].to_owned() + edit.text + text[edit.end:].to_owned()
  }
  assert_eq(apply_changes(before, update.change_set()), text)
  text
}

///|
test "packaged ChangeSet composes edits inside inserted UTF16 text" {
  let source = "ab終"
  let first = @text.ChangeSet::new([Keep(1), Replace(0, "🙂XY"), Keep(2)])
  let second = @text.ChangeSet::new([
    Keep(3),
    Replace(1, "語"),
    Keep(1),
    Replace(1, ""),
    Keep(1),
  ])
  assert_eq(apply_changes(source, first), "a🙂XYb終")
  assert_eq(apply_changes("a🙂XYb終", second), "a🙂語Y終")
  assert_eq(apply_changes(source, first.compose(second)), "a🙂語Y終")
}

///|
test "packaged Editor supports UTF16 edits, wire roundtrip, and explicit Undo ownership" {
  let alice = @text.Editor::new("alice")
  assert_eq(
    replay(
      "",
      alice.edit(
        alice.version(),
        { start: 0, end: 0, text: "日🙂本", },
        undo=NoHistory,
      ),
    ),
    "日🙂本",
  )
  assert_false(alice.can_undo())
  let before = alice.version()
  let changes = @text.ChangeSet::new([Keep(1), Replace(2, "語"), Keep(1)])
  assert_eq(replay("日🙂本", alice.edit_many(before, changes)), "日語本")
  assert_true(
    alice.edit(before, { start: 0, end: 0, text: "stale", })
    is Rejected(@text.EditError::StaleVersion),
  )
  let bob = @text.Editor::new("bob")
  let packet = alice.export_since(@text.Version::empty()).to_json_string()
  let decoded = @text.SyncMessage::from_json_string(packet)
  assert_eq(replay("", bob.receive(decoded)), "日語本")
  assert_eq(bob.version(), alice.version())
  assert_eq(replay("日語本", alice.undo()), "日🙂本")
  assert_eq(replay("日🙂本", alice.redo()), "日語本")
  assert_eq(alice.snapshot().text, bob.snapshot().text)
}

///|
test "packaged transition and live causal view expose owning diagnostic values" {
  let source = @text.TextState::new("source")
  source.insert(@text.Pos::at(0), "abc")
  let target = @text.TextState::new("target")
  let transition : @text.TextSyncTransition = target
    .sync()
    .apply_transition(source.sync().export_all())
  assert_true(transition.effect_availability() is Exact(_))
  ignore(transition.report())
  assert_eq(target.text(), "abc")
  let view : @history.CausalView = target.causal_view()
  let counts = view.children_counts()
  assert_eq(counts, [1, 1, 0])
  target.insert(@text.Pos::at(3), "d")
  assert_eq(view.op_count(), 4)
  assert_eq(counts, [1, 1, 0])
  assert_eq(view.children_counts(), [1, 1, 1, 0])
}
