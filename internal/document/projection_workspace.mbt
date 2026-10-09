///|
/// Exact index and effects are published together; snapshot fallback owns neither.
priv enum ProjectionCandidate {
  Exact(IndexedState, Array[ProjectionEffect])
  SnapshotRequired
}

///|
priv struct ProjectionWorkspace {
  mut candidate : ProjectionCandidate
}

///|
fn ProjectionWorkspace::ProjectionWorkspace(
  snapshot : (@order_tree.OrderTree[VisibleRun]?, LvLocator?),
) -> ProjectionWorkspace {
  let candidate = match snapshot {
    (Some(_), Some(_)) =>
      ProjectionCandidate::Exact(IndexedState::from_snapshot(snapshot), [])
    _ => ProjectionCandidate::SnapshotRequired
  }
  { candidate, }
}

///|
/// Apply a complete committed prefix without changing its change application boundary.
/// Topology ranks advance for every operation. Consecutive visible insertions
/// are accumulated with a linear builder and written to the OrderTree once.
/// Effects retain their original sequential, one-visibility-change granularity.
fn ProjectionWorkspace::project_all(
  self : ProjectionWorkspace,
  tree : @fugue.FugueTree[String],
  operations : ArrayView[@core.Op],
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise DocumentError {
  let (indexed, effects) = match self.candidate {
    Exact(indexed, effects) => (indexed, effects)
    SnapshotRequired => {
      for operation in operations {
        apply_projection(tree, operation, causal_graph)
      }
      return
    }
  }
  let mut pending : ProjectionInsertRun? = None
  for operation in operations {
    if self.candidate is SnapshotRequired {
      apply_projection(tree, operation, causal_graph)
      continue
    }
    let change = apply_projection_with_visible_change(
      tree, operation, causal_graph,
    )
    if @fugue_projection.is_became_hidden(change) {
      match pending {
        Some(run) => {
          indexed.flush_projection_run(run)
          pending = None
        }
        None => ()
      }
      let lv = @fugue_projection.visibility_identity(change)
      match indexed.lv_to_position(tree, lv.0) {
        Some(position) =>
          if indexed.delete_at(position) {
            effects.push(Delete(start=position, end=position + 1))
          } else {
            self.candidate = SnapshotRequired
          }
        None => self.candidate = SnapshotRequired
      }
    } else if @fugue_projection.is_became_visible(change) {
      let lv = @fugue_projection.visibility_identity(change)
      match (tree.get(lv), indexed.locate_visible(tree, lv.0)) {
        (Some(item), Some(position)) => {
          match pending {
            Some(run) if !run.text.is_empty() &&
              !item.content.is_empty() &&
              run.position + run.count == position &&
              run.start_lv + run.count == lv.0 => {
              run.text.write_string(item.content)
              run.count = run.count + 1
            }
            _ => {
              match pending {
                Some(run) => indexed.flush_projection_run(run)
                None => ()
              }
              let text = StringBuilder()
              text.write_string(item.content)
              pending = Some({ position, start_lv: lv.0, count: 1, text, })
            }
          }
          effects.push(Insert(position~, text=item.content))
        }
        _ => {
          self.candidate = SnapshotRequired
          pending = None
        }
      }
    }
  }
  if self.candidate is Exact(_, _) {
    match pending {
      Some(run) => indexed.flush_projection_run(run)
      None => ()
    }
  }
}

///|
priv struct ProjectionInsertRun {
  position : Int
  start_lv : Int
  mut count : Int
  text : StringBuilder
}

///|
fn IndexedState::flush_projection_run(
  self : IndexedState,
  run : ProjectionInsertRun,
) -> Unit {
  match self.cache {
    Some(cache) =>
      cache.insert_at(run.position, {
        start_lv: run.start_lv,
        text: run.text.to_string(),
        count: run.count,
      })
    None => ()
  }
}

///|
/// Own commit-time cache detachment, projection publication, and recovery.
/// A committed authority prefix is never rolled back after projection failure.
fn ProjectionWorkspace::commit_and_project(
  doc : Document,
  action : @oplog.ApplyChanges,
  recovered : Bool,
) -> DocumentChanges raise DocumentError {
  let detached = doc.indexed_state.take_cache()
  doc.observe_apply_changes()
  let outcome = doc.apply_changes_for_document(action) catch {
    error => {
      doc.indexed_state.restore_cache(detached)
      raise DocumentError::OpLog(error)
    }
  }
  let report = match outcome {
    Succeeded(report) => report
    Failed(report~, ..) => report
  }
  let committed = report.committed()
  if committed.is_empty() {
    doc.indexed_state.restore_cache(detached)
    doc.cursor = None
    let effects : Array[ProjectionEffect] = []
    let (status, availability) = if recovered {
      (
        ProjectionStatus::Recovered,
        ProjectionEffectAvailability::SnapshotRequired,
      )
    } else {
      (
        ProjectionStatus::Skipped,
        ProjectionEffectAvailability::Exact(effects[:]),
      )
    }
    return DocumentChanges::DocumentChanges(
      outcome, status, effects, availability,
    )
  }
  // Authority has advanced: the old derived state must never become readable.
  doc.invalidate_cache()
  doc.cursor = None
  let workspace = ProjectionWorkspace(detached)
  try doc.project_remote_ops(committed, workspace) catch {
    _ => {
      doc.invalidate_cache()
      doc.cursor = None
      let (status, availability) = try
        doc.recover_projection_for_apply_changes(report.frontier_after())
      catch {
        DocumentError::ProjectionRecoveryRequired(error~, ..) =>
          (
            ProjectionStatus::RecoveryRequired(error~),
            ProjectionEffectAvailability::Unavailable,
          )
        error => raise error
      } noraise {
        _ =>
          (
            ProjectionStatus::Recovered,
            ProjectionEffectAvailability::SnapshotRequired,
          )
      }
      DocumentChanges::DocumentChanges(outcome, status, [], availability)
    }
  } noraise {
    _ => {
      let status = if recovered {
        ProjectionStatus::Recovered
      } else {
        ProjectionStatus::Projected
      }
      let (effects, availability) = match workspace.candidate {
        Exact(indexed, effects) => {
          doc.indexed_state.restore_cache(indexed.take_cache())
          let availability = if recovered {
            ProjectionEffectAvailability::SnapshotRequired
          } else {
            ProjectionEffectAvailability::Exact(effects[:])
          }
          (effects, availability)
        }
        SnapshotRequired => ([], ProjectionEffectAvailability::SnapshotRequired)
      }
      DocumentChanges::DocumentChanges(outcome, status, effects, availability)
    }
  }
}
