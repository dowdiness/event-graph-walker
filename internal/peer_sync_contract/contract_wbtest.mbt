///|
/// Private test-only scheduler. It contains only pre-apply envelopes or
/// transport lifecycle events; causal pending state remains in each EGW session.
priv enum Scheduled[T] {
  Deliver(T)
  TransportDisconnected(String)
  TransportReconnected(String)
  PeerLeft(String)
}

///|
priv struct Scheduler[T] {
  ready : Array[Scheduled[T]]
  delayed : Array[Scheduled[T]]
}

///|
fn[T] Scheduler::new() -> Scheduler[T] {
  { ready: [], delayed: [] }
}

///|
fn[T] Scheduler::deliver(self : Scheduler[T], envelope : T) -> Unit {
  self.ready.push(Deliver(envelope))
}

///|
fn[T] Scheduler::delay(self : Scheduler[T], envelope : T) -> Unit {
  self.delayed.push(Deliver(envelope))
}

///|
fn[T] Scheduler::duplicate(self : Scheduler[T], envelope : T) -> Unit {
  self.ready.push(Deliver(envelope))
  self.ready.push(Deliver(envelope))
}

///|
fn[T] Scheduler::drop_next(self : Scheduler[T]) -> Unit {
  let _ = self.ready.pop().unwrap()
}

///|
fn[T] Scheduler::release_delayed(self : Scheduler[T]) -> Unit {
  self.delayed.each(event => self.ready.push(event))
  self.delayed.clear()
}

///|
fn[T] Scheduler::disconnect(self : Scheduler[T], peer : String) -> Unit {
  self.ready.push(TransportDisconnected(peer))
}

///|
fn[T] Scheduler::reconnect(self : Scheduler[T], peer : String) -> Unit {
  self.ready.push(TransportReconnected(peer))
}

///|
fn[T] Scheduler::peer_left(self : Scheduler[T], peer : String) -> Unit {
  self.ready.push(PeerLeft(peer))
}

///|
fn[T] Scheduler::next(self : Scheduler[T]) -> Scheduled[T] {
  self.ready.pop().unwrap()
}

///|
fn[T] Scheduler::take_delivery(self : Scheduler[T]) -> T raise {
  match self.next() {
    Deliver(envelope) => envelope
    _ => fail("scheduler next item is not a delivery")
  }
}

///|
fn[T] Scheduler::is_empty(self : Scheduler[T]) -> Bool {
  self.ready.length() == 0 && self.delayed.length() == 0
}

///|
priv enum DecisionKind {
  SendVersion
  RequestFullSync
  SendFullSync
  SendIncrementalSync
  ReportRecovered
  RetryFullSync
  ReportRecoveryExhausted
  ReportFailure
  Escalate
} derive(Eq)

///|
fn decision_kind(decision : Decision) -> DecisionKind {
  match decision {
    SendVersion(peer) => {
      let _ = peer.length()
      DecisionKind::SendVersion
    }
    RequestFullSync(peer) => {
      let _ = peer.length()
      DecisionKind::RequestFullSync
    }
    SendFullSync(peer) => {
      let _ = peer.length()
      DecisionKind::SendFullSync
    }
    SendIncrementalSync(peer) => {
      let _ = peer.length()
      DecisionKind::SendIncrementalSync
    }
    ReportRecovered(peer) => {
      let _ = peer.length()
      DecisionKind::ReportRecovered
    }
    RetryFullSync(peer) => {
      let _ = peer.length()
      DecisionKind::RetryFullSync
    }
    ReportRecoveryExhausted(peer) => {
      let _ = peer.length()
      DecisionKind::ReportRecoveryExhausted
    }
    ReportFailure(_, _) => DecisionKind::ReportFailure
    Escalate(_, _) => DecisionKind::Escalate
  }
}

///|
fn add_kinds(trace : Array[DecisionKind], decisions : Array[Decision]) -> Unit {
  decisions.each(decision => trace.push(decision_kind(decision)))
}

///|
fn expect_kinds(
  actual : Array[DecisionKind],
  expected : Array[DecisionKind],
) -> Unit raise {
  @debug.assert_eq(actual.length(), expected.length())
  for i = 0; i < expected.length(); i = i + 1 {
    inspect(actual[i] == expected[i], content="true")
  }
}

///|
fn expect_observation(
  observation : Observation,
  applied : Int,
  duplicates : Int,
  pending : Int,
) -> Unit raise {
  @debug.assert_eq(observation.applied, applied)
  @debug.assert_eq(observation.duplicates, duplicates)
  @debug.assert_eq(observation.pending, pending)
}

///|
fn expect_single(
  decisions : Array[Decision],
  expected : DecisionKind,
) -> Unit raise {
  @debug.assert_eq(decisions.length(), 1)
  inspect(decision_kind(decisions[0]) == expected, content="true")
}

///|
fn expect_no_request_or_retry(decisions : Array[Decision]) -> Unit raise {
  decisions.each(decision => {
    match decision {
      RequestFullSync(_) | RetryFullSync(_) =>
        fail("fatal/duplicate path requested or retried full sync")
      _ => ()
    }
  })
}

///|
fn expect_recovered(decisions : Array[Decision], peer : String) -> Unit raise {
  @debug.assert_eq(decisions.length(), 1)
  match decisions[0] {
    ReportRecovered(actual) => inspect(actual, content=peer)
    _ => fail("expected recovered report")
  }
}

///|
fn expect_escalated(decisions : Array[Decision], peer : String) -> Unit raise {
  @debug.assert_eq(decisions.length(), 2)
  match decisions[0] {
    ReportFailure(actual, failure) => {
      inspect(actual, content=peer)
      let _ = @sync.Failure::to_string(failure)
    }
    _ => fail("expected failure report")
  }
  match decisions[1] {
    Escalate(actual, failure) => {
      inspect(actual, content=peer)
      let _ = @sync.Failure::to_string(failure)
    }
    _ => fail("expected escalation")
  }
  expect_no_request_or_retry(decisions)
}

///|
fn expect_peer_removed(state : State, peer : String) -> Unit raise {
  inspect(state.peers.get(peer) is None, content="true")
}
