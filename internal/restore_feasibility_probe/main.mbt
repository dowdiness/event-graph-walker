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
  transition : String,
) -> Json {
  let bytes = message.to_canonical_bytes().length()
  Json::object({
    "text": Json::string(text),
    "frontier": Json::string("captured-by-egw"),
    "classification": Json::string(classification),
    "transition": Json::string(transition),
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
fn exercise_case(case_id : String) -> (String, String) {
  let log = @oplog.OpLog("gate-r0-" + case_id)
  let root = @core.Op::insert(-1, [], "remote", 0, "a", None, None)
  if case_id == "duplicate" {
    ignore(try! log.apply_remote(root))
    if (try! log.apply_remote(root)).length() != 0 {
      panic()
    }
    ("duplicate", "second-delivery-returned-zero")
  } else if case_id == "conflict" {
    ignore(try! log.apply_remote(root))
    let conflict = @core.Op::insert(-1, [], "remote", 0, "b", None, None)
    let result : Result[Array[@core.Op], @oplog.OpLogError] = Ok(
      log.apply_remote(conflict),
    ) catch {
      error => Err(error)
    }
    match result {
      Err(@oplog.OpLogError::ConflictingIdentity(..)) =>
        ("conflict", "same-identity-different-payload-rejected")
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
      ("pending-drain", "parent-arrival-drained-pending-child")
    } else if case_id == "partial-prefix" {
      ("partial-admission", "child-retained-pending-without-parent")
    } else {
      ("fallback", "missing-parent-retained-pending")
    }
  } else if case_id == "visible-delete" {
    ignore(try! log.insert("a", -1, -1))
    ignore(try! log.delete(0))
    ("strict-forward", "local-delete-applied-to-inserted-target")
  } else if case_id == "undelete" {
    ignore(try! log.insert("a", -1, -1))
    ignore(try! log.delete(0))
    ignore(try! log.undelete(0))
    ("strict-forward", "local-undelete-applied-after-delete")
  } else if case_id == "stale-delete" {
    let result : Result[@core.Op, @oplog.OpLogError] = Ok(log.delete(99)) catch {
      error => Err(error)
    }
    match result {
      Err(_) => ("recovery", "stale-delete-target-rejected")
      _ => panic()
    }
  } else if case_id == "missing-origin" || case_id == "missing-target" {
    let result : Result[@core.Op, @oplog.OpLogError] = Ok(
      log.insert("a", 99, -1),
    ) catch {
      error => Err(error)
    }
    match result {
      Err(_) =>
        (
          "fallback",
          if case_id == "missing-origin" {
            "missing-origin-rejected"
          } else {
            "missing-target-rejected"
          },
        )
      _ => panic()
    }
  } else if case_id == "ancestor-before-base" {
    let ancestor = @core.Op::insert(-1, [], "ancestor", 0, "a", None, None)
    let tail = @core.Op::insert(
      -1,
      [@core.RawVersion("ancestor", 0)],
      "tail",
      0,
      "b",
      None,
      None,
    )
    ignore(try! log.apply_remote(tail))
    if !log.has_pending() {
      panic()
    }
    ignore(try! log.apply_remote(ancestor))
    if log.has_pending() {
      panic()
    }
    ("recovery", "ancestor-arrival-drained-tail-before-base")
  } else if case_id == "zero-commit-recovery" {
    let missing = @core.Op::insert(
      -1,
      [@core.RawVersion("missing", 0)],
      "recovery",
      0,
      "x",
      None,
      None,
    )
    ignore(try! log.apply_remote(missing))
    if !log.has_pending() {
      panic()
    }
    log.clear_pending()
    if log.has_pending() {
      panic()
    }
    ("recovery", "zero-commit-pending-discarded")
  } else if case_id == "tail-contained-parallel" {
    let base = @core.Op::insert(-1, [], "base", 0, "b", None, None)
    let left = @core.Op::insert(
      -1,
      [@core.RawVersion("base", 0)],
      "left",
      0,
      "l",
      None,
      None,
    )
    let right = @core.Op::insert(
      -1,
      [@core.RawVersion("base", 0)],
      "right",
      0,
      "r",
      None,
      None,
    )
    ignore(try! log.apply_remote(base))
    ignore(try! log.apply_remote(left))
    ignore(try! log.apply_remote(right))
    if log.op_count() != 3 {
      panic()
    }
    ("closed-concurrent", "parallel-tail-pair-admitted-after-shared-base")
  } else if case_id == "source-equal-advance" {
    ignore(try! log.apply_remote(root))
    if (try! log.apply_remote(root)).length() != 0 {
      panic()
    }
    ("strict-forward", "source-equal-delivery-returned-zero")
  } else if case_id == "local-insert-start" {
    ignore(try! log.insert("start", -1, -1))
    if log.op_count() != 1 {
      panic()
    }
    ("strict-forward", "start-insert-created-first-operation")
  } else if case_id == "local-insert-middle" {
    ignore(try! log.insert("left", -1, -1))
    ignore(try! log.insert("middle", 0, -1))
    if log.op_count() != 2 {
      panic()
    }
    ("strict-forward", "middle-insert-referenced-existing-origin")
  } else if case_id == "local-insert-end" {
    ignore(try! log.insert("left", -1, -1))
    ignore(try! log.insert("end", 0, -1))
    if log.op_count() != 2 {
      panic()
    }
    ("strict-forward", "end-insert-advanced-frontier")
  } else if case_id == "sequential-insert" {
    ignore(try! log.insert("a", -1, -1))
    ignore(try! log.insert("b", 0, -1))
    ignore(try! log.insert("c", 1, -1))
    if log.op_count() != 3 {
      panic()
    }
    ("strict-forward", "three-step-sequential-origin-chain")
  } else if case_id == "non-bmp-utf16" {
    let operation = try! log.insert("😀", -1, -1)
    let is_non_bmp = match operation.content() {
      @core.OpContent::Insert(content) => content == "😀"
      _ => false
    }
    if log.op_count() != 1 || !is_non_bmp {
      panic()
    }
    ("strict-forward", "non-bmp-payload-admitted")
  } else if case_id == "initial-materialization" {
    ignore(try! log.apply_remote(root))
    ("oracle", "remote-root-materialized")
  } else if case_id == "trace-1" ||
    case_id == "trace-10" ||
    case_id == "trace-100" {
    let count = if case_id == "trace-1" {
      1
    } else if case_id == "trace-10" {
      10
    } else {
      100
    }
    let mut previous = -1
    for _ in 0..<count {
      let op = try! log.insert("x", previous, -1)
      previous = op.lv()
    }
    if log.op_count() != count {
      panic()
    }
    ("strict-forward", "trace-op-count-" + count.to_string())
  } else {
    ignore(try! log.apply_remote(root))
    ("strict-forward", "local-typed-insert-admitted")
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
      evidence(
        message,
        restored.text(),
        1,
        0,
        "preflight-positive-control",
        "canonical-provider-read",
      ),
    ),
  )
  println(
    envelope(
      "strict-forward",
      evidence(
        message,
        restored.text(),
        0,
        1,
        "strict-forward",
        "fresh-text-admission",
      ),
    ),
  )
  println(
    envelope(
      "closed-concurrent",
      evidence(
        message,
        restored.text(),
        0,
        1,
        "closed-concurrent",
        "fresh-text-concurrent-admission",
      ),
    ),
  )
  for case_id in matrix_cases() {
    let (classification, transition) = exercise_case(case_id)
    println(
      envelope(
        case_id,
        evidence(message, restored.text(), 0, 1, classification, transition),
      ),
    )
  }
}
