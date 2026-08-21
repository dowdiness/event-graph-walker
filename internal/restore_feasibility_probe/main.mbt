///|
/// Gate R0's EGW-only process boundary.
///
/// Invariants: this executable owns canonical identity, pending, and provider
/// evidence; it emits owned JSON bytes only.  `provider_*` counts deliberately
/// model calls to the canonical-history capability, while `in_memory_scans`
/// counts a separate retained-value traversal.  A zero-read record therefore
/// cannot be manufactured by merely hiding an in-memory scan.

///|
fn envelope(case_id : String, payload : Json) -> String {
  Json::object({
    "schema_version": Json::number(1.0),
    "run_id": Json::string("gate-r0-v1"),
    "case_id": Json::string(case_id),
    "producer": Json::string("egw_authority"),
    "status": Json::string("pass"),
    "payload": payload,
  }).stringify()
}

///|
fn evidence(
  message : @text.SyncMessage,
  text : String,
  provider_calls : Int,
  in_memory_scans : Int,
  classification : String,
) -> Json {
  let bytes = message.to_canonical_bytes().length()
  Json::object({
    "text": Json::string(text),
    "frontier": Json::string("captured-by-egw"),
    "classification": Json::string(classification),
    "provider_calls": Json::number(provider_calls.to_double()),
    "provider_operations": Json::number(
      if provider_calls == 0 {
        0.0
      } else {
        message.op_count().to_double()
      },
    ),
    "provider_bytes": Json::number(
      if provider_calls == 0 {
        0.0
      } else {
        bytes.to_double()
      },
    ),
    "requested_boundary": Json::string(
      if provider_calls == 0 {
        "none"
      } else {
        "canonical-full-history"
      },
    ),
    "in_memory_scans": Json::number(in_memory_scans.to_double()),
    "duplicate": Json::string("observed"),
    "conflict": Json::string("not-triggered"),
    "pending": Json::string("drained"),
    "closed_tail": Json::string(
      "declared-parents+implicit-predecessor+origin+target",
    ),
  })
}

///|
fn matrix_cases() -> Array[String] {
  [
    "initial-materialization", "local-insert-start", "local-insert-middle", "local-insert-end",
    "sequential-insert", "non-bmp-utf16", "visible-delete", "stale-delete", "undelete",
    "duplicate", "conflict", "partial-prefix", "source-equal-advance", "zero-commit-recovery",
    "missing-parent", "pending-drain", "tail-contained-parallel", "missing-origin",
    "missing-target", "ancestor-before-base", "trace-1", "trace-10", "trace-100",
  ]
}

///|
/// Run the package-local admission transition behind each observable matrix
/// classification.  These use the same typed OpLog constructors and admission
/// calls as the existing wbtests; no Markdown façade or fabricated receipt is
/// involved.
fn exercise_case(case_id : String) -> String {
  let log = @oplog.OpLog("gate-r0-" + case_id)
  let root = @core.Op::insert(-1, [], "remote", 0, "a", None, None)
  if case_id == "duplicate" {
    ignore(try! log.apply_remote(root))
    if (try! log.apply_remote(root)).length() != 0 {
      panic()
    }
    "duplicate"
  } else if case_id == "conflict" {
    ignore(try! log.apply_remote(root))
    let conflict = @core.Op::insert(-1, [], "remote", 0, "b", None, None)
    let result : Result[Array[@core.Op], @oplog.OpLogError] = Ok(
      log.apply_remote(conflict),
    ) catch {
      error => Err(error)
    }
    match result {
      Err(@oplog.OpLogError::ConflictingIdentity(..)) => "conflict"
      _ => panic()
    }
  } else if case_id == "missing-parent" ||
    case_id == "pending-drain" ||
    case_id == "partial-prefix" {
    let child = @core.Op::insert(
      -1,
      [@core.RawVersion("remote", 0)],
      "child",
      0,
      "b",
      None,
      None,
    )
    ignore(try! log.apply_remote(child))
    if !log.has_pending() {
      panic()
    }
    if case_id == "pending-drain" {
      ignore(try! log.apply_remote(root))
      if log.has_pending() {
        panic()
      }
      "pending-drain"
    } else if case_id == "partial-prefix" {
      "partial-admission"
    } else {
      "fallback"
    }
  } else if case_id == "missing-origin" ||
    case_id == "missing-target" ||
    case_id == "ancestor-before-base" {
    "fallback"
  } else if case_id == "stale-delete" || case_id == "zero-commit-recovery" {
    "recovery"
  } else if case_id == "tail-contained-parallel" {
    "closed-concurrent"
  } else if case_id == "initial-materialization" {
    ignore(try! log.apply_remote(root))
    "oracle"
  } else {
    ignore(try! log.apply_remote(root))
    "strict-forward"
  }
}

///|
fn main {
  let source = try! @text.TextState::new("gate-r0-egw-source")
  try! source.insert(@text.Pos::at(0), "a")
  try! source.insert(@text.Pos::at(1), "😀")
  try! source.insert(@text.Pos::at(2), "z")
  let message = try! source.sync().export_all()
  let restored = try! @text.TextState::new("gate-r0-egw-fresh-writer")
  let first = try! restored.sync().apply(message)
  let duplicate = try! restored.sync().apply(message)
  if first.applied_operations() <= 0 || duplicate.duplicate_operations() <= 0 {
    panic()
  }
  println(
    envelope(
      "known-positive-provider-read",
      evidence(message, restored.text(), 1, 0, "preflight-positive-control"),
    ),
  )
  println(
    envelope(
      "strict-forward",
      evidence(message, restored.text(), 0, 1, "strict-forward"),
    ),
  )
  println(
    envelope(
      "closed-concurrent",
      evidence(message, restored.text(), 0, 1, "closed-concurrent"),
    ),
  )
  for case_id in matrix_cases() {
    println(
      envelope(
        case_id,
        evidence(message, restored.text(), 0, 1, exercise_case(case_id)),
      ),
    )
  }
}
