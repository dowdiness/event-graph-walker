///|
/// CausalGraph - tracks operation dependencies and causal ordering
///
/// Stores both parent and children edges for bidirectional traversal:
/// - parents: backward traversal (is_ancestor, transitive_closure)
/// - children: forward traversal (topological_sort, walk_from_frontier)
///
/// Uses flat arrays indexed by LV (0..n-1) for O(1) lookup.
pub struct CausalGraph {
  priv entries : Array[@core.GraphEntry?]
  priv children : Array[Array[Int]]
  priv mut version_map : @immut/hashmap.HashMap[@core.RawVersion, Int]
  priv mut next_lv : Int
  priv mut frontier : @core.Frontier
  priv mut agent_seqs : @immut/hashmap.HashMap[String, Int]
  // Reusable query buffers — amortize allocation across repeated calls.
  // query_visited: generation-counter visited set (query_visited[lv] == gen → visited)
  // query_int_buf: reusable int buffer for in-degrees etc.
  priv query_visited : Array[Int]
  priv mut query_gen : Int
  priv query_int_buf : Array[Int]
} derive(Show)

///|
/// Create a new empty CausalGraph
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
    query_int_buf: [],
  }
}

///|
/// Ensure query buffers are large enough for the current graph size.
/// Doubles capacity to amortize reallocation.
fn CausalGraph::ensure_query_buffers(self : CausalGraph) -> Unit {
  let n = self.next_lv
  if self.query_visited.length() < n {
    let cap = if n < 16 { 16 } else { n * 2 }
    // Reallocate — old gen values become invalid, reset gen
    self.query_visited.resize(cap, 0)
    self.query_int_buf.resize(cap, 0)
    self.query_gen = 0
  }
}

///|
/// Get a fresh generation number for the query visited buffer.
fn CausalGraph::fresh_gen(self : CausalGraph) -> Int {
  self.ensure_query_buffers()
  self.query_gen = self.query_gen + 1
  self.query_gen
}

///|
/// Convert LV to RawVersion
pub fn CausalGraph::lv_to_raw(
  self : CausalGraph,
  lv : Int,
) -> @core.RawVersion? {
  if lv < 0 || lv >= self.next_lv {
    return None
  }
  match self.entries[lv] {
    Some(entry) => Some(@core.RawVersion::new(entry.agent, entry.seq))
    None => None
  }
}

///|
/// Convert RawVersion to LV
pub fn CausalGraph::raw_to_lv(
  self : CausalGraph,
  raw : @core.RawVersion,
) -> Int? {
  self.version_map.get(raw)
}

///|
/// Index operator for looking up a graph entry by LV.
/// Returns the graph entry for the given LV, or None if missing.
///
#alias("_[_]")
pub fn CausalGraph::get_entry(
  self : CausalGraph,
  lv : Int,
) -> @core.GraphEntry? {
  if lv < 0 || lv >= self.next_lv {
    return None
  }
  self.entries[lv]
}

///|
/// Add a new version to the graph
pub fn CausalGraph::add_version(
  self : CausalGraph,
  parents : Array[Int],
  agent : String,
) -> Int raise CausalGraphError {
  for parent in parents {
    if parent < 0 || parent >= self.next_lv || self.entries[parent] is None {
      raise CausalGraphError::MissingParent(lv=parent)
    }
  }
  // Calculate Lamport timestamp (max of parents + 1)
  let timestamp = if parents.is_empty() {
    0
  } else {
    let mut max_ts = 0
    for p in parents {
      match self.entries[p] {
        Some(entry) => if entry.timestamp > max_ts { max_ts = entry.timestamp }
        None => ()
      }
    }
    max_ts + 1
  }

  // Get next sequence for this agent
  let seq = match self.agent_seqs.get(agent) {
    Some(s) => s + 1
    None => 0
  }

  // Create entry
  let lv = self.next_lv
  let entry = @core.GraphEntry::{ parents, agent, seq, timestamp }

  // Append to flat arrays
  self.entries.push(Some(entry))
  self.children.push([])

  // Maintain children index: for each parent, record this LV as a child
  for p in parents {
    self.children[p].push(lv)
  }

  self.version_map = self.version_map.add(@core.RawVersion::new(agent, seq), lv)
  self.next_lv = lv + 1
  self.agent_seqs = self.agent_seqs.add(agent, seq)

  // Update frontier
  self.update_frontier(lv, parents)
  lv
}

///|
/// Add a new version with an explicit sequence number
pub fn CausalGraph::add_version_with_seq(
  self : CausalGraph,
  parents : Array[Int],
  agent : String,
  seq : Int,
) -> Int raise CausalGraphError {
  for parent in parents {
    if parent < 0 || parent >= self.next_lv || self.entries[parent] is None {
      raise CausalGraphError::MissingParent(lv=parent)
    }
  }
  // Calculate Lamport timestamp (max of parents + 1)
  let timestamp = if parents.is_empty() {
    0
  } else {
    let mut max_ts = 0
    for p in parents {
      match self.entries[p] {
        Some(entry) => if entry.timestamp > max_ts { max_ts = entry.timestamp }
        None => ()
      }
    }
    max_ts + 1
  }

  // Create entry
  let lv = self.next_lv
  let entry = @core.GraphEntry::{ parents, agent, seq, timestamp }

  // Append to flat arrays
  self.entries.push(Some(entry))
  self.children.push([])

  // Maintain children index
  for p in parents {
    self.children[p].push(lv)
  }

  self.version_map = self.version_map.add(@core.RawVersion::new(agent, seq), lv)
  self.next_lv = lv + 1
  let current_seq = self.agent_seqs.get(agent).unwrap_or(-1)
  let next_seq = if seq > current_seq { seq } else { current_seq }
  self.agent_seqs = self.agent_seqs.add(agent, next_seq)

  // Update frontier
  self.update_frontier(lv, parents)
  lv
}

///|
/// Update frontier after adding a version
fn CausalGraph::update_frontier(
  self : CausalGraph,
  new_lv : Int,
  parents : Array[Int],
) -> Unit {
  // Remove all parents from frontier (they now have a successor)
  let mut frontier = self.frontier.0.copy()
  frontier = frontier.filter(v => !parents.contains(v))

  // Add new version
  frontier.push(new_lv)
  self.frontier = @core.Frontier::from_array(frontier)
}

///|
/// Get current frontier
pub fn CausalGraph::get_frontier(self : CausalGraph) -> @core.Frontier {
  @core.Frontier::from_array(self.frontier.0.copy())
}

///|
/// Check if lv1 is an ancestor of lv2
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
  // BFS backward through parents. Uses gen-counter visited set (O(1) reset).
  let gen = self.fresh_gen()
  let visited = self.query_visited
  let queue : Array[Int] = []
  match self.entries[lv2] {
    Some(entry) =>
      for parent in entry.parents {
        queue.push(parent)
      }
    None => return false
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
    match self.entries[current] {
      Some(entry) =>
        for parent in entry.parents {
          if visited[parent] != gen {
            queue.push(parent)
          }
        }
      None => ()
    }
  }
  false
}

///|
/// Collect all LVs reachable from frontier via backward BFS through parents.
/// Uses gen-counter visited set (O(1) reset). Returns (gen, reachable_lvs)
/// where gen marks which entries in query_visited are in this set.

///|
/// BFS backward through parents using a given visited buffer + generation.
/// Returns the list of reachable LVs. Marks visited[lv] = gen for each.
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
    match self.entries[current] {
      Some(entry) =>
        for parent in entry.parents {
          if visited[parent] != gen {
            queue.push(parent)
          }
        }
      None => ()
    }
  }
  reachable
}

///|
/// Transitive closure using the shared query_visited buffer.
/// Returns (gen, reachable_lvs).
fn CausalGraph::transitive_closure_gen(
  self : CausalGraph,
  frontiers : @core.Frontier,
) -> (Int, Array[Int]) {
  let gen = self.fresh_gen()
  let reachable = self.bfs_backward(frontiers, self.query_visited, gen)
  (gen, reachable)
}

///|
/// Compute the symmetric difference between two frontiers as LV sets.
///
/// Returns `(retreat, advance)` where:
/// - `retreat` — LVs reachable from `from` but **not** from `to`
///   (operations that must be *undone* when moving from → to)
/// - `advance` — LVs reachable from `to` but **not** from `from`
///   (operations that must be *applied* when moving from → to)
///
/// Both sets are returned as unsorted arrays; call `diff_frontiers_lvs`
/// for a topologically ordered version ready for replay.
pub fn CausalGraph::graph_diff(
  self : CausalGraph,
  from : @core.Frontier,
  to : @core.Frontier,
) -> (Array[Int], Array[Int]) {
  self.ensure_query_buffers()
  // Use two separate buffers to avoid interference.
  // "from" set marked in query_visited, "to" set marked in query_int_buf.
  let from_gen = self.fresh_gen()
  let from_lvs = self.bfs_backward(from, self.query_visited, from_gen)
  let to_gen = self.fresh_gen()
  let to_lvs = self.bfs_backward(to, self.query_int_buf, to_gen)
  // retreat = in from but not in to
  let retreat : Array[Int] = []
  let to_buf = self.query_int_buf
  for lv in from_lvs {
    if to_buf[lv] != to_gen {
      retreat.push(lv)
    }
  }
  // advance = in to but not in from
  let advance : Array[Int] = []
  let from_buf = self.query_visited
  for lv in to_lvs {
    if from_buf[lv] != from_gen {
      advance.push(lv)
    }
  }
  (retreat, advance)
}
