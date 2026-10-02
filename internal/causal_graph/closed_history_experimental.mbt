///| Checked one-pass authority construction for an unpublished complete history.
/// Origins do not participate in causal ranks, child edges or frontier.

///|
pub fn CausalGraph::from_topological_ops_experimental(
  operations : ArrayView[@core.Op],
) -> CausalGraph raise CausalGraphError {
  let graph : CausalGraph = {
    entries: Array(capacity=operations.length()),
    children: Array(capacity=operations.length()),
    version_map: Map([]),
    next_lv: 0,
    frontier: @core.Frontier::from_array([]),
    agent_seqs: Map([]),
    version_cache: GraphVersionCache::Cold,
    query_visited: [],
    query_gen: 0,
    query_visited2: [],
    query_gen2: 0,
    query_int_buf: [],
  }
  for index, op in operations {
    let raw = @core.RawVersion(op.agent(), op.seq())
    if raw.agent == "" || raw.seq < 0 {
      raise CausalGraphError::InvalidIdentity(raw~)
    }
    if graph.version_map.contains(raw) {
      raise CausalGraphError::DuplicateVersion(raw~)
    }
    let parents : Array[Int] = []
    let mut timestamp = 0
    for parent in op.parents_iter() {
      let lv = match graph.version_map.get(parent) {
        Some(lv) if lv >= 0 && lv < index => lv
        _ => raise CausalGraphError::MissingParent(lv=-1)
      }
      parents.push(lv)
      let rank = graph.entries[lv].timestamp
      if rank >= timestamp {
        timestamp = rank + 1
      }
    }
    // All input identity/parent checks precede this row's candidate mutation.
    // parents is newly owned; no caller array becomes graph storage.
    graph.entries.push(@core.GraphEntry::{
      parents,
      agent: raw.agent,
      seq: raw.seq,
      timestamp,
    })
    graph.children.push([])
    for parent in parents {
      graph.children[parent].push(index)
    }
    graph.version_map[raw] = index
    let old_max = graph.agent_seqs.get(raw.agent).unwrap_or(-1)
    if raw.seq > old_max {
      graph.agent_seqs[raw.agent] = raw.seq
    }
  }
  graph.next_lv = operations.length()
  let heads : Array[Int] = []
  for lv = 0; lv < graph.next_lv; lv = lv + 1 {
    if graph.children[lv].is_empty() {
      heads.push(lv)
    }
  }
  // Exactly Frontier.advance's surviving insertion order, without per-op copies.
  graph.frontier = @core.Frontier::from_array(heads)
  graph
}
