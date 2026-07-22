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
priv struct DecisionRoute {
  kind : DecisionKind
  peer : String
}

///|
fn route(kind : DecisionKind, peer : String) -> DecisionRoute {
  { kind, peer }
}

///|
fn decision_route(decision : Decision) -> DecisionRoute {
  match decision {
    SendVersion(peer) => route(DecisionKind::SendVersion, peer)
    RequestFullSync(peer) => route(DecisionKind::RequestFullSync, peer)
    SendFullSync(peer) => route(DecisionKind::SendFullSync, peer)
    SendIncrementalSync(peer) => route(DecisionKind::SendIncrementalSync, peer)
    ReportRecovered(peer) => route(DecisionKind::ReportRecovered, peer)
    RetryFullSync(peer) => route(DecisionKind::RetryFullSync, peer)
    ReportRecoveryExhausted(peer) =>
      route(DecisionKind::ReportRecoveryExhausted, peer)
    ReportFailure(peer) => route(DecisionKind::ReportFailure, peer)
    Escalate(peer) => route(DecisionKind::Escalate, peer)
  }
}

///|
fn add_routes(
  trace : Array[DecisionRoute],
  decisions : Array[Decision],
) -> Unit {
  decisions.each(decision => trace.push(decision_route(decision)))
}

///|
fn expect_routes(
  actual : Array[DecisionRoute],
  expected : Array[DecisionRoute],
) -> Unit raise {
  @debug.assert_eq(actual.length(), expected.length())
  for i = 0; i < expected.length(); i = i + 1 {
    if actual[i].kind != expected[i].kind {
      fail("route kind mismatch at index " + i.to_string())
    }
    if actual[i].peer != expected[i].peer {
      fail(
        "route peer mismatch at index " +
        i.to_string() +
        ": expected " +
        expected[i].peer +
        ", actual " +
        actual[i].peer,
      )
    }
  }
}

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
    ReportFailure(_) => DecisionKind::ReportFailure
    Escalate(_) => DecisionKind::Escalate
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
    ReportFailure(actual) => inspect(actual, content=peer)
    _ => fail("expected failure report")
  }
  match decisions[1] {
    Escalate(actual) => inspect(actual, content=peer)
    _ => fail("expected escalation")
  }
  expect_no_request_or_retry(decisions)
}

///|
fn expect_peer_removed(state : State, peer : String) -> Unit raise {
  inspect(state.peers.get(peer) is None, content="true")
}
