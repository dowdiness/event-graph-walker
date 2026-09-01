///|
fn one_insert_message(agent : String, content : String) -> String {
  let client = try! @text.TextState::new(agent)
  try! client.insert(@text.Pos::at(0), content)
  let message = try! client.sync().export_all()
  message.to_json_string()
}

///|
test "empty submission identity is rejected before mutation" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=7,
    server_agent="server:7",
  )
  let result : Result[
    @text_epoch_cutover_verification.SubmitOutcome,
    @text_epoch_cutover_verification.ProtocolError,
  ] = Ok(
    server.submit(
      epoch=7,
      client_instance_id="",
      submission_sequence=1,
      request_json=one_insert_message("client", "hello"),
    ),
  ) catch {
    error => Err(error)
  }
  guard result is Err(InvalidSubmissionIdentity) else {
    fail("expected invalid submission identity")
  }
  inspect(server.cursor(), content="0")
  inspect(server.text(), content="")
}

///|
test "committed submission retry returns its receipt without reapplying" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=7,
    server_agent="server:7",
  )
  let request = one_insert_message("client", "hello")
  let first = try! server.submit(
    epoch=7,
    client_instance_id="browser",
    submission_sequence=1,
    request_json=request,
  )
  let retry = try! server.submit(
    epoch=7,
    client_instance_id="browser",
    submission_sequence=1,
    request_json=request,
  )
  inspect(first.cursor(), content="1")
  inspect(first.is_replay(), content="false")
  inspect(retry.cursor(), content="1")
  inspect(retry.is_replay(), content="true")
  inspect(server.cursor(), content="1")
  inspect(server.text(), content="hello")
}

///|
test "receipt comparison uses canonical request bytes" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=7,
    server_agent="server:7",
  )
  let request = one_insert_message("client", "hello")
  ignore(
    try! server.submit(
      epoch=7,
      client_instance_id="browser",
      submission_sequence=1,
      request_json=request,
    ),
  )
  let padded = " \n\{request}\n"
  let replay = try! server.submit(
    epoch=7,
    client_instance_id="browser",
    submission_sequence=1,
    request_json=padded,
  )
  inspect(replay.is_replay(), content="true")
  inspect(server.cursor(), content="1")
}

///|
test "same submission identity with different canonical bytes is rejected" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=7,
    server_agent="server:7",
  )
  ignore(
    try! server.submit(
      epoch=7,
      client_instance_id="browser",
      submission_sequence=1,
      request_json=one_insert_message("client-a", "hello"),
    ),
  )
  let result : Result[
    @text_epoch_cutover_verification.SubmitOutcome,
    @text_epoch_cutover_verification.ProtocolError,
  ] = Ok(
    server.submit(
      epoch=7,
      client_instance_id="browser",
      submission_sequence=1,
      request_json=one_insert_message("client-b", "world"),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(SubmissionConflict(client_instance_id~, sequence~)) => {
      inspect(client_instance_id, content="browser")
      inspect(sequence, content="1")
    }
    _ => fail("expected submission conflict")
  }
  inspect(server.cursor(), content="1")
  inspect(server.text(), content="hello")
}

///|
test "stale epoch is rejected before malformed sync JSON is decoded" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=8,
    server_agent="server:8",
  )
  let result : Result[
    @text_epoch_cutover_verification.SubmitOutcome,
    @text_epoch_cutover_verification.ProtocolError,
  ] = Ok(
    server.submit(
      epoch=7,
      client_instance_id="stale-browser",
      submission_sequence=1,
      request_json="not-json",
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(StaleEpoch(expected~, actual~)) => {
      inspect(expected, content="8")
      inspect(actual, content="7")
    }
    _ => fail("expected stale epoch")
  }
  inspect(server.cursor(), content="0")
  inspect(server.text(), content="")
}

///|
test "cursor tail returns strictly later entries in commit order" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=3,
    server_agent="server:3",
  )
  ignore(
    try! server.submit(
      epoch=3,
      client_instance_id="a",
      submission_sequence=1,
      request_json=one_insert_message("client-a", "a"),
    ),
  )
  ignore(
    try! server.submit(
      epoch=3,
      client_instance_id="b",
      submission_sequence=1,
      request_json=one_insert_message("client-b", "b"),
    ),
  )
  let tail = try! server.tail_after(epoch=3, cursor=1)
  inspect(tail.length(), content="1")
  inspect(tail[0].cursor(), content="2")
  inspect(tail[0].epoch(), content="3")
}

///|
test "cutover cannot begin while accepted operations remain pending" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=5,
    server_agent="server:5",
  )
  let child_only = "{\"schema\":2,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":1}]}"
  let accepted = try! server.submit(
    epoch=5,
    client_instance_id="browser",
    submission_sequence=1,
    request_json=child_only,
  )
  inspect(accepted.pending_operations(), content="1")
  let result : Result[Unit, @text_epoch_cutover_verification.ProtocolError] = Ok(
    server.begin_cutover(expected_epoch=5),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(PendingOperations(count)) => inspect(count, content="1")
    _ => fail("expected pending cutover rejection")
  }
  inspect(server.is_quiescing(), content="false")
}

///|
test "dependency arrival drains accepted pending work before cutover" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=5,
    server_agent="server:5",
  )
  let child_only = "{\"schema\":2,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":1},\"parents\":[{\"replica_id\":\"alice\",\"sequence\":0}],\"kind\":\"insert\",\"content\":\"B\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":1}]}"
  let parent_only = "{\"schema\":2,\"format\":\"event-graph-walker/text-sync\",\"operations\":[{\"id\":{\"replica_id\":\"alice\",\"sequence\":0},\"parents\":[],\"kind\":\"insert\",\"content\":\"A\",\"origin_left\":null,\"origin_right\":null}],\"heads\":[{\"replica_id\":\"alice\",\"sequence\":0}]}"
  ignore(
    try! server.submit(
      epoch=5,
      client_instance_id="browser",
      submission_sequence=1,
      request_json=child_only,
    ),
  )
  let release = try! server.submit(
    epoch=5,
    client_instance_id="browser",
    submission_sequence=2,
    request_json=parent_only,
  )
  inspect(release.applied_operations(), content="2")
  inspect(release.pending_operations(), content="0")
  let child_receipt = try! server.submit(
    epoch=5,
    client_instance_id="browser",
    submission_sequence=1,
    request_json=child_only,
  )
  inspect(child_receipt.cursor(), content="1")
  inspect(child_receipt.pending_operations(), content="1")
  inspect(child_receipt.is_replay(), content="true")
  inspect(server.cursor(), content="2")
  try! server.begin_cutover(expected_epoch=5)
  inspect(server.is_quiescing(), content="true")
}

///|
test "quiescing rejects new submissions before EGW mutation" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=5,
    server_agent="server:5",
  )
  try! server.begin_cutover(expected_epoch=5)
  let result : Result[
    @text_epoch_cutover_verification.SubmitOutcome,
    @text_epoch_cutover_verification.ProtocolError,
  ] = Ok(
    server.submit(
      epoch=5,
      client_instance_id="browser",
      submission_sequence=1,
      request_json=one_insert_message("client", "late"),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(Quiescing(epoch)) => inspect(epoch, content="5")
    _ => fail("expected quiescing rejection")
  }
  inspect(server.is_quiescing(), content="true")
  inspect(server.cursor(), content="0")
  inspect(server.text(), content="")
}

///|
test "committed receipt remains replayable while the generation is quiescing" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=5,
    server_agent="server:5",
  )
  let request = one_insert_message("client", "accepted")
  ignore(
    try! server.submit(
      epoch=5,
      client_instance_id="browser",
      submission_sequence=1,
      request_json=request,
    ),
  )
  try! server.begin_cutover(expected_epoch=5)
  let replay = try! server.submit(
    epoch=5,
    client_instance_id="browser",
    submission_sequence=1,
    request_json=request,
  )
  inspect(replay.cursor(), content="1")
  inspect(replay.is_replay(), content="true")
  inspect(server.cursor(), content="1")
  inspect(server.text(), content="accepted")
}

///|
test "complete baseline publication atomically advances the generation" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=5,
    server_agent="server:5",
  )
  ignore(
    try! server.submit(
      epoch=5,
      client_instance_id="browser",
      submission_sequence=1,
      request_json=one_insert_message("client", "a😀bc界d"),
    ),
  )
  try! server.begin_cutover(expected_epoch=5)
  let baseline = try! @text_epoch_cutover_verification.Baseline::build(
    server.text(),
    baseline_agent="baseline:6",
    chunk_scalars=2,
  )
  try! server.publish_cutover(expected_epoch=5, baseline~)
  inspect(server.epoch(), content="6")
  inspect(server.cursor(), content="3")
  inspect(server.text(), content="a😀bc界d")
  inspect(server.is_quiescing(), content="false")
  inspect(server.has_archived_epoch(5), content="true")
  match server.archived_text(5) {
    Some(text) => inspect(text, content="a😀bc界d")
    None => fail("expected archived text")
  }
  match server.archived_entry_count(5) {
    Some(count) => inspect(count, content="1")
    None => fail("expected archived log")
  }
  let receiver = try! @text.TextState::new("receiver")
  let baseline_entries = try! server.tail_after(epoch=6, cursor=0)
  for entry in baseline_entries {
    let message = try! @text.SyncMessage::from_json_string(entry.request_json())
    ignore(try! receiver.sync().apply(message))
  }
  inspect(receiver.text(), content="a😀bc界d")
  assert_eq(receiver.version(), baseline.version())
  ignore(
    try! server.submit(
      epoch=6,
      client_instance_id="new-browser",
      submission_sequence=1,
      request_json=one_insert_message("new-client", "x"),
    ),
  )
  inspect(baseline.text(), content="a😀bc界d")
}

///|
test "publication rejects a baseline not built from the quiesced text" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=5,
    server_agent="server:5",
  )
  ignore(
    try! server.submit(
      epoch=5,
      client_instance_id="browser",
      submission_sequence=1,
      request_json=one_insert_message("client", "authoritative"),
    ),
  )
  try! server.begin_cutover(expected_epoch=5)
  let unrelated = try! @text_epoch_cutover_verification.Baseline::build(
    "unrelated",
    baseline_agent="baseline:6",
    chunk_scalars=256,
  )
  let result : Result[Unit, @text_epoch_cutover_verification.ProtocolError] = Ok(
    server.publish_cutover(expected_epoch=5, baseline=unrelated),
  ) catch {
    error => Err(error)
  }
  guard result is Err(BaselineSourceMismatch) else {
    fail("expected baseline source mismatch")
  }
  inspect(server.epoch(), content="5")
  inspect(server.text(), content="authoritative")
  inspect(server.is_quiescing(), content="true")
  inspect(server.has_archived_epoch(5), content="false")
}

///|
test "old generation cursor cannot address a new generation tail" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=5,
    server_agent="server:5",
  )
  ignore(
    try! server.submit(
      epoch=5,
      client_instance_id="browser",
      submission_sequence=1,
      request_json=one_insert_message("client", "abc"),
    ),
  )
  try! server.begin_cutover(expected_epoch=5)
  let baseline = try! @text_epoch_cutover_verification.Baseline::build(
    server.text(),
    baseline_agent="baseline:6",
    chunk_scalars=1,
  )
  try! server.publish_cutover(expected_epoch=5, baseline~)
  let result : Result[
    Array[@text_epoch_cutover_verification.LogEntry],
    @text_epoch_cutover_verification.ProtocolError,
  ] = Ok(server.tail_after(epoch=5, cursor=1)) catch { error => Err(error) }
  guard result is Err(StaleEpoch(expected=6, actual=5)) else {
    fail("expected stale cursor epoch")
  }
}

///|
test "retired generation receipt is queryable but its operation cannot be resubmitted" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=5,
    server_agent="server:5",
  )
  let request = one_insert_message("client", "accepted")
  ignore(
    try! server.submit(
      epoch=5,
      client_instance_id="browser",
      submission_sequence=4,
      request_json=request,
    ),
  )
  try! server.begin_cutover(expected_epoch=5)
  let baseline = try! @text_epoch_cutover_verification.Baseline::build(
    server.text(),
    baseline_agent="baseline:6",
    chunk_scalars=256,
  )
  try! server.publish_cutover(expected_epoch=5, baseline~)
  let retained = try! server.lookup_receipt(
    epoch=5,
    client_instance_id="browser",
    submission_sequence=4,
    request_json=request,
  )
  match retained {
    Some(receipt) => {
      inspect(receipt.epoch(), content="5")
      inspect(receipt.cursor(), content="1")
      inspect(receipt.is_replay(), content="true")
    }
    None => fail("expected retained receipt")
  }
  let stale : Result[
    @text_epoch_cutover_verification.SubmitOutcome,
    @text_epoch_cutover_verification.ProtocolError,
  ] = Ok(
    server.submit(
      epoch=5,
      client_instance_id="browser",
      submission_sequence=5,
      request_json="not-json",
    ),
  ) catch {
    error => Err(error)
  }
  guard stale is Err(StaleEpoch(expected=6, actual=5)) else {
    fail("expected old generation rejection")
  }
  inspect(server.epoch(), content="6")
  inspect(server.text(), content="accepted")
}

///|
test "baseline build failure retains the old generation and can cancel quiescence" {
  let server = try! @text_epoch_cutover_verification.Server::Server(
    "doc",
    epoch=9,
    server_agent="server:9",
  )
  ignore(
    try! server.submit(
      epoch=9,
      client_instance_id="browser",
      submission_sequence=1,
      request_json=one_insert_message("client", "old"),
    ),
  )
  try! server.begin_cutover(expected_epoch=9)
  let result : Result[
    @text_epoch_cutover_verification.Baseline,
    @text_epoch_cutover_verification.ProtocolError,
  ] = Ok(
    @text_epoch_cutover_verification.Baseline::build(
      server.text(),
      baseline_agent="baseline:10",
      chunk_scalars=0,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(InvalidChunkSize(size)) => inspect(size, content="0")
    _ => fail("expected baseline build failure")
  }
  inspect(server.epoch(), content="9")
  inspect(server.cursor(), content="1")
  inspect(server.text(), content="old")
  inspect(server.is_quiescing(), content="true")
  try! server.cancel_cutover(expected_epoch=9)
  inspect(server.is_quiescing(), content="false")
}
