///| Generated typed-admission ownership traces.

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
  { mode: typed_ownership_rand_bounded(random_state.split(), 8) }
}

///|
impl @qc.Shrink for TypedOwnershipTrace with fn shrink(self) {
  if self.mode == 0 {
    [].iter()
  } else {
    [{ mode: 0 }].iter()
  }
}

///|
fn typed_ownership_unique_raws(
  operations : ArrayView[@core.Op],
) -> Array[@core.RawVersion] {
  let raws : Array[@core.RawVersion] = []
  let seen : @hashset.HashSet[@core.RawVersion] = @hashset.HashSet([])
  for operation in operations {
    let raw = remote_admission_raw(operation)
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
  let admitted = p0_insert("p1-property-admitted", 0, [], "A", None)
  let missing = p0_raw("p1-property-missing", 0)
  let pending = p0_insert("p1-property-pending", 0, [missing], "P", None)
  if (try! receiver.commit_remote(try! receiver.prepare_remote([admitted]))).length() !=
    1 {
    return false
  }
  ignore(try! receiver.commit_remote(try! receiver.prepare_remote([pending])))

  let dependency = p0_insert("p1-property-missing", 0, [], "D", None)
  let fresh = p0_insert("p1-property-fresh", 0, [], "N", None)
  let wake_pending = trace.mode % 2 == 1
  let operations = if wake_pending {
    [admitted, dependency, pending, fresh]
  } else {
    [admitted, pending, fresh]
  }
  let plan : PreparedAdmission = match
    (Ok(receiver.prepare_remote(operations)) catch { error => Err(error) }) {
    Ok(plan) => plan
    Err(_) => return false
  }
  if plan.required_pending != receiver.planner.required_pending_set_oracle(plan) {
    return false
  }
  let operation_count = plan.operations().length()
  if operation_count == 0 {
    return false
  }
  let fail_enabled = trace.mode >= 2
  let failure_index = trace.mode % operation_count
  let mut attempt = 0
  let outcome_result : Result[AdmissionOutcome, OpLogError] = Ok(
    receiver.commit_admission_with(plan, operation => {
      let index = attempt
      attempt += 1
      if fail_enabled && index == failure_index {
        raise @causal_graph.CausalGraphError::MissingParent(lv=-200)
      }
      receiver.commit_one_remote_for_admission(operation)
    }),
  ) catch {
    error => Err(error)
  }
  let outcome = match outcome_result {
    Ok(outcome) => outcome
    Err(_) => return false
  }
  let receipt = match outcome {
    AdmissionOutcome::Complete(receipt) => receipt
    AdmissionOutcome::Partial(receipt~, error~) => {
      match error {
        @causal_graph.CausalGraphError::MissingParent(_) => ()
        _ => return false
      }
      receipt
    }
  }

  let committed = typed_ownership_unique_raws(receipt.committed())
  let already_admitted = receipt.already_admitted()
  let pending = receipt.pending_from_transition()
  let discarded_pending = receipt.discarded_pending()
  let discarded_staged = receipt.discarded_staged()
  if !typed_ownership_disjoint(committed, already_admitted) ||
    !typed_ownership_disjoint(committed, pending) ||
    !typed_ownership_disjoint(committed, discarded_pending) ||
    !typed_ownership_disjoint(committed, discarded_staged) ||
    !typed_ownership_disjoint(already_admitted, pending) ||
    !typed_ownership_disjoint(already_admitted, discarded_pending) ||
    !typed_ownership_disjoint(already_admitted, discarded_staged) ||
    !typed_ownership_disjoint(pending, discarded_pending) ||
    !typed_ownership_disjoint(pending, discarded_staged) ||
    !typed_ownership_disjoint(discarded_pending, discarded_staged) ||
    !typed_ownership_disjoint(
      receipt.pending_retained(),
      receipt.pending_staged(),
    ) {
    return false
  }
  for raw in receipt.pending_retained() {
    if !typed_ownership_contains(pending, raw) {
      return false
    }
  }
  for raw in receipt.pending_staged() {
    if !typed_ownership_contains(pending, raw) {
      return false
    }
  }
  if !typed_ownership_assert_authority(receiver, committed) ||
    !typed_ownership_assert_authority(receiver, already_admitted) {
    return false
  }
  for raw in pending {
    if !receiver.planner.pending.contains(raw) {
      return false
    }
  }
  for raw in discarded_pending {
    if receiver.graph.raw_to_lv(raw) is Some(_) ||
      receiver.planner.pending.contains(raw) {
      return false
    }
  }
  for raw in discarded_staged {
    if receiver.graph.raw_to_lv(raw) is Some(_) ||
      receiver.planner.pending.contains(raw) {
      return false
    }
  }
  let affected = typed_ownership_unique_raws(operations[:])
  let mut owned_count = 0
  for raw in affected {
    if typed_ownership_contains(committed, raw) ||
      typed_ownership_contains(already_admitted, raw) ||
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
test "property: typed admission ownership partition is disjoint" {
  @qc.quick_check_fn(typed_ownership_property, max_success=100, max_size=24)
}
