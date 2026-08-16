///| P1 pending-membership measurement matrix.

///|
/// These benchmarks measure the current implementation and compare duplicate
/// pending delivery with a distinct prepare+admit operation. They do not
/// authorize a further optimization without a reproduced regression.

///|
fn p1_pending_benchmark_fixture(
  count : Int,
) -> (OpLog, Array[@core.Op]) raise OpLogError {
  let target = OpLog("p1-pending-benchmark")
  if count == 0 {
    let seed = p0_insert("p1-benchmark-seed", 0, [], "S", None)
    ignore(try! target.commit_remote(try! target.prepare_remote([seed])))
    return (target, [seed])
  }
  let missing = p0_raw("p1-benchmark-missing", 0)
  let first : @core.Op? = None
  let mut first_operation = first
  for seq in 0..<count {
    let operation = p0_insert("p1-benchmark-pending", seq, [missing], "P", None)
    target.planner.register_pending(operation, _ => false)
    if seq == 0 {
      first_operation = Some(operation)
    }
  }
  match first_operation {
    Some(operation) => (target, [operation])
    None => abort("positive pending benchmark count produced no operation")
  }
}

///|
fn p1_pending_benchmark_prepare(
  b : @bench.T,
  count : Int,
  max_pending : Int?,
) -> Unit raise OpLogError {
  let (target, incoming) = p1_pending_benchmark_fixture(count)
  b.bench(fn() {
    let result : Result[PreparedAdmission, OpLogError] = match max_pending {
      Some(limit) =>
        Ok(target.prepare_remote(incoming, max_pending=limit)) catch {
          error => Err(error)
        }
      None => Ok(target.prepare_remote(incoming)) catch { error => Err(error) }
    }
    match result {
      Ok(plan) => b.keep(plan.required_pending)
      Err(OpLogError::PendingLimitExceeded(required~, ..)) => b.keep(required)
      Err(_) => b.keep(-1)
    }
  })
}

///|
fn p1_pending_benchmark_prepare_and_commit(
  b : @bench.T,
  count : Int,
  max_pending : Int?,
) -> Unit raise OpLogError {
  let (target, incoming) = p1_pending_benchmark_fixture(count)
  b.bench(fn() {
    let result : Result[PreparedAdmission, OpLogError] = match max_pending {
      Some(limit) =>
        Ok(target.prepare_remote(incoming, max_pending=limit)) catch {
          error => Err(error)
        }
      None => Ok(target.prepare_remote(incoming)) catch { error => Err(error) }
    }
    match result {
      Ok(plan) => {
        let outcome : Result[AdmissionOutcome, OpLogError] = Ok(
          target.commit_admission(plan),
        ) catch {
          error => Err(error)
        }
        match outcome {
          Ok(AdmissionOutcome::Complete(receipt)) =>
            b.keep(receipt.pending_after_count())
          Ok(AdmissionOutcome::Partial(receipt~, error~)) => {
            ignore(error)
            b.keep(receipt.pending_after_count())
          }
          Err(_) => b.keep(-1)
        }
      }
      Err(OpLogError::PendingLimitExceeded(limit~, required~)) => {
        ignore(limit)
        b.keep(required)
      }
      Err(_) => b.keep(-1)
    }
  })
}

///|
/// The fresh path keeps a valid same-agent causal chain. A bounded
/// rejection leaves the current operation and predecessor state unchanged.
fn p1_pending_benchmark_prepare_and_admit(
  b : @bench.T,
  count : Int,
  max_pending : Int?,
  expect_pending_limit_rejection : Bool,
) -> Unit raise OpLogError {
  let (target, _) = p1_pending_benchmark_fixture(count)
  let mut next_seq = 0
  let mut previous : @core.RawVersion? = None
  b.bench(fn() {
    let parents = match previous {
      Some(parent) => [parent]
      None => []
    }
    let operation = p0_insert(
      "p1-benchmark-fresh",
      next_seq,
      parents,
      "N",
      None,
    )
    let raw = remote_admission_raw(operation)
    let result : Result[PreparedAdmission, OpLogError] = match max_pending {
      Some(limit) =>
        Ok(target.prepare_remote([operation], max_pending=limit)) catch {
          error => Err(error)
        }
      None =>
        Ok(target.prepare_remote([operation])) catch {
          error => Err(error)
        }
    }
    match result {
      Ok(plan) => {
        let outcome : Result[AdmissionOutcome, OpLogError] = Ok(
          target.commit_admission(plan),
        ) catch {
          error => Err(error)
        }
        match outcome {
          Ok(AdmissionOutcome::Complete(receipt)) => {
            if receipt.committed().length() != 1 {
              abort("fresh admission did not commit exactly one operation")
            }
            previous = Some(raw)
            next_seq += 1
            b.keep(1)
          }
          Ok(AdmissionOutcome::Partial(..)) =>
            abort("fresh admission unexpectedly became partial")
          Err(_) => abort("fresh admission commit unexpectedly failed")
        }
      }
      Err(OpLogError::PendingLimitExceeded(limit~, required~)) => {
        ignore(limit)
        if expect_pending_limit_rejection {
          b.keep(required)
        } else {
          abort("fresh admission unexpectedly hit the pending limit")
        }
      }
      Err(_) => abort("fresh admission prepare unexpectedly failed")
    }
  })
}

///|
test "bench: P1 prepare pending matrix unbounded" (b : @bench.T) {
  for count in [0, 1000, 10000, 100000] {
    p1_pending_benchmark_prepare(b, count, None)
  }
}

///|
test "bench: P1 prepare pending matrix bounded pass" (b : @bench.T) {
  for count in [0, 1000, 10000, 100000] {
    p1_pending_benchmark_prepare(b, count, Some(count))
  }
}

///|
test "bench: P1 prepare pending matrix bounded reject" (b : @bench.T) {
  for count in [0, 1000, 10000, 100000] {
    p1_pending_benchmark_prepare(b, count, Some(count - 1))
  }
}

///|
test "bench: P1 prepare+commit pending matrix unbounded" (b : @bench.T) {
  for count in [0, 1000, 10000, 100000] {
    p1_pending_benchmark_prepare_and_commit(b, count, None)
  }
}

///|
test "bench: P1 prepare+commit pending matrix bounded pass" (b : @bench.T) {
  for count in [0, 1000, 10000, 100000] {
    p1_pending_benchmark_prepare_and_commit(b, count, Some(count))
  }
}

///|
test "bench: P1 prepare+commit pending matrix bounded reject" (b : @bench.T) {
  for count in [0, 1000, 10000, 100000] {
    p1_pending_benchmark_prepare_and_commit(b, count, Some(count - 1))
  }
}

///|
test "bench: P1 prepare+admit pending matrix unbounded" (b : @bench.T) {
  for count in [0, 1000, 10000, 100000] {
    p1_pending_benchmark_prepare_and_admit(b, count, None, false)
  }
}

///|
test "bench: P1 prepare+admit pending matrix bounded pass" (b : @bench.T) {
  for count in [0, 1000, 10000, 100000] {
    p1_pending_benchmark_prepare_and_admit(b, count, Some(count + 1), false)
  }
}

///|
test "bench: P1 prepare+admit pending matrix bounded reject" (b : @bench.T) {
  for count in [0, 1000, 10000, 100000] {
    p1_pending_benchmark_prepare_and_admit(b, count, Some(count), true)
  }
}
