///| P3 red tests for the projection-independent core pending adapters.

///|
test "P3 empty clear is a planner no-op" {
  let doc = Document::new("p3-clear-empty")
  let prepared = try! doc.oplog.prepare_remote([])

  assert_eq(doc.pending_count(), 0)
  doc.clear_pending()

  assert_eq(doc.pending_count(), 0)
  ignore(try! doc.oplog.commit_admission(prepared))
}

///|
test "P3 clear removes pending membership and stales prepared admissions" {
  let doc = Document::new("p3-clear-non-empty")
  let pending = p2_pending_batch("p3-clear-peer")
  let admission = try! doc.admit_remote(pending)
  match admission.outcome {
    @oplog.AdmissionOutcome::Complete(receipt) => {
      assert_eq(receipt.committed().length(), 0)
      assert_eq(receipt.pending_after_count(), 1)
    }
    @oplog.AdmissionOutcome::Partial(..) =>
      fail("pending-only seed must be complete")
  }
  assert_eq(doc.pending_count(), 1)

  let before = try! p2_snapshot_document(doc)
  let prepared = try! doc.oplog.prepare_remote([pending[0]])

  doc.clear_pending()

  assert_eq(doc.pending_count(), 0)
  assert_true(!doc.oplog.has_pending())
  assert_eq(doc.get_frontier(), before.frontier)
  p2_assert_same_operations(doc.get_all_ops(), before.ops)
  assert_eq(doc.tree.to_text(), before.tree_text)
  p2_assert_same_tree_items(p2_tree_snapshot(doc), before.tree_items)
  p2_assert_cache_snapshot(try! p2_cache_snapshot(doc), before.cache)
  assert_true(doc.cursor is None)

  try doc.oplog.commit_admission(prepared) catch {
    @oplog.OpLogError::StaleAdmission => ()
    _ => fail("clear must stale a prepared admission")
  } noraise {
    _ => fail("cleared prepared admission must not commit")
  }
}

///|
test "P3 cleared pending operation does not revive when dependency arrives" {
  let doc = Document::new("p3-clear-no-revival")
  let pending = p2_pending_batch("p3-clear-no-revival-peer")
  ignore(try! doc.admit_remote(pending))
  assert_eq(doc.pending_count(), 1)
  doc.clear_pending()

  let dependency = p2_remote_insert(
    "p3-clear-no-revival-peer-missing",
    0,
    [],
    None,
  )
  ignore(try! doc.admit_remote([dependency]))

  assert_eq(doc.pending_count(), 0)
  assert_eq(doc.get_all_ops().length(), 1)
  assert_eq(doc.get_all_ops()[0].agent(), dependency.agent())
  assert_eq(doc.get_all_ops()[0].seq(), dependency.seq())
}

///|
test "P3 clear remains projection-independent during recovery required" {
  let doc = Document::new("p3-clear-recovery-required")
  let pending = p2_pending_batch("p3-clear-recovery-required-pending")
  ignore(try! doc.admit_remote(pending))
  assert_eq(doc.pending_count(), 1)

  ignore(try! doc.insert(0, "base"))
  ignore(doc.to_text())
  let incoming = p2_ready_batch("p3-clear-recovery-required-peer", 2)
  let mut recovery_calls = 0
  doc.set_admission_hooks({
    on_prepare_remote: () => (),
    on_commit_admission: () => (),
    on_projection_finalization: _ => (),
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
  match admission.projection {
    ProjectionStatus::RecoveryRequired(..) => ()
    ProjectionStatus::Skipped
    | ProjectionStatus::Projected
    | ProjectionStatus::Recovered =>
      fail("seeded projection failure must require recovery")
  }
  assert_true(recovery_calls >= 1)
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
  let frontier_before = doc.get_frontier()
  let tree_before = doc.tree.to_text()
  let cache_ready_before = doc.indexed_state.is_ready()

  doc.clear_pending()

  assert_eq(doc.pending_count(), 0)
  assert_eq(doc.get_frontier(), frontier_before)
  assert_eq(doc.tree.to_text(), tree_before)
  assert_eq(doc.indexed_state.is_ready(), cache_ready_before)
  assert_true(doc.projection_health is ProjectionHealth::RecoveryRequired(_))
}
