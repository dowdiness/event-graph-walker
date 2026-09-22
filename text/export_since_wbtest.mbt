///|
/// Regression oracle for delta export. Deliberately uses the old full-history
/// algorithm and does not share sparse subtraction with production.
fn export_since_full_scan_oracle(
  document : TextState,
  peer : Version,
) -> SyncMessage {
  let operations = document.inner
    .get_all_ops()
    .filter(op => !peer.graph().contains(op_identity(op)))
  try! SyncMessage::SyncMessage(operations, try! current_heads(document), None)
}

///|
fn assert_export_since_version_matches_oracle(
  source : TextState,
  peer_version : Version,
) -> Unit raise {
  let actual = try! source.sync().export_since(peer_version)
  let expected = export_since_full_scan_oracle(source, peer_version)
  assert_eq(actual.op_count(), expected.op_count())
  assert_eq(actual.to_canonical_bytes(), expected.to_canonical_bytes())
}

///|
fn assert_export_since_matches_oracle(
  source : TextState,
  peer : TextState,
) -> Unit raise {
  let peer_version = peer.version()
  let actual = try! source.sync().export_since(peer_version)
  let expected = export_since_full_scan_oracle(source, peer_version)
  assert_export_since_version_matches_oracle(source, peer_version)

  // Apply both messages to equivalent receivers. This checks payloads and
  // admission effects independently of byte equality.
  let peer_snapshot = try! peer.sync().export_all()
  let actual_receiver = try! TextState::new("actual-receiver")
  let oracle_receiver = try! TextState::new("oracle-receiver")
  ignore(try! actual_receiver.sync().apply(peer_snapshot))
  ignore(try! oracle_receiver.sync().apply(peer_snapshot))
  ignore(try! actual_receiver.sync().apply(actual))
  ignore(try! oracle_receiver.sync().apply(expected))
  assert_eq(actual_receiver.text(), oracle_receiver.text())
  assert_eq(
    (try! actual_receiver.sync().export_all()).to_canonical_bytes(),
    (try! oracle_receiver.sync().export_all()).to_canonical_bytes(),
  )
}

///|
fn export_root_message(
  agent : String,
  sequence : Int,
  content : String,
) -> SyncMessage {
  let raw = @core.RawVersion(agent, sequence)
  try! SyncMessage::SyncMessage(
    [@core.Op::insert(-1, [], agent, sequence, content, None, None)],
    [raw],
    None,
  )
}

///|
test "export_since matches full-scan oracle at empty full and incremental cuts" {
  let source = try! TextState::new("source")
  let peer = try! TextState::new("peer")
  assert_export_since_matches_oracle(source, peer)

  try! source.insert(Pos::at(0), "A")
  assert_export_since_matches_oracle(source, peer)
  ignore(try! peer.sync().apply(try! source.sync().export_all()))
  assert_export_since_matches_oracle(source, peer)

  try! source.insert(Pos::at(1), "B")
  assert_export_since_matches_oracle(source, peer)
  try! source.delete(Pos::at(0))
  ignore(try! source.inner.undelete(0))
  assert_export_since_matches_oracle(source, peer)
}

///|
test "export_since keeps hot sparse knowledge current after remote admission" {
  let source = try! TextState::new("source")
  let peer = try! TextState::new("peer")
  try! source.insert(Pos::at(0), "A")
  ignore(source.version())
  ignore(try! peer.sync().apply(try! source.sync().export_all()))
  ignore(try! source.sync().apply(export_root_message("remote", 50, "R")))
  assert_export_since_matches_oracle(source, peer)
}

///|
test "export_since oracle covers sparse holes branches and unknown peer heads" {
  let source = try! TextState::new("source")
  let peer = try! TextState::new("peer")
  for
    (agent, sequence, content) in [
      ("a", 0, "A"),
      ("a", 2, "C"),
      ("a", 1000000000, "Z"),
      ("b", 4, "B"),
    ] {
    ignore(
      try! source.sync().apply(export_root_message(agent, sequence, content)),
    )
  }
  for
    (agent, sequence, content) in [
      ("a", 2, "C"),
      ("peer-only", 2000000000, "P"),
    ] {
    ignore(
      try! peer.sync().apply(export_root_message(agent, sequence, content)),
    )
  }
  assert_export_since_matches_oracle(source, peer)
}

///|
test "export_since resolves the maximum signed sequence identity" {
  let source = try! TextState::new("source")
  ignore(
    try! source.sync().apply(export_root_message("maximum", 2147483647, "M")),
  )
  let delta = try! source.sync().export_since(Version::empty())
  assert_eq(delta.op_count(), 1)
  assert_eq(
    delta.to_canonical_bytes(),
    export_since_full_scan_oracle(source, Version::empty()).to_canonical_bytes(),
  )
}

///|
test "export_since excludes pending operations until dependency admission" {
  let source = try! TextState::new("source")
  let dependency = @core.RawVersion("remote", 0)
  let child = @core.RawVersion("remote", 1)
  let pending = try! SyncMessage::SyncMessage(
    [
      @core.Op::insert(
        -1,
        [dependency],
        child.agent,
        child.seq,
        "B",
        None,
        None,
      ),
    ],
    [],
    None,
  )
  let pending_report = try! source.sync().apply(pending)
  assert_eq(pending_report.pending_operations(), 1)
  assert_eq(try! source.sync().export_since(Version::empty()).op_count(), 0)
  assert_eq(source.sync().pending_sync_count(), 1)

  ignore(try! source.sync().apply(export_root_message("remote", 0, "A")))
  assert_eq(source.sync().pending_sync_count(), 0)
  let admitted = try! source.sync().export_since(Version::empty())
  assert_eq(admitted.op_count(), 2)
  assert_eq(
    admitted.to_canonical_bytes(),
    export_since_full_scan_oracle(source, Version::empty()).to_canonical_bytes(),
  )
}

///|
test "export_since accepts peer membership that is not a local causal cut" {
  let source = try! TextState::new("source")
  ignore(try! source.sync().apply(export_root_message("a", 0, "A")))
  ignore(try! source.sync().apply(export_root_message("a", 1, "B")))
  let peer = Version::from_graph_version(
    try! @causal_graph.GraphVersion::from_parts([@core.RawVersion("a", 0)], [
      ("a", [(0U, 2U)]),
    ]),
  )
  assert_export_since_version_matches_oracle(source, peer)
  assert_eq(try! source.sync().export_since(peer).op_count(), 0)
}

///|
test "export_since canonical bytes do not depend on local LV admission order" {
  let first = try! TextState::new("first")
  let second = try! TextState::new("second")
  let a = export_root_message("a", 0, "A")
  let b = export_root_message("b", 0, "B")
  ignore(try! first.sync().apply(a))
  ignore(try! first.sync().apply(b))
  ignore(try! second.sync().apply(b))
  ignore(try! second.sync().apply(a))
  let empty = Version::empty()
  let first_delta = try! first.sync().export_since(empty)
  let second_delta = try! second.sync().export_since(empty)
  assert_eq(first_delta.to_canonical_bytes(), second_delta.to_canonical_bytes())
  assert_eq(
    first_delta.to_canonical_bytes(),
    export_since_full_scan_oracle(first, empty).to_canonical_bytes(),
  )
}

///|
test "property: sparse export matches independent full-scan oracle" {
  let seeds : Array[Int] = @quickcheck.samples(40)
  for raw_seed in seeds {
    let reduced_seed = raw_seed % 997
    let seed = if reduced_seed < 0 { -reduced_seed } else { reduced_seed }
    let source = try! TextState::new("source")
    let peer = try! TextState::new("peer")
    let count = seed % 32 + 1
    for sequence in 0..<count {
      let agent = if sequence % 5 == 0 { "branch" } else { "main" }
      let logical_sequence = sequence * 1000003
      let message = export_root_message(agent, logical_sequence, "x")
      ignore(try! source.sync().apply(message))
      if (sequence + seed) % 3 == 0 {
        ignore(try! peer.sync().apply(message))
      }
    }
    assert_export_since_matches_oracle(source, peer)
  }
}
