///|
test "initial handshake and recovery policy" {
  let (state, decisions) = @peer_sync.State::handshake_started(
    @peer_sync.State::State(),
  )
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    @peer_sync.Decision::SendVersion => ()
    _ => fail("expected version decision")
  }
  let (state, decisions) = @peer_sync.State::version_compared(state, false)
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    @peer_sync.Decision::RequestFullSync => ()
    _ => fail("expected full-sync request")
  }
  let (_, decisions) = @peer_sync.State::full_sync_requested(state)
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    @peer_sync.Decision::SendFullSync => ()
    _ => fail("expected full-sync response")
  }
}

///|
test "causal and failure dispositions select policy decisions" {
  let (state, decisions) = @peer_sync.State::applied(
    @peer_sync.State::State(),
    ApplyDisposition(1),
  )
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    @peer_sync.Decision::RequestFullSync => ()
    _ => fail("expected pending recovery request")
  }
  let (_, decisions) = @peer_sync.State::applied(state, ApplyDisposition(0))
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    @peer_sync.Decision::SendVersion => ()
    _ => fail("expected version acknowledgement")
  }

  let (state, decisions) = @peer_sync.State::failed(
    @peer_sync.State::State(),
    @peer_sync.FailureDisposition::FailureDisposition(
      @sync.Failure::MissingDependency(replica_id="peer", sequence=1),
    ),
  )
  @debug.assert_eq(decisions.length(), 2)
  match decisions[0] {
    @peer_sync.Decision::ReportFailure => ()
    _ => fail("expected failure report")
  }
  match decisions[1] {
    @peer_sync.Decision::RequestFullSync => ()
    _ => fail("expected recoverable request")
  }
  let (_, decisions) = @peer_sync.State::failed(
    state,
    @peer_sync.FailureDisposition::FailureDisposition(
      @sync.Failure::MalformedMessage(detail="bad"),
    ),
  )
  @debug.assert_eq(decisions.length(), 2)
  match decisions[0] {
    @peer_sync.Decision::ReportFailure => ()
    _ => fail("expected terminal failure report")
  }
  match decisions[1] {
    @peer_sync.Decision::Escalate => ()
    _ => fail("expected escalation")
  }
}

///|
test "full recovery restarts an outstanding cycle" {
  let (state, decisions) = @peer_sync.State::full_recovery_required(
    @peer_sync.State::State(),
  )
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    @peer_sync.Decision::RequestFullSync => ()
    _ => fail("expected recovery request")
  }
  let (_, decisions) = @peer_sync.State::full_recovery_required(state)
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    @peer_sync.Decision::RequestFullSync => ()
    _ => fail("expected recovery restart")
  }
}

///|
test "decision arrays are fresh caller-owned values" {
  let state = @peer_sync.State::State()
  let (_, first) = @peer_sync.State::handshake_started(state)
  let (_, second) = @peer_sync.State::handshake_started(state)
  Array::clear(first)
  @debug.assert_eq(second.length(), 1)
  match second[0] {
    @peer_sync.Decision::SendVersion => ()
    _ => fail("expected second transition to retain its decision")
  }
}
