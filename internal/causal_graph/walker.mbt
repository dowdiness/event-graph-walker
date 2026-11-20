///|
/// Visit run prefixes in descending LV order. Every pending parent precedes its
/// child, so the first visit to a run is its greatest reachable prefix.
/// All frontier LVs must belong to this graph; violation is a programmer error.
pub fn CausalGraph::walk_from_frontier(
  self : CausalGraph,
  frontier : @core.Frontier,
) -> RangeSet {
  for lv in frontier.iter() {
    guard lv >= 0 && lv < self.next_lv else {
      abort("frontier LV outside graph")
    }
  }
  let pending = @priority_queue.PriorityQueue::from_iter(frontier.iter())
  let descending : Array[@core.LvRange] = []
  let mut start = self.next_lv
  let mut end = self.next_lv
  while pending.pop() is Some(lv) {
    if lv >= start {
      continue
    }
    let run = self.run_at(lv)
    if lv + 1 != start {
      if start < end {
        descending.push({ start, count: end - start, })
      }
      end = lv + 1
    }
    start = run.start
    for parent in run.parents {
      pending.push(parent)
    }
  }
  if start < end {
    descending.push({ start, count: end - start, })
  }
  { ranges: descending.rev_iter().collect(), }
}

///|
/// Walk only the suffixes absent from a causally closed editing view. Within a
/// causal run, displayed identities form a prefix, so locate its boundary by
/// binary search rather than visiting each operation. Descending LV order makes
/// shared ancestors safe to skip without retaining a per-operation visited set.
pub fn CausalGraph::unprojected_ranges(
  self : CausalGraph,
  view : ViewVersion,
) -> RangeSet {
  let pending = @priority_queue.PriorityQueue::from_iter(self.frontier.iter())
  let descending : Array[@core.LvRange] = []
  let mut visited_from = self.next_lv
  while pending.pop() is Some(lv) {
    if lv >= visited_from {
      continue
    }
    let run = self.run_at(lv)
    if view.contains(@core.RawVersion(run.agent, run.seq + lv - run.start)) {
      continue
    }
    let mut low = run.start
    let mut high = lv
    while low < high {
      let middle = low + (high - low) / 2
      if view.contains(
          @core.RawVersion(run.agent, run.seq + middle - run.start),
        ) {
        low = middle + 1
      } else {
        high = middle
      }
    }
    descending.push({ start: low, count: lv - low + 1, })
    visited_from = low
    if low == run.start {
      for parent in run.parents {
        pending.push(parent)
      }
    }
  }
  RangeSet::from_array(descending)
}

///|
/// Both sets are canonical ascending intervals, not execution sequences.
/// Execute retreat backward and advance forward, including within each interval.
pub fn CausalGraph::diff_frontiers_lvs(
  self : CausalGraph,
  from_frontier : @core.Frontier,
  to_frontier : @core.Frontier,
) -> (RangeSet, RangeSet) {
  let from = self.walk_from_frontier(from_frontier)
  let to = self.walk_from_frontier(to_frontier)
  (from.subtract(to), to.subtract(from))
}
