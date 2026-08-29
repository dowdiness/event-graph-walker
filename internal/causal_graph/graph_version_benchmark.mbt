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

///|
fn resource_agent_name(index : Int) -> String {
  let digits = index.to_string()
  "agent-" + "0".repeat(5 - digits.length()) + digits
}

///|
/// Build independent per-agent causal chains whose even sequence numbers form
/// the requested number of non-adjacent knowledge ranges.
fn graph_version_resource_graph(
  agent_count : Int,
  ranges_per_agent : Int,
) -> CausalGraph {
  let graph = CausalGraph::new()
  for agent_index in 0..<agent_count {
    let agent = resource_agent_name(agent_index)
    let mut frontier : Array[Int] = []
    for range_index in 0..<ranges_per_agent {
      frontier = [
        try! graph.add_version_with_seq(frontier, agent, range_index * 2),
      ]
    }
  }
  graph
}

///|
test "resource: warm snapshot (1 agent x 37000 ranges)" (b : @bench.T) {
  let graph = graph_version_resource_graph(1, 37000)
  ignore(graph.current_graph_version())
  b.bench(() => b.keep(graph.current_graph_version()))
}

///|
test "resource: resolve (1 agent x 37000 ranges)" (b : @bench.T) {
  let graph = graph_version_resource_graph(1, 37000)
  let version = graph.current_graph_version()
  b.bench(() => b.keep(graph.resolve_graph_version(version)))
}

///|
test "resource: warm snapshot (8000 agents x 1 range)" (b : @bench.T) {
  let graph = graph_version_resource_graph(8000, 1)
  ignore(graph.current_graph_version())
  b.bench(() => b.keep(graph.current_graph_version()))
}

///|
test "resource: resolve (8000 agents x 1 range)" (b : @bench.T) {
  let graph = graph_version_resource_graph(8000, 1)
  let version = graph.current_graph_version()
  b.bench(() => b.keep(graph.resolve_graph_version(version)))
}

///|
test "resource: warm snapshot (512 agents x 64 ranges)" (b : @bench.T) {
  let graph = graph_version_resource_graph(512, 64)
  ignore(graph.current_graph_version())
  b.bench(() => b.keep(graph.current_graph_version()))
}

///|
test "resource: resolve (512 agents x 64 ranges)" (b : @bench.T) {
  let graph = graph_version_resource_graph(512, 64)
  let version = graph.current_graph_version()
  b.bench(() => b.keep(graph.resolve_graph_version(version)))
}

///|
test "resource limit: resolve (1 agent x 4096 ranges)" (b : @bench.T) {
  let graph = graph_version_resource_graph(1, 4096)
  let version = graph.current_graph_version()
  b.bench(() => b.keep(graph.resolve_graph_version(version)))
}

///|
test "resource limit: resolve (4096 agents x 1 range)" (b : @bench.T) {
  let graph = graph_version_resource_graph(4096, 1)
  let version = graph.current_graph_version()
  b.bench(() => b.keep(graph.resolve_graph_version(version)))
}

///|
test "resource limit: resolve (64 agents x 64 ranges)" (b : @bench.T) {
  let graph = graph_version_resource_graph(64, 64)
  let version = graph.current_graph_version()
  b.bench(() => b.keep(graph.resolve_graph_version(version)))
}
