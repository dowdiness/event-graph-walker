///|
/// One canonical half-open sequence range in peer knowledge.
priv struct SequenceRange {
  start : UInt
  end : UInt
} derive(Debug, Eq)

///|
priv struct HaveEntry {
  agent : String
  ranges : Array[SequenceRange]
} derive(Debug, Eq)

///|
/// Exact membership knowledge. Entries and ranges are canonical: sorted,
/// unique, non-overlapping, and non-adjacent.
priv struct HaveSummary {
  entries : Array[HaveEntry]
} derive(Debug, Eq)

///|
/// Exact maximal identities for one causal cut.
priv struct CausalCheckpoint {
  frontier : Array[@core.RawVersion]
} derive(Debug, Eq)

///|
/// One opaque graph version statement. The checkpoint names an exact causal
/// cut; `have` names the identities in that cut's closure.
pub struct GraphVersion {
  priv checkpoint : CausalCheckpoint
  priv have : HaveSummary
} derive(Debug, Eq)

///|
pub suberror GraphVersionError {
  Invalid
} derive(Debug)

///|
/// Current-summary cache owned by the causal authority. A cold graph pays no
/// summary-maintenance cost until its version is first observed.
priv enum GraphVersionCache {
  Cold
  Hot(HaveSummary)
}

///|
fn compare_graph_raw(a : @core.RawVersion, b : @core.RawVersion) -> Int {
  match a.agent.compare(b.agent) {
    0 => a.seq.compare(b.seq)
    other => other
  }
}

///|
fn HaveSummary::empty() -> HaveSummary {
  { entries: [] }
}

///|
fn HaveSummary::copy(self : HaveSummary) -> HaveSummary {
  {
    entries: self.entries.map(entry => {
      agent: entry.agent,
      ranges: entry.ranges.map(range => { start: range.start, end: range.end }),
    }),
  }
}

///|
/// Insert one identity into canonical sparse membership. This is the only
/// interval union algorithm used by reconstruction and incremental admission.
fn HaveSummary::insert(self : HaveSummary, raw : @core.RawVersion) -> Unit {
  let sequence = raw.seq.reinterpret_as_uint()
  let entry_index = match
    self.entries.binary_search_by(entry => entry.agent.compare(raw.agent)) {
    Ok(index) => index
    Err(index) => {
      self.entries.insert(index, {
        agent: raw.agent,
        ranges: [{ start: sequence, end: sequence + 1U }],
      })
      return
    }
  }
  let entry = self.entries[entry_index]
  let range_index = match
    entry.ranges.binary_search_by(range => {
      if sequence < range.start {
        1
      } else if sequence >= range.end {
        -1
      } else {
        0
      }
    }) {
    Ok(_) => return
    Err(index) => index
  }
  let joins_left = range_index > 0 &&
    entry.ranges[range_index - 1].end == sequence
  let joins_right = range_index < entry.ranges.length() &&
    sequence + 1U == entry.ranges[range_index].start
  match (joins_left, joins_right) {
    (true, true) => {
      let left = entry.ranges[range_index - 1]
      let right = entry.ranges[range_index]
      entry.ranges[range_index - 1] = { start: left.start, end: right.end }
      ignore(entry.ranges.remove(range_index))
    }
    (true, false) => {
      let left = entry.ranges[range_index - 1]
      entry.ranges[range_index - 1] = { start: left.start, end: sequence + 1U }
    }
    (false, true) => {
      let right = entry.ranges[range_index]
      entry.ranges[range_index] = { start: sequence, end: right.end }
    }
    (false, false) =>
      entry.ranges.insert(range_index, { start: sequence, end: sequence + 1U })
  }
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
fn HaveSummary::from_graph(self : CausalGraph) -> HaveSummary {
  let summary = HaveSummary::empty()
  for lv in 0..<self.next_lv {
    let entry = self.entries[lv]
    summary.insert(@core.RawVersion(entry.agent, entry.seq))
  }
  summary
}

///|
fn HaveSummary::from_reachable(
  graph : CausalGraph,
  reachable : Array[Int],
) -> HaveSummary? {
  let summary = HaveSummary::empty()
  for lv in reachable {
    match graph.lv_to_raw(lv) {
      Some(raw) => summary.insert(raw)
      None => return None
    }
  }
  Some(summary)
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
  ranges : Array[(String, Array[(UInt, UInt)])],
) -> GraphVersion raise GraphVersionError {
  let checkpoint_values = frontier.copy()
  checkpoint_values.sort_by(compare_graph_raw)
  let entries : Array[HaveEntry] = ranges.map(entry => {
    agent: entry.0,
    ranges: entry.1.map(range => { start: range.0, end: range.1 }),
  })
  entries.sort_by((a, b) => a.agent.compare(b.agent))
  let result : GraphVersion = {
    checkpoint: { frontier: checkpoint_values },
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
) -> Array[(String, Array[(UInt, UInt)])] {
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
/// Return the current graph-owned version, lazily warming sparse knowledge.
pub fn CausalGraph::current_graph_version(self : CausalGraph) -> GraphVersion {
  let have = match self.version_cache {
    Cold => {
      let built = HaveSummary::from_graph(self)
      self.version_cache = Hot(built)
      built.copy()
    }
    Hot(summary) => summary.copy()
  }
  let frontier : Array[@core.RawVersion] = []
  for lv in self.frontier.iter() {
    match self.lv_to_raw(lv) {
      Some(raw) => frontier.push(raw)
      None => ()
    }
  }
  frontier.sort_by(compare_graph_raw)
  { checkpoint: { frontier, }, have }
}

///|
/// Resolve an exact checkpoint and prove that its claimed membership equals
/// the resident causal closure.
pub fn CausalGraph::resolve_graph_version(
  self : CausalGraph,
  version : GraphVersion,
) -> @core.Frontier? {
  let frontier : Array[Int] = []
  for raw in version.checkpoint.frontier {
    match self.raw_to_lv(raw) {
      Some(lv) => frontier.push(lv)
      None => return None
    }
  }
  let resolved = @core.Frontier::from_array(frontier)
  let (membership_gen, reachable) = self.transitive_closure_gen(resolved)
  // A checkpoint is the maximal antichain of its cut, not merely any set
  // whose union has the same closure. A checkpoint member is redundant exactly
  // when one of its direct children is also in the closure.
  for lv in frontier {
    for child in self.children[lv] {
      if self.query_visited[child] == membership_gen {
        return None
      }
    }
  }
  match HaveSummary::from_reachable(self, reachable) {
    Some(actual) if actual == version.have => Some(resolved)
    _ => None
  }
}
