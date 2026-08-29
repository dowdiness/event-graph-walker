///|
/// Observable contract tracer for authority-owned Text admission effects.
test "transition exact insert exposes sequential scalar effect and finishes report" {
  let source = try! TextState::new("transition-source")
  try! source.insert(Pos::at(0), "A")
  let message = try! source.sync().export_all()
  let receiver = try! TextState::new("transition-receiver")
  let before = receiver.version()

  let transition = try! receiver.sync().apply_transition(message)

  assert_eq(transition.version_before(), before)
  assert_eq(transition.version_after(), receiver.version())
  match transition.availability() {
    Exact(effects) => {
      assert_eq(effects.length(), 1)
      match effects[0] {
        Insert(position, text) => {
          assert_eq(position, Pos::at(0))
          assert_eq(text, "A")
        }
        Delete(_) => fail("insert admission exposed a delete effect")
      }
    }
    SnapshotRequired => fail("warm one-op insert required a snapshot")
    Unavailable => fail("warm one-op insert was unavailable")
  }
  let report = try! transition.finish()
  assert_eq(report.applied_operations(), 1)
  assert_eq(report.duplicate_operations(), 0)
  assert_eq(report.pending_operations(), 0)
}

///|
/// Sequential coordinates are relative to each preceding effect.
test "transition exact batch exposes ordered scalar insert coordinates" {
  let source = try! TextState::new("transition-batch-source")
  try! source.insert(Pos::at(0), "AB")
  let receiver = try! TextState::new("transition-batch-receiver")

  let transition = try! receiver
    .sync()
    .apply_transition(try! source.sync().export_all())

  match transition.availability() {
    Exact(effects) => {
      assert_eq(effects.length(), 2)
      assert_eq(effects[0], Insert(Pos::at(0), "A"))
      assert_eq(effects[1], Insert(Pos::at(1), "B"))
    }
    SnapshotRequired => fail("warm two-op insert required a snapshot")
    Unavailable => fail("warm two-op insert was unavailable")
  }
  ignore(try! transition.finish())
}

///|
/// Delete coordinates name the visible scalar interval before that effect.
test "transition exact delete exposes scalar range" {
  let source = try! TextState::new("transition-delete-source")
  try! source.insert(Pos::at(0), "A")
  let receiver = try! TextState::new("transition-delete-receiver")
  ignore(try! receiver.sync().apply(try! source.sync().export_all()))
  let receiver_version = receiver.version()
  try! source.delete(Pos::at(0))

  let transition = try! receiver
    .sync()
    .apply_transition(try! source.sync().export_since(receiver_version))

  match transition.availability() {
    Exact(effects) => {
      assert_eq(effects.length(), 1)
      assert_eq(effects[0], Delete(try! Range::from_ints(0, 1)))
    }
    SnapshotRequired => fail("warm one-op delete required a snapshot")
    Unavailable => fail("warm one-op delete was unavailable")
  }
  ignore(try! transition.finish())
}

///|
/// A remote undo revives deleted text with an exact insert effect.
test "transition exact remote undelete exposes visible insert effect" {
  let source = try! TextState::new("transition-undelete-source")
  let source_undo = @undo.UndoManager::new("transition-undelete-source")
  try! source.insert_and_record(Pos::at(0), "A", source_undo, timestamp_ms=0)
  try! source.delete_and_record(Pos::at(0), source_undo, timestamp_ms=1000)
  let receiver = try! TextState::new("transition-undelete-receiver")
  ignore(try! receiver.sync().apply(try! source.sync().export_all()))
  assert_eq(receiver.text(), "")
  let receiver_version = receiver.version()
  assert_true(try! source_undo.undo(source))

  let before = receiver.text()
  let transition = try! receiver
    .sync()
    .apply_transition(try! source.sync().export_since(receiver_version))
  assert_eq(transition.version_before(), receiver_version)
  assert_eq(transition.version_after(), receiver.version())
  match transition.availability() {
    Exact(effects) => {
      assert_eq(effects.length(), 1)
      assert_eq(effects[0], Insert(Pos::at(0), "A"))
      assert_eq(
        apply_transition_effects_for_test(before, effects),
        receiver.text(),
      )
    }
    SnapshotRequired => fail("remote undelete required a snapshot")
    Unavailable => fail("remote undelete was unavailable")
  }
  let report = try! transition.finish()
  assert_eq(report.applied_operations(), 1)
  assert_eq(report.duplicate_operations(), 0)
  assert_eq(report.pending_operations(), 0)
}

///|
/// A losing remote LWW delete is admitted, advances the version, and changes
/// no visible text, so its exact effect sequence is empty.
test "transition exact losing LWW delete reports admission with empty effects" {
  let source = try! TextState::new("transition-losing-delete-source")
  try! source.insert(Pos::at(0), "A")
  let receiver = try! TextState::new("transition-losing-delete-receiver")
  ignore(try! receiver.sync().apply(try! source.sync().export_all()))

  let receiver_undo = @undo.UndoManager::new(
    "transition-losing-delete-receiver",
  )
  try! receiver.delete_and_record(Pos::at(0), receiver_undo, timestamp_ms=0)
  assert_true(try! receiver_undo.undo(receiver))
  assert_eq(receiver.text(), "A")
  let before = receiver.text()
  let before_version = receiver.version()

  try! source.delete(Pos::at(0))
  let transition = try! receiver
    .sync()
    .apply_transition(try! source.sync().export_all())
  assert_eq(transition.version_before(), before_version)
  assert_true(transition.version_after() != before_version)
  assert_eq(transition.version_after(), receiver.version())
  match transition.availability() {
    Exact(effects) => {
      assert_eq(effects.length(), 0)
      assert_eq(
        apply_transition_effects_for_test(before, effects),
        receiver.text(),
      )
    }
    SnapshotRequired => fail("losing LWW delete required a snapshot")
    Unavailable => fail("losing LWW delete was unavailable")
  }
  let report = try! transition.finish()
  assert_eq(report.applied_operations(), 1)
  assert_eq(report.duplicate_operations(), 1)
  assert_eq(report.pending_operations(), 0)
  assert_eq(receiver.text(), "A")
}

///|
/// Duplicate and pending authority no-ops remain exact empty effects.
test "transition duplicate-only and pending-only expose exact empty effects" {
  let source = try! TextState::new("transition-noop-source")
  try! source.insert(Pos::at(0), "A")
  let message = try! source.sync().export_all()
  let receiver = try! TextState::new("transition-noop-receiver")
  ignore(try! receiver.sync().apply(message))
  let duplicate = try! receiver.sync().apply_transition(message)
  match duplicate.availability() {
    Exact(effects) => assert_eq(effects.length(), 0)
    _ => fail("duplicate-only admission did not expose exact empty effects")
  }
  let duplicate_report = try! duplicate.finish()
  assert_eq(duplicate_report.duplicate_operations(), 1)

  let pending_message = try! SyncMessage::from_json_string(
    "{\"schema\":2,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"transition-pending\",\"sequence\":1},\"parents\":[{\"replica_id\":\"transition-pending\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"transition-pending\",\"sequence\":1}]}",
  )
  let pending = try! receiver.sync().apply_transition(pending_message)
  match pending.availability() {
    Exact(effects) => assert_eq(effects.length(), 0)
    _ => fail("pending-only admission did not expose exact empty effects")
  }
  let pending_report = try! pending.finish()
  assert_eq(pending_report.applied_operations(), 0)
  assert_eq(pending_report.pending_operations(), 1)
}

///|
/// A dependency drain publishes every newly committed effect in commit order.
test "transition dependency drain exposes one sequential effect stream" {
  let receiver = try! TextState::new("transition-drain-receiver")
  let child = try! SyncMessage::from_json_string(
    "{\"schema\":2,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"transition-drain\",\"sequence\":1},\"parents\":[{\"replica_id\":\"transition-drain\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":{\"replica_id\":\"transition-drain\",\"sequence\":0},\"origin_right\":null}],\"heads\":[{\"replica_id\":\"transition-drain\",\"sequence\":1}]}",
  )
  ignore(try! receiver.sync().apply(child))
  let parent = try! SyncMessage::from_json_string(
    "{\"schema\":2,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"transition-drain\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"transition-drain\",\"sequence\":0}]}",
  )

  let transition = try! receiver.sync().apply_transition(parent)

  match transition.availability() {
    Exact(effects) => {
      assert_eq(effects.length(), 2)
      assert_eq(effects[0], Insert(Pos::at(0), "A"))
      assert_eq(effects[1], Insert(Pos::at(1), "B"))
    }
    _ => fail("warm dependency drain did not expose exact effects")
  }
  let report = try! transition.finish()
  assert_eq(report.applied_operations(), 2)
  assert_eq(report.pending_operations(), 0)
}

///|
/// Test-only scalar oracle; production consumers must not compare snapshots.
fn apply_transition_effects_for_test(
  source : String,
  effects : ArrayView[TextEffect],
) -> String {
  let chars = source.to_array()
  for effect in effects {
    match effect {
      Insert(position, text) => {
        let inserted = text.to_array()
        for offset = 0; offset < inserted.length(); offset = offset + 1 {
          chars.insert(position.value() + offset, inserted[offset])
        }
      }
      Delete(range) => {
        let start = range.start().value()
        let count = range.end().value() - start
        for _ in 0..<count {
          ignore(chars.remove(start))
        }
      }
    }
  }
  String::from_array(chars[:])
}

///|
/// Exact effects remain a complete sequential description across randomized
/// concurrent insert/delete histories and Unicode scalar content.
test "property: exact transition effects reproduce authority text" {
  let seeds : Array[Int] = @quickcheck.samples(20)
  for raw_seed in seeds {
    let alice = try! TextState::new("transition-property-alice")
    let bob = try! TextState::new("transition-property-bob")
    let receiver = try! TextState::new("transition-property-receiver")
    let sources = [alice, bob]
    let alphabet = ["a", "你", "😀", "\u{0301}", "\r", "\n"]
    let mut state = raw_seed % 997
    if state < 0 {
      state = -state
    }
    for step = 0; step < 60; step = step + 1 {
      state = (state * 37 + 17) % 997
      let source = sources[state % sources.length()]
      if state % 4 != 0 || source.len() == 0 {
        let position = state % (source.len() + 1)
        try! source.insert(
          Pos::at(position),
          alphabet[state % alphabet.length()],
        )
      } else {
        try! source.delete(Pos::at(state % source.len()))
      }
      let before = receiver.text()
      let transition = try! receiver
        .sync()
        .apply_transition(try! source.sync().export_all())
      match transition.availability() {
        Exact(effects) =>
          assert_eq(
            apply_transition_effects_for_test(before, effects),
            receiver.text(),
          )
        SnapshotRequired =>
          fail(
            "one-step warm randomized admission unexpectedly required snapshot",
          )
        Unavailable => fail("randomized admission unexpectedly unavailable")
      }
      ignore(try! transition.finish())
    }
  }
}

///|
/// The accepted initial policy sends oversized committed batches to the one
/// coherent snapshot fallback rather than publishing unproved partial effects.
test "transition oversized batch requires snapshot" {
  let source = try! TextState::new("transition-oversized-source")
  try! source.insert(Pos::at(0), "ABCD")
  let receiver = try! TextState::new("transition-oversized-receiver")
  let transition = try! receiver
    .sync()
    .apply_transition(try! source.sync().export_all())
  assert_true(transition.availability() is SnapshotRequired)
  let report = try! transition.finish()
  assert_eq(report.applied_operations(), 4)
}
