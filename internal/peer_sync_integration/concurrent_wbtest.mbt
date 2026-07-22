///|
fn text_concurrent_trace() -> Array[DecisionRoute] raise {
  let alice = try! @egw_text.TextState::new("alice")
  let bob = try! @egw_text.TextState::new("bob")
  let trace : Array[DecisionRoute] = []
  let (alice_state, decisions) = transition(
    State::empty(),
    PeerAvailable("bob"),
  )
  add_routes(trace, decisions)
  let (alice_state, decisions) = transition(
    alice_state,
    VersionCompared("bob", alice.version() == bob.version()),
  )
  add_routes(trace, decisions)
  let (bob_state, decisions) = transition(
    State::empty(),
    PeerAvailable("alice"),
  )
  add_routes(trace, decisions)
  let (bob_state, decisions) = transition(
    bob_state,
    VersionCompared("alice", bob.version() == alice.version()),
  )
  add_routes(trace, decisions)

  let scheduler : Scheduler[@egw_text.SyncMessage] = Scheduler::new()
  scheduler.disconnect("alice")
  scheduler.disconnect("bob")
  let (alice_state, decisions) = match scheduler.next() {
    TransportDisconnected(peer) =>
      transition(alice_state, PeerDisconnected(peer))
    _ => fail("expected bob transport disconnect")
  }
  inspect(decisions.length(), content="0")
  let (bob_state, decisions) = match scheduler.next() {
    TransportDisconnected(peer) => transition(bob_state, PeerDisconnected(peer))
    _ => fail("expected alice transport disconnect")
  }
  inspect(decisions.length(), content="0")

  try! alice.insert(@egw_text.Pos::at(0), "A")
  try! bob.insert(@egw_text.Pos::at(0), "B")
  let (_, decisions) = transition(alice_state, LocalCommitted)
  inspect(decisions.length(), content="0")
  let (_, decisions) = transition(bob_state, LocalCommitted)
  inspect(decisions.length(), content="0")

  scheduler.reconnect("alice")
  scheduler.reconnect("bob")
  let (alice_state, decisions) = match scheduler.next() {
    TransportReconnected(peer) => transition(alice_state, Reconnect(peer))
    _ => fail("expected bob transport reconnect")
  }
  add_routes(trace, decisions)
  let (bob_state, decisions) = match scheduler.next() {
    TransportReconnected(peer) => transition(bob_state, Reconnect(peer))
    _ => fail("expected alice transport reconnect")
  }
  add_routes(trace, decisions)

  let (bob_state, decisions) = transition(bob_state, FullSyncRequested("alice"))
  add_routes(trace, decisions)
  scheduler.deliver(try! bob.sync().export_all())
  let (alice_state, decisions) = transition(
    alice_state,
    FullSyncRequested("bob"),
  )
  add_routes(trace, decisions)
  scheduler.deliver(try! alice.sync().export_all())

  let bob_report = try! bob.sync().apply(scheduler.take_delivery())
  let (bob_state, decisions) = transition(
    bob_state,
    Applied("alice", text_observation(bob_report)),
  )
  add_routes(trace, decisions)
  let alice_report = try! alice.sync().apply(scheduler.take_delivery())
  let (alice_state, decisions) = transition(
    alice_state,
    Applied("bob", text_observation(alice_report)),
  )
  add_routes(trace, decisions)
  let (_, decisions) = transition(
    bob_state,
    VersionCompared("alice", alice.version() == bob.version()),
  )
  add_routes(trace, decisions)
  let (_, decisions) = transition(
    alice_state,
    VersionCompared("bob", alice.version() == bob.version()),
  )
  add_routes(trace, decisions)
  inspect(scheduler.is_empty(), content="true")
  inspect(alice.text(), content=bob.text())
  inspect(alice.version() == bob.version(), content="true")
  trace
}

///|
fn container_concurrent_trace() -> Array[DecisionRoute] raise {
  let alice = try! @egw_container.Document::new("alice")
  let bob = try! @egw_container.Document::new("bob")
  let alice_node = try! alice.create_node(parent=@egw_container.root_id)
  let initial = try! alice.sync().export_all()
  let _ = try! bob.sync().apply(initial)
  let trace : Array[DecisionRoute] = []
  let (alice_state, decisions) = transition(
    State::empty(),
    PeerAvailable("bob"),
  )
  add_routes(trace, decisions)
  let (alice_state, decisions) = transition(
    alice_state,
    VersionCompared("bob", alice.version() == bob.version()),
  )
  add_routes(trace, decisions)
  let (bob_state, decisions) = transition(
    State::empty(),
    PeerAvailable("alice"),
  )
  add_routes(trace, decisions)
  let (bob_state, decisions) = transition(
    bob_state,
    VersionCompared("alice", bob.version() == alice.version()),
  )
  add_routes(trace, decisions)

  let scheduler : Scheduler[@egw_container.SyncMessage] = Scheduler::new()
  scheduler.disconnect("alice")
  scheduler.disconnect("bob")
  let (alice_state, decisions) = match scheduler.next() {
    TransportDisconnected(peer) =>
      transition(alice_state, PeerDisconnected(peer))
    _ => fail("expected bob transport disconnect")
  }
  inspect(decisions.length(), content="0")
  let (bob_state, decisions) = match scheduler.next() {
    TransportDisconnected(peer) => transition(bob_state, PeerDisconnected(peer))
    _ => fail("expected alice transport disconnect")
  }
  inspect(decisions.length(), content="0")

  try! alice.insert_text(alice_node, 0, "A")
  try! bob.insert_text(alice_node, 0, "B")
  let (_, decisions) = transition(alice_state, LocalCommitted)
  inspect(decisions.length(), content="0")
  let (_, decisions) = transition(bob_state, LocalCommitted)
  inspect(decisions.length(), content="0")

  scheduler.reconnect("alice")
  scheduler.reconnect("bob")
  let (alice_state, decisions) = match scheduler.next() {
    TransportReconnected(peer) => transition(alice_state, Reconnect(peer))
    _ => fail("expected bob transport reconnect")
  }
  add_routes(trace, decisions)
  let (bob_state, decisions) = match scheduler.next() {
    TransportReconnected(peer) => transition(bob_state, Reconnect(peer))
    _ => fail("expected alice transport reconnect")
  }
  add_routes(trace, decisions)

  let (bob_state, decisions) = transition(bob_state, FullSyncRequested("alice"))
  add_routes(trace, decisions)
  scheduler.deliver(try! bob.sync().export_all())
  let (alice_state, decisions) = transition(
    alice_state,
    FullSyncRequested("bob"),
  )
  add_routes(trace, decisions)
  scheduler.deliver(try! alice.sync().export_all())

  let bob_report = try! bob.sync().apply(scheduler.take_delivery())
  let (bob_state, decisions) = transition(
    bob_state,
    Applied("alice", container_observation(bob_report)),
  )
  add_routes(trace, decisions)
  let alice_report = try! alice.sync().apply(scheduler.take_delivery())
  let (alice_state, decisions) = transition(
    alice_state,
    Applied("bob", container_observation(alice_report)),
  )
  add_routes(trace, decisions)
  let (_, decisions) = transition(
    bob_state,
    VersionCompared("alice", alice.version() == bob.version()),
  )
  add_routes(trace, decisions)
  let (_, decisions) = transition(
    alice_state,
    VersionCompared("bob", alice.version() == bob.version()),
  )
  add_routes(trace, decisions)
  inspect(scheduler.is_empty(), content="true")
  inspect(alice.get_text(alice_node), content=bob.get_text(alice_node))
  inspect(alice.version() == bob.version(), content="true")
  trace
}

///|
test "offline concurrent edits use identical local-commit decisions" {
  let text_trace = text_concurrent_trace()
  let container_trace = container_concurrent_trace()
  expect_routes(text_trace, [
    route(DecisionKind::SendVersion, "bob"),
    route(DecisionKind::ReportRecovered, "bob"),
    route(DecisionKind::SendVersion, "alice"),
    route(DecisionKind::ReportRecovered, "alice"),
    route(DecisionKind::RequestFullSync, "bob"),
    route(DecisionKind::RequestFullSync, "alice"),
    route(DecisionKind::SendFullSync, "alice"),
    route(DecisionKind::SendFullSync, "bob"),
    route(DecisionKind::SendVersion, "alice"),
    route(DecisionKind::SendVersion, "bob"),
    route(DecisionKind::ReportRecovered, "alice"),
    route(DecisionKind::ReportRecovered, "bob"),
  ])
  expect_routes(container_trace, text_trace)
}
