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
