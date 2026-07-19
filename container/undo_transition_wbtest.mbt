///|
fn transition_test_item(sequence : Int) -> UndoItem {
  TextInsert(
    block={ agent: "block", counter: 0 },
    id=@core.RawVersion::new("alice", sequence),
  )
}

///|
fn transition_item_sequence(item : UndoItem) -> Int {
  match item {
    TextInsert(id~, block=_) => id.seq
    _ => -1
  }
}

///|
test "undo replay plan and failure repair are deterministic" {
  let items = [
    transition_test_item(0),
    transition_test_item(1),
    transition_test_item(2),
  ]
  let commands = plan_replay(items, UndoPass)
  inspect(commands.length(), content="3")
  inspect(commands[0].source_index, content="2")
  inspect(commands[1].source_index, content="1")
  inspect(commands[2].source_index, content="0")
  let transition = replay_failure_transition(items, UndoPass, 1, [
    transition_test_item(2),
  ])
  inspect(transition.remaining_source.length(), content="2")
  inspect(transition_item_sequence(transition.remaining_source[0]), content="0")
  inspect(transition_item_sequence(transition.remaining_source[1]), content="1")
  inspect(transition.completed_opposite.length(), content="1")
  inspect(
    transition_item_sequence(transition.completed_opposite[0]),
    content="2",
  )
}

///|
test "redo failure repair retains failing and unprocessed commands" {
  let items = [
    transition_test_item(0),
    transition_test_item(1),
    transition_test_item(2),
  ]
  let transition = replay_failure_transition(items, RedoPass, 1, [
    transition_test_item(0),
  ])
  inspect(transition.remaining_source.length(), content="2")
  inspect(transition_item_sequence(transition.remaining_source[0]), content="1")
  inspect(transition_item_sequence(transition.remaining_source[1]), content="2")
  inspect(transition.completed_opposite.length(), content="1")
  inspect(
    transition_item_sequence(transition.completed_opposite[0]),
    content="0",
  )
}
