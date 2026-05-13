///|
fn build_position_bench_tree(n : Int) -> FugueTree[String] {
  let tree : FugueTree[String] = FugueTree::new()
  let mut left : Lv? = None
  for i in 0..<n {
    tree.insert({
      id: Lv(i),
      content: "a",
      origin_left: left,
      origin_right: None,
      timestamp: Timestamp(i),
      agent: ReplicaId("agent0"),
    })
    left = Some(Lv(i))
  }
  tree
}

///|
test "bench: lv_to_position middle of 10K tree" (b : @bench.T) {
  let tree = build_position_bench_tree(10000)
  b.bench(fn() { b.keep(tree.lv_to_position(Lv(5000))) })
}
