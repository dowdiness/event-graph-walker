///|
test "10k sequential text records have linear preparation comparisons" {
  let operations : Array[@core.Op] = []
  for sequence = 0; sequence < 10_000; sequence = sequence + 1 {
    let previous = if sequence == 0 {
      None
    } else {
      Some(@core.RawVersion::new("alice", sequence - 1))
    }
    let parents = match previous {
      Some(value) => [value]
      None => []
    }
    operations.push(
      @core.Op::new_insert(0, parents, "alice", sequence, "x", previous, None),
    )
  }
  let (ordered, comparisons) = try! canonical_order_counted(operations.rev())
  inspect(ordered.length(), content="10000")
  inspect(comparisons <= 10_000, content="true")
}

///|
test "sync preparation is deterministic and leaves receiver state untouched" {
  let source = try! TextState::new("source")
  let receiver = try! TextState::new("receiver")
  try! source.insert(Pos::at(0), "A")
  let message = try! source.sync().export_all()
  let local_ops = receiver.inner.get_all_ops()
  let pending = receiver.pending_sync_records.copy()
  let limits : @sync.Limits = @sync.Limits::default()
  let first = try! prepare_sync(message, limits, local_ops, pending)
  let second = try! prepare_sync(message, limits, local_ops, pending)
  inspect(first.report() == second.report(), content="true")
  inspect(first.applicable.length(), content="1")
  inspect(first.pending.length(), content="0")
  inspect(local_ops.length(), content="0")
  inspect(pending.length(), content="0")
  inspect(receiver.text(), content="")
  inspect(receiver.version() == Version::empty(), content="true")
  inspect(receiver.sync().pending_sync_count(), content="0")
}
