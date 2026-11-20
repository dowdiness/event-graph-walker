///| Remaining P2.1 red tests: rejection, divergence, recovery, retry, wrappers, and cursor.

///|
struct P2TreeItemSnapshot {
  lv : Int32
  content : String
  parent : Int32?
  side : @fugue.Side
  deleted : Bool
  deleted_ts : Int32
  deleted_agent : String
  deleted_is_undelete : Bool
  state : @fugue.ItemState
  delete_count : Int32
  timestamp : Int32
  agent : String
}

///|
struct P2CacheSnapshot {
  ready : Bool
  positions : Array[Int32]
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
    return { ready: false, positions: [], }
  }
  let positions : Array[Int32] = []
  for position = 0; position < doc.tree.visible_count(); position = position + 1 {
    match doc.lv_at_position(position) {
      Some(lv) => positions.push(lv)
      None => fail("ready cache must resolve every visible position")
    }
  }
  { ready: true, positions, }
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
  doc.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: None,
    commit_failure: None,
    projection_failure: None,
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

  let result : Result[DocumentChanges, DocumentError] = Ok(
    doc.apply_changes([malformed]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::ContentError(reason~)) =>
      assert_eq(reason, ContentErrorReason::MultipleCodepoints)
    _ => fail("malformed input must fail before change application")
  }
  p2_assert_document_snapshot(doc, before)
  assert_eq(prepare_count, 0)
  assert_eq(commit_count, 0)
  assert_eq(projection_count, 0)
}

///|
test "P2 red stale `ApplyChanges` action does not mutate Document" {
  let doc = Document::new("p2-stale")
  let stale_action = try! @oplog.ApplyChanges(doc.oplog, [])
  ignore(try! doc.insert(0, "baseline"))
  ignore(doc.to_text())
  let before = p2_snapshot_document(doc)
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: Some(_ => stale_action),
    commit_failure: None,
    projection_failure: None,
  })

  let result : Result[DocumentChanges, DocumentError] = Ok(
    doc.apply_changes([]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::OpLog(@oplog.OpLogError::StaleApplyChanges)) => ()
    _ => fail("expected stale change application")
  }
  p2_assert_document_snapshot(doc, before)
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 0)
}

///|
test "P2 red consumed `ApplyChanges` action does not mutate Document" {
  let doc = Document::new("p2-consumed")
  let consumed_action = try! @oplog.ApplyChanges(doc.oplog, [])
  let consumed_outcome = try! doc.oplog.apply_changes(consumed_action)
  match consumed_outcome {
    @oplog.ApplyChangesOutcome::Succeeded(report) =>
      assert_eq(report.committed().length(), 0)
    @oplog.ApplyChangesOutcome::Failed(..) =>
      fail("empty change application cannot be partial")
  }
  let before = p2_snapshot_document(doc)
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: Some(_ => consumed_action),
    commit_failure: None,
    projection_failure: None,
  })

  let result : Result[DocumentChanges, DocumentError] = Ok(
    doc.apply_changes([]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::OpLog(@oplog.OpLogError::ConsumedApplyChanges)) => ()
    _ => fail("expected consumed change application")
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
  doc.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: None,
    commit_failure: None,
    projection_failure: None,
  })
  let incoming = p2_pending_batch("p2-limit-peer")

  let result : Result[DocumentChanges, DocumentError] = Ok(
    doc.apply_changes(incoming, max_pending=0),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(
      DocumentError::OpLog(
        @oplog.OpLogError::PendingLimitExceeded(limit~, required~),
      ),
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
test "preflight rejects graph-known tree divergence before pending admission" {
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
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: None,
    commit_failure: None,
    projection_failure: None,
  })

  let rejected = Ok(doc.apply_changes([unready])) catch { error => Err(error) }
  assert_true(rejected is Err(DocumentError::ProjectionRecoveryRequired(..)))
  assert_eq(doc.pending_count(), 0)
  assert_eq(commit_count, 0)
  assert_true(!doc.indexed_state.is_ready())
  doc.integrate_projection()
  let change = try! doc.apply_changes([unready])
  assert_eq(doc.get_frontier(), before_frontier)
  assert_true(doc.oplog.has_pending())
  assert_eq(prepare_count, 2)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 0)
  match change.outcome {
    @oplog.ApplyChangesOutcome::Succeeded(receipt) => {
      assert_eq(receipt.committed().length(), 0)
      p2_assert_identity_prefix(receipt.pending_from_transition(), [unready], 1)
    }
    @oplog.ApplyChangesOutcome::Failed(..) =>
      fail("unready input must remain a complete pending transition")
  }
  match change.publication {
    Exact(edits) if edits.is_empty() => ()
    _ =>
      fail(
        "pending-only transition after reopening must publish exact empty edits",
      )
  }
  assert_true(change.publication is Exact(_))
  let fresh = try! @branch.Branch::checkout(doc.oplog, before_frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
}

///|
test "preflight divergence requires explicit reopening before projected batch" {
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
  let mut projection_count = 0
  doc.set_apply_changes_hooks({
    on_action: () => (),
    on_apply_changes: () => (),
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: None,
    commit_failure: None,
    projection_failure: None,
  })

  let rejected = Ok(doc.apply_changes([incoming])) catch { error => Err(error) }
  assert_true(rejected is Err(DocumentError::ProjectionRecoveryRequired(..)))
  assert_eq(projection_count, 0)
  doc.integrate_projection()
  let change = try! doc.apply_changes([incoming])
  assert_eq(projection_count, 1)
  match change.outcome {
    @oplog.ApplyChangesOutcome::Succeeded(receipt) =>
      p2_assert_operation_prefix(receipt.committed(), [incoming], 1)
    @oplog.ApplyChangesOutcome::Failed(..) =>
      fail("known-origin batch must complete after recovery")
  }
  match change.publication {
    Exact(_) => ()
    _ => fail("projected batch after reopening must publish exact edits")
  }
  assert_true(change.publication is Exact(_))
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
  let stale_action = try! @oplog.ApplyChanges(doc.oplog, [unready])
  let generation_action = try! @oplog.ApplyChanges(doc.oplog, [])
  ignore(try! doc.oplog.apply_changes(generation_action))
  doc.replace_projection_tree(@fugue.FugueTree::new())
  let before_frontier = doc.get_frontier()
  let before_ops = doc.get_all_ops()
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: Some(_ => stale_action),
    commit_failure: None,
    projection_failure: None,
  })

  let result : Result[DocumentChanges, DocumentError] = Ok(
    doc.apply_changes([unready]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("expected stale rejection after preflight recovery")
  }
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 0)
  assert_eq(projection_count, 0)
  assert_eq(doc.get_frontier(), before_frontier)
  p2_assert_same_operations(doc.get_all_ops(), before_ops)
  assert_true(!doc.oplog.has_pending())
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  assert_true(doc.projection_health is ProjectionHealth::Unavailable(_))
  doc.integrate_projection()
  let stale = Ok(doc.apply_changes([unready])) catch { error => Err(error) }
  assert_true(
    stale is Err(DocumentError::OpLog(@oplog.OpLogError::StaleApplyChanges)),
  )
  let fresh = try! @branch.Branch::checkout(doc.oplog, before_frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}

///|
test "history-only admission exposes partial progress without publishing and retries converge" {
  let doc = Document::new("partial-view")
  let before = doc.view_graph_version()
  let incoming = p2_ready_batch("remote-partial", 3)
  doc.set_apply_changes_hooks({
    on_action: () => (),
    on_apply_changes: () => (),
    on_projection_finalization: _ => (),
    action_override: None,
    commit_failure: Some(op => {
      if op.seq() == 1 {
        Some(@causal_graph.CausalGraphError::MissingParent(lv=-99))
      } else {
        None
      }
    }),
    projection_failure: None,
  })
  let structural = incoming.map(op => try! @core.StructuralOp(op))
  let outcome = try! doc.admit_structural_changes(structural[:], 100)
  guard outcome is @oplog.ApplyChangesOutcome::Failed(report~, ..) else {
    fail("expected partial admission")
  }
  assert_eq(report.committed().length(), 1)
  assert_eq(doc.pending_count(), 2)
  assert_true(doc.current_graph_version() != before)
  assert_eq(doc.view_graph_version(), before)
  assert_eq(doc.to_text(), "")
  doc.apply_changes_hooks = None
  assert_true(
    (try! doc.admit_structural_changes(structural[:], 100))
    is @oplog.ApplyChangesOutcome::Succeeded(_),
  )
  try! doc.advance_projection()
  assert_eq(doc.to_text(), "xxx")
  assert_eq(doc.view_graph_version(), doc.current_graph_version())
}

///|
test "immediate settlement includes hidden history even on duplicate delivery" {
  for duplicate_only in [false, true] {
    let doc = Document::new("mixed-view")
    let incoming = p2_ready_batch("mixed-peer", 3)
    let structural = incoming.map(op => try! @core.StructuralOp(op))
    ignore(try! doc.admit_structural_changes(structural[:2], 100))
    assert_eq(doc.to_text(), "")
    ignore(try! doc.insert(0, "L"))
    let before = doc.view_graph_version()
    let changes = try! doc.apply_changes(
      if duplicate_only {
        incoming[:2].to_owned()
      } else {
        incoming
      },
    )
    guard changes.publication is Exact(effects) else {
      fail("expected exact publication")
    }
    assert_eq(
      (try! changes.report()).committed().length(),
      if duplicate_only {
        0
      } else {
        1
      },
    )
    assert_true(doc.view_graph_version() != before)
    assert_eq(doc.view_graph_version(), doc.current_graph_version())
    let canonical = try! doc.checkout_branch(doc.get_frontier())
    assert_eq(doc.to_text(), canonical.to_text())
    assert_eq(batch_replay_effects("L", effects[:]), canonical.to_text())
    assert_eq(doc.visible_count(), if duplicate_only { 3 } else { 4 })
    let again = try! doc.apply_changes(incoming[:2].to_owned())
    assert_true(again.publication is Exact(edits) && edits.is_empty())
    assert_eq(doc.to_text(), canonical.to_text())
  }
}

///|
test "post-commit projection failure preserves receipt until explicit reopening" {
  let doc = Document::new("p2-post-commit")
  ignore(try! doc.insert(0, "base"))
  ignore(doc.to_text())
  let incoming = p2_ready_batch("p2-post-commit-peer", 2)
  let mut projection_count = 0
  doc.set_apply_changes_hooks({
    on_action: () => (),
    on_apply_changes: () => (),
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: None,
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
  })

  let change = try! doc.apply_changes(incoming)
  assert_eq(projection_count, 1)
  assert_true(doc.tree.to_text() != "base")
  assert_true(!doc.indexed_state.is_ready())
  match change.outcome {
    @oplog.ApplyChangesOutcome::Succeeded(receipt) => {
      p2_assert_operation_prefix(receipt.committed(), incoming, 2)
      assert_eq(doc.get_frontier(), receipt.frontier_after())
    }
    @oplog.ApplyChangesOutcome::Failed(..) =>
      fail("projection failure must not erase the change application outcome")
  }
  match change.publication {
    Unavailable(
      DocumentError::OpLog(@oplog.OpLogError::MissingLocalVersion(lv=999)),
    ) => ()
    _ => fail("failed projection must publish its error without recovery")
  }
  doc.integrate_projection()
  let fresh = try! @branch.Branch::checkout(doc.oplog, doc.get_frontier())
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
  assert_eq(doc.to_text(), fresh.to_text())
}

///|
test "post-commit projection failure returns unavailable and remains fail-closed" {
  let doc = Document::new("p2-recovery-required")
  ignore(try! doc.insert(0, "base"))
  ignore(doc.to_text())
  let incoming = p2_ready_batch("p2-recovery-required-peer", 2)
  let mut projection_count = 0
  doc.set_apply_changes_hooks({
    on_action: () => (),
    on_apply_changes: () => (),
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: None,
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
  })

  let change = try! doc.apply_changes(incoming)
  assert_eq(projection_count, 1)
  match change.outcome {
    @oplog.ApplyChangesOutcome::Succeeded(receipt) => {
      p2_assert_operation_prefix(receipt.committed(), incoming, 2)
      assert_eq(doc.get_frontier(), receipt.frontier_after())
    }
    @oplog.ApplyChangesOutcome::Failed(..) =>
      fail("recovery failure must retain the change application receipt")
  }
  match change.publication {
    Unavailable(_) => ()
    _ => fail("projection failure must publish unavailable without checkout")
  }
  assert_true(change.publication is Unavailable(_))
  assert_true(doc.projection_health is ProjectionHealth::Unavailable(_))
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  let mutation : Result[Unit, DocumentError] = Ok(doc.prepare_for_mutation()) catch {
    error => Err(error)
  }
  match mutation {
    Err(DocumentError::Fugue(_)) => ()
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
  doc.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: committed => {
      projection_count = projection_count + 1
      for op in committed {
        projected_ops.push(op)
      }
    },
    action_override: None,
    commit_failure: Some(op => {
      if fail_enabled && op.seq() == 1 {
        Some(@causal_graph.CausalGraphError::MissingParent(lv=-202))
      } else {
        None
      }
    }),
    projection_failure: None,
  })

  let first = try! doc.apply_changes(incoming)
  match first.publication {
    Exact(effects) => assert_eq(effects.length(), 1)
    _ => fail("warm committed partial prefix must publish exact effects")
  }
  match first.outcome {
    @oplog.ApplyChangesOutcome::Failed(report=receipt, error~) => {
      p2_assert_operation_prefix(receipt.committed(), incoming, 1)
      let suffix = [incoming[1], incoming[2]]
      p2_assert_identity_prefix(receipt.pending_from_transition(), suffix, 2)
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) =>
          assert_eq(lv, -202)
        _ => fail("expected retryable causal cause")
      }
    }
    @oplog.ApplyChangesOutcome::Succeeded(_) =>
      fail("first change application must leave a pending suffix")
  }
  assert_eq(projected_ops.length(), 1)
  fail_enabled = false

  let retry = try! doc.apply_changes([])
  match retry.outcome {
    @oplog.ApplyChangesOutcome::Succeeded(receipt) => {
      let suffix = [incoming[1], incoming[2]]
      p2_assert_operation_prefix(receipt.committed(), suffix, 2)
      assert_eq(receipt.already_applied().length(), 0)
    }
    @oplog.ApplyChangesOutcome::Failed(..) =>
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
test "P2 red apply_remote remains compatible with one-op change application" {
  let source = Document::new("p2-compat-source")
  let remote = try! source.insert(0, "R")
  let legacy = Document::new("p2-compat-legacy")
  let batch = Document::new("p2-compat-batch")
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  legacy.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: None,
    commit_failure: None,
    projection_failure: None,
  })

  try! legacy.apply_remote(remote)
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 1)
  let change = try! batch.apply_changes([remote])
  match change.outcome {
    @oplog.ApplyChangesOutcome::Succeeded(receipt) =>
      p2_assert_operation_prefix(receipt.committed(), [remote], 1)
    @oplog.ApplyChangesOutcome::Failed(..) =>
      fail("one valid operation must complete")
  }
  assert_eq(legacy.to_text(), batch.to_text())
  assert_eq(legacy.get_frontier(), batch.get_frontier())
  assert_eq(legacy.get_all_ops().length(), batch.get_all_ops().length())
}

///|
test "P2 wrapper apply_remote translates partial change application" {
  let doc = Document::new("p2-wrapper-partial")
  let incoming = p2_ready_batch("p2-wrapper-partial-peer", 1)[0]
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: None,
    commit_failure: Some(_ => {
      Some(@causal_graph.CausalGraphError::MissingParent(lv=-204))
    }),
    projection_failure: None,
  })

  let result : Result[Unit, DocumentError] = Ok(doc.apply_remote(incoming)) catch {
    error => Err(error)
  }
  match result {
    Err(
      DocumentError::OpLog(
        @oplog.OpLogError::PartialApplyChanges(committed~, error~),
      ),
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
  doc.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: None,
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
  })

  let result : Result[Unit, DocumentError] = Ok(
    doc.merge_remote(incoming, remote_frontier),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::Fugue(@fugue.FugueError::MissingItem(id~))) =>
      assert_eq(id, @fugue.Lv(997))
    Err(DocumentError::OpLog(@oplog.OpLogError::PartialApplyChanges(..))) =>
      fail("recovery failure must take priority over partial legacy error")
    _ => fail("merge wrapper must expose typed recovery failure")
  }
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 1)
  assert_eq(projection_count, 1)
  assert_eq(doc.oplog.op_count(), 1)
  assert_true(doc.projection_health is ProjectionHealth::Unavailable(_))
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
}

///|
test "P2 red merge_remote keeps closure validation while batch change application accepts incomplete input" {
  let source = Document::new("p2-merge-source")
  ignore(try! source.insert(0, "a"))
  ignore(try! source.insert(1, "b"))
  let remote_ops = source.get_all_ops()
  let remote_frontier = try! source.get_frontier_raw()

  let merged = Document::new("p2-merge-legacy")
  let mut merged_prepare_count = 0
  let mut merged_commit_count = 0
  let mut merged_projection_count = 0
  merged.set_apply_changes_hooks({
    on_action: () => merged_prepare_count = merged_prepare_count + 1,
    on_apply_changes: () => merged_commit_count = merged_commit_count + 1,
    on_projection_finalization: _ => {
      merged_projection_count = merged_projection_count + 1
    },
    action_override: None,
    commit_failure: None,
    projection_failure: None,
  })
  try! merged.merge_remote(remote_ops, remote_frontier)
  assert_eq(merged_prepare_count, 1)
  assert_eq(merged_commit_count, 1)
  assert_eq(merged_projection_count, 1)
  let batched = Document::new("p2-merge-batch")
  ignore(try! batched.apply_changes(remote_ops))
  assert_eq(merged.to_text(), batched.to_text())
  assert_eq(merged.get_frontier(), batched.get_frontier())

  let incomplete = Document::new("p2-merge-incomplete")
  let second_only = [remote_ops[1]]
  let mut invalid_prepare_count = 0
  let mut invalid_commit_count = 0
  let mut invalid_projection_count = 0
  incomplete.set_apply_changes_hooks({
    on_action: () => invalid_prepare_count = invalid_prepare_count + 1,
    on_apply_changes: () => invalid_commit_count = invalid_commit_count + 1,
    on_projection_finalization: _ => {
      invalid_projection_count = invalid_projection_count + 1
    },
    action_override: None,
    commit_failure: None,
    projection_failure: None,
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

  let pending = try! incomplete.apply_changes(second_only)
  match pending.outcome {
    @oplog.ApplyChangesOutcome::Succeeded(receipt) => {
      assert_eq(receipt.committed().length(), 0)
      p2_assert_identity_prefix(
        receipt.pending_from_transition(),
        second_only,
        1,
      )
    }
    @oplog.ApplyChangesOutcome::Failed(..) =>
      fail("incomplete batch should be pending, not partial")
  }
  match pending.publication {
    Exact(edits) if edits.is_empty() => ()
    _ => fail("pending incomplete batch must skip projection")
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
test "P2 red remote complete change application resets cursor before local insert" {
  let source = Document::new("p2-cursor-complete-source")
  let remote = try! source.insert(0, "R")
  let doc = Document::new("p2-cursor-complete")
  ignore(try! doc.insert(0, "a"))
  ignore(try! doc.apply_changes([remote]))
  ignore(try! doc.insert(doc.visible_count(), "l"))
  p2_assert_fresh_cursor_convergence(doc)
}

///|
test "P2 red partial change application resets cursor before local insert" {
  let doc = Document::new("p2-cursor-partial")
  ignore(try! doc.insert(0, "a"))
  let incoming = p2_ready_batch("p2-cursor-partial-peer", 2)
  doc.set_apply_changes_hooks({
    on_action: () => (),
    on_apply_changes: () => (),
    on_projection_finalization: _ => (),
    action_override: None,
    commit_failure: Some(op => {
      if op.seq() == 1 {
        Some(@causal_graph.CausalGraphError::MissingParent(lv=-203))
      } else {
        None
      }
    }),
    projection_failure: None,
  })
  let change = try! doc.apply_changes(incoming)
  match change.outcome {
    @oplog.ApplyChangesOutcome::Failed(..) => ()
    @oplog.ApplyChangesOutcome::Succeeded(_) =>
      fail("expected partial cursor fixture")
  }
  ignore(try! doc.insert(doc.visible_count(), "l"))
  p2_assert_fresh_cursor_convergence(doc)
}

///|
test "explicit reopening after projection failure resets cursor before local insert" {
  let doc = Document::new("p2-cursor-recovery")
  ignore(try! doc.insert(0, "a"))
  let incoming = p2_ready_batch("p2-cursor-recovery-peer", 1)
  doc.set_apply_changes_hooks({
    on_action: () => (),
    on_apply_changes: () => (),
    on_projection_finalization: _ => (),
    action_override: None,
    commit_failure: None,
    projection_failure: Some(_ => {
      Some(
        DocumentError::Fugue(@fugue.FugueError::MissingItem(id=@fugue.Lv(998))),
      )
    }),
  })
  let change = try! doc.apply_changes(incoming)
  match change.publication {
    Unavailable(_) => ()
    _ => fail("expected unavailable projection")
  }
  assert_true(change.publication is Unavailable(_))
  doc.integrate_projection()
  ignore(try! doc.insert(doc.visible_count(), "l"))
  p2_assert_fresh_cursor_convergence(doc)
}

///|
test "duplicate-only change application stays blocked until explicit reopening" {
  let doc = Document::new("p2-entry-duplicate")
  let incoming = p2_ready_batch("p2-entry-duplicate-peer", 1)
  let mut projection_failure = true
  let mut prepare_count = 0
  let mut commit_count = 0
  let mut projection_count = 0
  doc.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: None,
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
  })

  let first = try! doc.apply_changes(incoming)
  match first.publication {
    Unavailable(_) => ()
    _ => fail("fixture must leave entry recovery required")
  }
  projection_failure = false
  projection_count = 0
  let blocked = Ok(doc.apply_changes(incoming)) catch { error => Err(error) }
  assert_true(blocked is Err(DocumentError::Fugue(_)))
  doc.integrate_projection()
  let change = try! doc.apply_changes(incoming)
  assert_eq(prepare_count, 2)
  assert_eq(commit_count, 2)
  assert_eq(projection_count, 0)
  match change.outcome {
    @oplog.ApplyChangesOutcome::Succeeded(receipt) =>
      assert_eq(receipt.committed().length(), 0)
    @oplog.ApplyChangesOutcome::Failed(..) =>
      fail("duplicate-only change application must be complete")
  }
  match change.publication {
    Exact(edits) if edits.is_empty() => ()
    _ =>
      fail(
        "duplicate-only change application after reopening must publish exact empty edits",
      )
  }
  assert_true(change.publication is Exact(_))
  assert_true(doc.projection_health is ProjectionHealth::Ready)
}

///|
test "projected change application stays blocked until explicit reopening" {
  let doc = Document::new("p2-entry-projected")
  let seed = p2_ready_batch("p2-entry-projected-seed", 1)
  let incoming = p2_ready_batch("p2-entry-projected-peer", 1)
  let mut projection_failure = true
  let mut projection_count = 0
  doc.set_apply_changes_hooks({
    on_action: () => (),
    on_apply_changes: () => (),
    on_projection_finalization: _ => projection_count = projection_count + 1,
    action_override: None,
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
  })

  let first = try! doc.apply_changes(seed)
  match first.publication {
    Unavailable(_) => ()
    _ => fail("fixture must leave entry recovery required")
  }
  projection_failure = false
  projection_count = 0
  let blocked = Ok(doc.apply_changes(incoming)) catch { error => Err(error) }
  assert_true(blocked is Err(DocumentError::Fugue(_)))
  doc.integrate_projection()
  let change = try! doc.apply_changes(incoming)
  assert_eq(projection_count, 1)
  match change.outcome {
    @oplog.ApplyChangesOutcome::Succeeded(receipt) =>
      p2_assert_operation_prefix(receipt.committed(), incoming, 1)
    @oplog.ApplyChangesOutcome::Failed(..) =>
      fail("complete change application must not be partial")
  }
  match change.publication {
    Exact(_) => ()
    _ => fail("change application after reopening must publish exact edits")
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
  let mut prepare_count = 0
  let mut commit_count = 0
  doc.set_apply_changes_hooks({
    on_action: () => prepare_count = prepare_count + 1,
    on_apply_changes: () => commit_count = commit_count + 1,
    on_projection_finalization: _ => (),
    action_override: None,
    commit_failure: None,
    projection_failure: None,
  })

  let result : Result[DocumentChanges, DocumentError] = Ok(
    doc.apply_changes([unready]),
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
  assert_eq(prepare_count, 1)
  assert_eq(commit_count, 0)
  assert_true(!doc.oplog.has_pending())
  assert_eq(doc.get_frontier(), before_frontier)
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  assert_true(doc.projection_health is ProjectionHealth::Unavailable(_))
  let mutation : Result[Unit, DocumentError] = Ok(doc.prepare_for_mutation()) catch {
    error => Err(error)
  }
  match mutation {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("unresolved divergence must keep later mutations fail-closed")
  }
  assert_true(doc.projection_health is ProjectionHealth::Unavailable(_))
  try! doc.integrate_projection()
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  let fresh = try! @branch.Branch::checkout(doc.oplog, before_frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}

///|
test "P2 red divergence is repaired before invalid change application rejection" {
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
  let result : Result[Unit, DocumentError] = Ok(
    doc.ensure_apply_changes_targets([invalid_noninsert, invalid_dependent], [
      incoming,
    ]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::MissingOrigin(raw~)) =>
      assert_eq(raw, invalid_noninsert_raw)
    _ => fail("invalid change application must remain the returned error")
  }
  assert_eq(doc.get_frontier(), before_frontier)
  p2_assert_same_operations(doc.get_all_ops(), before_ops)
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  assert_eq(doc.tree.to_text(), "")
  doc.integrate_projection()
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
  let partial_tree : @fugue.FugueTree[String] = @fugue.FugueTree::new()
  try! apply_projection(partial_tree, first, doc.oplog.causal_graph())
  let result : Result[DocumentChanges, DocumentError] = Ok(
    doc.apply_changes([incoming]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("initial incomplete recovery must remain fail-closed")
  }
  doc.replace_projection_tree(partial_tree)
  let second_retry : Result[Unit, DocumentError] = Ok(
    doc.prepare_for_mutation(),
  ) catch {
    error => Err(error)
  }
  match second_retry {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("one-target recovery must not hide the second divergence")
  }
  assert_true(doc.projection_health is ProjectionHealth::Unavailable(_))
  try! doc.integrate_projection()
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
  let result : Result[DocumentChanges, DocumentError] = Ok(
    doc.apply_changes([incoming]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("checkout failure must preserve recovery-required state")
  }
  let failed_reopen = Ok(
    doc.recover_projection_with((_, _) => {
      raise @branch.BranchError::MissingOp(lv=777)
    }),
  ) catch {
    error => Err(error)
  }
  assert_true(
    failed_reopen is Err(DocumentError::ProjectionRecoveryRequired(..)),
  )
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
  assert_eq(doc.get_frontier(), before_frontier)
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  assert_true(doc.projection_health is ProjectionHealth::Unavailable(_))
  try! doc.integrate_projection()
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
  ignore(try! doc.apply_changes([first_input, second_input]))
  ignore(doc.to_text())
  let applied = doc.get_all_ops()
  let first = applied[0]
  let second = applied[1]
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
  let initial_result : Result[DocumentChanges, DocumentError] = Ok(
    doc.apply_changes([incoming]),
  ) catch {
    error => Err(error)
  }
  match initial_result {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("initial swapped recovery must remain fail-closed")
  }
  doc.replace_projection_tree(partial_tree)
  assert_true(doc.projection_health is ProjectionHealth::Unavailable(_))
  let second_retry : Result[Unit, DocumentError] = Ok(
    doc.prepare_for_mutation(),
  ) catch {
    error => Err(error)
  }
  match second_retry {
    Err(DocumentError::ProjectionRecoveryRequired(..)) => ()
    _ => fail("present origin must remain part of recovery verification")
  }
  assert_eq(doc.get_frontier(), before_frontier)
  assert_true(!doc.indexed_state.is_ready())
  assert_true(doc.cursor is None)
  assert_true(doc.projection_health is ProjectionHealth::Unavailable(_))
  try! doc.integrate_projection()
  assert_true(doc.projection_health is ProjectionHealth::Ready)
  let fresh = try! @branch.Branch::checkout(doc.oplog, before_frontier)
  assert_eq(doc.tree.to_text(), fresh.to_text())
  assert_eq(doc.get_frontier(), fresh.get_frontier())
}
