///|
fn sparse_root_message(sequence : Int) -> SyncMessage {
  let raw = @core.RawVersion("shared-agent", sequence)
  let operation = @core.Op::insert(-1, [], raw.agent, raw.seq, "x", None, None)
  try! SyncMessage::SyncMessage([operation], [raw], None)
}

///|
/// Sparse knowledge may arrive in any sequence order. Reconnection must export
/// every missing identity, drain pending membership, and reproduce the exact
/// checkpoint without treating sequence order as causality.
test "property: sparse same-agent disconnect reconnect converges" {
  let seeds : Array[Int] = @quickcheck.samples(40)
  for raw_seed in seeds {
    let mut seed = raw_seed % 997
    if seed < 0 {
      seed = -seed
    }
    let count = seed % 31 + 1
    let source = try! TextState::new("source")
    let peer = try! TextState::new("peer")
    for offset in 0..<count {
      let sequence = count - offset - 1
      let message = sparse_root_message(sequence)
      ignore(try! source.sync().apply(message))
      if (sequence + seed) % 3 == 0 {
        ignore(try! peer.sync().apply(message))
        let duplicate = try! peer.sync().apply(message)
        assert_eq(duplicate.applied_operations(), 0)
        assert_true(duplicate.duplicate_operations() > 0)
      }
    }
    let delta = try! source.sync().export_since(peer.version())
    ignore(try! peer.sync().apply(delta))
    assert_eq(peer.sync().pending_sync_count(), 0)
    assert_eq(peer.text(), source.text())
    assert_eq(peer.version(), source.version())
    let roundtrip = try! Version::from_json_string(
      peer.version().to_json_string(),
    )
    assert_eq(try! peer.checkout(roundtrip).text(), peer.text())
  }
}
