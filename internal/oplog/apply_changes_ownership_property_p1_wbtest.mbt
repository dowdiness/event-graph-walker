///| Generated typed-change application ownership traces.

///|
struct TypedOwnershipTrace {
  mode : Int
} derive(Debug)

///|
fn typed_ownership_rand_bounded(
  random_state : @splitmix.RandomState,
  bound : Int,
) -> Int {
  random_state.next_positive_int() % bound
}

///|
impl @quickcheck.Arbitrary for TypedOwnershipTrace with fn arbitrary(
  _size,
  random_state,
) {
  { mode: typed_ownership_rand_bounded(random_state.split(), 8), }
}

///|
impl @qc.Shrink for TypedOwnershipTrace with fn shrink(self) {
  if self.mode == 0 {
    [].iter()
  } else {
    [{ mode: 0, }].iter()
  }
}

///|
fn typed_ownership_unique_raws(
  operations : ArrayView[@core.Op],
) -> Array[@core.RawVersion] {
  let raws : Array[@core.RawVersion] = []
  let seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for operation in operations {
    let raw = apply_changes_raw(operation)
    if seen.add_and_check(raw) {
      raws.push(raw)
    }
  }
  raws
}

///|
fn typed_ownership_contains(
  raws : ArrayView[@core.RawVersion],
  raw : @core.RawVersion,
) -> Bool {
  for candidate in raws {
    if candidate == raw {
      return true
    }
  }
  false
}

///|
fn typed_ownership_disjoint(
  left : ArrayView[@core.RawVersion],
  right : ArrayView[@core.RawVersion],
) -> Bool {
  for raw in left {
    if typed_ownership_contains(right, raw) {
      return false
    }
  }
  true
}

///|
fn typed_ownership_assert_authority(
  receiver : OpLog,
  raws : ArrayView[@core.RawVersion],
) -> Bool {
  for raw in raws {
    if receiver.graph.raw_to_lv(raw) is None {
      return false
    }
  }
  true
}

///|
fn typed_ownership_property(trace : TypedOwnershipTrace) -> Bool {
  let receiver = OpLog("p1-ownership-property")
  let applied = p0_insert("p1-property-admitted", 0, [], "A", None)
  let missing = p0_raw("p1-property-missing", 0)
  let pending = p0_insert("p1-property-pending", 0, [missing], "P", None)
  if (try! p1_apply_success(receiver, try! ApplyChanges(receiver, [applied])))
    .committed()
    .length() !=
    1 {
    return false
  }
  ignore(
    try! p1_apply_success(receiver, try! ApplyChanges(receiver, [pending])),
  )

  let dependency = p0_insert("p1-property-missing", 0, [], "D", None)
  let fresh = p0_insert("p1-property-fresh", 0, [], "N", None)
  let wake_pending = trace.mode % 2 == 1
  let operations = if wake_pending {
    [applied, dependency, pending, fresh]
  } else {
    [applied, pending, fresh]
  }
  let action : ApplyChanges = match
    (Ok(ApplyChanges(receiver, operations)) catch { error => Err(error) }) {
    Ok(action) => action
    Err(_) => return false
  }
  if action.required_pending !=
    receiver.pending_changes.required_pending_set_oracle(action) {
    return false
  }
  let operation_count = action.operations().length()
  if operation_count == 0 {
    return false
  }
  let fail_enabled = trace.mode >= 2
  let failure_index = trace.mode % operation_count
  let mut attempt = 0
  let outcome_result : Result[ApplyChangesOutcome, OpLogError] = Ok(
    receiver.apply_changes_with(action, operation => {
      let index = attempt
      attempt += 1
      if fail_enabled && index == failure_index {
        raise @causal_graph.CausalGraphError::MissingParent(lv=-200)
      }
      receiver.commit_one_remote_for_apply_changes(operation)
    }),
  ) catch {
    error => Err(error)
  }
  let outcome = match outcome_result {
    Ok(outcome) => outcome
    Err(_) => return false
  }
  let report = match outcome {
    ApplyChangesOutcome::Succeeded(report) => report
    ApplyChangesOutcome::Failed(report~, error~) => {
      match error {
        @causal_graph.CausalGraphError::MissingParent(_) => ()
        _ => return false
      }
      report
    }
  }

  let committed = typed_ownership_unique_raws(report.committed())
  let already_applied = report.already_applied()
  let pending = report.pending_from_transition()
  let discarded_pending = report.discarded_pending()
  let discarded_staged = report.discarded_staged()
  if !typed_ownership_disjoint(committed, already_applied) ||
    !typed_ownership_disjoint(committed, pending) ||
    !typed_ownership_disjoint(committed, discarded_pending) ||
    !typed_ownership_disjoint(committed, discarded_staged) ||
    !typed_ownership_disjoint(already_applied, pending) ||
    !typed_ownership_disjoint(already_applied, discarded_pending) ||
    !typed_ownership_disjoint(already_applied, discarded_staged) ||
    !typed_ownership_disjoint(pending, discarded_pending) ||
    !typed_ownership_disjoint(pending, discarded_staged) ||
    !typed_ownership_disjoint(discarded_pending, discarded_staged) ||
    !typed_ownership_disjoint(
      report.pending_retained(),
      report.pending_staged(),
    ) {
    return false
  }
  for raw in report.pending_retained() {
    if !typed_ownership_contains(pending, raw) {
      return false
    }
  }
  for raw in report.pending_staged() {
    if !typed_ownership_contains(pending, raw) {
      return false
    }
  }
  if !typed_ownership_assert_authority(receiver, committed) ||
    !typed_ownership_assert_authority(receiver, already_applied) {
    return false
  }
  for raw in pending {
    if !receiver.pending_changes.pending.contains(raw) {
      return false
    }
  }
  for raw in discarded_pending {
    if receiver.graph.raw_to_lv(raw) is Some(_) ||
      receiver.pending_changes.pending.contains(raw) {
      return false
    }
  }
  for raw in discarded_staged {
    if receiver.graph.raw_to_lv(raw) is Some(_) ||
      receiver.pending_changes.pending.contains(raw) {
      return false
    }
  }
  let affected = typed_ownership_unique_raws(operations[:])
  let mut owned_count = 0
  for raw in affected {
    if typed_ownership_contains(committed, raw) ||
      typed_ownership_contains(already_applied, raw) ||
      typed_ownership_contains(pending, raw) ||
      typed_ownership_contains(discarded_pending, raw) ||
      typed_ownership_contains(discarded_staged, raw) {
      owned_count += 1
    }
  }
  let expected_count = if wake_pending { 4 } else { 3 }
  owned_count == expected_count
}

///|
test "property generator: typed ownership traces are valid" {
  let traces : Array[TypedOwnershipTrace] = @quickcheck.samples(32)
  assert_true(!traces.is_empty())
  for trace in traces {
    assert_true(trace.mode >= 0 && trace.mode < 8)
  }
  for mode in 0..<8 {
    assert_true(typed_ownership_property({ mode, }))
  }
}

///|
test "property: typed change application ownership partition is disjoint" {
  @qc.quick_check_fn(typed_ownership_property, max_success=100, max_size=24)
}

// --- Explicit trait-method promotions (E0079) ---

///|
#deprecated("Use `@debug.to_repr` instead", skip_current_package=true)
#doc(hidden)
pub extend TypedOwnershipTrace with @debug.Debug::{to_repr}
