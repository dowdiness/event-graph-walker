///| Internal prototype for a retained OpLog authority and fresh writers.
///
/// A session deliberately stores only a writer identity and an observed
/// frontier. It shares the retained OpLog instead of copying its causal graph
/// or maintaining a per-admission causal-cut map. This is causal-layer proof,
/// not a text/tree restore API.

///|
priv struct ReplicaSession {
  authority : OpLog
  writer_id : String
  mut frontier : @core.Frontier
}

///|
priv struct ReplicaDelta {
  retreat : Array[@core.Op]
  advance : Array[@core.Op]
  frontier : @core.Frontier
}

///|
fn ReplicaSession::attach(
  authority : OpLog,
  writer_id : String,
) -> ReplicaSession {
  guard writer_id != "" else { abort("replica session requires a writer") }
  { authority, writer_id, frontier: authority.get_frontier() }
}

///|
fn ReplicaSession::frontier(self : ReplicaSession) -> @core.Frontier {
  self.frontier
}

///|
fn ReplicaSession::pull(self : ReplicaSession) -> ReplicaDelta {
  let frontier = self.authority.get_frontier()
  let (retreat, advance) = self.authority.diff_and_collect(
    self.frontier,
    frontier,
  )
  self.frontier = frontier
  { retreat, advance, frontier }
}

///|
fn ReplicaSession::export_since(
  self : ReplicaSession,
  from : @core.Frontier,
) -> ReplicaDelta {
  let (retreat, advance) = self.authority.diff_and_collect(from, self.frontier)
  { retreat, advance, frontier: self.frontier }
}

///|
fn ReplicaSession::insert(
  self : ReplicaSession,
  text : String,
  origin_left : @core.RawVersion?,
  origin_right : @core.RawVersion?,
) -> @core.Op raise OpLogError {
  let parent_lvs = self.frontier.to_array()
  let parents = replica_session_raw_versions(self.authority, parent_lvs)
  let operation = replica_session_admit_insert(
    self.authority,
    self.writer_id,
    parents,
    text,
    origin_left,
    origin_right,
  )
  self.frontier = self.frontier.advance(operation.lv(), parent_lvs)
  operation
}

///|
fn replica_session_raw_versions(
  authority : OpLog,
  lvs : Array[Int],
) -> Array[@core.RawVersion] raise OpLogError {
  let result : Array[@core.RawVersion] = []
  for lv in lvs {
    match authority.graph.lv_to_raw(lv) {
      Some(raw) => result.push(raw)
      None => raise OpLogError::MissingLocalVersion(lv~)
    }
  }
  result
}

///|
fn replica_session_resolve_origin(
  authority : OpLog,
  origin : @core.RawVersion?,
) -> @core.RawVersion? raise OpLogError {
  match origin {
    None => None
    Some(raw) => {
      guard authority.graph.raw_to_lv(raw) is Some(_) else {
        raise OpLogError::MissingRemoteParent(raw~)
      }
      Some(raw)
    }
  }
}

///|
/// Admit a local insert against explicit session parents and identity.
///
/// This is intentionally test-only. It isolates the missing production seam:
/// local operation allocation must accept a session writer and observed
/// parents rather than silently using OpLog's coordinator writer/frontier.
fn replica_session_admit_insert(
  authority : OpLog,
  writer_id : String,
  parents : Array[@core.RawVersion],
  text : String,
  origin_left : @core.RawVersion?,
  origin_right : @core.RawVersion?,
) -> @core.Op raise OpLogError {
  let parent_lvs : Array[Int] = []
  for parent in parents {
    match authority.graph.raw_to_lv(parent) {
      Some(lv) => parent_lvs.push(lv)
      None => raise OpLogError::MissingRemoteParent(raw=parent)
    }
  }
  let origin_left = replica_session_resolve_origin(authority, origin_left)
  let origin_right = replica_session_resolve_origin(authority, origin_right)
  let lv = authority.graph.add_version(parent_lvs, writer_id) catch {
    error => raise OpLogError::CausalGraphError(error~)
  }
  let seq = match authority.graph.lv_to_raw(lv) {
    Some(raw) => raw.seq
    None => raise OpLogError::MissingLocalVersion(lv~)
  }
  let operation = @core.Op::new_insert(
    lv, parents, writer_id, seq, text, origin_left, origin_right,
  )
  authority.add_op(operation)
  authority.planner.acknowledge_admitted(
    @core.RawVersion::new(operation.agent(), operation.seq()),
  )
  ignore(
    authority.planner.maybe_compact(raw => {
      authority.graph.raw_to_lv(raw) is Some(_)
    }),
  )
  operation
}
