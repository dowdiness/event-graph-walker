///| Checked one-pass authority construction for an unpublished complete history.
/// Origins do not participate in causal ranks, child edges or frontier.

///|
pub fn CausalGraph::from_topological_ops_experimental(
  operations : ArrayView[@core.Op],
) -> CausalGraph raise CausalGraphError {
  let graph = CausalGraph::new()
  for index, op in operations {
    let raw = @core.RawVersion(op.agent(), op.seq())
    if raw.agent == "" || raw.seq < 0 {
      raise CausalGraphError::InvalidIdentity(raw~)
    }
    if graph.raw_to_lv(raw) is Some(_) {
      raise CausalGraphError::DuplicateVersion(raw~)
    }
    let parents : Array[Int32] = []
    let mut timestamp = 0
    for parent in op.parents_iter() {
      let lv = match graph.raw_to_lv(parent) {
        Some(lv) if lv >= 0 && lv < index => lv
        _ => raise CausalGraphError::MissingParent(lv=-1)
      }
      parents.push(lv)
      let run = graph.run_at(lv)
      let rank = run.timestamp + (lv - run.start)
      if rank >= timestamp {
        timestamp = rank + 1
      }
    }
    // All input identity/parent checks precede this row's candidate mutation.
    // parents is newly owned; no caller array becomes graph storage.
    graph.append_entry(parents, raw.agent, raw.seq, timestamp)
    let old_max = graph.agent_seqs.get(raw.agent).unwrap_or(-1)
    if raw.seq > old_max {
      graph.agent_seqs[raw.agent] = raw.seq
    }
  }
  let candidates : Map[Int32, Unit] = Map([])
  for run in graph.runs {
    candidates[run.start + run.count - 1] = ()
  }
  for run in graph.runs {
    for parent in run.parents {
      candidates.remove(parent)
    }
  }
  let heads = candidates.keys().collect()
  heads.sort()
  // Exactly Frontier.advance's surviving insertion order, without per-op copies.
  graph.frontier = @core.Frontier::from_array(heads)
  graph
}
