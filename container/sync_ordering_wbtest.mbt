///|
test "10k sequential container records have linear preparation comparisons" {
  let records : Array[SyncOpRecord] = []
  for sequence = 0; sequence < 10_000; sequence = sequence + 1 {
    let version = @core.RawVersion::new("alice", sequence)
    let parents = if sequence == 0 {
      []
    } else {
      [@core.RawVersion::new("alice", sequence - 1)]
    }
    records.push(
      Tree({
        version,
        parents,
        op: @mt.SetProperty({
          timestamp: sequence,
          target: { agent: "node", counter: 0 },
          key: "k",
          value: sequence.to_string(),
          agent: "alice",
        }),
      }),
    )
  }
  let (ordered, comparisons) = try! canonical_sync_order_counted(records.rev())
  inspect(ordered.length(), content="10000")
  inspect(comparisons <= 10_000, content="true")
}
