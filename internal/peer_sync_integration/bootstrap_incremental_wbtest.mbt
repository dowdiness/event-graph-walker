///|
fn text_bootstrap_trace() -> Array[DecisionKind] raise {
  let source = try! @egw_text.TextState::new("source")
  let receiver = try! @egw_text.TextState::new("receiver")
  try! source.insert(@egw_text.Pos::at(0), "A")
  let full = try! source.sync().export_all()
  let scheduler : Scheduler[@egw_text.SyncMessage] = Scheduler::new()
  scheduler.duplicate(full)
  let trace : Array[DecisionKind] = []
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::RequestFullSync)
  let (state, decisions) = transition(state, FullSyncRequested("source"))
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendFullSync)
  let report = try! receiver.sync().apply(scheduler.take_delivery())
  let observation = text_observation(report)
  assert_text_observation(report, 1, 0, 0)
  let (state, decisions) = transition(state, Applied("source", observation))
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  expect_recovered(decisions, "source")
  let duplicate = try! receiver.sync().apply(scheduler.take_delivery())
  assert_text_observation(duplicate, 0, 1, 0)
  let (state, decisions) = transition(
    state,
    Applied("source", text_observation(duplicate)),
  )
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let (_, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  inspect(decisions.length(), content="0")
  inspect(scheduler.is_empty(), content="true")
  inspect(receiver.text(), content="A")
  inspect(receiver.version() == source.version(), content="true")
  trace
}

///|
fn container_bootstrap_trace() -> Array[DecisionKind] raise {
  let source = try! @egw_container.Document::new("source")
  let receiver = try! @egw_container.Document::new("receiver")
  let node = try! source.create_node(parent=@egw_container.root_id)
  source.set_property(node, "kind", "shared")
  try! source.insert_text(node, 0, "A")
  let full = try! source.sync().export_all()
  let scheduler : Scheduler[@egw_container.SyncMessage] = Scheduler::new()
  scheduler.duplicate(full)
  let trace : Array[DecisionKind] = []
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::RequestFullSync)
  let (state, decisions) = transition(state, FullSyncRequested("source"))
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendFullSync)
  let report = try! receiver.sync().apply(scheduler.take_delivery())
  let observation = container_observation(report)
  assert_container_observation(report, 3, 0, 0)
  let (state, decisions) = transition(state, Applied("source", observation))
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  expect_recovered(decisions, "source")
  let duplicate = try! receiver.sync().apply(scheduler.take_delivery())
  assert_container_observation(duplicate, 0, 3, 0)
  let (state, decisions) = transition(
    state,
    Applied("source", container_observation(duplicate)),
  )
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let (_, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  inspect(decisions.length(), content="0")
  inspect(scheduler.is_empty(), content="true")
  inspect(receiver.get_text(node), content="A")
  inspect(receiver.get_property(node, "kind") == Some("shared"), content="true")
  inspect(receiver.version() == source.version(), content="true")
  trace
}

///|
test "shared bootstrap and duplicate traces use actual façade versions" {
  let text_trace = text_bootstrap_trace()
  let container_trace = container_bootstrap_trace()
  expect_kinds(text_trace, [
    DecisionKind::SendVersion,
    DecisionKind::RequestFullSync,
    DecisionKind::SendFullSync,
    DecisionKind::SendVersion,
    DecisionKind::ReportRecovered,
    DecisionKind::SendVersion,
  ])
  expect_kinds(container_trace, text_trace)
}

///|
fn text_incremental_trace() -> Array[DecisionKind] raise {
  let source = try! @egw_text.TextState::new("source")
  let receiver = try! @egw_text.TextState::new("receiver")
  try! source.insert(@egw_text.Pos::at(0), "A")
  let full = try! source.sync().export_all()
  let scheduler : Scheduler[@egw_text.SyncMessage] = Scheduler::new()
  scheduler.deliver(full)
  let trace : Array[DecisionKind] = []
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  add_kinds(trace, decisions)
  let (state, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  let (state, decisions) = transition(state, FullSyncRequested("source"))
  add_kinds(trace, decisions)
  let report = try! receiver.sync().apply(scheduler.take_delivery())
  let (state, decisions) = transition(
    state,
    Applied("source", text_observation(report)),
  )
  add_kinds(trace, decisions)
  let (state, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  expect_recovered(decisions, "source")
  let baseline = receiver.version()
  try! source.insert(@egw_text.Pos::at(source.len()), "B")
  let (state, decisions) = transition(state, LocalCommitted)
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendIncrementalSync)
  scheduler.deliver(try! source.sync().export_since(baseline))
  let report = try! receiver.sync().apply(scheduler.take_delivery())
  let (state, decisions) = transition(
    state,
    Applied("source", text_observation(report)),
  )
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let (_, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  inspect(decisions.length(), content="0")
  inspect(scheduler.is_empty(), content="true")
  inspect(receiver.text(), content="AB")
  inspect(receiver.version() == source.version(), content="true")
  trace
}

///|
fn container_incremental_trace() -> Array[DecisionKind] raise {
  let source = try! @egw_container.Document::new("source")
  let receiver = try! @egw_container.Document::new("receiver")
  let node = try! source.create_node(parent=@egw_container.root_id)
  try! source.insert_text(node, 0, "A")
  let scheduler : Scheduler[@egw_container.SyncMessage] = Scheduler::new()
  scheduler.deliver(try! source.sync().export_all())
  let trace : Array[DecisionKind] = []
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  add_kinds(trace, decisions)
  let (state, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  let (state, decisions) = transition(state, FullSyncRequested("source"))
  add_kinds(trace, decisions)
  let report = try! receiver.sync().apply(scheduler.take_delivery())
  let (state, decisions) = transition(
    state,
    Applied("source", container_observation(report)),
  )
  add_kinds(trace, decisions)
  let (state, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  expect_recovered(decisions, "source")
  let baseline = receiver.version()
  try! source.insert_text(node, source.text_len(node), "B")
  let (state, decisions) = transition(state, LocalCommitted)
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendIncrementalSync)
  scheduler.deliver(try! source.sync().export_since(baseline))
  let report = try! receiver.sync().apply(scheduler.take_delivery())
  let (state, decisions) = transition(
    state,
    Applied("source", container_observation(report)),
  )
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let (_, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  inspect(decisions.length(), content="0")
  inspect(scheduler.is_empty(), content="true")
  inspect(receiver.get_text(node), content="AB")
  inspect(receiver.version() == source.version(), content="true")
  trace
}

///|
test "shared incremental traces send local commits through both façades" {
  let text_trace = text_incremental_trace()
  let container_trace = container_incremental_trace()
  expect_kinds(text_trace, [
    DecisionKind::SendVersion,
    DecisionKind::RequestFullSync,
    DecisionKind::SendFullSync,
    DecisionKind::SendVersion,
    DecisionKind::ReportRecovered,
    DecisionKind::SendIncrementalSync,
    DecisionKind::SendVersion,
  ])
  expect_kinds(container_trace, text_trace)
}
