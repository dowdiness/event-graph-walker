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
  operation_count : Int,
) -> ProjectionWorkspace {
  let candidate = match snapshot {
    (Some(_), Some(_)) if operation_count <= 3 =>
      ProjectionCandidate::Exact(IndexedState::from_snapshot(snapshot), [])
    _ => ProjectionCandidate::SnapshotRequired
  }
  { candidate, }
}

///|
/// Apply one committed operation. Losing exactness drops the whole candidate;
/// an invalid index and stale effects cannot survive as independent fields.
fn ProjectionWorkspace::project(
  self : ProjectionWorkspace,
  tree : @fugue.FugueTree[String],
  operation : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise DocumentError {
  let (indexed, effects) = match self.candidate {
    Exact(indexed, effects) => (indexed, effects)
    SnapshotRequired => {
      apply_projection(tree, operation, causal_graph)
      return
    }
  }
  let change = apply_projection_with_visible_change(
    tree, operation, causal_graph,
  )
  if @fugue_projection.is_became_hidden(change) {
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
    match tree.get(lv) {
      Some(item) =>
        match
          indexed.insert_visible(tree, lv.0, {
            start_lv: lv.0,
            text: item.content,
            count: 1,
          }) {
          Some(position) => effects.push(Insert(position~, text=item.content))
          None => self.candidate = SnapshotRequired
        }
      None => self.candidate = SnapshotRequired
    }
  }
}

///|
/// Own commit-time cache detachment, projection publication, and recovery.
/// A committed authority prefix is never rolled back after projection failure.
fn ProjectionWorkspace::commit_and_project(
  doc : Document,
  prepared : @oplog.PreparedAdmission,
  recovered : Bool,
) -> DocumentAdmission raise DocumentError {
  let detached = doc.indexed_state.take_cache()
  doc.observe_commit_admission()
  let outcome = doc.commit_admission_for_document(prepared) catch {
    error => {
      doc.indexed_state.restore_cache(detached)
      raise DocumentError::OpLog(error)
    }
  }
  let receipt = match outcome {
    Complete(receipt) => receipt
    Partial(receipt~, ..) => receipt
  }
  let committed = receipt.committed()
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
    return DocumentAdmission::DocumentAdmission(
      outcome, status, effects, availability,
    )
  }
  // Authority has advanced: the old derived state must never become readable.
  doc.invalidate_cache()
  doc.cursor = None
  let workspace = ProjectionWorkspace(detached, committed.length())
  try doc.project_remote_ops(committed, workspace) catch {
    _ => {
      doc.invalidate_cache()
      doc.cursor = None
      let (status, availability) = try
        doc.recover_projection_for_admission(receipt.frontier_after())
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
      DocumentAdmission::DocumentAdmission(outcome, status, [], availability)
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
      DocumentAdmission::DocumentAdmission(
        outcome, status, effects, availability,
      )
    }
  }
}
