///| Remaining P2.1 red tests: rejection, divergence, recovery, retry, wrappers, and cursor.

///|
struct P2TreeItemSnapshot {
  lv : Int
  content : String
  parent : Int?
  side : @fugue.Side
  deleted : Bool
  deleted_ts : Int
  deleted_agent : String
  deleted_is_undelete : Bool
  state : @fugue.ItemState
  delete_count : Int
  timestamp : Int
  agent : String
}

///|
struct P2CacheSnapshot {
  ready : Bool
  positions : Array[Int]
}

///|
struct P2DocumentSnapshot {
  frontier : @core.Frontier
  ops : Array[@core.Op]
  tree_text : String
  tree_items : Array[P2TreeItemSnapshot]
  pending : Bool
  cache : P2CacheSnapshot
}

///|
fn p2_tree_snapshot(doc : Document) -> Array[P2TreeItemSnapshot] {
  doc.tree
  .get_all_items()
  .map(pair => {
    let (lv, item) = pair
    {
      lv: lv.0,
      content: item.content,
      parent: item.parent.map(parent => parent.0),
      side: item.side,
      deleted: item.deleted,
      deleted_ts: item.deleted_ts,
      deleted_agent: item.deleted_agent,
      deleted_is_undelete: item.deleted_is_undelete,
      state: item.state,
      delete_count: item.delete_count,
      timestamp: item.timestamp.0,
      agent: item.agent.0,
    }
  })
}

///|
fn p2_cache_snapshot(doc : Document) -> P2CacheSnapshot raise {
  if !doc.indexed_state.is_ready() {
    return { ready: false, positions: [] }
  }
  let positions : Array[Int] = []
  for position = 0; position < doc.tree.visible_count(); position = position + 1 {
    match doc.lv_at_position(position) {
      Some(lv) => positions.push(lv)
      None => fail("ready cache must resolve every visible position")
    }
  }
  { ready: true, positions }
}

///|
fn p2_snapshot_document(doc : Document) -> P2DocumentSnapshot raise {
  {
    frontier: doc.get_frontier(),
    ops: doc.get_all_ops(),
    tree_text: doc.tree.to_text(),
    tree_items: p2_tree_snapshot(doc),
    pending: doc.oplog.has_pending(),
    cache: p2_cache_snapshot(doc),
  }
}

///|
fn p2_assert_same_operations(
  actual : Array[@core.Op],
  expected : Array[@core.Op],
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for index = 0; index < expected.length(); index = index + 1 {
    assert_eq(actual[index].lv(), expected[index].lv())
    assert_eq(actual[index].agent(), expected[index].agent())
    assert_eq(actual[index].seq(), expected[index].seq())
    assert_eq(actual[index].content(), expected[index].content())
  }
}

///|
fn p2_assert_same_tree_items(
  actual : Array[P2TreeItemSnapshot],
  expected : Array[P2TreeItemSnapshot],
) -> Unit raise {
  assert_eq(actual.length(), expected.length())
  for index = 0; index < expected.length(); index = index + 1 {
    let actual_item = actual[index]
    let expected_item = expected[index]
    assert_eq(actual_item.lv, expected_item.lv)
    assert_eq(actual_item.content, expected_item.content)
    assert_eq(actual_item.parent, expected_item.parent)
    assert_eq(actual_item.side, expected_item.side)
    assert_eq(actual_item.deleted, expected_item.deleted)
    assert_eq(actual_item.deleted_ts, expected_item.deleted_ts)
    assert_eq(actual_item.deleted_agent, expected_item.deleted_agent)
    assert_eq(
      actual_item.deleted_is_undelete,
      expected_item.deleted_is_undelete,
    )
    assert_eq(actual_item.state, expected_item.state)
    assert_eq(actual_item.delete_count, expected_item.delete_count)
    assert_eq(actual_item.timestamp, expected_item.timestamp)
    assert_eq(actual_item.agent, expected_item.agent)
  }
}

///|
fn p2_assert_cache_snapshot(
  actual : P2CacheSnapshot,
  expected : P2CacheSnapshot,
) -> Unit raise {
  assert_eq(actual.ready, expected.ready)
  assert_eq(actual.positions, expected.positions)
}

///|
fn p2_assert_document_snapshot(
  doc : Document,
  before : P2DocumentSnapshot,
) -> Unit raise {
  assert_eq(doc.get_frontier(), before.frontier)
  p2_assert_same_operations(doc.get_all_ops(), before.ops)
  assert_eq(doc.tree.to_text(), before.tree_text)
  p2_assert_same_tree_items(p2_tree_snapshot(doc), before.tree_items)
  assert_eq(doc.oplog.has_pending(), before.pending)
  p2_assert_cache_snapshot(p2_cache_snapshot(doc), before.cache)
  assert_true(doc.cursor is None)
}

///|
test "P2 red malformed current input is fully atomic" {
  let doc = Document::new("p2-malformed")
  ignore(try! doc.insert(0, "warm"))
  ignore(doc.to_text())
  let before = p2_snapshot_document(doc)
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: None,
  })
  let malformed = @core.Op::insert(
    -1,
    [],
    "p2-malformed-peer",
    0,
    "xy",
    None,
    None,
  )

  let result : Result[DocumentAdmission, DocumentError] = Ok(
    doc.admit_remote([malformed]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::ContentError(reason~)) =>
      assert_eq(reason, ContentErrorReason::MultipleCodepoints)
    _ => fail("malformed input must fail before admission")
  }
  p2_assert_document_snapshot(doc, before)
  assert_eq(prepare_count, 0)
  assert_eq(commit_count, 0)
  assert_eq(projection_count, 0)
}

///|
test "P2 red stale prepared admission does not mutate Document" {
  let doc = Document::new("p2-stale")
  let stale_plan = try! doc.oplog.prepare_remote([])
  ignore(try! doc.insert(0, "baseline"))
  ignore(doc.to_text())
  let before = p2_snapshot_document(doc)
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: Some(_ => stale_plan),
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: None,
  })

  let result : Result[DocumentAdmission, DocumentError] = Ok(
    doc.admit_remote([]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::OpLog(@oplog.OpLogError::StaleAdmission)) => ()
    _ => fail("expected stale admission")
  }
  p2_assert_document_snapshot(doc, before)
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 0)
}

///|
test "P2 red consumed prepared admission does not mutate Document" {
  let doc = Document::new("p2-consumed")
  let consumed_plan = try! doc.oplog.prepare_remote([])
  let consumed_outcome = try! doc.oplog.commit_admission(consumed_plan)
  match consumed_outcome {
    @oplog.AdmissionOutcome::Complete(receipt) =>
      assert_eq(receipt.committed().length(), 0)
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("empty admission cannot be partial")
  }
  let before = p2_snapshot_document(doc)
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: Some(_ => consumed_plan),
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: None,
  })

  let result : Result[DocumentAdmission, DocumentError] = Ok(
    doc.admit_remote([]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::OpLog(@oplog.OpLogError::ConsumedAdmission)) => ()
    _ => fail("expected consumed admission")
  }
  p2_assert_document_snapshot(doc, before)
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 0)
}

///|
test "P2 red pending limit rejection is fully atomic" {
  let doc = Document::new("p2-limit")
  ignore(try! doc.insert(0, "warm"))
  ignore(doc.to_text())
  let before = p2_snapshot_document(doc)
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: None,
  })
  let incoming = p2_pending_batch("p2-limit-peer")

  let result : Result[DocumentAdmission, DocumentError] = Ok(
    doc.admit_remote(incoming, max_pending=0),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(
      DocumentError::OpLog(
        @oplog.OpLogError::PendingLimitExceeded(limit~, required~)
      )
    ) => {
      assert_eq(limit, 0)
      assert_eq(required, 1)
    }
    _ => fail("expected hard pending-limit rejection")
  }
  p2_assert_document_snapshot(doc, before)
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 0)
  assert_eq(projection_count, 0)
}

///|
test "P2 red preflight repairs graph-known tree divergence before pending" {
  let doc = Document::new("p2-preflight")
  let known = try! doc.insert(0, "Y")
  ignore(doc.to_text())
  let known_raw = @core.RawVersion(known.agent(), known.seq())
  let missing = @core.RawVersion("p2-preflight-missing", 0)
  let unready = p2_remote_insert(
    "p2-preflight-peer",
    0,
    [missing],
    Some(known_raw),
  )
  // A tombstone still resolves through FugueTree::get. Replace the tree so
  // the authority-known Insert is genuinely absent from the projection.
  doc.replace_projection_tree(@fugue.FugueTree::new())
  let before_frontier = doc.get_frontier()
  let mut recovery_calls = 0
  let mut recovery_saw_no_pending = false
  let mut recovery_saw_invalid_derived_state = false
  let mut recovery_frontier : @core.Frontier? = None
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: Some(frontier => {
      recovery_calls = recovery_calls + 1
      recovery_frontier = Some(frontier)
      recovery_saw_no_pending = !doc.oplog.has_pending()
      recovery_saw_invalid_derived_state = !doc.indexed_state.is_ready() &&
        doc.cursor is None
      @branch.Branch::checkout(doc.oplog, frontier)
    }),
  })

  let admission = try! doc.admit_remote([unready])
  assert_eq(recovery_calls, 1)
  assert_true(recovery_saw_no_pending)
  assert_true(recovery_saw_invalid_derived_state)
  assert_eq(recovery_frontier, Some(before_frontier))
  assert_eq(doc.get_frontier(), before_frontier)
  assert_true(doc.oplog.has_pending())
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 0)
  match admission.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.committed().length(), 0)
      p2_assert_identity_prefix(receipt.pending_from_transition(), [unready], 1)
    }
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("unready input must remain a complete pending transition")
  }
  match admission.projection {
    ProjectionStatus::Recovered => ()
    ProjectionStatus::Projected
    | ProjectionStatus::Skipped
    | ProjectionStatus::RecoveryRequired(..) =>
      fail("successful preflight recovery must be reported")
  }
  assert_true(
    admission.effect_availability
    is ProjectionEffectAvailability::SnapshotRequired,
  )
  let fresh = try! @branch.Branch::checkout(doc.oplog, before_frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
}

///|
test "P2 green preflight recovery remains sticky for projected batch" {
  let doc = Document::new("p2-preflight-project")
  let known = try! doc.insert(0, "Y")
  ignore(doc.to_text())
  let known_raw = @core.RawVersion(known.agent(), known.seq())
  let incoming = p2_remote_insert(
    "p2-preflight-project-peer",
    0,
    [],
    Some(known_raw),
  )
  doc.replace_projection_tree(@fugue.FugueTree::new())
  let mut recovery_calls = 0
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => (),
    on_commit_admission: () => (),
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: Some(frontier => {
      recovery_calls = recovery_calls + 1
      @branch.Branch::checkout(doc.oplog, frontier)
    }),
  })

  let admission = try! doc.admit_remote([incoming])
  assert_eq(recovery_calls, 1)
  assert_eq(projection_count, 1)
  match admission.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) =>
      p2_assert_operation_prefix(receipt.committed(), [incoming], 1)
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("known-origin batch must complete after recovery")
  }
  match admission.projection {
    ProjectionStatus::Recovered => ()
    ProjectionStatus::Projected
    | ProjectionStatus::Skipped
    | ProjectionStatus::RecoveryRequired(..) =>
      fail("successful preflight recovery must remain sticky")
  }
  assert_true(
    admission.effect_availability
    is ProjectionEffectAvailability::SnapshotRequired,
  )
  let fresh = try! @branch.Branch::checkout(doc.oplog, doc.get_frontier())
  assert_eq(doc.to_text(), fresh.to_text())
}

///|
test "P2 red preflight recovery then stale rejection keeps authority unchanged" {
  let doc = Document::new("p2-preflight-stale")
  let known = try! doc.insert(0, "Y")
  ignore(doc.to_text())
  let known_raw = @core.RawVersion(known.agent(), known.seq())
  let missing = @core.RawVersion("p2-preflight-stale-missing", 0)
  let unready = p2_remote_insert(
    "p2-preflight-stale-peer",
    0,
    [missing],
    Some(known_raw),
  )
  let stale_plan = try! doc.oplog.prepare_remote([unready])
  let generation_tick = try! doc.oplog.prepare_remote([])
  ignore(try! doc.oplog.commit_admission(generation_tick))
  doc.replace_projection_tree(@fugue.FugueTree::new())
  let before_frontier = doc.get_frontier()
  let before_ops = doc.get_all_ops()
  let mut recovery_calls = 0
  let mut recovery_saw_no_pending = false
  let mut recovery_saw_invalid_derived_state = false
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: Some(_ => stale_plan),
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: Some(frontier => {
      recovery_calls = recovery_calls + 1
      recovery_saw_no_pending = !doc.oplog.has_pending()
      recovery_saw_invalid_derived_state = !doc.indexed_state.is_ready() &&
        doc.cursor is None
      @branch.Branch::checkout(doc.oplog, frontier)
    }),
  })

  let result : Result[DocumentAdmission, DocumentError] = Ok(
    doc.admit_remote([unready]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::OpLog(@oplog.OpLogError::StaleAdmission)) => ()
    _ => fail("expected stale rejection after preflight recovery")
  }
  assert_eq(recovery_calls, 1)
  assert_true(recovery_saw_no_pending)
  assert_true(recovery_saw_invalid_derived_state)
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 0)
  assert_eq(doc.get_frontier(), before_frontier)
  p2_assert_same_operations(doc.get_all_ops(), before_ops)
  assert_true(!doc.oplog.has_pending())
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  let fresh = try! @branch.Branch::checkout(doc.oplog, before_frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}

///|
test "P2 red post-commit projection failure preserves receipt and recovers" {
  let doc = Document::new("p2-post-commit")
  ignore(try! doc.insert(0, "base"))
  ignore(doc.to_text())
  let incoming = p2_ready_batch("p2-post-commit-peer", 2)
  let mut projection_count = 0
  let mut recovery_calls = 0
  let mut recovery_saw_partial_tree = false
  let mut recovery_saw_invalid_cache = false
  doc.set_admission_hooks({
    on_prepare_remote: () => (),
    on_commit_admission: () => (),
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: None,
    projection_failure: Some(committed => {
      let applied : Result[Unit, DocumentError] = Ok(
        apply_projection(doc.tree, committed[0], doc.oplog.causal_graph()),
      ) catch {
        error => Err(error)
      }
      match applied {
        Ok(_) =>
          Some(
            DocumentError::OpLog(@oplog.OpLogError::MissingLocalVersion(lv=999)),
          )
        Err(error) => Some(error)
      }
    }),
    recovery_checkout: Some(frontier => {
      recovery_calls = recovery_calls + 1
      recovery_saw_partial_tree = doc.tree.to_text() != "base"
      recovery_saw_invalid_cache = !doc.indexed_state.is_ready() &&
        doc.cursor is None
      @branch.Branch::checkout(doc.oplog, frontier)
    }),
  })

  let admission = try! doc.admit_remote(incoming)
  assert_eq(projection_count, 1)
  assert_eq(recovery_calls, 1)
  assert_true(recovery_saw_partial_tree)
  assert_true(recovery_saw_invalid_cache)
  match admission.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => {
      p2_assert_operation_prefix(receipt.committed(), incoming, 2)
      assert_eq(doc.get_frontier(), receipt.frontier_after())
    }
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("projection failure must not erase the admission outcome")
  }
  match admission.projection {
    ProjectionStatus::Recovered => ()
    ProjectionStatus::Projected
    | ProjectionStatus::Skipped
    | ProjectionStatus::RecoveryRequired(..) =>
      fail("successful recovery must be distinguished from projection")
  }
  let fresh = try! @branch.Branch::checkout(doc.oplog, doc.get_frontier())
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
  assert_eq(doc.to_text(), fresh.to_text())
}

///|
test "P2 red failed recovery returns RecoveryRequired and remains fail-closed" {
  let doc = Document::new("p2-recovery-required")
  ignore(try! doc.insert(0, "base"))
  ignore(doc.to_text())
  let incoming = p2_ready_batch("p2-recovery-required-peer", 2)
  let mut recovery_calls = 0
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => (),
    on_commit_admission: () => (),
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: None,
    projection_failure: Some(committed => {
      let applied : Result[Unit, DocumentError] = Ok(
        apply_projection(doc.tree, committed[0], doc.oplog.causal_graph()),
      ) catch {
        error => Err(error)
      }
      match applied {
        Ok(_) =>
          Some(
            DocumentError::Fugue(
              @fugue.FugueError::MissingItem(id=@fugue.Lv(999)),
            ),
          )
        Err(error) => Some(error)
      }
    }),
    recovery_checkout: Some(_frontier => {
      recovery_calls = recovery_calls + 1
      raise @branch.BranchError::MissingOp(lv=999)
    }),
  })

  let admission = try! doc.admit_remote(incoming)
  assert_eq(projection_count, 1)
  assert_true(recovery_calls >= 1)
  match admission.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => {
      p2_assert_operation_prefix(receipt.committed(), incoming, 2)
      assert_eq(doc.get_frontier(), receipt.frontier_after())
    }
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("recovery failure must retain the admission receipt")
  }
  match admission.projection {
    ProjectionStatus::RecoveryRequired(..) => ()
    ProjectionStatus::Projected
    | ProjectionStatus::Recovered
    | ProjectionStatus::Skipped =>
      fail("failed checkout must return RecoveryRequired")
  }
  assert_true(
    admission.effect_availability is ProjectionEffectAvailability::Unavailable,
  )
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  let mutation : Result[Unit, DocumentError] = Ok(doc.prepare_for_mutation()) catch {
    error => Err(error)
  }
  match mutation {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("failed recovery must block later mutation")
  }
}

///|
test "P2 red retry drains only core pending suffix" {
  let doc = Document::new("p2-retry")
  let incoming = p2_ready_batch("p2-retry-peer", 3)
  let mut fail_enabled = true
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  let projected_ops : Array[@core.Op] = []
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: committed => {
      projection_count = projection_count + 1
      for op in committed {
        projected_ops.push(op)
      }
    },
    prepare_override: None,
    commit_failure: Some(op => {
      if fail_enabled && op.seq() == 1 {
        Some(@causal_graph.CausalGraphError::MissingParent(lv=-202))
      } else {
        None
      }
    }),
    projection_failure: None,
    recovery_checkout: None,
  })

  let first = try! doc.admit_remote(incoming)
  match first.effect_availability {
    ProjectionEffectAvailability::Exact(effects) =>
      assert_eq(effects.length(), 1)
    _ => fail("warm committed partial prefix must publish exact effects")
  }
  match first.outcome {
    @oplog.AdmissionOutcome::Partial(receipt~, error~) => {
      p2_assert_operation_prefix(receipt.committed(), incoming, 1)
      let suffix = [incoming[1], incoming[2]]
      p2_assert_identity_prefix(receipt.pending_from_transition(), suffix, 2)
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) =>
          assert_eq(lv, -202)
        _ => fail("expected retryable causal cause")
      }
    }
    @oplog.AdmissionOutcome::Complete(_) =>
      fail("first admission must leave a pending suffix")
  }
  assert_eq(projected_ops.length(), 1)
  fail_enabled = false

  let retry = try! doc.admit_remote([])
  match retry.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => {
      let suffix = [incoming[1], incoming[2]]
      p2_assert_operation_prefix(receipt.committed(), suffix, 2)
      assert_eq(receipt.already_admitted().length(), 0)
    }
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("cleared failure must drain the pending suffix")
  }
  assert_eq(prepare_count, 2)
  assert_eq(commit_count, 2)
  assert_eq(projection_count, 2)
  p2_assert_operation_prefix(projected_ops, incoming, 3)
  assert_eq(doc.get_all_ops().length(), 3)
  assert_true(!doc.oplog.has_pending())
}

///|
test "P2 red apply_remote remains compatible with one-op admission" {
  let source = Document::new("p2-compat-source")
  let remote = try! source.insert(0, "R")
  let legacy = Document::new("p2-compat-legacy")
  let batch = Document::new("p2-compat-batch")
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  legacy.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: None,
  })

  try! legacy.apply_remote(remote)
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 1)
  let admission = try! batch.admit_remote([remote])
  match admission.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) =>
      p2_assert_operation_prefix(receipt.committed(), [remote], 1)
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("one valid operation must complete")
  }
  assert_eq(legacy.to_text(), batch.to_text())
  assert_eq(legacy.get_frontier(), batch.get_frontier())
  assert_eq(legacy.get_all_ops().length(), batch.get_all_ops().length())
}

///|
test "P2 wrapper apply_remote translates partial admission" {
  let doc = Document::new("p2-wrapper-partial")
  let incoming = p2_ready_batch("p2-wrapper-partial-peer", 1)[0]
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: Some(_ => {
      Some(@causal_graph.CausalGraphError::MissingParent(lv=-204))
    }),
    projection_failure: None,
    recovery_checkout: None,
  })

  let result : Result[Unit, DocumentError] = Ok(doc.apply_remote(incoming)) catch {
    error => Err(error)
  }
  match result {
    Err(
      DocumentError::OpLog(
        @oplog.OpLogError::PartialRemoteAdmission(committed~, error~)
      )
    ) => {
      assert_eq(committed.length(), 0)
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) =>
          assert_eq(lv, -204)
        _ => fail("legacy wrapper must preserve the partial cause")
      }
    }
    _ => fail("apply_remote must translate a partial typed outcome")
  }
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 0)
  assert_true(doc.oplog.has_pending())
  assert_eq(doc.get_all_ops().length(), 0)
}

///|
test "P2 wrapper merge_remote prioritizes recovery over partial legacy error" {
  let doc = Document::new("p2-wrapper-partial-recovery")
  let agent = "p2-wrapper-partial-recovery-peer"
  let incoming = p2_ready_batch(agent, 2)
  let remote_frontier = [@core.RawVersion(agent, 1)]
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: Some(op => {
      if op.seq() == 1 {
        Some(@causal_graph.CausalGraphError::MissingParent(lv=-205))
      } else {
        None
      }
    }),
    projection_failure: Some(_ => {
      Some(
        DocumentError::Fugue(@fugue.FugueError::MissingItem(id=@fugue.Lv(997))),
      )
    }),
    recovery_checkout: Some(_frontier => {
      raise @branch.BranchError::MissingOp(lv=1001)
    }),
  })

  let result : Result[Unit, DocumentError] = Ok(
    doc.merge_remote(incoming, remote_frontier),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::ProjectionRecoveryRequired(frontier~, error~)) => {
      assert_eq(frontier, doc.get_frontier())
      match error {
        @branch.BranchError::MissingOp(lv~) => assert_eq(lv, 1001)
        _ => fail("recovery failure must retain its branch cause")
      }
    }
    Err(DocumentError::OpLog(@oplog.OpLogError::PartialRemoteAdmission(..))) =>
      fail("recovery failure must take priority over partial legacy error")
    _ => fail("merge wrapper must expose typed recovery failure")
  }
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 1)
  assert_eq(doc.oplog.op_count(), 1)
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
}

///|
test "P2 red merge_remote keeps closure validation while batch admission accepts incomplete input" {
  let source = Document::new("p2-merge-source")
  ignore(try! source.insert(0, "a"))
  ignore(try! source.insert(1, "b"))
  let remote_ops = source.get_all_ops()
  let remote_frontier = try! source.get_frontier_raw()

  let merged = Document::new("p2-merge-legacy")
  let mut merged_prepare_count = 0
  let mut merged_commit_count = 0
  let mut merged_projection_count = 0
  merged.set_admission_hooks({
    on_prepare_remote: () => merged_prepare_count = merged_prepare_count + 1,
    on_commit_admission: () => merged_commit_count = merged_commit_count + 1,
    on_projection_finalization: _ => {
      merged_projection_count = merged_projection_count + 1
    },
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: None,
  })
  try! merged.merge_remote(remote_ops, remote_frontier)
  assert_eq(merged_prepare_count, 1)
  assert_eq(merged_commit_count, 1)
  assert_eq(merged_projection_count, 1)
  let batched = Document::new("p2-merge-batch")
  ignore(try! batched.admit_remote(remote_ops))
  assert_eq(merged.to_text(), batched.to_text())
  assert_eq(merged.get_frontier(), batched.get_frontier())

  let incomplete = Document::new("p2-merge-incomplete")
  let second_only = [remote_ops[1]]
  let mut invalid_prepare_count = 0
  let mut invalid_commit_count = 0
  let mut invalid_projection_count = 0
  incomplete.set_admission_hooks({
    on_prepare_remote: () => invalid_prepare_count = invalid_prepare_count + 1,
    on_commit_admission: () => invalid_commit_count = invalid_commit_count + 1,
    on_projection_finalization: _ => {
      invalid_projection_count = invalid_projection_count + 1
    },
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: None,
  })
  let closure_result : Result[Unit, DocumentError] = Ok(
    incomplete.merge_remote(second_only, remote_frontier),
  ) catch {
    error => Err(error)
  }
  match closure_result {
    Err(DocumentError::OpLog(@oplog.OpLogError::MissingRemoteParent(..))) => ()
    _ => fail("merge_remote must retain complete-frontier closure validation")
  }
  assert_eq(invalid_prepare_count, 0)
  assert_eq(invalid_commit_count, 0)
  assert_eq(invalid_projection_count, 0)
  assert_eq(incomplete.get_all_ops().length(), 0)
  assert_true(!incomplete.oplog.has_pending())

  let pending = try! incomplete.admit_remote(second_only)
  match pending.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.committed().length(), 0)
      p2_assert_identity_prefix(
        receipt.pending_from_transition(),
        second_only,
        1,
      )
    }
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("incomplete batch should be pending, not partial")
  }
  match pending.projection {
    ProjectionStatus::Skipped => ()
    ProjectionStatus::Projected
    | ProjectionStatus::Recovered
    | ProjectionStatus::RecoveryRequired(..) =>
      fail("pending incomplete batch must skip projection")
  }
}

///|
fn p2_assert_fresh_cursor_convergence(doc : Document) -> Unit raise {
  let fresh = try! @branch.Branch::checkout(doc.oplog, doc.get_frontier())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.to_text(), fresh.to_text())
}

///|
test "P2 red remote complete admission resets cursor before local insert" {
  let source = Document::new("p2-cursor-complete-source")
  let remote = try! source.insert(0, "R")
  let doc = Document::new("p2-cursor-complete")
  ignore(try! doc.insert(0, "a"))
  ignore(try! doc.admit_remote([remote]))
  ignore(try! doc.insert(doc.visible_count(), "l"))
  p2_assert_fresh_cursor_convergence(doc)
}

///|
test "P2 red partial admission resets cursor before local insert" {
  let doc = Document::new("p2-cursor-partial")
  ignore(try! doc.insert(0, "a"))
  let incoming = p2_ready_batch("p2-cursor-partial-peer", 2)
  doc.set_admission_hooks({
    on_prepare_remote: () => (),
    on_commit_admission: () => (),
    on_projection_finalization: _ => (),
    prepare_override: None,
    commit_failure: Some(op => {
      if op.seq() == 1 {
        Some(@causal_graph.CausalGraphError::MissingParent(lv=-203))
      } else {
        None
      }
    }),
    projection_failure: None,
    recovery_checkout: None,
  })
  let admission = try! doc.admit_remote(incoming)
  match admission.outcome {
    @oplog.AdmissionOutcome::Partial(..) => ()
    @oplog.AdmissionOutcome::Complete(_) =>
      fail("expected partial cursor fixture")
  }
  ignore(try! doc.insert(doc.visible_count(), "l"))
  p2_assert_fresh_cursor_convergence(doc)
}

///|
test "P2 red recovered admission resets cursor before local insert" {
  let doc = Document::new("p2-cursor-recovery")
  ignore(try! doc.insert(0, "a"))
  let incoming = p2_ready_batch("p2-cursor-recovery-peer", 1)
  doc.set_admission_hooks({
    on_prepare_remote: () => (),
    on_commit_admission: () => (),
    on_projection_finalization: _ => (),
    prepare_override: None,
    commit_failure: None,
    projection_failure: Some(_ => {
      Some(
        DocumentError::Fugue(@fugue.FugueError::MissingItem(id=@fugue.Lv(998))),
      )
    }),
    recovery_checkout: Some(frontier => {
      @branch.Branch::checkout(doc.oplog, frontier)
    }),
  })
  let admission = try! doc.admit_remote(incoming)
  match admission.projection {
    ProjectionStatus::Recovered => ()
    ProjectionStatus::Projected
    | ProjectionStatus::Skipped
    | ProjectionStatus::RecoveryRequired(..) =>
      fail("expected successful recovery")
  }
  assert_true(
    admission.effect_availability
    is ProjectionEffectAvailability::SnapshotRequired,
  )
  ignore(try! doc.insert(doc.visible_count(), "l"))
  p2_assert_fresh_cursor_convergence(doc)
}

///|
test "P2 green entry recovery is sticky for duplicate-only admission" {
  let doc = Document::new("p2-entry-duplicate")
  let incoming = p2_ready_batch("p2-entry-duplicate-peer", 1)
  let mut recovery_ready = false
  let mut recovery_calls = 0
  let mut projection_failure = true
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: None,
    projection_failure: Some(_ => {
      if projection_failure {
        Some(
          DocumentError::Fugue(
            @fugue.FugueError::MissingItem(id=@fugue.Lv(999)),
          ),
        )
      } else {
        None
      }
    }),
    recovery_checkout: Some(frontier => {
      recovery_calls = recovery_calls + 1
      if recovery_ready {
        @branch.Branch::checkout(doc.oplog, frontier)
      } else {
        raise @branch.BranchError::MissingOp(lv=999)
      }
    }),
  })

  let first = try! doc.admit_remote(incoming)
  match first.projection {
    ProjectionStatus::RecoveryRequired(..) => ()
    ProjectionStatus::Skipped
    | ProjectionStatus::Projected
    | ProjectionStatus::Recovered =>
      fail("fixture must leave entry recovery required")
  }
  recovery_ready = true
  projection_failure = false
  projection_count = 0
  let admission = try! doc.admit_remote(incoming)
  assert_eq(recovery_calls, 2)
  assert_eq(prepare_count, 2)
  assert_eq(commit_count, 2)
  assert_eq(projection_count, 0)
  match admission.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) =>
      assert_eq(receipt.committed().length(), 0)
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("duplicate-only admission must be complete")
  }
  match admission.projection {
    ProjectionStatus::Recovered => ()
    ProjectionStatus::Skipped
    | ProjectionStatus::Projected
    | ProjectionStatus::RecoveryRequired(..) =>
      fail("entry recovery must remain sticky for duplicate-only admission")
  }
  assert_true(
    admission.effect_availability
    is ProjectionEffectAvailability::SnapshotRequired,
  )
  assert_true(doc.projection_health is ProjectionHealth::Ready)
}

///|
test "P2 green entry recovery is sticky for projected admission" {
  let doc = Document::new("p2-entry-projected")
  let seed = p2_ready_batch("p2-entry-projected-seed", 1)
  let incoming = p2_ready_batch("p2-entry-projected-peer", 1)
  let mut recovery_ready = false
  let mut recovery_calls = 0
  let mut projection_failure = true
  let mut projection_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => (),
    on_commit_admission: () => (),
    on_projection_finalization: _ => projection_count = projection_count + 1,
    prepare_override: None,
    commit_failure: None,
    projection_failure: Some(_ => {
      if projection_failure {
        Some(
          DocumentError::Fugue(
            @fugue.FugueError::MissingItem(id=@fugue.Lv(999)),
          ),
        )
      } else {
        None
      }
    }),
    recovery_checkout: Some(frontier => {
      recovery_calls = recovery_calls + 1
      if recovery_ready {
        @branch.Branch::checkout(doc.oplog, frontier)
      } else {
        raise @branch.BranchError::MissingOp(lv=999)
      }
    }),
  })

  let first = try! doc.admit_remote(seed)
  match first.projection {
    ProjectionStatus::RecoveryRequired(..) => ()
    ProjectionStatus::Skipped
    | ProjectionStatus::Projected
    | ProjectionStatus::Recovered =>
      fail("fixture must leave entry recovery required")
  }
  recovery_ready = true
  projection_failure = false
  projection_count = 0
  let admission = try! doc.admit_remote(incoming)
  assert_eq(recovery_calls, 2)
  assert_eq(projection_count, 1)
  match admission.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) =>
      p2_assert_operation_prefix(receipt.committed(), incoming, 1)
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("complete admission must not be partial")
  }
  match admission.projection {
    ProjectionStatus::Recovered => ()
    ProjectionStatus::Skipped
    | ProjectionStatus::Projected
    | ProjectionStatus::RecoveryRequired(..) =>
      fail("entry recovery must remain sticky for projected admission")
  }
  let fresh = try! @branch.Branch::checkout(doc.oplog, doc.get_frontier())
  assert_eq(doc.to_text(), fresh.to_text())
}

///|
test "P2 red divergence after recovery remains RecoveryRequired" {
  let doc = Document::new("p2-divergence-after-recovery")
  let known = try! doc.insert(0, "Y")
  ignore(doc.to_text())
  let known_raw = @core.RawVersion(known.agent(), known.seq())
  let missing = @core.RawVersion("p2-divergence-after-recovery-missing", 0)
  let unready = p2_remote_insert(
    "p2-divergence-after-recovery-peer",
    0,
    [missing],
    Some(known_raw),
  )
  doc.replace_projection_tree(@fugue.FugueTree::new())
  let before_frontier = doc.get_frontier()
  let mut recovery_calls = 0
  let mut prepare_count = 0
  let mut commit_count = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => prepare_count = prepare_count + 1,
    on_commit_admission: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => (),
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: Some(_frontier => {
      recovery_calls = recovery_calls + 1
      if recovery_calls <= 2 {
        @branch.Branch::from_tree_and_oplog(@fugue.FugueTree::new(), doc.oplog)
      } else {
        @branch.Branch::checkout(doc.oplog, _frontier)
      }
    }),
  })

  let result : Result[DocumentAdmission, DocumentError] = Ok(
    doc.admit_remote([unready]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::ProjectionRecoveryRequired(frontier~, error~)) => {
      assert_eq(frontier, before_frontier)
      match error {
        @branch.BranchError::Fugue(@fugue.FugueError::MissingItem(..)) => ()
        _ => fail("second divergence must preserve a BranchError cause")
      }
    }
    _ => fail("second divergence must remain typed recovery-required")
  }
  assert_eq(recovery_calls, 1)
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 0)
  assert_true(!doc.oplog.has_pending())
  assert_eq(doc.get_frontier(), before_frontier)
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
  let mutation : Result[Unit, DocumentError] = Ok(doc.prepare_for_mutation()) catch {
    error => Err(error)
  }
  match mutation {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("unresolved divergence must keep later mutations fail-closed")
  }
  assert_eq(recovery_calls, 2)
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
  try! doc.prepare_for_mutation()
  assert_eq(recovery_calls, 3)
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  let fresh = try! @branch.Branch::checkout(doc.oplog, before_frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}

///|
test "P2 red divergence is repaired before invalid admission rejection" {
  let doc = Document::new("p2-invalid-with-divergence")
  let known = try! doc.insert(0, "Y")
  ignore(doc.to_text())
  let known_raw = @core.RawVersion(known.agent(), known.seq())
  let invalid_noninsert_raw = @core.RawVersion("p2-invalid-noninsert", 0)
  let invalid_noninsert = @core.Op::delete(
    -1,
    [],
    invalid_noninsert_raw.agent,
    invalid_noninsert_raw.seq,
    Some(@core.RawVersion("p2-invalid-target", 0)),
  )
  let invalid_dependent = @core.Op::insert(
    -1,
    [],
    "p2-invalid-dependent",
    0,
    "x",
    Some(invalid_noninsert_raw),
    None,
  )
  let incoming = p2_remote_insert(
    "p2-invalid-with-divergence-peer",
    0,
    [],
    Some(known_raw),
  )
  doc.replace_projection_tree(@fugue.FugueTree::new())
  let before_frontier = doc.get_frontier()
  let before_ops = doc.get_all_ops()
  let mut recovery_calls = 0
  let result : Result[Bool, DocumentError] = Ok(
    doc.ensure_admission_targets(
      [invalid_noninsert, invalid_dependent],
      [incoming],
      frontier => {
        recovery_calls = recovery_calls + 1
        doc.recover_projection(frontier)
      },
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::MissingOrigin(raw~)) =>
      assert_eq(raw, invalid_noninsert_raw)
    _ => fail("invalid admission must remain the returned error")
  }
  assert_eq(recovery_calls, 1)
  assert_eq(doc.get_frontier(), before_frontier)
  p2_assert_same_operations(doc.get_all_ops(), before_ops)
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  let fresh = try! @branch.Branch::checkout(doc.oplog, before_frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}

///|
test "P2 red recovery retains all missing target verification" {
  let doc = Document::new("p2-multiple-recovery-targets")
  let first = try! doc.insert(0, "Y1")
  let second = try! doc.insert(1, "Y2")
  ignore(doc.to_text())
  let first_raw = @core.RawVersion(first.agent(), first.seq())
  let second_raw = @core.RawVersion(second.agent(), second.seq())
  let incoming = @core.Op::insert(
    -1,
    [],
    "p2-multiple-recovery-targets-peer",
    0,
    "x",
    Some(first_raw),
    Some(second_raw),
  )
  doc.replace_projection_tree(@fugue.FugueTree::new())
  let before_frontier = doc.get_frontier()
  let mut recovery_calls = 0
  let partial_tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply_projection(partial_tree, first, doc.oplog.causal_graph())
  let partial_branch = @branch.Branch::from_tree_and_oplog(
    partial_tree,
    doc.oplog,
  )
  let result : Result[DocumentAdmission, DocumentError] = Ok(
    {
      doc.set_admission_hooks({
        on_prepare_remote: () => (),
        on_commit_admission: () => (),
        on_projection_finalization: _ => (),
        prepare_override: None,
        commit_failure: None,
        projection_failure: None,
        recovery_checkout: Some(frontier => {
          recovery_calls = recovery_calls + 1
          if recovery_calls == 1 {
            @branch.Branch::from_tree_and_oplog(
              @fugue.FugueTree::new(),
              doc.oplog,
            )
          } else if recovery_calls == 2 {
            partial_branch
          } else {
            @branch.Branch::checkout(doc.oplog, frontier)
          }
        }),
      })
      doc.admit_remote([incoming])
    },
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("initial incomplete recovery must remain fail-closed")
  }
  assert_eq(recovery_calls, 1)
  let second_retry : Result[Unit, DocumentError] = Ok(
    doc.prepare_for_mutation(),
  ) catch {
    error => Err(error)
  }
  match second_retry {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("one-target recovery must not hide the second divergence")
  }
  assert_eq(recovery_calls, 2)
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
  try! doc.prepare_for_mutation()
  assert_eq(recovery_calls, 3)
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  let fresh = try! @branch.Branch::checkout(doc.oplog, before_frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}

///|
test "P2 red recovery retains verification after checkout failure" {
  let doc = Document::new("p2-recovery-failure-verification")
  let known = try! doc.insert(0, "Y")
  ignore(doc.to_text())
  let known_raw = @core.RawVersion(known.agent(), known.seq())
  let incoming = p2_remote_insert(
    "p2-recovery-failure-verification-peer",
    0,
    [],
    Some(known_raw),
  )
  doc.replace_projection_tree(@fugue.FugueTree::new())
  let before_frontier = doc.get_frontier()
  let mut recovery_calls = 0
  let result : Result[DocumentAdmission, DocumentError] = Ok(
    {
      doc.set_admission_hooks({
        on_prepare_remote: () => (),
        on_commit_admission: () => (),
        on_projection_finalization: _ => (),
        prepare_override: None,
        commit_failure: None,
        projection_failure: None,
        recovery_checkout: Some(frontier => {
          recovery_calls = recovery_calls + 1
          if recovery_calls == 1 {
            raise @branch.BranchError::MissingOp(lv=777)
          } else if recovery_calls == 2 {
            @branch.Branch::from_tree_and_oplog(
              @fugue.FugueTree::new(),
              doc.oplog,
            )
          } else {
            @branch.Branch::checkout(doc.oplog, frontier)
          }
        }),
      })
      doc.admit_remote([incoming])
    },
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("checkout failure must preserve recovery-required state")
  }
  assert_eq(recovery_calls, 1)
  assert_eq(doc.get_frontier(), before_frontier)
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  let second_retry : Result[Unit, DocumentError] = Ok(
    doc.prepare_for_mutation(),
  ) catch {
    error => Err(error)
  }
  match second_retry {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("failed recovery must retain target verification")
  }
  assert_eq(recovery_calls, 2)
  assert_eq(doc.get_frontier(), before_frontier)
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
  try! doc.prepare_for_mutation()
  assert_eq(recovery_calls, 3)
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  let fresh = try! @branch.Branch::checkout(doc.oplog, before_frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}

///|
test "P2 red recovery retains present origins across swapped missing targets" {
  let doc = Document::new("p2-swapped-recovery-targets")
  let first_input = p2_remote_insert("p2-swapped-origin-y1", 0, [], None)
  let second_input = p2_remote_insert("p2-swapped-origin-y2", 0, [], None)
  ignore(try! doc.admit_remote([first_input, second_input]))
  ignore(doc.to_text())
  let admitted = doc.get_all_ops()
  let first = admitted[0]
  let second = admitted[1]
  let first_raw = @core.RawVersion(first.agent(), first.seq())
  let second_raw = @core.RawVersion(second.agent(), second.seq())
  let initial_tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply_projection(initial_tree, second, doc.oplog.causal_graph())
  assert_true(initial_tree.get(@fugue.Lv(second.lv())) is Some(_))
  assert_true(initial_tree.get(@fugue.Lv(first.lv())) is None)
  doc.replace_projection_tree(initial_tree)
  let incoming = @core.Op::insert(
    -1,
    [],
    "p2-swapped-recovery-peer",
    0,
    "x",
    Some(first_raw),
    Some(second_raw),
  )
  let before_frontier = doc.get_frontier()
  let partial_tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply_projection(partial_tree, first, doc.oplog.causal_graph())
  assert_true(partial_tree.get(@fugue.Lv(first.lv())) is Some(_))
  assert_true(partial_tree.get(@fugue.Lv(second.lv())) is None)
  let partial_branch = @branch.Branch::from_tree_and_oplog(
    partial_tree,
    doc.oplog,
  )
  let mut recovery_calls = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => (),
    on_commit_admission: () => (),
    on_projection_finalization: _ => (),
    prepare_override: None,
    commit_failure: None,
    projection_failure: None,
    recovery_checkout: Some(frontier => {
      recovery_calls = recovery_calls + 1
      if recovery_calls <= 2 {
        partial_branch
      } else {
        @branch.Branch::checkout(doc.oplog, frontier)
      }
    }),
  })
  let initial_result : Result[DocumentAdmission, DocumentError] = Ok(
    doc.admit_remote([incoming]),
  ) catch {
    error => Err(error)
  }
  match initial_result {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("initial swapped recovery must remain fail-closed")
  }
  assert_eq(recovery_calls, 1)
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
  let second_retry : Result[Unit, DocumentError] = Ok(
    doc.prepare_for_mutation(),
  ) catch {
    error => Err(error)
  }
  match second_retry {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("present origin must remain part of recovery verification")
  }
  assert_eq(recovery_calls, 2)
  assert_eq(doc.get_frontier(), before_frontier)
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
  try! doc.prepare_for_mutation()
  assert_eq(recovery_calls, 3)
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  let fresh = try! @branch.Branch::checkout(doc.oplog, before_frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}
