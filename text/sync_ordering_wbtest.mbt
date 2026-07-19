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
