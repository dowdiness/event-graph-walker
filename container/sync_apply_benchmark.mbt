// Benchmark receiver preparation overhead for no-op synchronization.
// Run with:
// moon bench --release -p dowdiness/event-graph-walker/container \
//   -f sync_apply_benchmark.mbt

///|
test "container sync apply - empty message on 1000-node tree" (b : @bench.T) {
  let receiver = try! Document::new("receiver")
  for i = 0; i < 1000; i = i + 1 {
    ignore(try! receiver.create_node(parent=root_id))
  }
  let source = try! Document::new("source")
  let empty = try! source.sync().export_all()
  b.bench(fn() {
    let report = try! receiver.sync().apply(empty)
    b.keep(report)
  })
}

///|
test "container sync apply - duplicate text on 1000-node tree" (b : @bench.T) {
  let source = try! Document::new("source")
  let nodes : Array[TreeNodeId] = []
  for i = 0; i < 1000; i = i + 1 {
    nodes.push(try! source.create_node(parent=root_id))
  }
  let receiver = try! Document::new("receiver")
  ignore(try! receiver.sync().apply(try! source.sync().export_all()))
  let tree_version = source.version()
  try! source.insert_text(nodes[0], 0, "A")
  let text = try! source.sync().export_since(tree_version)
  ignore(try! receiver.sync().apply(text))
  b.bench(fn() {
    let report = try! receiver.sync().apply(text)
    b.keep(report)
  })
}
