///| Typed evidence for one remote-admission transition.

///|
pub struct AdmissionReceipt {
  priv committed : Array[@core.Op]
  priv already_admitted : Array[@core.RawVersion]
  priv pending_from_transition : Array[@core.RawVersion]
  priv pending_retained : Array[@core.RawVersion]
  priv pending_staged : Array[@core.RawVersion]
  priv discarded_pending : Array[@core.RawVersion]
  priv discarded_staged : Array[@core.RawVersion]
  priv pending_before_count : Int
  priv pending_after_count : Int
  priv frontier_before : @core.Frontier
  priv frontier_after : @core.Frontier
}

///|
pub enum AdmissionOutcome {
  Complete(AdmissionReceipt)
  Partial(receipt~ : AdmissionReceipt, error~ : @causal_graph.CausalGraphError)
}

///|
fn AdmissionReceipt::from_parts(
  committed : Array[@core.Op],
  already_admitted : Array[@core.RawVersion],
  pending_from_transition : Array[@core.RawVersion],
  pending_retained : Array[@core.RawVersion],
  pending_staged : Array[@core.RawVersion],
  discarded_pending : Array[@core.RawVersion],
  discarded_staged : Array[@core.RawVersion],
  pending_before_count : Int,
  pending_after_count : Int,
  frontier_before : @core.Frontier,
  frontier_after : @core.Frontier,
) -> AdmissionReceipt {
  {
    committed: committed.copy(),
    already_admitted: already_admitted.copy(),
    pending_from_transition: pending_from_transition.copy(),
    pending_retained: pending_retained.copy(),
    pending_staged: pending_staged.copy(),
    discarded_pending: discarded_pending.copy(),
    discarded_staged: discarded_staged.copy(),
    pending_before_count,
    pending_after_count,
    frontier_before: @core.Frontier::from_array(frontier_before.to_array()),
    frontier_after: @core.Frontier::from_array(frontier_after.to_array()),
  }
}

///|
pub fn AdmissionReceipt::committed(
  self : AdmissionReceipt,
) -> ArrayView[@core.Op] {
  self.committed[:]
}

///|
pub fn AdmissionReceipt::already_admitted(
  self : AdmissionReceipt,
) -> ArrayView[@core.RawVersion] {
  self.already_admitted[:]
}

///|
pub fn AdmissionReceipt::pending_from_transition(
  self : AdmissionReceipt,
) -> ArrayView[@core.RawVersion] {
  self.pending_from_transition[:]
}

///|
pub fn AdmissionReceipt::pending_retained(
  self : AdmissionReceipt,
) -> ArrayView[@core.RawVersion] {
  self.pending_retained[:]
}

///|
pub fn AdmissionReceipt::pending_staged(
  self : AdmissionReceipt,
) -> ArrayView[@core.RawVersion] {
  self.pending_staged[:]
}

///|
pub fn AdmissionReceipt::discarded_pending(
  self : AdmissionReceipt,
) -> ArrayView[@core.RawVersion] {
  self.discarded_pending[:]
}

///|
pub fn AdmissionReceipt::discarded_staged(
  self : AdmissionReceipt,
) -> ArrayView[@core.RawVersion] {
  self.discarded_staged[:]
}

///|
pub fn AdmissionReceipt::pending_before_count(self : AdmissionReceipt) -> Int {
  self.pending_before_count
}

///|
pub fn AdmissionReceipt::pending_after_count(self : AdmissionReceipt) -> Int {
  self.pending_after_count
}

///|
pub fn AdmissionReceipt::frontier_before(
  self : AdmissionReceipt,
) -> @core.Frontier {
  self.frontier_before
}

///|
pub fn AdmissionReceipt::frontier_after(
  self : AdmissionReceipt,
) -> @core.Frontier {
  self.frontier_after
}

///|
/// Return the transition-local identities that can remain pending after the
/// actual commit attempt. Delivery provenance alone never adds an identity.
fn PreparedAdmission::transition_pending_candidates(
  self : PreparedAdmission,
) -> Array[@core.RawVersion] {
  let result : Array[@core.RawVersion] = []
  let seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for raw in self.retained_pending {
    if seen.add_and_check(raw) {
      result.push(raw)
    }
  }
  for op in self.planned {
    let raw = remote_admission_raw(op)
    if seen.add_and_check(raw) {
      result.push(raw)
    }
  }
  for raw in self.staged_raws() {
    if seen.add_and_check(raw) {
      result.push(raw)
    }
  }
  for raw in self.duplicate_of_pending {
    if seen.add_and_check(raw) {
      result.push(raw)
    }
  }
  result
}

///|
/// Construct receipt-owned actual evidence from the post-commit planner and
/// authority state. Unrelated retained pending work is represented by counts,
/// not copied into the receipt.
fn OpLog::admission_receipt(
  self : OpLog,
  prepared : PreparedAdmission,
  committed : Array[@core.Op],
  frontier_before : @core.Frontier,
) -> AdmissionReceipt {
  let pending_from_transition : Array[@core.RawVersion] = []
  let pending_retained : Array[@core.RawVersion] = []
  let pending_staged : Array[@core.RawVersion] = []
  for raw in prepared.retained_pending {
    if self.planner.pending.contains(raw) {
      pending_retained.push(raw)
    }
  }
  for raw in prepared.staged_raws() {
    if self.planner.pending.contains(raw) {
      pending_staged.push(raw)
    }
  }
  for raw in prepared.transition_pending_candidates() {
    if self.planner.pending.contains(raw) {
      pending_from_transition.push(raw)
    }
  }
  AdmissionReceipt::from_parts(
    committed,
    prepared.already_admitted,
    pending_from_transition,
    pending_retained,
    pending_staged,
    prepared.discarded_pending.to_array(),
    prepared.discarded_staged.to_array(),
    prepared.pending_before_count,
    self.planner.pending_raws().length(),
    frontier_before,
    self.get_frontier(),
  )
}
