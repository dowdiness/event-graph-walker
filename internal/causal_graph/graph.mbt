///|
/// CausalGraph - tracks operation dependencies and causal ordering
pub struct CausalGraph {
  mut entries : @immut/hashmap.HashMap[Int, @core.GraphEntry]
  mut version_map : @immut/hashmap.HashMap[@core.RawVersion, Int]
  mut next_lv : Int
  mut frontier : @core.Frontier
  mut agent_seqs : @immut/hashmap.HashMap[String, Int]
} derive(Show)

///|
/// Create a new empty CausalGraph
pub fn CausalGraph::new() -> CausalGraph {
  {
    entries: @immut/hashmap.new(),
    version_map: @immut/hashmap.new(),
    next_lv: 0,
    frontier: @core.Frontier::from_array([]),
    agent_seqs: @immut/hashmap.new(),
  }
}

///|
/// Convert LV to RawVersion
pub fn CausalGraph::lv_to_raw(
  self : CausalGraph,
  lv : Int,
) -> @core.RawVersion? {
  match self.entries.get(lv) {
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
/// Get graph entry by LV
#alias("_[_]")
pub fn CausalGraph::get_entry(
  self : CausalGraph,
  lv : Int,
) -> @core.GraphEntry? {
  self.entries.get(lv)
}

///|
/// Add a new version to the graph
pub fn CausalGraph::add_version(
  self : CausalGraph,
  parents : Array[Int],
  agent : String,
) -> Int raise CausalGraphError {
  for parent in parents {
    if self.entries.get(parent) is None {
      raise CausalGraphError::MissingParent(lv=parent)
    }
  }
  // Calculate Lamport timestamp (max of parents + 1)
  let timestamp = if parents.is_empty() {
    0
  } else {
    let max_parent_timestamp = parents
      .iter()
      .filter_map(lv => self.entries.get(lv))
      .fold((prev_max, curr) => curr.timestamp.max(prev_max), init=0)
    max_parent_timestamp + 1
  }

  // Get next sequence for this agent
  let seq = match self.agent_seqs.get(agent) {
    Some(s) => s + 1
    None => 0
  }

  // Create entry
  let lv = self.next_lv
  let entry = @core.GraphEntry::{ parents, agent, seq, timestamp }

  // Update graph
  self.entries = self.entries.add(lv, entry)
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
    if self.entries.get(parent) is None {
      raise CausalGraphError::MissingParent(lv=parent)
    }
  }
  // Calculate Lamport timestamp (max of parents + 1)
  let timestamp = if parents.is_empty() {
    0
  } else {
    let max_parent_timestamp = parents
      .iter()
      .filter_map(lv => self.entries.get(lv))
      .fold((prev_max, curr) => curr.timestamp.max(prev_max), init=0)
    max_parent_timestamp + 1
  }

  // Create entry
  let lv = self.next_lv
  let entry = @core.GraphEntry::{ parents, agent, seq, timestamp }

  // Update graph
  self.entries = self.entries.add(lv, entry)
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
  frontier = frontier.filter(v => not(parents.contains(v)))

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

  // BFS to find if lv1 is reachable from lv2's parents
  let mut visited : @immut/hashset.HashSet[Int] = @immut/hashset.new()
  let queue = @queue.Queue::new()
  match self.entries.get(lv2) {
    Some(entry) =>
      for parent in entry.parents {
        queue.push(parent)
      }
    None => return false
  }
  while not(queue.is_empty()) {
    match queue.pop() {
      Some(current) => {
        if current == lv1 {
          return true
        }
        if visited.contains(current) {
          continue
        }
        visited = visited.add(current)
        match self.entries.get(current) {
          Some(entry) =>
            for parent in entry.parents {
              queue.push(parent)
            }
          None => ()
        }
      }
      None => break
    }
  }
  false
}

///|
/// Get all versions reachable from given frontiers (transitive closure)
fn CausalGraph::transitive_closure(
  self : CausalGraph,
  frontiers : @core.Frontier,
) -> @immut/hashset.HashSet[Int] {
  let mut result : @immut/hashset.HashSet[Int] = @immut/hashset.new()
  let queue = @queue.from_array(frontiers.0)
  while not(queue.is_empty()) {
    match queue.pop() {
      Some(current) => {
        if result.contains(current) {
          continue
        }
        result = result.add(current)
        match self.entries.get(current) {
          Some(entry) =>
            for parent in entry.parents {
              queue.push(parent)
            }
          None => ()
        }
      }
      None => break
    }
  }
  result
}

///|
/// Calculate diff between two frontiers for retreat/advance
pub fn CausalGraph::graph_diff(
  self : CausalGraph,
  from : @core.Frontier,
  to : @core.Frontier,
) -> (Array[Int], Array[Int]) {
  let from_set = self.transitive_closure(from)
  let to_set = self.transitive_closure(to)

  // from_set.difference(to_set)
  // retreat = versions in 'from' but not in 'to'
  let retreat = from_set.difference(to_set).iter().to_array()

  // advance = versions in 'to' but not in 'from'
  let advance = to_set.difference(from_set).iter().to_array()
  (retreat, advance)
}
