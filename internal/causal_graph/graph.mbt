///|
/// CausalGraph - tracks operation dependencies and causal ordering
///
/// Stores both parent and children edges for bidirectional traversal:
/// - parents: backward traversal (is_ancestor, transitive_closure)
/// - children: forward traversal (topological_sort, walk_from_frontier)
///
/// Uses flat arrays indexed by LV (0..n-1) for O(1) lookup.
pub struct CausalGraph {
  priv entries : Array[@core.GraphEntry]
  priv children : Array[Array[Int]]
  priv mut version_map : @immut/hashmap.HashMap[@core.RawVersion, Int]
  priv mut next_lv : Int
  priv mut frontier : @core.Frontier
  priv mut agent_seqs : @immut/hashmap.HashMap[String, Int]
  // Reusable query buffers — amortize allocation across repeated calls.
  // Two gen-counter visited buffers (independent counters).
  // One in-degree buffer for toposort (manually zeroed before/after use).
  priv query_visited : Array[Int]
  priv mut query_gen : Int
  priv query_visited2 : Array[Int]
  priv mut query_gen2 : Int
  priv query_int_buf : Array[Int]
}

///|
pub impl @debug.Debug for CausalGraph with to_repr(self) {
  @debug.Repr::literal(
    "CausalGraph(entries=" + self.entries.length().to_string() + ")",
  )
}

///|
pub fn CausalGraph::new() -> CausalGraph {
  {
    entries: [],
    children: [],
    version_map: @immut/hashmap.new(),
    next_lv: 0,
    frontier: @core.Frontier::from_array([]),
    agent_seqs: @immut/hashmap.new(),
    query_visited: [],
    query_gen: 0,
    query_visited2: [],
    query_gen2: 0,
    query_int_buf: [],
  }
}

///|
fn CausalGraph::ensure_query_buffers(self : CausalGraph) -> Unit {
  let n = self.next_lv
  if self.query_visited.length() < n {
    let cap = if n < 16 { 16 } else { n * 2 }
    self.query_visited.resize(cap, 0)
    self.query_visited2.resize(cap, 0)
    self.query_int_buf.resize(cap, 0)
    self.query_gen = 0
    self.query_gen2 = 0
  }
}

///|
fn CausalGraph::fresh_gen(self : CausalGraph) -> Int {
  self.ensure_query_buffers()
  self.query_gen = self.query_gen + 1
  self.query_gen
}

///|
fn CausalGraph::fresh_gen2(self : CausalGraph) -> Int {
  self.ensure_query_buffers()
  self.query_gen2 = self.query_gen2 + 1
  self.query_gen2
}

///|
pub fn CausalGraph::lv_to_raw(
  self : CausalGraph,
  lv : Int,
) -> @core.RawVersion? {
  if lv < 0 || lv >= self.next_lv {
    return None
  }
  let entry = self.entries[lv]
  Some(@core.RawVersion::new(entry.agent, entry.seq))
}

///|
pub fn CausalGraph::raw_to_lv(
  self : CausalGraph,
  raw : @core.RawVersion,
) -> Int? {
  self.version_map.get(raw)
}

///|
#alias("_[_]")
pub fn CausalGraph::get_entry(
  self : CausalGraph,
  lv : Int,
) -> @core.GraphEntry? {
  if lv < 0 || lv >= self.next_lv {
    return None
  }
  Some(self.entries[lv])
}

///|
/// Shared logic for add_version and add_version_with_seq.
fn CausalGraph::add_version_inner(
  self : CausalGraph,
  parents : Array[Int],
  agent : String,
  seq : Int,
) -> Int raise CausalGraphError {
  for parent in parents {
    if parent < 0 || parent >= self.next_lv {
      raise CausalGraphError::MissingParent(lv=parent)
    }
  }
  let timestamp = if parents.is_empty() {
    0
  } else {
    for p in parents; max_ts = 0 {
      let ts = self.entries[p].timestamp
      continue if ts > max_ts { ts } else { max_ts }
    } nobreak {
      max_ts + 1
    }
  }
  let lv = self.next_lv
  let entry = @core.GraphEntry::{ parents, agent, seq, timestamp }
  self.entries.push(entry)
  self.children.push([])
  for p in parents {
    self.children[p].push(lv)
  }
  self.version_map = self.version_map.add(@core.RawVersion::new(agent, seq), lv)
  self.next_lv = lv + 1
  self.update_frontier(lv, parents)
  lv
}

///|
pub fn CausalGraph::add_version(
  self : CausalGraph,
  parents : Array[Int],
  agent : String,
) -> Int raise CausalGraphError {
  let seq = match self.agent_seqs.get(agent) {
    Some(s) => s + 1
    None => 0
  }
  let lv = self.add_version_inner(parents, agent, seq)
  self.agent_seqs = self.agent_seqs.add(agent, seq)
  lv
}

///|
pub fn CausalGraph::add_version_with_seq(
  self : CausalGraph,
  parents : Array[Int],
  agent : String,
  seq : Int,
) -> Int raise CausalGraphError {
  let lv = self.add_version_inner(parents, agent, seq)
  let current_seq = self.agent_seqs.get(agent).unwrap_or(-1)
  let next_seq = if seq > current_seq { seq } else { current_seq }
  self.agent_seqs = self.agent_seqs.add(agent, next_seq)
  lv
}

///|
fn CausalGraph::update_frontier(
  self : CausalGraph,
  new_lv : Int,
  parents : Array[Int],
) -> Unit {
  let mut frontier = self.frontier.0.copy()
  frontier = frontier.filter(v => !parents.contains(v))
  frontier.push(new_lv)
  self.frontier = @core.Frontier::from_array(frontier)
}

///|
pub fn CausalGraph::get_frontier(self : CausalGraph) -> @core.Frontier {
  @core.Frontier::from_array(self.frontier.0.copy())
}

///|
pub fn CausalGraph::is_ancestor(
  self : CausalGraph,
  lv1 : Int,
  lv2 : Int,
) -> Bool {
  if lv1 == lv2 {
    return true
  }
  let n = self.next_lv
  if lv1 < 0 || lv1 >= n || lv2 < 0 || lv2 >= n {
    return false
  }
  let gen = self.fresh_gen()
  let visited = self.query_visited
  let queue : Array[Int] = []
  for parent in self.entries[lv2].parents {
    queue.push(parent)
  }
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    if current == lv1 {
      return true
    }
    if visited[current] == gen {
      continue
    }
    visited[current] = gen
    for parent in self.entries[current].parents {
      if visited[parent] != gen {
        queue.push(parent)
      }
    }
  }
  false
}

///|
/// BFS backward through parents. Marks visited[lv] = gen for each reachable LV.
fn CausalGraph::bfs_backward(
  self : CausalGraph,
  frontiers : @core.Frontier,
  visited : Array[Int],
  gen : Int,
) -> Array[Int] {
  let n = self.next_lv
  let reachable : Array[Int] = []
  let queue : Array[Int] = []
  for lv in frontiers.0 {
    if lv >= 0 && lv < n {
      queue.push(lv)
    }
  }
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    if visited[current] == gen {
      continue
    }
    visited[current] = gen
    reachable.push(current)
    for parent in self.entries[current].parents {
      if visited[parent] != gen {
        queue.push(parent)
      }
    }
  }
  reachable
}

///|
fn CausalGraph::transitive_closure_gen(
  self : CausalGraph,
  frontiers : @core.Frontier,
) -> (Int, Array[Int]) {
  let gen = self.fresh_gen()
  let reachable = self.bfs_backward(frontiers, self.query_visited, gen)
  (gen, reachable)
}

///|
/// Topological sort a subset, marking membership in query_visited.
fn CausalGraph::toposort_lv_set(
  self : CausalGraph,
  lv_set : Array[Int],
) -> @rle.Rle[@core.LvRange] {
  let gen = self.fresh_gen()
  let visited = self.query_visited
  for lv in lv_set {
    visited[lv] = gen
  }
  topological_sort_subset(self, lv_set, visited, gen)
}

///|
pub fn CausalGraph::graph_diff(
  self : CausalGraph,
  from : @core.Frontier,
  to : @core.Frontier,
) -> (Array[Int], Array[Int]) {
  // Two BFS passes on independent buffers (no interference)
  let from_gen = self.fresh_gen()
  let from_lvs = self.bfs_backward(from, self.query_visited, from_gen)
  let to_gen = self.fresh_gen2()
  let to_lvs = self.bfs_backward(to, self.query_visited2, to_gen)
  let retreat : Array[Int] = []
  let to_buf = self.query_visited2
  for lv in from_lvs {
    if to_buf[lv] != to_gen {
      retreat.push(lv)
    }
  }
  let advance : Array[Int] = []
  let from_buf = self.query_visited
  for lv in to_lvs {
    if from_buf[lv] != from_gen {
      advance.push(lv)
    }
  }
  (retreat, advance)
}

///|
pub impl Show for CausalGraph with output(self, logger) {
  logger.write_string("CausalGraph(")
  logger.write_string(self.next_lv.to_string())
  logger.write_string(" versions)")
}
