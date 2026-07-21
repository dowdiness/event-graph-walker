///|
fn assert_fatal_failure(failure : @sync.Failure) -> Unit raise {
  let (state, decisions) = transition(State::empty(), PeerAvailable("source"))
  expect_single(decisions, DecisionKind::SendVersion)
  let (_, decisions) = transition(state, Failed("source", failure))
  expect_escalated(decisions, "source")
}

///|
test "text malformed invalid conflict and limit failures never request" {
  inspect(text_failure(@text.TextError::EmptyReplicaId) is None, content="true")
  let malformed = "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null},{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":1}]}"
  let malformed_message = try! @text.SyncMessage::from_json_string(malformed)
  let malformed_receiver = try! @text.TextState::new("malformed-receiver")
  try malformed_receiver.sync().apply(malformed_message) catch {
    error => {
      let failure = match text_failure(error) {
        Some(failure) => failure
        None => fail("expected text malformed sync failure")
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
  try @text.SyncMessage::from_json_string(invalid) catch {
    error => {
      let failure = match text_failure(error) {
        Some(failure) => failure
        None => fail("expected text invalid sync failure")
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

  let receiver = try! @text.TextState::new("receiver")
  let source = try! @text.TextState::new("alice")
  try! source.insert(@text.Pos::at(0), "A")
  let first = try! source.sync().export_all()
  let _ = try! receiver.sync().apply(first)
  let conflict = try! @text.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":0}]}",
  )
  try receiver.sync().apply(conflict) catch {
    error => {
      let failure = match text_failure(error) {
        Some(failure) => failure
        None => fail("expected text conflict sync failure")
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

  let limited = try! @text.TextState::new_with_sync_limits(
    "limited",
    try! @sync.Limits::Limits(max_decoded_operations=0),
  )
  try limited.sync().apply(first) catch {
    error => {
      let failure = match text_failure(error) {
        Some(failure) => failure
        None => fail("expected text limit sync failure")
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
    container_failure(@container.DocumentError::EmptyReplicaId) is None,
    content="true",
  )
  try @container.SyncMessage::from_json_string("[]") catch {
    error => {
      let failure = match container_failure(error) {
        Some(failure) => failure
        None => fail("expected container malformed sync failure")
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

  let invalid_message = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"bob\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"bob\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}}]}",
  )
  let invalid_receiver = try! @container.Document::new("invalid-receiver")
  try invalid_receiver.sync().apply(invalid_message) catch {
    error => {
      let failure = match container_failure(error) {
        Some(failure) => failure
        None => fail("expected container invalid sync failure")
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

  let conflict_receiver = try! @container.Document::new("conflict-receiver")
  let conflict_first = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"move\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"parent\":{\"kind\":\"root\"},\"position\":[32768]}}]}",
  )
  let _ = try! conflict_receiver.sync().apply(conflict_first)
  let conflict_message = try! @container.SyncMessage::from_json_string(
    "{\"schema\":1,\"format\":\"event-graph-walker/container-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"domain\":\"tree\",\"payload\":{\"kind\":\"property\",\"timestamp\":0,\"agent\":\"alice\",\"target\":{\"kind\":\"node\",\"replica_id\":\"alice\",\"sequence\":0},\"key\":\"title\",\"value\":\"fork\"}}]}",
  )
  try conflict_receiver.sync().apply(conflict_message) catch {
    error => {
      let failure = match container_failure(error) {
        Some(failure) => failure
        None => fail("expected container conflict sync failure")
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

  let limit_source = try! @container.Document::new("limit-source")
  let _ = try! limit_source.create_node(parent=@container.root_id)
  let limit_json = (try! limit_source.sync().export_all()).to_json_string()
  let limit_receiver = try! @container.Document::new_with_sync_limits(
    "limit-receiver",
    try! @sync.Limits::Limits(max_encoded_bytes=limit_json.length() - 1),
  )
  let limit_message = try! limit_receiver.sync().decode_json(limit_json)
  try limit_receiver.sync().apply(limit_message) catch {
    error => {
      let failure = match container_failure(error) {
        Some(failure) => failure
        None => fail("expected container limit sync failure")
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
