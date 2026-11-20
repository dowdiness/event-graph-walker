///| Editing session: one document, one local undo history, one change stream.
/// No independently maintained text mirror or position index lives here.

///|
pub(all) struct Utf16Edit {
  start : Int32
  end : Int32
  text : String
}

///|
pub struct TextSnapshot {
  version : Version
  text : String
}

///|
/// Apply edits in order to the text at `before`, then advance to `after`.
pub struct TextUpdate {
  before : Version
  after : Version
  before_len : Int32
  origin : UpdateOrigin
  sync_report : SyncReport?
  priv changes : Array[Utf16Edit]
  priv mut composed : ChangeSet?
}

///|
pub fn TextUpdate::edits(self : TextUpdate) -> ArrayView[Utf16Edit] {
  self.changes[:]
}

///|
/// Derived lazily from the applied sequential edits, never from a snapshot diff.
pub fn TextUpdate::change_set(self : TextUpdate) -> ChangeSet {
  if self.composed is Some(changes) {
    return changes
  }
  // A nonoverlapping right-to-left sequence already uses base coordinates.
  // Checking starts alone is insufficient: a later range may overlap an
  // earlier replacement. Derive only from the actual edits, regardless of origin.
  let mut boundary = self.before_len
  let mut descending = true
  for edit in self.changes {
    if edit.end > boundary {
      descending = false
      break
    }
    boundary = edit.start
  }
  if descending {
    let sections : Array[ChangeSection] = []
    let mut position = 0
    for i = self.changes.length() - 1; i >= 0; i = i - 1 {
      let edit = self.changes[i]
      sections.push(Keep(edit.start - position))
      sections.push(Replace(edit.end - edit.start, edit.text))
      position = edit.end
    }
    sections.push(Keep(self.before_len - position))
    let changes = try! normalize_sections(sections[:], validate_text=false)
    self.composed = Some(changes)
    return changes
  }
  let mut changes = try! ChangeSet::new([Keep(self.before_len)])
  for edit in self.changes {
    let step = try! ChangeSet::new([
      Keep(edit.start),
      Replace(edit.end - edit.start, edit.text),
      Keep(changes.new_length() - edit.end),
    ])
    changes = try! changes.compose(step)
  }
  self.composed = Some(changes)
  changes
}

///|
#derive(Eq, Debug)
pub(all) enum UpdateOrigin {
  Local(String?)
  Remote
  Undo
  Redo
}

///|
#derive(Eq, Debug)
pub(all) enum UndoPolicy {
  NewGroup
  JoinPrevious
  NoHistory
}

///|
pub(all) suberror EditError {
  ReversedRange
  InvalidText
  InvalidChange(ChangeError)
  StaleVersion
  Unavailable
  Engine(TextError)
  Undo(@undo.UndoError)
}

///|
/// Rejected requests leave visible text and causal version unchanged.
/// Invalidated means the caller
/// must stop using its projection AND this session; history may have advanced.
/// Recovery/reopening is an explicit application action, never a read fallback.
pub(all) enum Edit {
  Applied(TextUpdate)
  Rejected(EditError)
  Invalidated(EditError)
}

///|
pub struct Editor {
  priv state : TextState
  priv undo_history : @undo.UndoManager
  priv mut available : Bool
  priv mut can_join : Bool
}

///|
pub fn Editor::new(writer : String) -> Editor raise TextError {
  let state = TextState::new(writer)
  {
    state,
    undo_history: @undo.UndoManager::new(writer),
    available: true,
    can_join: false,
  }
}

///|
pub fn Editor::snapshot(self : Editor) -> TextSnapshot raise EditError {
  if !self.available {
    raise Unavailable
  }
  let text = self.state.text() catch { error => raise Engine(error) }
  { version: self.version(), text, }
}

///|
/// The displayed editing cut, not necessarily all accepted history.
pub fn Editor::version(self : Editor) -> Version {
  Version::from_graph_version(self.state.inner.view_graph_version())
}

///|
pub fn Editor::history_version(self : Editor) -> Version {
  self.state.version()
}

///|
pub fn Editor::can_undo(self : Editor) -> Bool {
  self.available && self.undo_history.can_undo()
}

///|
pub fn Editor::can_redo(self : Editor) -> Bool {
  self.available && self.undo_history.can_redo()
}

///|
/// Export remains available after invalidation: causal history is authoritative
/// even when the materialized document can no longer be published.
pub fn Editor::export_since(
  self : Editor,
  version : Version,
) -> SyncMessage raise TextError {
  self.state.sync().export_since(version)
}

///|
fn Editor::reset_session(self : Editor, available : Bool) -> Unit {
  self.undo_history.clear()
  self.can_join = false
  self.available = available
}

///|
fn Editor::invalidate_session(self : Editor, error : EditError) -> Edit {
  self.reset_session(false)
  Invalidated(error)
}

///|
fn Editor::change(
  self : Editor,
  origin : UpdateOrigin,
  action : (Int32) -> SyncReport? raise EditError,
) -> Edit {
  if !self.available {
    return Invalidated(Unavailable)
  }
  let before = self.version()
  let before_len = try {
    let length = self.state.inner.utf16_len()
    self.state.inner.begin_text_change()
    length
  } catch {
    error =>
      return self.invalidate_session(
        Engine(TextError::from_document_error(error, () => self.state.len())),
      )
  }
  let result = Ok(action(before_len)) catch { error => Err(error) }
  let changes = self.state.inner.finish_text_change()
  let after = self.version()
  match (changes, result) {
    (Some(changes), Ok(sync_report)) => {
      if origin is Remote && !changes.is_empty() {
        self.can_join = false
      }
      Applied({
        before,
        after,
        before_len,
        origin,
        sync_report,
        composed: None,
        changes: changes.map(edit => {
          start: edit.start,
          end: edit.end,
          text: edit.text,
        }),
      })
    }
    _ => {
      let error = match result {
        Ok(_) => EditError::Unavailable
        Err(error) => error
      }
      self.invalidate_session(error)
    }
  }
}

///|
/// Single-replacement convenience API. The default is a new undo group.
pub fn Editor::edit(
  self : Editor,
  expected : Version,
  edit : Utf16Edit,
  undo~ : UndoPolicy = NewGroup,
  label? : String,
) -> Edit {
  self.edit_with(
    expected,
    length => {
      if edit.end < edit.start {
        return Err(Rejected(ReversedRange))
      }
      if !is_well_formed_utf16(edit.text) {
        return Err(Rejected(InvalidText))
      }
      if edit.start < 0 || edit.start > length {
        return Err(Rejected(InvalidChange(InvalidBoundary(offset=edit.start))))
      }
      if edit.end > length {
        return Err(Rejected(InvalidChange(InvalidBoundary(offset=edit.end))))
      }
      // Normalization removes empty replacements, but the single-edit API still
      // validates their supplied coordinate before discarding them.
      if edit.start == edit.end && edit.text == "" {
        let boundary = self.state.inner.scalar_at_utf16(edit.start) catch {
          error =>
            return Err(
              self.invalidate_session(
                Engine(
                  TextError::from_document_error(error, () => self.state.len()),
                ),
              ),
            )
        }
        if boundary is None {
          return Err(
            Rejected(InvalidChange(InvalidBoundary(offset=edit.start))),
          )
        }
      }
      let changes = ChangeSet::new([
        Keep(edit.start),
        Replace(edit.end - edit.start, edit.text),
        Keep(length - edit.end),
      ]) catch {
        error => return Err(Rejected(InvalidChange(error)))
      }
      Ok(changes)
    },
    undo,
    label,
  )
}

///|
/// Validate every base-coordinate replacement before applying any of them.
/// Rejected leaves history unchanged; internal failures invalidate the session.
pub fn Editor::edit_many(
  self : Editor,
  base : Version,
  changes : ChangeSet,
  undo~ : UndoPolicy = NewGroup,
  label? : String,
) -> Edit {
  self.edit_with(base, _ => Ok(changes), undo, label)
}

///|
fn Editor::edit_with(
  self : Editor,
  expected : Version,
  build : (Int32) -> Result[ChangeSet, Edit],
  undo : UndoPolicy,
  label : String?,
) -> Edit {
  if !self.available {
    return Invalidated(Unavailable)
  }
  if expected != self.version() {
    return Rejected(StaleVersion)
  }
  let plans : Array[(Int32, Int32, String)] = []
  try {
    let length = self.state.inner.utf16_len()
    let changes = match build(length) {
      Ok(changes) => changes
      Err(outcome) => return outcome
    }
    if changes.length() != length {
      return Rejected(InvalidChange(LengthMismatch))
    }
    let mut position = 0
    for section in changes.sections() {
      match section {
        Keep(n) => position += n
        Replace(n, text) => {
          let start = self.state.inner.scalar_at_utf16(position)
          let end = self.state.inner.scalar_at_utf16(position + n)
          guard start is Some(start) else {
            return Rejected(InvalidChange(InvalidBoundary(offset=position)))
          }
          guard end is Some(end) else {
            return Rejected(InvalidChange(InvalidBoundary(offset=position + n)))
          }
          plans.push((start, end, text))
          position += n
        }
      }
    }
  } catch {
    error =>
      return self.invalidate_session(
        Engine(TextError::from_document_error(error, () => self.state.len())),
      )
  }
  self.change(Local(label), _ => {
    let items : Array[@undo.UndoItem] = []
    for i = plans.length() - 1; i >= 0; i = i - 1 {
      let (start, end, text) = plans[i]
      if undo is NoHistory {
        self.state.replace_range(Range::from_ints(start, end), text) catch {
          error => raise Engine(error)
        }
      } else {
        self.state.replace_range_collect(start, end, text, items) catch {
          error => raise Engine(error)
        }
      }
    }
    if !plans.is_empty() {
      if undo is NoHistory {
        self.can_join = false
      } else {
        self.undo_history.record_group(
          items[:],
          join=undo is JoinPrevious && self.can_join,
        )
        self.can_join = true
      }
    }
    None
  })
}

///|
pub fn Editor::undo(self : Editor) -> Edit {
  self.change(Undo, _ => {
    ignore(self.undo_history.undo(self.state)) catch {
      error => raise Undo(error)
    }
    self.can_join = false
    None
  })
}

///|
pub fn Editor::redo(self : Editor) -> Edit {
  self.change(Redo, _ => {
    ignore(self.undo_history.redo(self.state)) catch {
      error => raise Undo(error)
    }
    self.can_join = false
    None
  })
}

///|
/// Accept history and explicitly advance the view, including earlier hidden edits.
/// Never use this convenience operation for receipt-only native textarea input.
pub fn Editor::receive(self : Editor, message : SyncMessage) -> Edit {
  if !self.available {
    return Invalidated(Unavailable)
  }
  let admission = self.accept_remote(message)
  self.change(Remote, _ => {
    self.state.inner.advance_projection() catch {
      error =>
        raise Engine(
          TextError::from_document_error(error, () => self.state.len()),
        )
    }
    match admission.result {
      Ok(report) => Some(report)
      Err(error) => raise Engine(error)
    }
  })
}

///|
/// Explicitly publish accepted history, preserving EGW selective undo.
/// A native textarea host must not call this during its editing session.
pub fn Editor::advance_view(self : Editor) -> Edit {
  self.change(Remote, _ => {
    self.state.inner.advance_projection() catch {
      error =>
        raise Engine(
          TextError::from_document_error(error, () => self.state.len()),
        )
    }
    None
  })
}

///|
/// In-memory progress, including partial acceptance on failure; never durability.
pub struct Admission {
  before : Version
  after : Version
  pending_operations : Int32
  result : Result[SyncReport, TextError]
}

///|
/// Always history-only, including after a projection failure.
pub fn Editor::accept_remote(self : Editor, message : SyncMessage) -> Admission {
  let before = self.history_version()
  let result = Ok(self.accept_remote_report(message)) catch {
    error => Err(error)
  }
  {
    before,
    after: self.history_version(),
    pending_operations: self.state.inner.pending_count(),
    result,
  }
}

///|
fn Editor::accept_remote_report(
  self : Editor,
  message : SyncMessage,
) -> SyncReport raise TextError {
  let limits = self.state.sync_limits
  map_sync_failure(fn() raise @sync.Failure {
    validate_message_limits(message, limits)
  })
  let outcome = self.state.inner.admit_structural_changes(
    message.structural_operations[:],
    limits.max_pending_operations(),
  ) catch {
    error => raise TextError::from_document_error(error, () => self.state.len())
  }
  match outcome {
    @oplog.ApplyChangesOutcome::Succeeded(report) =>
      {
        applied_operations: report.committed().length(),
        duplicate_operations: report.redelivery_count(),
        pending_operations: report.pending_after_count(),
      }
    @oplog.ApplyChangesOutcome::Failed(error~, ..) =>
      raise TextError::from_oplog_error(
        @oplog.OpLogError::CausalGraphError(error~),
      )
  }
}

///|
/// End the editing session's undo history and publish the complete accepted cut.
/// Hosts must explicitly establish a new native input baseline for this snapshot.
/// Also recovers an invalidated projection; accepted history is never rolled back.
pub fn Editor::reopen_view(self : Editor) -> TextSnapshot raise EditError {
  self.state.inner.integrate_projection() catch {
    error => {
      self.reset_session(false)
      raise Engine(
        TextError::from_document_error(error, () => self.state.len()),
      )
    }
  }
  self.reset_session(true)
  self.snapshot()
}

///|
pub extend UpdateOrigin with Eq::{equal, not_equal}

///|
pub extend UpdateOrigin with @debug.Debug::{to_repr}

///|
pub extend UndoPolicy with Eq::{equal, not_equal}

///|
pub extend UndoPolicy with @debug.Debug::{to_repr}
