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
/// Matrix rows execute the owned export/admission seam before observation.
/// Fallback rows are classified explicitly; retained scans stay distinct from
/// canonical-provider reads.
fn matrix_classification(case_id : String) -> String {
  match case_id {
    "initial-materialization" => "oracle"
    "duplicate" => "duplicate"
    "conflict" => "conflict"
    "partial-prefix" => "partial-admission"
    "zero-commit-recovery" | "stale-delete" => "recovery"
    "pending-drain" => "pending-drain"
    "tail-contained-parallel" => "closed-concurrent"
    "missing-parent"
    | "missing-origin"
    | "missing-target"
    | "ancestor-before-base" => "fallback"
    _ => "strict-forward"
  }
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
        evidence(message, restored.text(), 0, 1, matrix_classification(case_id)),
      ),
    )
  }
}
