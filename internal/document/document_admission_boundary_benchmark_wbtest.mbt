/// P2.3 M-boundary benchmark for the Document admission shell.
///
/// The inner clock measures only the remote boundary after each lane has built
/// the same initial state. `moonbitlang/core/bench` exposes timing and `keep`,
/// but no allocator counter; the JSON observation records that limitation
/// rather than presenting retained work as an allocation measurement.

///|
enum P2BoundaryCase {
  Complete
  DuplicateOnly
  PendingOnly
  Partial
}

///|
enum P2BoundaryLane {
  ApplyEach
  AdmitBatch
}

///|
struct P2BoundaryObservation {
  case_name : String
  lane_name : String
  count : Int
  elapsed_us : Double
  prepare_calls : Int
  commit_calls : Int
  projection_attempts : Int
  recovery_checkouts : Int
  committed_count : Int
  operation_count : Int
  pending : Bool
  pending_count : Int
  projection_status : String
  retained_work : Int
}

///|
fn p2_boundary_expect(condition : Bool, message : String) -> Unit {
  if !condition {
    abort(message)
  }
}

///|
fn p2_boundary_case_name(case : P2BoundaryCase) -> String {
  match case {
    Complete => "complete"
    DuplicateOnly => "duplicate-only"
    PendingOnly => "pending-only"
    Partial => "partial"
  }
}

///|
fn p2_boundary_lane_name(lane : P2BoundaryLane) -> String {
  match lane {
    ApplyEach => "M-apply_remote"
    AdmitBatch => "1-admit_remote"
  }
}

///|
fn p2_boundary_pending_batch(prefix : String, count : Int) -> Array[@core.Op] {
  let operations : Array[@core.Op] = []
  for index in 0..<count {
    let agent = prefix + "-" + index.to_string()
    let missing = @core.RawVersion(agent + "-missing", 0)
    operations.push(@core.Op::insert(-1, [missing], agent, 0, "x", None, None))
  }
  operations
}

///|
fn p2_boundary_fixture(
  case : P2BoundaryCase,
  count : Int,
  iteration : Int,
) -> (Document, Array[@core.Op], Int) {
  let prefix = "p2-boundary-" +
    p2_boundary_case_name(case) +
    "-" +
    iteration.to_string()
  let incoming = match case {
    Complete | DuplicateOnly | Partial => p2_ready_batch(prefix, count)
    PendingOnly => p2_boundary_pending_batch(prefix, count)
  }
  let doc = Document::new("p2-boundary-target-" + iteration.to_string())
  if case is DuplicateOnly {
    let seeded : Result[DocumentAdmission, DocumentError] = Ok(
      doc.admit_remote(incoming),
    ) catch {
      error => Err(error)
    }
    match seeded {
      Ok(admission) =>
        match admission.outcome {
          @oplog.AdmissionOutcome::Complete(receipt) =>
            p2_boundary_expect(
              receipt.committed().length() == count,
              "duplicate fixture committed the wrong count",
            )
          @oplog.AdmissionOutcome::Partial(..) =>
            abort("duplicate fixture seeding became partial")
        }
      Err(_) => abort("duplicate fixture seeding failed")
    }
  }
  (doc, incoming, doc.get_all_ops().length())
}

///|
fn p2_boundary_failure_index(case : P2BoundaryCase, count : Int) -> Int? {
  match case {
    Partial => Some(count / 2)
    Complete | DuplicateOnly | PendingOnly => None
  }
}

///|
/// Apply the legacy lane until its first expected partial error. The batch
/// lane receives the full operation set; this models the Unit wrapper's
/// caller-visible fail-fast boundary rather than silently retrying it.
fn p2_boundary_apply_each(
  doc : Document,
  incoming : Array[@core.Op],
  failure_index : Int?,
) -> Unit {
  for index in 0..<incoming.length() {
    let result : Result[Unit, DocumentError] = Ok(
      doc.apply_remote(incoming[index]),
    ) catch {
      error => Err(error)
    }
    match result {
      Ok(_) =>
        match failure_index {
          Some(expected) if index == expected =>
            abort("apply_remote did not expose expected partial error")
          _ => ()
        }
      Err(
        DocumentError::OpLog(
          @oplog.OpLogError::PartialRemoteAdmission(committed~, error~)
        )
      ) =>
        match failure_index {
          Some(expected) if index == expected => {
            p2_boundary_expect(
              committed.length() == 0,
              "apply_remote committed work in the failing transition",
            )
            match error {
              @causal_graph.CausalGraphError::MissingParent(lv~) =>
                p2_boundary_expect(
                  lv == -401,
                  "apply_remote changed the partial cause",
                )
              _ => abort("apply_remote changed the partial cause")
            }
            return
          }
          _ => abort("apply_remote exposed an unexpected partial error")
        }
      Err(_) => abort("apply_remote exposed an unexpected error")
    }
  }
  match failure_index {
    Some(_) => abort("apply_remote did not fail at the expected index")
    None => ()
  }
}

///|
fn p2_boundary_admit_batch(
  doc : Document,
  incoming : Array[@core.Op],
  case : P2BoundaryCase,
  failure_index : Int?,
) -> (String, Int) {
  let result : Result[DocumentAdmission, DocumentError] = Ok(
    doc.admit_remote(incoming),
  ) catch {
    error => Err(error)
  }
  let admission = match result {
    Ok(admission) => admission
    Err(_) => abort("admit_remote exposed an unexpected error")
  }
  let mut pending_count = 0
  match (case, admission.outcome) {
    (Complete, @oplog.AdmissionOutcome::Complete(receipt)) => {
      p2_boundary_expect(
        receipt.committed().length() == incoming.length(),
        "complete batch committed the wrong count",
      )
      pending_count = receipt.pending_after_count()
      p2_boundary_expect(
        pending_count == 0,
        "complete batch retained pending work",
      )
    }
    (DuplicateOnly, @oplog.AdmissionOutcome::Complete(receipt)) => {
      p2_boundary_expect(
        receipt.committed().length() == 0,
        "duplicate batch committed an operation",
      )
      pending_count = receipt.pending_after_count()
      p2_boundary_expect(
        pending_count == 0,
        "duplicate batch retained pending work",
      )
      p2_boundary_expect(
        receipt.already_admitted().length() == incoming.length(),
        "duplicate batch lost an already-admitted identity",
      )
    }
    (PendingOnly, @oplog.AdmissionOutcome::Complete(receipt)) => {
      p2_boundary_expect(
        receipt.committed().length() == 0,
        "pending batch committed an operation",
      )
      pending_count = receipt.pending_after_count()
      p2_boundary_expect(
        pending_count == incoming.length(),
        "pending batch lost a pending identity",
      )
    }
    (Partial, @oplog.AdmissionOutcome::Partial(receipt~, error~)) => {
      let expected = match failure_index {
        Some(index) => index
        None => abort("partial case did not have a failure index")
      }
      p2_boundary_expect(
        receipt.committed().length() == expected,
        "partial batch committed the wrong prefix",
      )
      pending_count = receipt.pending_after_count()
      p2_boundary_expect(
        pending_count == incoming.length() - expected,
        "partial batch retained the wrong suffix",
      )
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) =>
          p2_boundary_expect(
            lv == -401,
            "admit_remote changed the partial cause",
          )
        _ => abort("admit_remote changed the partial cause")
      }
    }
    (_, @oplog.AdmissionOutcome::Complete(_))
    | (_, @oplog.AdmissionOutcome::Partial(..)) =>
      abort("admit_remote returned the wrong outcome kind")
  }
  let projection_status = match (case, admission.projection) {
    (Complete, ProjectionStatus::Projected) => "Projected"
    (DuplicateOnly, ProjectionStatus::Skipped)
    | (PendingOnly, ProjectionStatus::Skipped) => "Skipped"
    (Partial, ProjectionStatus::Skipped) =>
      match failure_index {
        Some(0) => "Skipped"
        _ => abort("partial batch skipped an unexpected projection")
      }
    (Partial, ProjectionStatus::Projected) =>
      match failure_index {
        Some(index) if index > 0 => "Projected"
        _ => abort("partial batch projected an empty prefix")
      }
    _ => abort("admit_remote returned the wrong projection status")
  }
  (projection_status, pending_count)
}

///|
fn p2_boundary_pending_probe(doc : Document) -> Int {
  let result : Result[DocumentAdmission, DocumentError] = Ok(
    doc.admit_remote([]),
  ) catch {
    error => Err(error)
  }
  let admission = match result {
    Ok(admission) => admission
    Err(_) => abort("pending probe exposed an unexpected error")
  }
  match admission.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => receipt.pending_after_count()
    @oplog.AdmissionOutcome::Partial(receipt~, ..) =>
      receipt.pending_after_count()
  }
}

///|
fn p2_boundary_expected_committed(
  case : P2BoundaryCase,
  count : Int,
  failure_index : Int?,
) -> Int {
  match case {
    Complete => count
    DuplicateOnly | PendingOnly => 0
    Partial =>
      match failure_index {
        Some(index) => index
        None => abort("partial case did not have a failure index")
      }
  }
}

///|
fn p2_boundary_run(
  case : P2BoundaryCase,
  lane : P2BoundaryLane,
  count : Int,
  iteration : Int,
) -> P2BoundaryObservation {
  let (doc, incoming, initial_count) = p2_boundary_fixture(
    case, count, iteration,
  )
  let failure_index = p2_boundary_failure_index(case, count)
  let mut prepare_calls = 0
  let mut commit_calls = 0
  let mut projection_attempts = 0
  let mut recovery_checkouts = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_calls = prepare_calls + 1,
    on_commit_admission: () => commit_calls = commit_calls + 1,
    on_projection_finalization: _ => {
      projection_attempts = projection_attempts + 1
    },
    prepare_override: None,
    commit_failure: Some(op => {
      match failure_index {
        Some(index) if op.seq() == index =>
          Some(@causal_graph.CausalGraphError::MissingParent(lv=-401))
        _ => None
      }
    }),
    projection_failure: None,
    recovery_checkout: Some(frontier => {
      recovery_checkouts = recovery_checkouts + 1
      @branch.Branch::checkout(doc.oplog, frontier)
    }),
  })
  let start = @bench.monotonic_clock_start()
  let (projection_status, batch_pending_count) = match lane {
    ApplyEach => {
      p2_boundary_apply_each(doc, incoming, failure_index)
      ("legacy-wrapper", 0)
    }
    AdmitBatch => p2_boundary_admit_batch(doc, incoming, case, failure_index)
  }
  let elapsed_us = @bench.monotonic_clock_end(start)
  let committed_count = doc.get_all_ops().length() - initial_count
  let boundary_prepare_calls = prepare_calls
  let boundary_commit_calls = commit_calls
  let boundary_projection_attempts = projection_attempts
  let boundary_recovery_checkouts = recovery_checkouts
  let pending_count = match case {
    Complete | DuplicateOnly => 0
    PendingOnly | Partial => {
      let probed = p2_boundary_pending_probe(doc)
      if lane is AdmitBatch {
        p2_boundary_expect(
          probed == batch_pending_count,
          "pending probe disagreed with the batch receipt",
        )
      }
      probed
    }
  }
  let expected_committed = p2_boundary_expected_committed(
    case, count, failure_index,
  )
  p2_boundary_expect(
    committed_count == expected_committed,
    "benchmark committed count differs from the expected outcome",
  )
  let expected_pending_count = match case {
    Complete | DuplicateOnly => 0
    PendingOnly => count
    Partial =>
      match lane {
        ApplyEach => 1
        AdmitBatch =>
          match failure_index {
            Some(index) => count - index
            None => abort("partial case did not have a failure index")
          }
      }
  }
  p2_boundary_expect(
    pending_count == expected_pending_count,
    "benchmark pending count differs from the expected outcome",
  )
  p2_boundary_expect(
    doc.oplog.has_pending() == (pending_count > 0),
    "benchmark pending state differs from the expected outcome",
  )
  let fresh_result : Result[@branch.Branch, @branch.BranchError] = Ok(
    @branch.Branch::checkout(doc.oplog, doc.get_frontier()),
  ) catch {
    error => Err(error)
  }
  let fresh = match fresh_result {
    Ok(fresh) => fresh
    Err(_) => abort("fresh checkout failed in benchmark")
  }
  p2_boundary_expect(
    doc.get_frontier() == fresh.get_frontier(),
    "benchmark frontier differs from fresh checkout",
  )
  p2_boundary_expect(
    doc.tree.to_text() == fresh.to_text(),
    "benchmark tree differs from fresh checkout",
  )
  let expected_prepare = match lane {
    ApplyEach =>
      match case {
        Partial =>
          match failure_index {
            Some(index) => index + 1
            None => abort("partial case did not have a failure index")
          }
        Complete | DuplicateOnly | PendingOnly => count
      }
    AdmitBatch => 1
  }
  let expected_commit = expected_prepare
  let expected_projection = match lane {
    ApplyEach =>
      match case {
        Complete => count
        DuplicateOnly | PendingOnly => 0
        Partial =>
          match failure_index {
            Some(index) => index
            None => abort("partial case did not have a failure index")
          }
      }
    AdmitBatch =>
      match case {
        Complete => 1
        DuplicateOnly | PendingOnly => 0
        Partial =>
          match failure_index {
            Some(index) => if index == 0 { 0 } else { 1 }
            None => abort("partial case did not have a failure index")
          }
      }
  }
  p2_boundary_expect(
    boundary_prepare_calls == expected_prepare,
    "benchmark prepare call count differs from expectation",
  )
  p2_boundary_expect(
    boundary_commit_calls == expected_commit,
    "benchmark typed commit call count differs from expectation",
  )
  p2_boundary_expect(
    boundary_projection_attempts == expected_projection,
    "benchmark projection count differs from expectation",
  )
  p2_boundary_expect(
    boundary_recovery_checkouts == 0,
    "benchmark unexpectedly entered projection recovery",
  )
  {
    case_name: p2_boundary_case_name(case),
    lane_name: p2_boundary_lane_name(lane),
    count,
    elapsed_us,
    prepare_calls: boundary_prepare_calls,
    commit_calls: boundary_commit_calls,
    projection_attempts: boundary_projection_attempts,
    recovery_checkouts: boundary_recovery_checkouts,
    committed_count,
    operation_count: doc.get_all_ops().length(),
    pending: pending_count > 0,
    pending_count,
    projection_status,
    retained_work: doc.get_all_ops().length() + pending_count,
  }
}

///|
fn p2_boundary_bench_case(
  b : @bench.T,
  case : P2BoundaryCase,
  count : Int,
  lane : P2BoundaryLane,
) -> Unit {
  let benchmark_name = "bench: document admission boundary " +
    p2_boundary_case_name(case) +
    " M=" +
    count.to_string() +
    " " +
    p2_boundary_lane_name(lane)
  let mut iteration = 0
  let mut last_observation : P2BoundaryObservation? = None
  // The framework summary is end-to-end for this benchmark and includes
  // fixture setup plus postcondition validation. `inner_us` is the
  // boundary-only clock used for the M comparison.
  b.bench(
    name=benchmark_name,
    fn() {
      let observation = p2_boundary_run(case, lane, count, iteration)
      iteration = iteration + 1
      last_observation = Some(observation)
      // Keep both result shape and retained work live. Core bench has no
      // allocator counter, so this is not reported as an allocation count.
      b.keep(
        (
          observation.committed_count,
          observation.operation_count,
          observation.pending,
          observation.retained_work,
        ),
      )
    },
    count=1,
  )
  match last_observation {
    Some(observation) => {
      let pending = if observation.pending { "true" } else { "false" }
      println(
        "{\"benchmark\":\"\{benchmark_name}\",\"timing_scope\":\"framework_end_to_end_inner_us_boundary_only\",\"case\":\"\{observation.case_name}\",\"lane\":\"\{observation.lane_name}\",\"M\":\{observation.count.to_string()},\"inner_us\":\{observation.elapsed_us.to_string()},\"prepare_calls\":\{observation.prepare_calls.to_string()},\"typed_commit_calls\":\{observation.commit_calls.to_string()},\"projection_finalization_attempts\":\{observation.projection_attempts.to_string()},\"recovery_checkouts\":\{observation.recovery_checkouts.to_string()},\"committed_count\":\{observation.committed_count.to_string()},\"operation_count\":\{observation.operation_count.to_string()},\"pending\":\"\{pending}\",\"pending_count\":\{observation.pending_count.to_string()},\"projection_status\":\"\{observation.projection_status}\",\"allocation_observation\":\"core-bench-counter-unavailable\",\"retained_work\":\{observation.retained_work.to_string()}}",
      )
    }
    None => abort("benchmark did not run")
  }
}

///|
fn p2_boundary_bench_matrix(b : @bench.T, case : P2BoundaryCase) -> Unit {
  for count in [1, 10, 100, 1000] {
    p2_boundary_bench_case(b, case, count, ApplyEach)
    p2_boundary_bench_case(b, case, count, AdmitBatch)
  }
}

///|
test "bench: document admission boundary complete" (b : @bench.T) {
  p2_boundary_bench_matrix(b, Complete)
}

///|
test "bench: document admission boundary duplicate-only" (b : @bench.T) {
  p2_boundary_bench_matrix(b, DuplicateOnly)
}

///|
test "bench: document admission boundary pending-only" (b : @bench.T) {
  p2_boundary_bench_matrix(b, PendingOnly)
}

///|
test "bench: document admission boundary partial" (b : @bench.T) {
  p2_boundary_bench_matrix(b, Partial)
}
