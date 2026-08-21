///|
/// Build a pathological Fugue sibling set: every item is a right child of
/// the virtual root, so a traversal-based rank query must sort and walk the
/// entire set while the warm locator follows one balanced child-set path.
fn locator_sibling_fixture(
  count : Int,
) -> (@fugue.FugueTree[String], IndexedState) {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  for index in 0..<count {
    tree.insert({
      id: @fugue.Lv(index),
      content: "x",
      origin_left: None,
      origin_right: None,
      timestamp: @fugue.Timestamp(index),
      agent: @fugue.ReplicaId("sibling"),
    })
  }
  (tree, IndexedState::from_tree(tree))
}

///|
fn bench_warm_locator_sibling_rank(b : @bench.T, count : Int) -> Unit {
  let (tree, state) = locator_sibling_fixture(count)
  let target = count / 2
  b.bench(() => b.keep(state.lv_to_position(tree, target)))
}

///|
test "bench: warm locator rank among 1000 siblings" (b : @bench.T) {
  bench_warm_locator_sibling_rank(b, 1000)
}

///|
test "bench: warm locator rank among 100000 siblings" (b : @bench.T) {
  bench_warm_locator_sibling_rank(b, 100000)
}
