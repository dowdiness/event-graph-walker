///|
/// Append-only causal intervals. Every parent LV precedes its child LV.
pub struct CausalGraph {
  priv runs : Array[CausalRun]
  priv agent_runs : Map[String, IdentityIndex]
  priv mut next_lv : Int
  priv mut frontier : @core.Frontier
  priv agent_seqs : Map[String, Int]
  priv mut version_cache : GraphVersionCache
}

///|
pub impl @debug.Debug for CausalGraph with fn to_repr(self) {
  @debug.Repr::literal("CausalGraph(entries=" + self.next_lv.to_string() + ")")
}

///|
pub fn CausalGraph::new() -> CausalGraph {
  {
    runs: [],
    agent_runs: Map([]),
    next_lv: 0,
    frontier: @core.Frontier::from_array([]),
    agent_seqs: Map([]),
    version_cache: Cold,
  }
}

///|
pub fn CausalGraph::lv_to_raw(
  self : CausalGraph,
  lv : Int,
) -> @core.RawVersion? {
  if lv < 0 || lv >= self.next_lv {
    return None
  }
  let run = self.run_at(lv)
  Some(@core.RawVersion(run.agent, run.seq + (lv - run.start)))
}

///|
pub fn CausalGraph::raw_to_lv(
  self : CausalGraph,
  raw : @core.RawVersion,
) -> Int? {
  guard raw.seq >= 0 && self.agent_runs.get(raw.agent) is Some(index) else {
    return None
  }
  index.find(raw.seq).map(run => run.start + (raw.seq - run.seq))
}

///|
/// Materialize a single diagnostic entry; traversal does not use this API.
#alias("_[_]")
pub fn CausalGraph::get_entry(
  self : CausalGraph,
  lv : Int,
) -> @core.GraphEntry? {
  if lv < 0 || lv >= self.next_lv {
    return None
  }
  let run = self.run_at(lv)
  let offset = lv - run.start
  Some(@core.GraphEntry::{
    parents: if offset == 0 {
      run.parents.copy()
    } else {
      [lv - 1]
    },
    agent: run.agent,
    seq: run.seq + offset,
    timestamp: run.timestamp + offset,
  })
}

///|
fn CausalGraph::add_version_inner(
  self : CausalGraph,
  parents : Array[Int],
  agent : String,
  seq : Int,
) -> Int raise CausalGraphError {
  if agent == "" || seq < 0 {
    raise CausalGraphError::InvalidIdentity(raw=@core.RawVersion(agent, seq))
  }
  if self.agent_runs.get(agent) is Some(index) && index.find(seq) is Some(_) {
    raise CausalGraphError::DuplicateVersion(raw=@core.RawVersion(agent, seq))
  }
  let mut timestamp = 0
  for parent in parents {
    if parent < 0 || parent >= self.next_lv {
      raise CausalGraphError::MissingParent(lv=parent)
    }
    let run = self.run_at(parent)
    let rank = run.timestamp + (parent - run.start)
    if rank >= timestamp {
      timestamp = rank + 1
    }
  }
  let lv = self.next_lv
  self.append_entry(parents, agent, seq, timestamp)
  self.frontier = self.frontier.advance(lv, parents)
  match self.version_cache {
    Cold => ()
    Hot(summary) => summary.insert(@core.RawVersion(agent, seq))
  }
  lv
}

///|
pub fn CausalGraph::add_version(
  self : CausalGraph,
  parents : Array[Int],
  agent : String,
) -> Int raise CausalGraphError {
  let seq = self.agent_seqs.get(agent).unwrap_or(-1) + 1
  let lv = self.add_version_inner(parents, agent, seq)
  self.agent_seqs[agent] = seq
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
  let previous = self.agent_seqs.get(agent).unwrap_or(-1)
  self.agent_seqs[agent] = if seq > previous { seq } else { previous }
  lv
}

///|
pub fn CausalGraph::get_frontier(self : CausalGraph) -> @core.Frontier {
  self.frontier
}

///|
pub fn CausalGraph::op_count(self : CausalGraph) -> Int {
  self.next_lv
}

///|
/// Owning diagnostic counts indexed by LV. One O(events + head edges) pass;
/// no child index or diagnostic cache is retained by the graph.
pub fn CausalGraph::children_counts(self : CausalGraph) -> Array[Int] {
  let counts = Array::make(self.next_lv, 1)
  for head in self.runs {
    counts[head.start + head.count - 1] = 0
  }
  for head in self.runs {
    for parent in head.parents {
      counts[parent] += 1
    }
  }
  counts
}

///|
pub fn CausalGraph::is_ancestor(
  self : CausalGraph,
  lv1 : Int,
  lv2 : Int,
) -> Bool {
  if lv1 < 0 || lv2 < 0 || lv1 >= self.next_lv || lv2 >= self.next_lv {
    return false
  }
  self.walk_from_frontier(@core.Frontier::from_array([lv2])).contains(lv1)
}

///|
pub impl Show for CausalGraph with fn output(self, logger) {
  logger.write_string("CausalGraph(")
  logger.write_string(self.next_lv.to_string())
  logger.write_string(" versions)")
}

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend CausalGraph with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend CausalGraph with Show::{to_string}

///|
#deprecated("Use `Show::output` via the trait or `to_string` instead", skip_current_package=true)
#doc(hidden)
pub extend CausalGraph with Show::{output}
