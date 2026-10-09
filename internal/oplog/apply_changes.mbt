///| Typed evidence for one remote-change application transition.

///|
pub struct ApplyChangesReport {
  priv committed : Array[@core.Op]
  priv already_applied : Array[@core.RawVersion]
  priv pending_from_transition : Array[@core.RawVersion]
  priv pending_retained : Array[@core.RawVersion]
  priv pending_staged : Array[@core.RawVersion]
  priv discarded_pending : Array[@core.RawVersion]
  priv discarded_staged : Array[@core.RawVersion]
  priv redelivery_count : Int
  priv pending_before_count : Int
  priv pending_after_count : Int
  priv frontier_before : @core.Frontier
  priv frontier_after : @core.Frontier
}

///|
pub enum ApplyChangesOutcome {
  Succeeded(ApplyChangesReport)
  Failed(report~ : ApplyChangesReport, error~ : @causal_graph.CausalGraphError)
}

///|
fn ApplyChangesReport::from_parts(
  committed : Array[@core.Op],
  already_applied : Array[@core.RawVersion],
  pending_from_transition : Array[@core.RawVersion],
  pending_retained : Array[@core.RawVersion],
  pending_staged : Array[@core.RawVersion],
  discarded_pending : Array[@core.RawVersion],
  discarded_staged : Array[@core.RawVersion],
  redelivery_count : Int,
  pending_before_count : Int,
  pending_after_count : Int,
  frontier_before : @core.Frontier,
  frontier_after : @core.Frontier,
) -> ApplyChangesReport {
  {
    committed: committed.copy(),
    already_applied: already_applied.copy(),
    pending_from_transition: pending_from_transition.copy(),
    pending_retained: pending_retained.copy(),
    pending_staged: pending_staged.copy(),
    discarded_pending: discarded_pending.copy(),
    discarded_staged: discarded_staged.copy(),
    redelivery_count,
    pending_before_count,
    pending_after_count,
    frontier_before: @core.Frontier::from_array(frontier_before.to_array()),
    frontier_after: @core.Frontier::from_array(frontier_after.to_array()),
  }
}

///|
pub fn ApplyChangesReport::committed(
  self : ApplyChangesReport,
) -> ArrayView[@core.Op] {
  self.committed[:]
}

///|
pub fn ApplyChangesReport::already_applied(
  self : ApplyChangesReport,
) -> ArrayView[@core.RawVersion] {
  self.already_applied[:]
}

///|
pub fn ApplyChangesReport::pending_from_transition(
  self : ApplyChangesReport,
) -> ArrayView[@core.RawVersion] {
  self.pending_from_transition[:]
}

///|
pub fn ApplyChangesReport::pending_retained(
  self : ApplyChangesReport,
) -> ArrayView[@core.RawVersion] {
  self.pending_retained[:]
}

///|
pub fn ApplyChangesReport::pending_staged(
  self : ApplyChangesReport,
) -> ArrayView[@core.RawVersion] {
  self.pending_staged[:]
}

///|
pub fn ApplyChangesReport::discarded_pending(
  self : ApplyChangesReport,
) -> ArrayView[@core.RawVersion] {
  self.discarded_pending[:]
}

///|
pub fn ApplyChangesReport::discarded_staged(
  self : ApplyChangesReport,
) -> ArrayView[@core.RawVersion] {
  self.discarded_staged[:]
}

///|
pub fn ApplyChangesReport::redelivery_count(self : ApplyChangesReport) -> Int {
  self.redelivery_count
}

///|
pub fn ApplyChangesReport::pending_before_count(
  self : ApplyChangesReport,
) -> Int {
  self.pending_before_count
}

///|
pub fn ApplyChangesReport::pending_after_count(
  self : ApplyChangesReport,
) -> Int {
  self.pending_after_count
}

///|
pub fn ApplyChangesReport::frontier_before(
  self : ApplyChangesReport,
) -> @core.Frontier {
  self.frontier_before
}

///|
pub fn ApplyChangesReport::frontier_after(
  self : ApplyChangesReport,
) -> @core.Frontier {
  self.frontier_after
}

///|
/// Return the transition-local identities that can remain pending after the
/// actual commit attempt. Delivery provenance alone never adds an identity.
fn ApplyChanges::transition_pending_candidates(
  self : ApplyChanges,
) -> Array[@core.RawVersion] {
  let result : Array[@core.RawVersion] = []
  let seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for raw in self.retained_pending {
    if seen.add_and_check(raw) {
      result.push(raw)
    }
  }
  for op in self.planned {
    let raw = apply_changes_raw(op)
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
/// Construct receipt-owned actual evidence from the post-commit pending-changes owner and
/// authority state. Unrelated retained pending work is represented by counts,
/// not copied into the receipt.
fn OpLog::apply_changes_report(
  self : OpLog,
  action : ApplyChanges,
  committed : Array[@core.Op],
  frontier_before : @core.Frontier,
) -> ApplyChangesReport {
  let pending_from_transition : Array[@core.RawVersion] = []
  let pending_retained : Array[@core.RawVersion] = []
  let pending_staged : Array[@core.RawVersion] = []
  if !self.pending_changes.pending.is_empty() {
    for raw in action.retained_pending {
      if self.pending_changes.pending.contains(raw) {
        pending_retained.push(raw)
      }
    }
    for raw in action.staged_raws() {
      if self.pending_changes.pending.contains(raw) {
        pending_staged.push(raw)
      }
    }
    for raw in action.transition_pending_candidates() {
      if self.pending_changes.pending.contains(raw) {
        pending_from_transition.push(raw)
      }
    }
  }
  ApplyChangesReport::from_parts(
    committed,
    action.already_applied,
    pending_from_transition,
    pending_retained,
    pending_staged,
    action.discarded_pending.to_array(),
    action.discarded_staged.to_array(),
    action.already_applied.length() + action.duplicate_of_pending.length(),
    action.pending_before_count,
    self.pending_changes.pending_count(),
    frontier_before,
    self.get_frontier(),
  )
}
