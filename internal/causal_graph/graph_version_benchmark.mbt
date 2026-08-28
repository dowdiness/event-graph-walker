///|
fn graph_version_benchmark_graph(operation_count : Int) -> CausalGraph {
  let graph = CausalGraph::new()
  let mut frontier : Array[Int] = []
  for _ in 0..<operation_count {
    frontier = [try! graph.add_version(frontier, "agent")]
  }
  graph
}

///|
test "perf: graph version warm snapshot (1000 ops)" (b : @bench.T) {
  let graph = graph_version_benchmark_graph(1000)
  ignore(graph.current_graph_version())
  b.bench(() => b.keep(graph.current_graph_version()))
}

///|
test "perf: graph version warm snapshot (100000 ops)" (b : @bench.T) {
  let graph = graph_version_benchmark_graph(100000)
  ignore(graph.current_graph_version())
  b.bench(() => b.keep(graph.current_graph_version()))
}

///|
test "perf: graph version fragmented warm snapshot (32x32 ranges)" (
  b : @bench.T,
) {
  let graph = CausalGraph::new()
  for agent in 0..<32 {
    for range in 0..<32 {
      ignore(
        try! graph.add_version_with_seq(
          [],
          "agent-" + agent.to_string(),
          range * 2,
        ),
      )
    }
  }
  ignore(graph.current_graph_version())
  b.bench(() => b.keep(graph.current_graph_version()))
}

///|
test "perf: graph version cold reconstruction (1000 ops)" (b : @bench.T) {
  let graph = graph_version_benchmark_graph(1000)
  b.bench(fn() {
    graph.version_cache = Cold
    b.keep(graph.current_graph_version())
  })
}

///|
test "perf: sparse summary insert (32 agents)" (b : @bench.T) {
  let source = HaveSummary::empty()
  for i in 0..<32 {
    source.insert(@core.RawVersion("agent-" + i.to_string(), 100))
  }
  b.bench(fn() {
    let summary = source.copy()
    summary.insert(@core.RawVersion("agent-31", 101))
    b.keep(summary)
  })
}
