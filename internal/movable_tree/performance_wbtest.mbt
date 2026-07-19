///|
test "10k monotonic tree operations use linear ordering comparisons" {
  let tree = MovableTree::new()
  let log = TreeOpLog::new()
  for index = 0; index < 10_000; index = index + 1 {
    log.apply(tree, {
      timestamp: index,
      target: { agent: "alice", counter: index },
      new_parent: root_id,
      position: @fi.FractionalIndex::new([index + 1]),
      agent: "alice",
    })
  }
  inspect(log.ordering_comparisons, content="9999")
  inspect(log.all_ops().length(), content="10000")
}
