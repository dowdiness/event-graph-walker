///| Internal prototype: an explicit causal-cut capture boundary.
///
/// This is deliberately not a public checkpoint or restore API. OpLog remains
/// Causal Authority. The candidate append-only live store is used only while
/// capturing a snapshot; matched admission benchmarks rejected keeping a
/// duplicate node map on every typing operation.

///|
/// One structural node per admitted operation. Parent identities remain in the
/// operation payload and resolve through the append-only node store.
priv struct CausalNode {
  operation : @core.Op
  timestamp : Int
}

///|
/// Runtime-owned append-only evidence store. It is not exposed to consumers.
priv struct CausalCut {
  nodes : @hashmap.HashMap[@core.RawVersion, CausalNode]
  frontier : @hashset.HashSet[@core.RawVersion]
}

///|
/// Immutable evidence returned by an explicit capture boundary.
priv struct CausalCutSnapshot {
  nodes : @immut/hashmap.HashMap[@core.RawVersion, CausalNode]
  frontier : @immut/hashset.HashSet[@core.RawVersion]
}

///|
fn CausalCut::new() -> CausalCut {
  { nodes: @hashmap.HashMap::default(), frontier: @hashset.HashSet::default() }
}

///|
fn CausalCut::append(self : CausalCut, operation : @core.Op) -> Unit {
  let raw = @core.RawVersion::new(operation.agent(), operation.seq())
  match self.nodes.get(raw) {
    Some(existing) => {
      guard remote_admission_same_logical_operation(
        existing.operation,
        operation,
      ) else {
        abort("causal cut identity conflict")
      }
      return
    }
    None => ()
  }
  let parents = operation.parents()
  let timestamp = parents.fold(init=0, fn(max_timestamp, parent) {
    match self.nodes.get(parent) {
      Some(node) => max_timestamp.max(node.timestamp + 1)
      None => abort("causal cut missing parent")
    }
  })
  self.nodes.set(raw, { operation, timestamp })
  for parent in parents {
    self.frontier.remove(parent)
  }
  self.frontier.add(raw)
}

///|
fn CausalCut::append_all(
  self : CausalCut,
  operations : ArrayView[@core.Op],
) -> Unit {
  for operation in operations {
    self.append(operation)
  }
}

///|
fn CausalCut::snapshot(self : CausalCut) -> CausalCutSnapshot {
  let nodes : @immut/hashmap.HashMap[@core.RawVersion, CausalNode] = @immut/hashmap.HashMap::from_iter(
    self.nodes.iter(),
  )
  let frontier : @immut/hashset.HashSet[@core.RawVersion] = @immut/hashset.HashSet::from_iter(
    self.frontier.iter(),
  )
  { nodes, frontier }
}

///|
/// Rebuild an exact immutable snapshot from a topologically ordered log.
/// This is the explicit-capture reference path after the per-admission
/// duplicate-store performance gate returned NO-GO.
fn CausalCut::from_operations(
  operations : ArrayView[@core.Op],
) -> CausalCutSnapshot {
  let cut = CausalCut::new()
  cut.append_all(operations)
  cut.snapshot()
}

///|
fn CausalCutSnapshot::op_count(self : CausalCutSnapshot) -> Int {
  self.nodes.length()
}

///|
fn CausalCutSnapshot::frontier(
  self : CausalCutSnapshot,
) -> Array[@core.RawVersion] {
  self.frontier.iter().to_array()
}

///|
/// Compare causal evidence without destination-local LVs or map order.
fn CausalCutSnapshot::equal(
  self : CausalCutSnapshot,
  other : CausalCutSnapshot,
) -> Bool {
  if self.nodes.length() != other.nodes.length() {
    return false
  }
  if !self.frontier.equal(other.frontier) {
    return false
  }
  for entry in self.nodes.iter() {
    let raw = entry.0
    let node = entry.1
    match other.nodes.get(raw) {
      Some(other_node) =>
        if !remote_admission_same_logical_operation(
            node.operation,
            other_node.operation,
          ) ||
          node.timestamp != other_node.timestamp {
          return false
        }
      None => return false
    }
  }
  true
}

///|
/// Explicit capture seam for whitebox tests and future coordinator work.
/// The matched admission gate rejected maintaining a duplicate node map on
/// every edit; capture currently rebuilds from OpLog at this boundary.
fn OpLog::causal_cut(self : OpLog) -> CausalCutSnapshot {
  CausalCut::from_operations(self.get_all_ops())
}
