///| Complete offline Text history proof. No live pending/planned state is imported.

///|
pub struct ClosedHistory {
  priv graph : @causal_graph.CausalGraph
  priv operations : Array[@core.Op]
  priv mut consumed : Bool
}

///|
fn closed_history_scalar(text : String) -> Bool {
  if text.length() == 1 {
    let cu = text[0].to_int()
    cu < 0xD800 || cu > 0xDFFF
  } else if text.length() == 2 {
    let high = text[0].to_int()
    let low = text[1].to_int()
    high >= 0xD800 && high <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF
  } else {
    false
  }
}

///|
fn closed_history_add_budget(
  total : Int,
  amount : Int,
  limit : Int,
) -> Int raise OpLogError {
  if amount < 0 || total > limit || amount > limit - total {
    raise OpLogError::InvalidApplyChanges
  }
  total + amount
}

///|
/// Public-internal checked constructor; the wire-facing Text path additionally
/// supplies existing StructuralOp/canonical-order proof and full archive budgets.
/// No sorted actor-sequence or origin-as-parent assumption is made here.
pub fn ClosedHistory::prepare_experimental(
  input : Array[@core.Op],
) -> ClosedHistory raise OpLogError {
  if input.length() > 100000 {
    raise OpLogError::InvalidApplyChanges
  }
  let operations = input.copy()
  let mut edges = 0
  let mut identity_units = 0
  // Complete bounded structural pass before allocating graph authority.
  for op in operations {
    let raw = apply_changes_raw(op)
    if raw.agent == "" || raw.seq < 0 {
      raise OpLogError::InvalidApplyChanges
    }
    identity_units = closed_history_add_budget(
      identity_units,
      raw.agent.length(),
      64 * 1024 * 1024,
    )
    let parents = op.parents()
    if parents.length() > 256 {
      raise OpLogError::InvalidApplyChanges
    }
    edges = closed_history_add_budget(edges, parents.length(), 1000000)
    let seen : Map[@core.RawVersion, Bool] = Map([])
    for parent in parents {
      if parent.agent == "" ||
        parent.seq < 0 ||
        parent == raw ||
        seen.contains(parent) {
        raise OpLogError::InvalidApplyChanges
      }
      seen[parent] = true
      identity_units = closed_history_add_budget(
        identity_units,
        parent.agent.length(),
        64 * 1024 * 1024,
      )
    }
    apply_changes_validate_origin_shape(op)
    for origin in [op.origin_left(), op.origin_right()] {
      match origin {
        Some(origin) => {
          if origin.agent == "" || origin.seq < 0 {
            raise OpLogError::InvalidApplyChanges
          }
          edges = closed_history_add_budget(edges, 1, 1000000)
          identity_units = closed_history_add_budget(
            identity_units,
            origin.agent.length(),
            64 * 1024 * 1024,
          )
        }
        None => ()
      }
    }
    match op.content() {
      @core.Insert(text) =>
        if !closed_history_scalar(text) {
          raise OpLogError::InvalidApplyChanges
        }
      @core.Delete | @core.Undelete => ()
    }
  }
  let graph = @causal_graph.CausalGraph::from_topological_ops_experimental(
    operations[:],
  ) catch {
    error => raise OpLogError::CausalGraphError(error~)
  }
  // Parent closure/order is proved by graph construction. Origins are distinct
  // readiness edges: they must name earlier Inserts, even if outside ancestry,
  // equal to each other, nonadjacent, or currently deleted.
  for index, op in operations {
    for origin in [op.origin_left(), op.origin_right()] {
      match origin {
        Some(origin) => {
          let lv = match graph.raw_to_lv(origin) {
            Some(lv) if lv >= 0 && lv < index => lv
            _ => raise OpLogError::MissingRemoteParent(raw=origin)
          }
          if !operations[lv].is_insert() {
            raise OpLogError::OriginTargetNotInsert(
              operation=apply_changes_raw(op),
              target=origin,
            )
          }
        }
        None => ()
      }
    }
  }
  { graph, operations, consumed: false, }
}

///|
pub fn ClosedHistory::version_experimental(
  self : ClosedHistory,
) -> @causal_graph.GraphVersion raise OpLogError {
  if self.consumed {
    raise OpLogError::ConsumedApplyChanges
  }
  self.graph.current_graph_version()
}

///|
pub fn ClosedHistory::heads_experimental(
  self : ClosedHistory,
) -> Array[@core.RawVersion] raise OpLogError {
  if self.consumed {
    raise OpLogError::ConsumedApplyChanges
  }
  self.graph
  .get_frontier()
  .to_array()
  .map(lv => self.graph.lv_to_raw(lv).unwrap())
}

///|
/// One-shot adoption prevents two live documents aliasing mutable graph authority.
/// Returned local operations are immutable; their owning array is only a projection
/// input, independent of the RLE storage created through its ordinary constructors.
pub fn ClosedHistory::consume_experimental(
  self : ClosedHistory,
  writer : String,
) -> (OpLog, Array[@core.Op]) raise OpLogError {
  if self.consumed {
    raise OpLogError::ConsumedApplyChanges
  }
  if writer == "" {
    raise OpLogError::InvalidApplyChanges
  }
  self.consumed = true
  let local_operations : Array[@core.Op] = Array(
    capacity=self.operations.length(),
  )
  let runs : Array[@core.OpRun] = Array(capacity=self.operations.length())
  for lv, op in self.operations {
    let next = match op.content() {
      @core.Insert(text) =>
        @core.Op::insert(
          lv,
          op.parents(),
          op.agent(),
          op.seq(),
          text,
          op.origin_left(),
          op.origin_right(),
        )
      @core.Delete =>
        @core.Op::delete(
          lv,
          op.parents(),
          op.agent(),
          op.seq(),
          op.origin_left(),
        )
      @core.Undelete =>
        @core.Op::undelete(
          lv,
          op.parents(),
          op.agent(),
          op.seq(),
          op.origin_left(),
        )
    }
    local_operations.push(next)
    runs.push(@core.OpRun::from_op(next))
  }
  let log : OpLog = {
    operations: @rle.Rle::from_array(runs),
    pending_changes: PendingChanges(),
    graph: self.graph,
    agent_id: writer,
  }
  (log, local_operations)
}
