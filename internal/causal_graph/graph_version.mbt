///|
/// One canonical half-open sequence range in peer knowledge.
#derive(Debug, Eq, Hash)
priv struct SequenceRange {
  start : UInt32
  end : UInt32
}

///|
#derive(Debug, Eq, Hash)
priv struct HaveEntry {
  agent : String
  ranges : Array[SequenceRange]
}

///|
/// Exact membership knowledge. Entries and ranges are canonical: sorted,
/// unique, non-overlapping, and non-adjacent.
#derive(Debug, Eq, Hash)
priv struct HaveSummary {
  entries : Array[HaveEntry]
}

///|
/// Exact maximal identities for one causal cut.
#derive(Debug, Eq, Hash)
priv struct CausalCheckpoint {
  frontier : Array[@core.RawVersion]
}

///|
/// One opaque graph version statement. The checkpoint names an exact causal
/// cut; `have` names the identities in that cut's closure.
#derive(Debug, Eq, Hash)
pub struct GraphVersion {
  priv checkpoint : CausalCheckpoint
  priv have : HaveSummary
}

///|
#derive(Debug)
pub suberror GraphVersionError {
  Invalid
}

///|
/// Current-summary cache owned by the causal authority. A cold graph pays no
/// summary-maintenance cost until its version is first observed.
priv enum GraphVersionCache {
  Cold
  Hot(HaveIndex)
}

///|
priv struct HaveIndex {
  agents : @sorted_map.SortedMap[String, SequenceIndex]
  mut snapshot : HaveSummary?
}

///|
/// Membership of a retained editing projection. It starts at a complete cut;
/// every appended local operation must name its current frontier as parents.
pub struct ViewVersion {
  priv index : HaveIndex
  priv mut checkpoint : CausalCheckpoint
}

///|
pub fn ViewVersion::ViewVersion(version : GraphVersion) -> ViewVersion {
  {
    index: HaveIndex::from_summary(version.have),
    checkpoint: version.checkpoint,
  }
}

///|
pub fn ViewVersion::append(self : ViewVersion, raw : @core.RawVersion) -> Unit {
  self.index.insert(raw)
  self.checkpoint = { frontier: [raw], }
}

///|
pub fn ViewVersion::snapshot(self : ViewVersion) -> GraphVersion {
  { checkpoint: self.checkpoint, have: self.index.snapshot(), }
}

///|
pub fn ViewVersion::contains(
  self : ViewVersion,
  raw : @core.RawVersion,
) -> Bool {
  guard raw.seq >= 0 && self.index.agents.get(raw.agent) is Some(index) else {
    return false
  }
  let sequence = raw.seq.reinterpret_as_uint()
  let mut node = index.root
  while node is Some(current) {
    if sequence < current.range.start {
      node = current.left
    } else if sequence >= current.range.end {
      node = current.right
    } else {
      return true
    }
  }
  false
}

///|
/// Publish newly projected identities, preserving the existing membership index.
/// The caller supplies the previously absent LV ranges from this graph.
pub fn ViewVersion::advance(
  self : ViewVersion,
  graph : CausalGraph,
  added : RangeSet,
) -> Unit {
  self.index.snapshot = None
  for range in added.iter() {
    let mut lv = range.start
    while lv < range.end() {
      let run = graph.run_at(lv)
      let end = Int32::min(range.end(), run.start + run.count)
      let start = run.seq.reinterpret_as_uint() +
        (lv - run.start).reinterpret_as_uint()
      let index = self.index.agents.get_or_init(run.agent, () => { root: None, })
      index.insert_range({
        start,
        end: start + (end - lv).reinterpret_as_uint(),
      })
      lv = end
    }
  }
  let frontier = graph.frontier
    .to_array()
    .map(lv => graph.lv_to_raw(lv).unwrap())
  frontier.sort_by(compare_graph_raw)
  self.checkpoint = { frontier, }
}

///|
fn compare_graph_raw(a : @core.RawVersion, b : @core.RawVersion) -> Int32 {
  match a.agent.compare(b.agent) {
    0 => a.seq.compare(b.seq)
    other => other
  }
}

///|
fn HaveSummary::empty() -> HaveSummary {
  { entries: [], }
}

///|
fn HaveIndex::from_summary(summary : HaveSummary) -> HaveIndex {
  let agents : @sorted_map.SortedMap[String, SequenceIndex] = @sorted_map.SortedMap([],
  )
  for entry in summary.entries {
    agents[entry.agent] = SequenceIndex::from_ranges(entry.ranges)
  }
  { agents, snapshot: Some(summary), }
}

///|
/// Admission has proved this identity absent. Insert into its canonical interval
/// tree, independently of arrival order.
fn HaveIndex::insert(self : HaveIndex, raw : @core.RawVersion) -> Unit {
  self.snapshot = None
  let entry = self.agents.get_or_init(raw.agent, () => { root: None, })
  entry.insert(raw.seq.reinterpret_as_uint())
}

///|
/// Materialize a canonical, owning version value in agent/sequence order.
fn HaveIndex::snapshot(self : HaveIndex) -> HaveSummary {
  if self.snapshot is Some(snapshot) {
    return snapshot
  }
  let entries : Array[HaveEntry] = []
  self.agents.each((agent, index) => {
    entries.push({ agent, ranges: index.snapshot(), })
  })
  let summary = HaveSummary::{ entries, }
  self.snapshot = Some(summary)
  summary
}

///|
fn HaveSummary::contains(self : HaveSummary, raw : @core.RawVersion) -> Bool {
  guard raw.seq >= 0 else { return false }
  let entry_index = match
    self.entries.binary_search_by(entry => entry.agent.compare(raw.agent)) {
    Ok(index) => index
    Err(_) => return false
  }
  let sequence = raw.seq.reinterpret_as_uint()
  self.entries[entry_index].ranges.binary_search_by(range => {
    if sequence < range.start {
      1
    } else if sequence >= range.end {
      -1
    } else {
      0
    }
  })
  is Ok(_)
}

///|
/// Subtract one canonical sparse summary from another without enumerating
/// identities in either summary. The result retains the left-hand shape.
fn HaveSummary::subtract(
  self : HaveSummary,
  other : HaveSummary,
) -> HaveSummary {
  self.subtract_counted(other).0
}

///|
fn HaveSummary::subtract_counted(
  self : HaveSummary,
  other : HaveSummary,
) -> (HaveSummary, Int32, Int32) {
  let result = HaveSummary::empty()
  let mut other_entry_index = 0
  let mut agent_steps = 0
  let mut range_steps = 0
  for entry in self.entries {
    agent_steps = agent_steps + 1
    while other_entry_index < other.entries.length() &&
          other.entries[other_entry_index].agent < entry.agent {
      agent_steps = agent_steps + 1
      other_entry_index = other_entry_index + 1
    }
    let other_ranges = if other_entry_index < other.entries.length() &&
      other.entries[other_entry_index].agent == entry.agent {
      other.entries[other_entry_index].ranges
    } else {
      []
    }
    let ranges : Array[SequenceRange] = []
    let mut other_range_index = 0
    for range in entry.ranges {
      range_steps = range_steps + 1
      let mut cursor = range.start
      while other_range_index < other_ranges.length() &&
            other_ranges[other_range_index].end <= cursor {
        range_steps = range_steps + 1
        other_range_index = other_range_index + 1
      }
      while other_range_index < other_ranges.length() &&
            other_ranges[other_range_index].start < range.end {
        range_steps = range_steps + 1
        let covered = other_ranges[other_range_index]
        if covered.start > cursor {
          ranges.push({
            start: cursor,
            end: if covered.start < range.end {
              covered.start
            } else {
              range.end
            },
          })
        }
        if covered.end > cursor {
          cursor = covered.end
        }
        if cursor >= range.end {
          break
        }
        other_range_index = other_range_index + 1
      }
      if cursor < range.end {
        ranges.push({ start: cursor, end: range.end, })
      }
    }
    if !ranges.is_empty() {
      result.entries.push({ agent: entry.agent, ranges, })
    }
  }
  (result, agent_steps, range_steps)
}

///|
fn HaveSummary::from_graph(self : CausalGraph) -> HaveSummary {
  HaveSummary::from_reachable(
    self,
    RangeSet::from_array([{ start: 0, count: self.next_lv, }]),
  )
}

///|
fn HaveSummary::from_reachable(
  graph : CausalGraph,
  reachable : RangeSet,
) -> HaveSummary {
  let by_agent : Map[String, Array[SequenceRange]] = Map([])
  for range in reachable.iter() {
    let mut index = graph.run_index(range.start)
    let mut lv = range.start
    while lv < range.end() {
      let run = graph.runs[index]
      let end = if run.start + run.count < range.end() {
        run.start + run.count
      } else {
        range.end()
      }
      let start = (run.seq + (lv - run.start)).reinterpret_as_uint()
      let part = { start, end: start + (end - lv).reinterpret_as_uint(), }
      match by_agent.get(run.agent) {
        Some(ranges) => ranges.push(part)
        None => by_agent[run.agent] = [part]
      }
      lv = end
      index += 1
    }
  }
  let entries : Array[HaveEntry] = []
  for agent, parts in by_agent {
    parts.sort_by((a, b) => a.start.compare(b.start))
    let ranges : Array[SequenceRange] = []
    for part in parts {
      if !ranges.is_empty() {
        let last = ranges[ranges.length() - 1]
        if part.start <= last.end {
          if part.end > last.end {
            ranges[ranges.length() - 1] = { start: last.start, end: part.end, }
          }
          continue
        }
      }
      ranges.push(part)
    }
    entries.push({ agent, ranges, })
  }
  entries.sort_by((a, b) => a.agent.compare(b.agent))
  { entries, }
}

///|
fn validate_graph_version(
  checkpoint : CausalCheckpoint,
  have : HaveSummary,
) -> Unit raise GraphVersionError {
  for i = 0; i < checkpoint.frontier.length(); i = i + 1 {
    let raw = checkpoint.frontier[i]
    if raw.agent == "" ||
      raw.seq < 0 ||
      (i > 0 && compare_graph_raw(checkpoint.frontier[i - 1], raw) >= 0) {
      raise GraphVersionError::Invalid
    }
  }
  for i = 0; i < have.entries.length(); i = i + 1 {
    let entry = have.entries[i]
    if entry.agent == "" ||
      entry.ranges.is_empty() ||
      (i > 0 && have.entries[i - 1].agent >= entry.agent) {
      raise GraphVersionError::Invalid
    }
    for j = 0; j < entry.ranges.length(); j = j + 1 {
      let range = entry.ranges[j]
      if range.start > 0x7fffffffU ||
        range.end <= range.start ||
        range.end > 0x80000000U ||
        (j > 0 && range.start <= entry.ranges[j - 1].end) {
        raise GraphVersionError::Invalid
      }
    }
  }
  if checkpoint.frontier.is_empty() != have.entries.is_empty() {
    raise GraphVersionError::Invalid
  }
  for raw in checkpoint.frontier {
    if !have.contains(raw) {
      raise GraphVersionError::Invalid
    }
  }
}

///|
/// Construct a structurally validated graph version from defensive wire DTO
/// copies. Closure equality is graph-context validation performed by
/// `CausalGraph::resolve_graph_version`.
pub fn GraphVersion::from_parts(
  frontier : Array[@core.RawVersion],
  ranges : Array[(String, Array[(UInt32, UInt32)])],
) -> GraphVersion raise GraphVersionError {
  let checkpoint_values = frontier.copy()
  checkpoint_values.sort_by(compare_graph_raw)
  let entries : Array[HaveEntry] = ranges.map(entry => {
    agent: entry.0,
    ranges: entry.1.map(range => { start: range.0, end: range.1, }),
  })
  entries.sort_by((a, b) => a.agent.compare(b.agent))
  let result : GraphVersion = {
    checkpoint: { frontier: checkpoint_values, },
    have: { entries, },
  }
  validate_graph_version(result.checkpoint, result.have)
  result
}

///|
/// Return a defensive checkpoint copy for a wire adapter.
pub fn GraphVersion::frontier(self : GraphVersion) -> Array[@core.RawVersion] {
  self.checkpoint.frontier.copy()
}

///|
/// Return a defensive sparse-membership DTO for a wire adapter.
pub fn GraphVersion::ranges(
  self : GraphVersion,
) -> Array[(String, Array[(UInt32, UInt32)])] {
  self.have.entries.map(entry => {
    (entry.agent, entry.ranges.map(range => (range.start, range.end)))
  })
}

///|
/// Test exact identity membership for delta export.
pub fn GraphVersion::contains(
  self : GraphVersion,
  raw : @core.RawVersion,
) -> Bool {
  self.have.contains(raw)
}

///|
/// Return identities present in this version but absent from `other` as
/// canonical sparse ranges. Work is proportional to the summaries' agents and
/// ranges, not to sequence values or the number of covered identities.
pub fn GraphVersion::subtract_ranges(
  self : GraphVersion,
  other : GraphVersion,
) -> Array[(String, Array[(UInt32, UInt32)])] {
  self.have.subtract(other.have).entries.map(entry => {
    (entry.agent, entry.ranges.map(range => (range.start, range.end)))
  })
}

///|
/// Return the current graph-owned version, lazily warming sparse knowledge.
pub fn CausalGraph::current_graph_version(self : CausalGraph) -> GraphVersion {
  let have = match self.version_cache {
    Cold => {
      let built = HaveSummary::from_graph(self)
      self.version_cache = Hot(HaveIndex::from_summary(built))
      built
    }
    Hot(index) => index.snapshot()
  }
  let frontier : Array[@core.RawVersion] = []
  for lv in self.frontier.iter() {
    match self.lv_to_raw(lv) {
      Some(raw) => frontier.push(raw)
      None => abort("resident frontier LV outside graph")
    }
  }
  frontier.sort_by(compare_graph_raw)
  { checkpoint: { frontier, }, have, }
}

///|
/// Resolve an exact checkpoint and prove that its claimed membership equals
/// the resident causal closure.
pub fn CausalGraph::resolve_graph_version(
  self : CausalGraph,
  version : GraphVersion,
) -> @core.Frontier? {
  let frontier : Array[Int32] = []
  for raw in version.checkpoint.frontier {
    match self.raw_to_lv(raw) {
      Some(lv) => frontier.push(lv)
      None => return None
    }
  }
  let resolved = @core.Frontier::from_array(frontier)
  let reachable = self.walk_from_frontier(resolved)
  // A checkpoint is an antichain, not just an arbitrary generating set.
  let parents : Array[Int32] = []
  for head in frontier {
    let run = self.run_at(head)
    if head > run.start {
      parents.push(head - 1)
    } else {
      parents.append(run.parents)
    }
  }
  let ancestors = self.walk_from_frontier(@core.Frontier::from_array(parents))
  for head in frontier {
    if ancestors.contains(head) {
      return None
    }
  }
  if HaveSummary::from_reachable(self, reachable) == version.have {
    Some(resolved)
  } else {
    None
  }
}

// ---------------------------------------------------------------------------
// Explicit trait-method promotions (E0079).
// `#doc(hidden)` keeps these out of the generated interface while preserving
// dot-syntax and cross-package use.
// ---------------------------------------------------------------------------

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend GraphVersion with @debug.Debug::{to_repr}

///|
#doc(hidden)
pub extend GraphVersion with Eq::{equal}

///|
#deprecated("Use `!=` instead", skip_current_package=true)
#doc(hidden)
pub extend GraphVersion with Eq::{not_equal}

///|
#doc(hidden)
pub extend GraphVersion with Hash::{hash}

///|
#deprecated("Use `Hash::hash_combine` via the trait instead", skip_current_package=true)
#doc(hidden)
pub extend GraphVersion with Hash::{hash_combine}

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend GraphVersionError with @debug.Debug::{to_repr}
