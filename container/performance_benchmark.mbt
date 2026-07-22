///| Release baselines for v0.4 container synchronization and local histories.

///|
fn benchmark_sequential_text(b : @bench.T, count : Int) -> Unit {
  b.bench(fn() {
    let document = try! Document::new("text-benchmark")
    let block = try! document.create_node(parent=root_id)
    for index = 0; index < count; index = index + 1 {
      try! document.insert_text(block, index, "x")
    }
    b.keep(document.text_len(block))
  })
}

///|
test "container text sequential 1k" (b : @bench.T) {
  benchmark_sequential_text(b, 1_000)
}

///|
test "container text sequential 10k" (b : @bench.T) {
  benchmark_sequential_text(b, 10_000)
}

///|
/// Release-scale local make -> apply chain. This intentionally measures the
/// public local path rather than a synthetic cache lookup.
test "container text sequential 100k" (b : @bench.T) {
  benchmark_sequential_text(b, 100_000)
}

///|
/// Build a sequential Fugue chain from direct, already-known origins. Input
/// construction is outside the timed closure; the closure times only
/// FugueTree::insert and retains the resulting visible count. With each
/// origin_left set to the previous LV and no origin_right, every item is a
/// right child of the preceding item.
fn benchmark_fugue_sequential_right_insert(b : @bench.T, count : Int) -> Unit {
  let ops : Array[@fugue.InsertOp[String]] = Array::makei(count, index => {
    id: @fugue.Lv(index),
    content: "x",
    origin_left: if index == 0 {
      None
    } else {
      Some(@fugue.Lv(index - 1))
    },
    origin_right: None,
    timestamp: @fugue.Timestamp(index),
    agent: @fugue.ReplicaId("stage2-benchmark"),
  })
  b.bench(fn() {
    let tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
    for op in ops {
      tree.insert(op)
    }
    b.keep(tree.visible_count())
  })
}

///|
test "container Stage2 FugueTree sequential Right-child insert 1k" (
  b : @bench.T,
) {
  benchmark_fugue_sequential_right_insert(b, 1_000)
}

///|
test "container Stage2 FugueTree sequential Right-child insert 10k" (
  b : @bench.T,
) {
  benchmark_fugue_sequential_right_insert(b, 10_000)
}

///|
test "container Stage2 FugueTree sequential Right-child insert 100k" (
  b : @bench.T,
) {
  benchmark_fugue_sequential_right_insert(b, 100_000)
}

///|
/// Prepare sibling children once, then measure only the position lookup.
fn benchmark_position_after_last_child(b : @bench.T, count : Int) -> Unit {
  let document = try! Document::new("position-benchmark")
  for _index = 0; _index < count; _index = _index + 1 {
    ignore(try! document.create_node(parent=root_id))
  }
  b.bench(fn() {
    let position = document.position_after_last_child(@mt.root_id)
    b.keep(position)
  })
}

///|
test "container position_after_last_child 1k siblings" (b : @bench.T) {
  benchmark_position_after_last_child(b, 1_000)
}

///|
test "container position_after_last_child 10k siblings" (b : @bench.T) {
  benchmark_position_after_last_child(b, 10_000)
}

///|
/// Prepare independent sequential-growth states at 1k increments, then measure
/// one position lookup per state in the timed closure.
fn benchmark_position_after_last_child_sampled_growth(b : @bench.T) -> Unit {
  let documents : Array[Document] = []
  let mut sample_size = 1_000
  while sample_size <= 10_000 {
    let document = try! Document::new("position-sample")
    for _index = 0; _index < sample_size; _index = _index + 1 {
      ignore(try! document.create_node(parent=root_id))
    }
    documents.push(document)
    sample_size = sample_size + 1_000
  }
  b.bench(fn() {
    for sample_index = 0
        sample_index < documents.length()
        sample_index = sample_index + 1 {
      let position = documents[sample_index].position_after_last_child(
        @mt.root_id,
      )
      b.keep(position)
    }
  })
}

///|
test "container position_after_last_child sampled growth 1k-10k" (b : @bench.T) {
  benchmark_position_after_last_child_sampled_growth(b)
}

///|
/// Measure one public text append against a rotating pool of prebuilt 10k
/// documents. The pool bounds, but does not eliminate, state drift because
/// Document has no copy API.
fn benchmark_document_insert_text_append_pool(b : @bench.T) -> Unit {
  let pool_size = 4
  let documents : Array[Document] = []
  let blocks : Array[TreeNodeId] = []
  let added : Array[Int] = []
  for pool_index = 0; pool_index < pool_size; pool_index = pool_index + 1 {
    let document = try! Document::new(
      "public-text-append-" + pool_index.to_string(),
    )
    let block = try! document.create_node(parent=root_id)
    for index = 0; index < 10_000; index = index + 1 {
      try! document.insert_text(block, index, "x")
    }
    documents.push(document)
    blocks.push(block)
    added.push(0)
  }
  let mut next_document = 0
  b.bench(fn() {
    let pool_index = next_document
    next_document = (next_document + 1) % pool_size
    let document = documents[pool_index]
    let block = blocks[pool_index]
    let end = document.text_len(block)
    try! document.insert_text(block, end, "x")
    added[pool_index] = added[pool_index] + 1
    b.keep(document.text_len(block))
  })
  let mut max_added = 0
  for count in added {
    if count > max_added {
      max_added = count
    }
  }
  b.keep((pool_size, max_added))
  println(
    "public insert_text append pool_size=" +
    pool_size.to_string() +
    " max_added_per_document=" +
    max_added.to_string(),
  )
}

///|
test "container Document insert_text append public 10k pool 4" (b : @bench.T) {
  benchmark_document_insert_text_append_pool(b)
}

///|
/// Measure one public root append against a rotating pool of prebuilt 10k
/// documents. The pool bounds, but does not eliminate, state drift because
/// Document has no copy API.
fn benchmark_document_create_node_root_pool(b : @bench.T) -> Unit {
  let pool_size = 4
  let documents : Array[Document] = []
  let added : Array[Int] = []
  for pool_index = 0; pool_index < pool_size; pool_index = pool_index + 1 {
    let document = try! Document::new(
      "public-root-append-" + pool_index.to_string(),
    )
    for _index = 0; _index < 10_000; _index = _index + 1 {
      ignore(try! document.create_node(parent=root_id))
    }
    documents.push(document)
    added.push(0)
  }
  let mut next_document = 0
  b.bench(fn() {
    let pool_index = next_document
    next_document = (next_document + 1) % pool_size
    let document = documents[pool_index]
    let node = try! document.create_node(parent=root_id)
    added[pool_index] = added[pool_index] + 1
    b.keep(node)
  })
  let mut max_added = 0
  for count in added {
    if count > max_added {
      max_added = count
    }
  }
  b.keep((pool_size, max_added))
  println(
    "public create_node root pool_size=" +
    pool_size.to_string() +
    " max_added_per_document=" +
    max_added.to_string(),
  )
}

///|
test "container Document create_node root public 10k pool 4" (b : @bench.T) {
  benchmark_document_create_node_root_pool(b)
}

///|
fn benchmark_sequential_tree(b : @bench.T, count : Int) -> Unit {
  b.bench(fn() {
    let document = try! Document::new("tree-benchmark")
    for _index = 0; _index < count; _index = _index + 1 {
      let _ = try! document.create_node(parent=root_id)
    }
    b.keep(document.children(root_id).length())
  })
}

///|
test "container tree sequential 1k" (b : @bench.T) {
  benchmark_sequential_tree(b, 1_000)
}

///|
test "container tree sequential 10k" (b : @bench.T) {
  benchmark_sequential_tree(b, 10_000)
}

///|
fn reverse_ordered_tree_message(count : Int) -> SyncMessage {
  let source = try! Document::new("reverse-source")
  for _index = 0; _index < count; _index = _index + 1 {
    let _ = try! source.create_node(parent=root_id)
  }
  let message = try! source.sync().export_all()
  try! SyncMessage::SyncMessage(
    message.tree_ops.rev(),
    [],
    None,
    message.tree_ops.length(),
  )
}

///|
test "container reverse causal batch 1k" (b : @bench.T) {
  let message = reverse_ordered_tree_message(1_000)
  b.bench(fn() {
    let receiver = try! Document::new("reverse-receiver")
    let report = try! receiver.sync().apply(message)
    b.keep(report.applied_tree_operations())
  })
}

///|
test "container reverse causal batch 10k" (b : @bench.T) {
  let message = reverse_ordered_tree_message(10_000)
  b.bench(fn() {
    let receiver = try! Document::new("reverse-receiver")
    let report = try! receiver.sync().apply(message)
    b.keep(report.applied_tree_operations())
  })
}

///|
test "container permanently missing dependency" (b : @bench.T) {
  let source = try! Document::new("missing-source")
  let _ = try! source.create_node(parent=root_id)
  let version = source.version()
  let _ = try! source.create_node(parent=root_id)
  let missing = try! source.sync().export_since(version)
  b.bench(fn() {
    let receiver = try! Document::new("missing-receiver")
    let report = try! receiver.sync().apply(missing)
    b.keep(report.pending_operations())
  })
}
