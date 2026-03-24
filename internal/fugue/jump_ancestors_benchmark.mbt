///|
test "jump - sequential append 1K" (b : @bench.T) {
  b.bench(fn() {
    let tree : FugueTree[String] = FugueTree::new()
    let mut prev = -1
    for i = 0; i < 1000; i = i + 1 {
      tree.insert({
        id: Lv(i),
        content: "a",
        origin_left: if prev == -1 {
          None
        } else {
          Some(Lv(prev))
        },
        origin_right: None,
        timestamp: Timestamp(i),
        agent: ReplicaId("agent0"),
      })
      prev = i
    }
    b.keep(tree)
  })
}

///|
test "jump - concurrent insert into 1K doc" (b : @bench.T) {
  b.bench(fn() {
    let tree : FugueTree[String] = FugueTree::new()
    let mut prev = -1
    for i = 0; i < 1000; i = i + 1 {
      tree.insert({
        id: Lv(i),
        content: "a",
        origin_left: if prev == -1 {
          None
        } else {
          Some(Lv(prev))
        },
        origin_right: None,
        timestamp: Timestamp(i),
        agent: ReplicaId("agent0"),
      })
      prev = i
    }
    tree.insert({
      id: Lv(1000),
      content: "X",
      origin_left: Some(Lv(0)),
      origin_right: Some(Lv(500)),
      timestamp: Timestamp(1000),
      agent: ReplicaId("agent1"),
    })
    b.keep(tree)
  })
}

///|
test "jump - concurrent insert into 10K doc" (b : @bench.T) {
  b.bench(fn() {
    let tree : FugueTree[String] = FugueTree::new()
    let mut prev = -1
    for i = 0; i < 10000; i = i + 1 {
      tree.insert({
        id: Lv(i),
        content: "a",
        origin_left: if prev == -1 {
          None
        } else {
          Some(Lv(prev))
        },
        origin_right: None,
        timestamp: Timestamp(i),
        agent: ReplicaId("agent0"),
      })
      prev = i
    }
    tree.insert({
      id: Lv(10000),
      content: "X",
      origin_left: Some(Lv(0)),
      origin_right: Some(Lv(5000)),
      timestamp: Timestamp(10000),
      agent: ReplicaId("agent1"),
    })
    b.keep(tree)
  })
}

///|
test "jump - degenerate chain remote insert" (b : @bench.T) {
  b.bench(fn() {
    let tree : FugueTree[String] = FugueTree::new()
    let mut prev = -1
    for i = 0; i < 1000; i = i + 1 {
      tree.insert({
        id: Lv(i),
        content: "a",
        origin_left: if prev == -1 {
          None
        } else {
          Some(Lv(prev))
        },
        origin_right: None,
        timestamp: Timestamp(i),
        agent: ReplicaId("agent0"),
      })
      prev = i
    }
    tree.insert({
      id: Lv(1000),
      content: "X",
      origin_left: Some(Lv(0)),
      origin_right: Some(Lv(999)),
      timestamp: Timestamp(1000),
      agent: ReplicaId("agent1"),
    })
    b.keep(tree)
  })
}
