///|
fn assert_fatal_failure(failure : @sync.Failure) -> Unit raise {
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (_, decisions) = transition(
    state,
    Failed("source", failure_disposition(failure)),
  )
  expect_escalated(decisions, "source")
}

///|
fn expect_terminal_text(error : @egw_text.TextError) -> Unit raise {
  match @peer_sync_text.classify_error(error) {
    Some(@peer_sync.FailureDisposition::Terminal) => ()
    _ => fail("expected terminal text peer-sync failure")
  }
}

///|
fn expect_terminal_container(
  error : @egw_container.DocumentError,
) -> Unit raise {
  match @peer_sync_container.classify_error(error) {
    Some(@peer_sync.FailureDisposition::Terminal) => ()
    _ => fail("expected terminal container peer-sync failure")
  }
}

///|
test "text malformed invalid conflict and limit failures never request" {
  inspect(
    text_failure(@egw_text.TextError::EmptyReplicaId) is None,
    content="true",
  )
  let malformed = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":1}]}"
  let malformed_message = try! @egw_text.SyncMessage::from_json_string(
    malformed,
  )
  let malformed_receiver = try! @egw_text.TextState::new("malformed-receiver")
  try malformed_receiver.sync().apply(malformed_message) catch {
    error => {
      expect_terminal_text(error)
      let failure = match error {
        @egw_text.TextError::SyncFailed(failure) => failure
        _ => fail("expected text malformed sync failure")
      }
      match failure {
        @sync.Failure::MalformedMessage(_) => ()
        _ => fail("expected malformed classification")
      }
      assert_fatal_failure(failure)
    }
  } noraise {
    _ => fail("malformed fixture must fail")
  }

  let invalid = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":0}]}"
  try @egw_text.SyncMessage::from_json_string(invalid) catch {
    error => {
      expect_terminal_text(error)
      let failure = match error {
        @egw_text.TextError::SyncFailed(failure) => failure
        _ => fail("expected text invalid sync failure")
      }
      match failure {
        @sync.Failure::InvalidContent(_) => ()
        _ => fail("expected invalid-content classification")
      }
      assert_fatal_failure(failure)
    }
  } noraise {
    _ => fail("invalid fixture must fail")
  }

  let receiver = try! @egw_text.TextState::new("receiver")
  let source = try! @egw_text.TextState::new("alice")
  try! source.insert(@egw_text.Pos::at(0), "A")
  let first = try! source.sync().export_all()
  let _ = try! receiver.sync().apply(first)
  let conflict = try! @egw_text.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":0}]}",
  )
  try receiver.sync().apply(conflict) catch {
    error => {
      expect_terminal_text(error)
      let failure = match error {
        @egw_text.TextError::SyncFailed(failure) => failure
        _ => fail("expected text conflict sync failure")
      }
      match failure {
        @sync.Failure::ConflictingIdentity(_) => ()
        _ => fail("expected conflicting-identity classification")
      }
      assert_fatal_failure(failure)
    }
  } noraise {
    _ => fail("conflict fixture must fail")
  }

  let limited = try! @egw_text.TextState::new_with_sync_limits(
    "limited",
    try! @sync.Limits::Limits(max_decoded_operations=0),
  )
  try limited.sync().apply(first) catch {
    error => {
      expect_terminal_text(error)
      let failure = match error {
        @egw_text.TextError::SyncFailed(failure) => failure
        _ => fail("expected text limit sync failure")
      }
      match failure {
        @sync.Failure::LimitExceeded(_) => ()
        _ => fail("expected limit classification")
      }
      assert_fatal_failure(failure)
    }
  } noraise {
    _ => fail("limit fixture must fail")
  }
}

///|
test "container malformed invalid conflict and limit failures never request" {
  inspect(
    container_failure(@egw_container.DocumentError::EmptyReplicaId) is None,
    content="true",
  )
  try @egw_container.SyncMessage::from_json_string("[]") catch {
    error => {
      expect_terminal_container(error)
      let failure = match error {
        @egw_container.DocumentError::SyncFailed(failure) => failure
        _ => fail("expected container malformed sync failure")
      }
      match failure {
        @sync.Failure::MalformedMessage(_) => ()
        _ => fail("expected malformed classification")
      }
      assert_fatal_failure(failure)
    }
  } noraise {
    _ => fail("container malformed fixture must fail")
  }

  let invalid_message = try! @egw_container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"bob\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"bob\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}}]}",
  )
  let invalid_receiver = try! @egw_container.Document::new("invalid-receiver")
  try invalid_receiver.sync().apply(invalid_message) catch {
    error => {
      expect_terminal_container(error)
      let failure = match error {
        @egw_container.DocumentError::SyncFailed(failure) => failure
        _ => fail("expected container invalid sync failure")
      }
      match failure {
        @sync.Failure::InvalidContent(_) => ()
        _ => fail("expected invalid-content classification")
      }
      assert_fatal_failure(failure)
    }
  } noraise {
    _ => fail("container invalid fixture must fail")
  }

  let conflict_receiver = try! @egw_container.Document::new("conflict-receiver")
  let conflict_first = try! @egw_container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}}]}",
  )
  let _ = try! conflict_receiver.sync().apply(conflict_first)
  let conflict_message = try! @egw_container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"property\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"key\":\"title\",\"value\":\"fork\"}}]}",
  )
  try conflict_receiver.sync().apply(conflict_message) catch {
    error => {
      expect_terminal_container(error)
      let failure = match error {
        @egw_container.DocumentError::SyncFailed(failure) => failure
        _ => fail("expected container conflict sync failure")
      }
      match failure {
        @sync.Failure::ConflictingIdentity(_) => ()
        _ => fail("expected conflicting-identity classification")
      }
      assert_fatal_failure(failure)
    }
  } noraise {
    _ => fail("container conflict fixture must fail")
  }

  let limit_source = try! @egw_container.Document::new("limit-source")
  let _ = try! limit_source.create_node(parent=@egw_container.root_id)
  let limit_json = (try! limit_source.sync().export_all()).to_json_string()
  let limit_receiver = try! @egw_container.Document::new_with_sync_limits(
    "limit-receiver",
    try! @sync.Limits::Limits(max_encoded_bytes=limit_json.length() - 1),
  )
  let limit_message = try! limit_receiver.sync().decode_json(limit_json)
  try limit_receiver.sync().apply(limit_message) catch {
    error => {
      expect_terminal_container(error)
      let failure = match error {
        @egw_container.DocumentError::SyncFailed(failure) => failure
        _ => fail("expected container limit sync failure")
      }
      match failure {
        @sync.Failure::LimitExceeded(_) => ()
        _ => fail("expected limit classification")
      }
      assert_fatal_failure(failure)
    }
  } noraise {
    _ => fail("container limit fixture must fail")
  }
}
