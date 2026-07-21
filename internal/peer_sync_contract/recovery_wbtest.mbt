///|
fn text_pending_trace() -> Array[DecisionKind] raise {
  let source = try! @text.TextState::new("source")
  try! source.insert(@text.Pos::at(0), "A")
  let baseline = source.version()
  try! source.insert(@text.Pos::at(1), "B")
  let future = try! source.sync().export_since(baseline)
  let complete = try! source.sync().export_all()
  let receiver = try! @text.TextState::new("receiver")
  let scheduler : Scheduler[@text.SyncMessage] = Scheduler::new()
  scheduler.delay(complete)
  scheduler.duplicate(future)
  let trace : Array[DecisionKind] = []
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let pending_report = try! receiver.sync().apply(scheduler.take_delivery())
  expect_observation(text_observation(pending_report), 0, 0, 1)
  inspect(receiver.sync().pending_sync_count(), content="1")
  let (state, decisions) = transition(
    state,
    Applied("source", text_observation(pending_report)),
  )
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::RequestFullSync)
  let repeated = try! receiver.sync().apply(scheduler.take_delivery())
  let repeated_observation = text_observation(repeated)
  expect_observation(repeated_observation, 0, 1, 1)
  let (state, decisions) = transition(
    state,
    Applied("source", repeated_observation),
  )
  add_kinds(trace, decisions)
  inspect(decisions.length(), content="0")
  scheduler.release_delayed()
  let complete_report = try! receiver.sync().apply(scheduler.take_delivery())
  inspect(receiver.sync().pending_sync_count(), content="0")
  let (state, decisions) = transition(
    state,
    Applied("source", text_observation(complete_report)),
  )
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let (_, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  expect_recovered(decisions, "source")
  inspect(scheduler.is_empty(), content="true")
  inspect(receiver.text(), content="AB")
  trace
}

///|
fn container_pending_trace() -> Array[DecisionKind] raise {
  let source = try! @container.Document::new("source")
  let first = try! source.create_node(parent=@container.root_id)
  let baseline = source.version()
  let second = try! source.create_node(parent=@container.root_id)
  let future = try! source.sync().export_since(baseline)
  let complete = try! source.sync().export_all()
  let receiver = try! @container.Document::new("receiver")
  let scheduler : Scheduler[@container.SyncMessage] = Scheduler::new()
  scheduler.delay(complete)
  scheduler.duplicate(future)
  let trace : Array[DecisionKind] = []
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let pending_report = try! receiver.sync().apply(scheduler.take_delivery())
  expect_observation(container_observation(pending_report), 0, 0, 1)
  inspect(receiver.sync().pending_sync_count(), content="1")
  let (state, decisions) = transition(
    state,
    Applied("source", container_observation(pending_report)),
  )
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::RequestFullSync)
  let repeated = try! receiver.sync().apply(scheduler.take_delivery())
  let repeated_observation = container_observation(repeated)
  expect_observation(repeated_observation, 0, 1, 1)
  let (state, decisions) = transition(
    state,
    Applied("source", repeated_observation),
  )
  add_kinds(trace, decisions)
  inspect(decisions.length(), content="0")
  scheduler.release_delayed()
  let complete_report = try! receiver.sync().apply(scheduler.take_delivery())
  inspect(receiver.sync().pending_sync_count(), content="0")
  inspect(receiver.is_alive(first), content="true")
  inspect(receiver.is_alive(second), content="true")
  let (state, decisions) = transition(
    state,
    Applied("source", container_observation(complete_report)),
  )
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::SendVersion)
  let (_, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  expect_recovered(decisions, "source")
  inspect(scheduler.is_empty(), content="true")
  trace
}

///|
test "pending and out-of-order recovery is identical and version-confirmed" {
  let text_trace = text_pending_trace()
  let container_trace = container_pending_trace()
  expect_kinds(text_trace, [
    DecisionKind::SendVersion,
    DecisionKind::RequestFullSync,
    DecisionKind::SendVersion,
    DecisionKind::ReportRecovered,
  ])
  expect_kinds(container_trace, text_trace)
}

///|
fn reconnect_trace_text() -> Array[DecisionKind] raise {
  let source = try! @text.TextState::new("source")
  let receiver = try! @text.TextState::new("receiver")
  try! source.insert(@text.Pos::at(0), "A")
  let full = try! source.sync().export_all()
  let scheduler : Scheduler[@text.SyncMessage] = Scheduler::new()
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
  scheduler.deliver(try! source.sync().export_all())
  scheduler.disconnect("source")
  let (state, decisions) = match scheduler.next() {
    TransportDisconnected(peer) => transition(state, PeerDisconnected(peer))
    _ => fail("expected disconnect before reconnect")
  }
  inspect(decisions.length(), content="0")
  scheduler.reconnect("source")
  let (state, decisions) = match scheduler.next() {
    TransportReconnected(peer) => transition(state, Reconnect(peer))
    _ => fail("expected reconnect event")
  }
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::RequestFullSync)
  let (state, decisions) = transition(state, FullSyncRequested("source"))
  add_kinds(trace, decisions)
  let reconnect_report = try! receiver.sync().apply(scheduler.take_delivery())
  let (state, decisions) = transition(
    state,
    Applied("source", text_observation(reconnect_report)),
  )
  add_kinds(trace, decisions)
  let (_, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  expect_recovered(decisions, "source")
  inspect(scheduler.is_empty(), content="true")
  inspect(receiver.text(), content="A")
  trace
}

///|
fn reconnect_trace_container() -> Array[DecisionKind] raise {
  let source = try! @container.Document::new("source")
  let receiver = try! @container.Document::new("receiver")
  let node = try! source.create_node(parent=@container.root_id)
  try! source.insert_text(node, 0, "A")
  let full = try! source.sync().export_all()
  let scheduler : Scheduler[@container.SyncMessage] = Scheduler::new()
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
    Applied("source", container_observation(report)),
  )
  add_kinds(trace, decisions)
  let (state, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  expect_recovered(decisions, "source")
  scheduler.deliver(try! source.sync().export_all())
  scheduler.disconnect("source")
  let (state, decisions) = match scheduler.next() {
    TransportDisconnected(peer) => transition(state, PeerDisconnected(peer))
    _ => fail("expected disconnect before reconnect")
  }
  inspect(decisions.length(), content="0")
  scheduler.reconnect("source")
  let (state, decisions) = match scheduler.next() {
    TransportReconnected(peer) => transition(state, Reconnect(peer))
    _ => fail("expected reconnect event")
  }
  add_kinds(trace, decisions)
  expect_single(decisions, DecisionKind::RequestFullSync)
  let (state, decisions) = transition(state, FullSyncRequested("source"))
  add_kinds(trace, decisions)
  let reconnect_report = try! receiver.sync().apply(scheduler.take_delivery())
  let (state, decisions) = transition(
    state,
    Applied("source", container_observation(reconnect_report)),
  )
  add_kinds(trace, decisions)
  let (_, decisions) = transition(
    state,
    VersionCompared("source", source.version() == receiver.version()),
  )
  add_kinds(trace, decisions)
  expect_recovered(decisions, "source")
  inspect(scheduler.is_empty(), content="true")
  inspect(receiver.get_text(node), content="A")
  trace
}

///|
test "reconnect requests full sync and waits for version confirmation" {
  let text_trace = reconnect_trace_text()
  let container_trace = reconnect_trace_container()
  expect_kinds(text_trace, [
    DecisionKind::SendVersion,
    DecisionKind::RequestFullSync,
    DecisionKind::SendFullSync,
    DecisionKind::SendVersion,
    DecisionKind::ReportRecovered,
    DecisionKind::RequestFullSync,
    DecisionKind::SendFullSync,
    DecisionKind::SendVersion,
    DecisionKind::ReportRecovered,
  ])
  expect_kinds(container_trace, text_trace)
}
