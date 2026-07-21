///|
test "timeout retry metadata is bounded and fatal failures never retry" {
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(state, VersionCompared("source", false))
  expect_single(decisions, DecisionKind::RequestFullSync)
  let (state, decisions) = transition(state, RecoveryTimedOut("source"))
  expect_single(decisions, DecisionKind::RetryFullSync)
  let (state, decisions) = transition(state, RecoveryTimedOut("source"))
  expect_single(decisions, DecisionKind::RetryFullSync)
  let (state, decisions) = transition(state, RecoveryTimedOut("source"))
  expect_single(decisions, DecisionKind::ReportRecoveryExhausted)
  let (_, decisions) = transition(state, RecoveryTimedOut("source"))
  inspect(decisions.length(), content="0")

  let failure = @sync.Failure::MalformedMessage(detail="fatal")
  let (fatal_state, decisions) = transition(
    State::empty(),
    PeerAvailable("source"),
  )
  expect_single(decisions, DecisionKind::SendVersion)
  let (fatal_state, decisions) = transition(
    fatal_state,
    Failed("source", failure),
  )
  expect_escalated(decisions, "source")
  let (_, decisions) = transition(fatal_state, RecoveryTimedOut("source"))
  inspect(decisions.length(), content="0")
}

///|
test "applied acknowledgement cannot recover without a later equal version" {
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(
    state,
    Applied("source", { applied: 4, duplicates: 0, pending: 0 }),
  )
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(state, VersionCompared("source", false))
  expect_single(decisions, DecisionKind::RequestFullSync)
  let (state, decisions) = transition(
    state,
    Applied("source", { applied: 0, duplicates: 1, pending: 0 }),
  )
  expect_single(decisions, DecisionKind::SendVersion)
  let (_, decisions) = transition(state, VersionCompared("source", true))
  expect_recovered(decisions, "source")
}

///|
test "duplicate peer availability preserves recovery metadata" {
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(state, VersionCompared("source", false))
  expect_single(decisions, DecisionKind::RequestFullSync)
  let (state, decisions) = transition(state, RecoveryTimedOut("source"))
  expect_single(decisions, DecisionKind::RetryFullSync)
  let (state, decisions) = transition(state, RecoveryTimedOut("source"))
  expect_single(decisions, DecisionKind::RetryFullSync)
  match state.peers.get("source") {
    Some(metadata) => {
      inspect(metadata.phase is Recovering, content="true")
      inspect(metadata.full_sync_requested, content="true")
      @debug.assert_eq(metadata.retry_count, 2)
    }
    None => fail("admitted peer metadata missing")
  }
  let (state, decisions) = transition(state, PeerAvailable("source"))
  inspect(decisions.length(), content="0")
  match state.peers.get("source") {
    Some(metadata) => {
      inspect(metadata.phase is Recovering, content="true")
      inspect(metadata.full_sync_requested, content="true")
      @debug.assert_eq(metadata.retry_count, 2)
    }
    None => fail("duplicate admission removed peer metadata")
  }
  let (state, decisions) = transition(state, PeerDisconnected("source"))
  inspect(decisions.length(), content="0")
  let (state, decisions) = transition(state, PeerAvailable("source"))
  inspect(decisions.length(), content="0")
  match state.peers.get("source") {
    Some(metadata) => {
      inspect(metadata.phase is Disconnected, content="true")
      inspect(metadata.full_sync_requested, content="true")
      @debug.assert_eq(metadata.retry_count, 2)
    }
    None => fail("disconnected peer metadata was recreated")
  }
  let (state, decisions) = transition(state, Reconnect("source"))
  expect_single(decisions, DecisionKind::RequestFullSync)
  match state.peers.get("source") {
    Some(metadata) => {
      inspect(metadata.phase is Recovering, content="true")
      inspect(metadata.full_sync_requested, content="true")
      @debug.assert_eq(metadata.retry_count, 0)
    }
    None => fail("reconnected peer metadata missing")
  }
}

///|
test "local commits fan out to every connected peer" {
  let (state, decisions) = transition(State::empty(), PeerAvailable("alice"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(state, VersionCompared("alice", true))
  expect_single(decisions, DecisionKind::ReportRecovered)
  let (state, decisions) = transition(state, PeerAvailable("bob"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(state, VersionCompared("bob", true))
  expect_single(decisions, DecisionKind::ReportRecovered)
  let (_, decisions) = transition(state, LocalCommitted)
  expect_kinds(decisions.map(decision_kind), [
    DecisionKind::SendIncrementalSync,
    DecisionKind::SendIncrementalSync,
  ])
}

///|
test "escalated peers are terminal for ordinary events" {
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let fatal = @sync.Failure::MalformedMessage(detail="fatal")
  let (state, decisions) = transition(state, Failed("source", fatal))
  expect_escalated(decisions, "source")
  let events = [
    VersionCompared("source", false),
    Applied("source", { applied: 1, duplicates: 0, pending: 1 }),
    Failed(
      "source",
      @sync.Failure::MissingDependency(replica_id="late", sequence=1),
    ),
    RecoveryTimedOut("source"),
    FullSyncRequested("source"),
    PeerDisconnected("source"),
    Reconnect("source"),
    LocalCommitted,
    PeerAvailable("source"),
  ]
  events.each(event => {
    let (next, decisions) = transition(state, event)
    inspect(decisions.length(), content="0")
    match next.peers.get("source") {
      Some(metadata) => {
        inspect(metadata.phase is Escalated, content="true")
        inspect(metadata.full_sync_requested is false, content="true")
        @debug.assert_eq(metadata.retry_count, 0)
      }
      None => fail("ordinary event removed escalated peer")
    }
  })
}

///|
test "departed peers ignore late reducer events" {
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(state, PeerDeparted("source"))
  inspect(decisions.length(), content="0")
  expect_peer_removed(state, "source")
  let events = [
    VersionCompared("source", false),
    Applied("source", { applied: 1, duplicates: 0, pending: 0 }),
    Failed(
      "source",
      @sync.Failure::MissingDependency(replica_id="late", sequence=1),
    ),
    Reconnect("source"),
  ]
  events.each(event => {
    let (next, decisions) = transition(state, event)
    inspect(decisions.length(), content="0")
    expect_peer_removed(next, "source")
  })
}

///|
test "scheduler performs delay duplicate drop and lifecycle events" {
  let scheduler : Scheduler[String] = Scheduler::new()
  scheduler.delay("delayed")
  scheduler.duplicate("duplicate")
  scheduler.deliver("dropped")
  scheduler.drop_next()
  scheduler.disconnect("peer")
  match scheduler.next() {
    TransportDisconnected(peer) => inspect(peer, content="peer")
    _ => fail("expected disconnect")
  }
  match scheduler.take_delivery() {
    _ => ()
  }
  match scheduler.take_delivery() {
    _ => ()
  }
  scheduler.release_delayed()
  inspect(scheduler.take_delivery(), content="delayed")
  inspect(scheduler.is_empty(), content="true")
  scheduler.reconnect("peer")
  match scheduler.next() {
    TransportReconnected(peer) => inspect(peer, content="peer")
    _ => fail("expected reconnect")
  }
  scheduler.peer_left("peer")
  match scheduler.next() {
    PeerLeft(peer) => inspect(peer, content="peer")
    _ => fail("expected peer left")
  }
  inspect(scheduler.is_empty(), content="true")
}

///|
test "peer departure removes metadata but not actual EGW pending" {
  let source = try! @text.TextState::new("source")
  try! source.insert(@text.Pos::at(0), "A")
  let baseline = source.version()
  try! source.insert(@text.Pos::at(1), "B")
  let future = try! source.sync().export_since(baseline)
  let receiver = try! @text.TextState::new("receiver")
  let pending = try! receiver.sync().apply(future)
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(
    state,
    Applied("source", text_observation(pending)),
  )
  expect_single(decisions, DecisionKind::RequestFullSync)
  let scheduler : Scheduler[@text.SyncMessage] = Scheduler::new()
  scheduler.peer_left("source")
  match scheduler.next() {
    PeerLeft(peer) => {
      let (state, decisions) = transition(state, PeerDeparted(peer))
      expect_peer_removed(state, peer)
      inspect(decisions.length(), content="0")
    }
    _ => fail("expected peer-left event")
  }
  inspect(receiver.sync().pending_sync_count(), content="1")
  inspect(scheduler.is_empty(), content="true")

  let csource = try! @container.Document::new("source")
  let _ = try! csource.create_node(parent=@container.root_id)
  let cbaseline = csource.version()
  let _ = try! csource.create_node(parent=@container.root_id)
  let cfuture = try! csource.sync().export_since(cbaseline)
  let creceiver = try! @container.Document::new("receiver")
  let cpending = try! creceiver.sync().apply(cfuture)
  let (cstate, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (cstate, decisions) = transition(
    cstate,
    Applied("source", container_observation(cpending)),
  )
  expect_single(decisions, DecisionKind::RequestFullSync)
  let cscheduler : Scheduler[@container.SyncMessage] = Scheduler::new()
  cscheduler.peer_left("source")
  match cscheduler.next() {
    PeerLeft(peer) => {
      let (cstate, decisions) = transition(cstate, PeerDeparted(peer))
      expect_peer_removed(cstate, peer)
      inspect(decisions.length(), content="0")
    }
    _ => fail("expected peer-left event")
  }
  inspect(creceiver.sync().pending_sync_count(), content="1")
  inspect(cscheduler.is_empty(), content="true")
}
