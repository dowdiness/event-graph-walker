///|
/// Build a pathological Fugue sibling set: every item is a right child of
/// the virtual root, so a traversal-based rank query must sort and walk the
/// entire set while the warm locator follows one balanced child-set path.
fn locator_sibling_fixture(
  count : Int,
) -> (@fugue.FugueTree[String], IndexedState) {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  for index in 0..<count {
    tree.insert(
      {
        id: @fugue.Lv(index),
        content: "x",
        origin_left: None,
        origin_right: None,
        timestamp: @fugue.Timestamp(index),
        agent: @fugue.ReplicaId("sibling"),
      },
      sequence=index,
    )
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

///|
/// Build the ordinary append-shaped Fugue chain that previously forced the
/// topology locator to walk every ancestor for the final LV.
fn locator_chain_fixture(
  count : Int,
) -> (@fugue.FugueTree[String], IndexedState) {
  let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  for index in 0..<count {
    tree.insert(
      {
        id: @fugue.Lv(index),
        content: "x",
        origin_left: if index == 0 {
          None
        } else {
          Some(@fugue.Lv(index - 1))
        },
        origin_right: None,
        timestamp: @fugue.Timestamp(index),
        agent: @fugue.ReplicaId("chain"),
      },
      sequence=index,
    )
  }
  (tree, IndexedState::from_tree(tree))
}

///|
fn bench_warm_locator_chain_rank(b : @bench.T, count : Int) -> Unit {
  let (tree, state) = locator_chain_fixture(count)
  b.bench(() => b.keep(state.lv_to_position(tree, count - 1)))
}

///|
test "bench: warm locator rank at end of 1000 chain" (b : @bench.T) {
  bench_warm_locator_chain_rank(b, 1000)
}

///|
test "bench: warm locator rank at end of 100000 chain" (b : @bench.T) {
  bench_warm_locator_chain_rank(b, 100000)
}
