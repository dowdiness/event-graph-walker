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
/// Fresh right-child chains defer locator splices while their sequential ranks
/// are known from the insertion run. Flush before branching or visibility changes.
/// Consecutive visible insertions are written to the OrderTree once.
/// Adjacent deletions advance locator weights immediately but remove their
/// whole visible interval from the OrderTree together, in either direction.
/// Effects retain their original sequential, one-visibility-change granularity.
fn ProjectionWorkspace::project_all(
  self : ProjectionWorkspace,
  tree : @fugue.FugueTree[String],
  operations : ArrayView[@core.Op],
  causal_graph : @causal_graph.CausalGraph,
  changes : TextChangeCollector?,
) -> Unit raise DocumentError {
  let (indexed, effects) = match self.candidate {
    Exact(indexed, effects) => (indexed, effects)
    SnapshotRequired => {
      match changes {
        Some(changes) => changes.valid = false
        None => ()
      }
      for operation in operations {
        apply_projection(tree, operation, causal_graph)
      }
      return
    }
  }
  let mut pending : ProjectionInsertRun? = None
  let mut deleted : (Int, Int)? = None
  for operation in operations {
    if self.candidate is SnapshotRequired {
      apply_projection(tree, operation, causal_graph)
      continue
    }
    // Visibility operations mutate the buffered Fugue items themselves.
    // Publish the insertion while those items still have their original state.
    if !(operation.content() is @core.Insert(_)) {
      match pending {
        Some(run) => {
          indexed.flush_projection_run(run)
          pending = None
        }
        None => ()
      }
    }
    let change = apply_projection_with_visible_change(
      tree, operation, causal_graph,
    )
    if @fugue_projection.is_became_hidden(change) {
      let lv = @fugue_projection.visibility_identity(change)
      match indexed.lv_to_position(tree, lv.0) {
        Some(position) => {
          match changes {
            Some(changes) =>
              changes.delete(
                indexed.utf16_at(position),
                indexed.utf16_at(position + 1),
              )
            None => ()
          }
          let next_deleted = match deleted {
            Some((start, end)) if position == start => Some((start, end + 1))
            Some((start, end)) if position + 1 == start => Some((position, end))
            _ => {
              if !indexed.flush_projection_deletes(deleted) {
                self.candidate = SnapshotRequired
                continue
              }
              Some((position, position + 1))
            }
          }
          if indexed.locator.unwrap().hide(lv.0) {
            deleted = next_deleted
            effects.push(Delete(start=position, end=position + 1))
          } else {
            self.candidate = SnapshotRequired
          }
        }
        None => self.candidate = SnapshotRequired
      }
    } else if @fugue_projection.is_became_visible(change) {
      if !indexed.flush_projection_deletes(deleted) {
        self.candidate = SnapshotRequired
        continue
      }
      deleted = None
      let lv = @fugue_projection.visibility_identity(change)
      let item = tree.get(lv)
      let fresh = !indexed.locator.unwrap().contains(lv.0)
      match (pending, item) {
        (Some(run), Some(item)) if run.can_chain &&
          fresh &&
          !run.text.is_empty() &&
          !item.content.is_empty() &&
          lv.0 == run.start_lv + run.count &&
          item.parent == Some(@fugue.Lv(lv.0 - 1)) &&
          item.side is @fugue.Right => {
          let position = run.position + run.count
          match changes {
            Some(changes) => changes.insert(run.utf16_end, item.content)
            None => ()
          }
          run.chain.push(item)
          run.text.write_string(item.content)
          run.count += 1
          run.utf16_end += item.content.length()
          effects.push(Insert(position~, text=item.content))
          continue
        }
        _ => ()
      }
      match pending {
        Some(run) => {
          indexed.locator.unwrap().add_right_chain(run.chain)
          run.chain.clear()
        }
        None => ()
      }
      match (tree.get(lv), indexed.locate_visible(tree, lv.0)) {
        (Some(item), Some(position)) => {
          let utf16_position = match changes {
            Some(changes) => {
              let offset = match pending {
                Some(run) if run.position + run.count == position =>
                  run.utf16_end
                _ => indexed.utf16_at(position)
              }
              changes.insert(offset, item.content)
              offset
            }
            None => 0
          }
          match pending {
            Some(run) if !run.text.is_empty() &&
              !item.content.is_empty() &&
              run.position + run.count == position &&
              run.start_lv + run.count == lv.0 => {
              run.text.write_string(item.content)
              run.count = run.count + 1
              run.utf16_end = utf16_position + item.content.length()
              run.can_chain = fresh
            }
            _ => {
              match pending {
                Some(run) => indexed.flush_projection_run(run)
                None => ()
              }
              let text = StringBuilder()
              text.write_string(item.content)
              pending = Some({
                position,
                start_lv: lv.0,
                count: 1,
                text,
                utf16_end: utf16_position + item.content.length(),
                can_chain: fresh,
                chain: [],
              })
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
    if !indexed.flush_projection_deletes(deleted) {
      self.candidate = SnapshotRequired
    }
  }
  if self.candidate is SnapshotRequired {
    match changes {
      Some(changes) => changes.valid = false
      None => ()
    }
  }
}

///|
priv struct ProjectionInsertRun {
  position : Int32
  start_lv : Int32
  mut count : Int32
  text : StringBuilder
  mut utf16_end : Int
  mut can_chain : Bool
  chain : Array[@fugue.Item[String]]
}

///|
/// Locator visibility already reflects these sequential deletions. The cache
/// still has the original interval until this publication-local buffer flushes.
fn IndexedState::flush_projection_deletes(
  self : IndexedState,
  deleted : (Int, Int)?,
) -> Bool {
  match deleted {
    None => true
    Some((start, end)) => {
      let cache = self.cache.unwrap()
      let before = cache.span()
      cache.delete_range(start, end)
      cache.span() == before - (end - start)
    }
  }
}

///|
fn IndexedState::flush_projection_run(
  self : IndexedState,
  run : ProjectionInsertRun,
) -> Unit {
  self.locator.unwrap().add_right_chain(run.chain)
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
