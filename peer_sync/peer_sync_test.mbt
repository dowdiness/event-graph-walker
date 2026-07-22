///|
test "initial handshake and recovery policy" {
  let (state, decisions) = State::handshake_started(State::State())
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    Decision::SendVersion => ()
    _ => fail("expected version decision")
  }
  let (state, decisions) = State::version_compared(state, false)
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    Decision::RequestFullSync => ()
    _ => fail("expected full-sync request")
  }
  let (_, decisions) = State::full_sync_requested(state)
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    Decision::SendFullSync => ()
    _ => fail("expected full-sync response")
  }
}

///|
test "causal and failure dispositions select policy decisions" {
  let (state, decisions) = State::applied(State::State(), ApplyDisposition(1))
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    Decision::RequestFullSync => ()
    _ => fail("expected pending recovery request")
  }
  let (_, decisions) = State::applied(state, ApplyDisposition(0))
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    Decision::SendVersion => ()
    _ => fail("expected version acknowledgement")
  }

  let (state, decisions) = State::failed(
    State::State(),
    FailureDisposition::FailureDisposition(
      @sync.Failure::MissingDependency(replica_id="peer", sequence=1),
    ),
  )
  @debug.assert_eq(decisions.length(), 2)
  match decisions[0] {
    Decision::ReportFailure => ()
    _ => fail("expected failure report")
  }
  match decisions[1] {
    Decision::RequestFullSync => ()
    _ => fail("expected recoverable request")
  }
  let (_, decisions) = State::failed(
    state,
    FailureDisposition::FailureDisposition(
      @sync.Failure::MalformedMessage(detail="bad"),
    ),
  )
  @debug.assert_eq(decisions.length(), 2)
  match decisions[0] {
    Decision::ReportFailure => ()
    _ => fail("expected terminal failure report")
  }
  match decisions[1] {
    Decision::Escalate => ()
    _ => fail("expected escalation")
  }
}

///|
test "full recovery restarts an outstanding cycle" {
  let (state, decisions) = State::full_recovery_required(State::State())
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    Decision::RequestFullSync => ()
    _ => fail("expected recovery request")
  }
  let (_, decisions) = State::full_recovery_required(state)
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    Decision::RequestFullSync => ()
    _ => fail("expected recovery restart")
  }
}

///|
test "decision arrays are fresh caller-owned values" {
  let state = State::State()
  let (_, first) = State::handshake_started(state)
  let (_, second) = State::handshake_started(state)
  Array::clear(first)
  @debug.assert_eq(second.length(), 1)
  match second[0] {
    Decision::SendVersion => ()
    _ => fail("expected second transition to retain its decision")
  }
}
