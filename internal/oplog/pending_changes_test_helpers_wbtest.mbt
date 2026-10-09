///|
/// Reference set oracle for the begin-after pending membership contract.
/// Production change application uses `required_pending_for`; tests compare both.
fn PendingChanges::required_pending_set_oracle(
  self : PendingChanges,
  plan : ApplyChanges,
) -> Int {
  let pending : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet(
    self.pending_raws(),
  )
  for raw in plan.discarded_pending {
    pending.remove(raw)
  }
  for raw in plan.staged_raws() {
    pending.add(raw)
  }
  pending.length()
}

///|
/// Copy planned operations for white-box snapshots.
fn ApplyChanges::planned_operations(self : ApplyChanges) -> Array[@core.Op] {
  self.operations().to_owned()
}

///|
/// Snapshot canonical pending operations in arrival order for the white-box
/// oracle. The pending-changes owner remains the sole owner of pending membership.
fn PendingChanges::pending_operations(self : PendingChanges) -> Array[@core.Op] {
  let result : Array[@core.Op] = []
  for entry in self.pending_order {
    if !apply_changes_order_entry_is_live(self.pending, entry) {
      continue
    }
    match self.pending.get(entry.raw) {
      Some(node) => result.push(node.op)
      None => ()
    }
  }
  result
}

///|
/// Generation captured by this action.
fn ApplyChanges::generation(self : ApplyChanges) -> Int {
  self.generation
}

///|
/// White-box generation accessor; preparation must preserve this value.
fn PendingChanges::generation(self : PendingChanges) -> Int {
  self.generation
}

///|
/// White-box arrival accessor.
fn PendingChanges::arrival_of(
  self : PendingChanges,
  raw : @core.RawVersion,
) -> Int? {
  match self.pending.get(raw) {
    Some(node) => Some(node.arrival)
    None => None
  }
}
