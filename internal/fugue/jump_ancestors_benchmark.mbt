///|
/// Build the deep Right-child chain used by query and mixed-workload baselines.
/// Setup is intentionally kept outside timed closures for those workloads.
fn build_ancestry_chain(count : Int) -> FugueTree[String] {
  let tree : FugueTree[String] = FugueTree::new()
  for i = 0; i < count; i = i + 1 {
    tree.insert({
      id: Lv(i),
      content: "a",
      origin_left: if i == 0 {
        None
      } else {
        Some(Lv(i - 1))
      },
      origin_right: None,
      timestamp: Timestamp(i),
      agent: ReplicaId("baseline-chain"),
    })
  }
  tree
}

///|
/// A small pool avoids timing chain construction for one-shot insert/query
/// workloads while bounding mutable state drift across benchmark samples.
fn build_ancestry_chain_pool(
  count : Int,
  pool_size : Int,
) -> Array[FugueTree[String]] {
  Array::makei(pool_size, _ => build_ancestry_chain(count))
}

///|
/// Query pairs cover deep positive, reflexive, and reverse-direction checks.
/// The first several pairs deliberately use the deepest descendant.
fn deep_ancestry_query_pairs(count : Int) -> Array[(Lv, Lv)] {
  let last = count - 1
  [
    (Lv(0), Lv(last)),
    (Lv(count / 4), Lv(last)),
    (Lv(count / 2), Lv(last)),
    (Lv(count * 3 / 4), Lv(last)),
    (Lv(last), Lv(last)),
    (Lv(last), Lv(0)),
  ]
}

///|
/// The sequential baseline explicitly measures chain construction/insertion.
fn benchmark_sequential_right_chain(b : @bench.T, count : Int) -> Unit {
  b.bench(fn() {
    let tree : FugueTree[String] = FugueTree::new()
    for i = 0; i < count; i = i + 1 {
      tree.insert({
        id: Lv(i),
        content: "a",
        origin_left: if i == 0 {
          None
        } else {
          Some(Lv(i - 1))
        },
        origin_right: None,
        timestamp: Timestamp(i),
        agent: ReplicaId("baseline-chain"),
      })
    }
    b.keep(tree.visible_count())
  })
}

///|
test "ancestry baseline - sequential Right chain 1k" (b : @bench.T) {
  benchmark_sequential_right_chain(b, 1_000)
}

///|
test "ancestry baseline - sequential Right chain 10k" (b : @bench.T) {
  benchmark_sequential_right_chain(b, 10_000)
}

///|
test "ancestry baseline - sequential Right chain 100k" (b : @bench.T) {
  benchmark_sequential_right_chain(b, 100_000)
}

///|
/// Insert one concurrent operation into the midpoint of a prebuilt chain.
/// The operation ID advances so repeated harness samples do not duplicate IDs.
fn benchmark_midpoint_concurrent_insert(b : @bench.T, count : Int) -> Unit {
  let trees = build_ancestry_chain_pool(count, 4)
  let midpoint = count / 2
  let mut next_tree = 0
  let mut next_id = count
  b.bench(fn() {
    let tree = trees[next_tree]
    next_tree = (next_tree + 1) % trees.length()
    let id = next_id
    next_id = next_id + 1
    tree.insert({
      id: Lv(id),
      content: "remote",
      origin_left: Some(Lv(midpoint - 1)),
      origin_right: Some(Lv(midpoint)),
      timestamp: Timestamp(id),
      agent: ReplicaId("concurrent-agent"),
    })
    b.keep(tree.visible_count())
  })
}

///|
test "ancestry baseline - midpoint concurrent insert 1k" (b : @bench.T) {
  benchmark_midpoint_concurrent_insert(b, 1_000)
}

///|
test "ancestry baseline - midpoint concurrent insert 10k" (b : @bench.T) {
  benchmark_midpoint_concurrent_insert(b, 10_000)
}

///|
test "ancestry baseline - midpoint concurrent insert 100k" (b : @bench.T) {
  benchmark_midpoint_concurrent_insert(b, 100_000)
}

///|
/// Measure the first ancestry check assigned to each prebuilt chain in the
/// pool. The pool keeps chain setup outside the timed closure and varies pairs.
fn benchmark_cold_ancestry_query(b : @bench.T, count : Int) -> Unit {
  let pairs = deep_ancestry_query_pairs(count)
  let trees = build_ancestry_chain_pool(count, pairs.length())
  let mut next_pair = 0
  b.bench(fn() {
    let pair = pairs[next_pair]
    let tree = trees[next_pair]
    next_pair = (next_pair + 1) % pairs.length()
    let (ancestor, descendant) = pair
    b.keep(tree.is_ancestor(ancestor, descendant))
  })
}

///|
test "ancestry baseline - eager deep query 1k" (b : @bench.T) {
  benchmark_cold_ancestry_query(b, 1_000)
}

///|
test "ancestry baseline - eager deep query 10k" (b : @bench.T) {
  benchmark_cold_ancestry_query(b, 10_000)
}

///|
test "ancestry baseline - eager deep query 100k" (b : @bench.T) {
  benchmark_cold_ancestry_query(b, 100_000)
}

///|
/// Measure varied ancestry pairs repeatedly against one prebuilt chain.
fn benchmark_warm_ancestry_query(b : @bench.T, count : Int) -> Unit {
  let tree = build_ancestry_chain(count)
  let pairs = deep_ancestry_query_pairs(count)
  let mut next_pair = 0
  b.bench(fn() {
    let pair = pairs[next_pair]
    next_pair = (next_pair + 1) % pairs.length()
    let (ancestor, descendant) = pair
    b.keep(tree.is_ancestor(ancestor, descendant))
  })
}

///|
test "ancestry baseline - warm varied query 1k" (b : @bench.T) {
  benchmark_warm_ancestry_query(b, 1_000)
}

///|
test "ancestry baseline - warm varied query 10k" (b : @bench.T) {
  benchmark_warm_ancestry_query(b, 10_000)
}

///|
test "ancestry baseline - warm varied query 100k" (b : @bench.T) {
  benchmark_warm_ancestry_query(b, 100_000)
}

///|
/// One midpoint insert followed by varied ancestry checks models a small
/// collaboration/editing batch. Chain and query setup stay outside timing.
fn benchmark_mixed_insert_and_query(b : @bench.T, count : Int) -> Unit {
  let trees = build_ancestry_chain_pool(count, 4)
  let pairs = deep_ancestry_query_pairs(count)
  let midpoint = count / 2
  let mut next_tree = 0
  let mut next_id = count
  b.bench(fn() {
    let tree = trees[next_tree]
    next_tree = (next_tree + 1) % trees.length()
    let id = next_id
    next_id = next_id + 1
    tree.insert({
      id: Lv(id),
      content: "remote",
      origin_left: Some(Lv(midpoint - 1)),
      origin_right: Some(Lv(midpoint)),
      timestamp: Timestamp(id),
      agent: ReplicaId("mixed-agent"),
    })
    let mut hits = 0
    for pair in pairs {
      let (ancestor, descendant) = pair
      if tree.is_ancestor(ancestor, descendant) {
        hits = hits + 1
      }
    }
    b.keep((tree.visible_count(), hits))
  })
}

///|
test "ancestry baseline - mixed insert plus queries 1k" (b : @bench.T) {
  benchmark_mixed_insert_and_query(b, 1_000)
}

///|
test "ancestry baseline - mixed insert plus queries 10k" (b : @bench.T) {
  benchmark_mixed_insert_and_query(b, 10_000)
}

///|
test "ancestry baseline - mixed insert plus queries 100k" (b : @bench.T) {
  benchmark_mixed_insert_and_query(b, 100_000)
}
