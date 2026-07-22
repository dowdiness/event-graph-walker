///|
test "timeout retry metadata is bounded and fatal failures never retry" {
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(state, VersionCompared("source", false))
  expect_single(decisions, DecisionKind::RequestFullSync)
  let (state, decisions) = transition(state, RecoveryTimedOut("source"))
  expect_single(decisions, DecisionKind::RetryFullSync)
  let (state, decisions) = transition(state, VersionCompared("source", true))
  expect_recovered(decisions, "source")
  match state.peers.get("source") {
    Some(metadata) => {
      inspect(metadata.recovering, content="false")
      @debug.assert_eq(metadata.retry_count, 0)
    }
    None => fail("recovered peer metadata missing")
  }
  let (state, decisions) = transition(state, VersionCompared("source", false))
  expect_single(decisions, DecisionKind::RequestFullSync)
  let (state, decisions) = transition(state, RecoveryTimedOut("source"))
  expect_single(decisions, DecisionKind::RetryFullSync)
  let (state, decisions) = transition(state, RecoveryTimedOut("source"))
  expect_single(decisions, DecisionKind::RetryFullSync)
  let (state, decisions) = transition(state, RecoveryTimedOut("source"))
  expect_single(decisions, DecisionKind::ReportRecoveryExhausted)
  match state.peers.get("source") {
    Some(metadata) => {
      inspect(metadata.shell_exhausted, content="true")
      @debug.assert_eq(metadata.retry_count, 2)
    }
    None => fail("exhausted peer metadata missing")
  }
  let exhausted_events = [
    VersionCompared("source", false),
    Applied("source", @peer_sync.ApplyDisposition(1)),
    Failed(
      "source",
      failure_disposition(
        @sync.Failure::MissingDependency(replica_id="late", sequence=1),
      ),
    ),
    FullSyncRequested("source"),
    Reconnect("source"),
    LocalCommitted,
  ]
  exhausted_events.each(event => {
    let (next, decisions) = transition(state, event)
    inspect(decisions.length(), content="0")
    match next.peers.get("source") {
      Some(metadata) => inspect(metadata.shell_exhausted, content="true")
      None => fail("shell-exhausted peer was removed")
    }
  })
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
    Failed("source", failure_disposition(failure)),
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
    Applied("source", @peer_sync.ApplyDisposition(0)),
  )
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(state, VersionCompared("source", false))
  expect_single(decisions, DecisionKind::RequestFullSync)
  let (state, decisions) = transition(
    state,
    Applied("source", @peer_sync.ApplyDisposition(0)),
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
      inspect(metadata.recovering, content="true")
      @debug.assert_eq(metadata.retry_count, 2)
    }
    None => fail("admitted peer metadata missing")
  }
  let (state, decisions) = transition(state, PeerAvailable("source"))
  inspect(decisions.length(), content="0")
  match state.peers.get("source") {
    Some(metadata) => {
      inspect(metadata.recovering, content="true")
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
      inspect(metadata.connected is false, content="true")
      inspect(metadata.recovering, content="true")
      @debug.assert_eq(metadata.retry_count, 2)
    }
    None => fail("disconnected peer metadata was recreated")
  }
  let (state, decisions) = transition(state, Reconnect("source"))
  expect_single(decisions, DecisionKind::RequestFullSync)
  match state.peers.get("source") {
    Some(metadata) => {
      inspect(metadata.recovering, content="true")
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
  expect_routes(decisions.map(decision_route), [
    route(DecisionKind::SendIncrementalSync, "alice"),
    route(DecisionKind::SendIncrementalSync, "bob"),
  ])
}

///|
test "escalated peers are terminal for ordinary events" {
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let fatal = @sync.Failure::MalformedMessage(detail="fatal")
  let (state, decisions) = transition(
    state,
    Failed("source", failure_disposition(fatal)),
  )
  expect_escalated(decisions, "source")
  let events = [
    VersionCompared("source", false),
    Applied("source", @peer_sync.ApplyDisposition(1)),
    Failed(
      "source",
      failure_disposition(
        @sync.Failure::MissingDependency(replica_id="late", sequence=1),
      ),
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
        inspect(metadata.terminal, content="true")
        inspect(metadata.recovering is false, content="true")
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
    Applied("source", @peer_sync.ApplyDisposition(0)),
    Failed(
      "source",
      failure_disposition(
        @sync.Failure::MissingDependency(replica_id="late", sequence=1),
      ),
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
  let (state, decisions) = transition(State::empty(), PeerAvailable("peer"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(state, VersionCompared("peer", true))
  expect_recovered(decisions, "peer")

  let scheduler : Scheduler[String] = Scheduler::new()
  scheduler.disconnect("peer")
  let (state, decisions) = match scheduler.next() {
    TransportDisconnected(peer) => transition(state, PeerDisconnected(peer))
    _ => fail("expected disconnect")
  }
  inspect(decisions.length(), content="0")

  scheduler.delay("delayed")
  scheduler.duplicate("duplicate")
  scheduler.deliver("dropped")
  scheduler.drop_next()
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
  let (state, decisions) = match scheduler.next() {
    TransportReconnected(peer) => transition(state, Reconnect(peer))
    _ => fail("expected reconnect")
  }
  expect_routes(decisions.map(decision_route), [
    route(DecisionKind::RequestFullSync, "peer"),
  ])

  scheduler.peer_left("peer")
  let state = match scheduler.next() {
    PeerLeft(peer) => {
      let (state, decisions) = transition(state, PeerDeparted(peer))
      inspect(decisions.length(), content="0")
      state
    }
    _ => fail("expected peer left")
  }
  expect_peer_removed(state, "peer")
  inspect(scheduler.is_empty(), content="true")
}

///|
test "peer departure removes metadata but not actual EGW pending" {
  let source = try! @egw_text.TextState::new("source")
  try! source.insert(@egw_text.Pos::at(0), "A")
  let baseline = source.version()
  try! source.insert(@egw_text.Pos::at(1), "B")
  let future = try! source.sync().export_since(baseline)
  let receiver = try! @egw_text.TextState::new("receiver")
  let pending = try! receiver.sync().apply(future)
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (state, decisions) = transition(
    state,
    Applied("source", text_observation(pending)),
  )
  expect_single(decisions, DecisionKind::RequestFullSync)
  let scheduler : Scheduler[@egw_text.SyncMessage] = Scheduler::new()
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

  let csource = try! @egw_container.Document::new("source")
  let _ = try! csource.create_node(parent=@egw_container.root_id)
  let cbaseline = csource.version()
  let _ = try! csource.create_node(parent=@egw_container.root_id)
  let cfuture = try! csource.sync().export_since(cbaseline)
  let creceiver = try! @egw_container.Document::new("receiver")
  let cpending = try! creceiver.sync().apply(cfuture)
  let (cstate, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (cstate, decisions) = transition(
    cstate,
    Applied("source", container_observation(cpending)),
  )
  expect_single(decisions, DecisionKind::RequestFullSync)
  let cscheduler : Scheduler[@egw_container.SyncMessage] = Scheduler::new()
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
