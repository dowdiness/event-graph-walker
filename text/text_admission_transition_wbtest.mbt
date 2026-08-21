///| Observable contract tracer for authority-owned Text admission effects.
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

///| Sequential coordinates are relative to each preceding effect.
test "transition exact batch exposes ordered scalar insert coordinates" {
  let source = try! TextState::new("transition-batch-source")
  try! source.insert(Pos::at(0), "AB")
  let receiver = try! TextState::new("transition-batch-receiver")

  let transition = try! receiver.sync().apply_transition(
    try! source.sync().export_all(),
  )

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

///| Delete coordinates name the visible scalar interval before that effect.
test "transition exact delete exposes scalar range" {
  let source = try! TextState::new("transition-delete-source")
  try! source.insert(Pos::at(0), "A")
  let receiver = try! TextState::new("transition-delete-receiver")
  ignore(try! receiver.sync().apply(try! source.sync().export_all()))
  let receiver_version = receiver.version()
  try! source.delete(Pos::at(0))

  let transition = try! receiver.sync().apply_transition(
    try! source.sync().export_since(receiver_version),
  )

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

///| Duplicate and pending authority no-ops remain exact empty effects.
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
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"transition-pending\",\"sequence\":1},\"parents\":[{\"replica_id\":\"transition-pending\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"transition-pending\",\"sequence\":1}]}",
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

///| A dependency drain publishes every newly committed effect in commit order.
test "transition dependency drain exposes one sequential effect stream" {
  let receiver = try! TextState::new("transition-drain-receiver")
  let child = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"transition-drain\",\"sequence\":1},\"parents\":[{\"replica_id\":\"transition-drain\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":{\"replica_id\":\"transition-drain\",\"sequence\":0},\"origin_right\":null}],\"heads\":[{\"replica_id\":\"transition-drain\",\"sequence\":1}]}",
  )
  ignore(try! receiver.sync().apply(child))
  let parent = try! SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"transition-drain\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"transition-drain\",\"sequence\":0}]}",
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
