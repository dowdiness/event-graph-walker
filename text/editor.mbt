///| Editing session: one document, one local undo history, one change stream.
/// No independently maintained text mirror or position index lives here.

///|
pub(all) struct Utf16Edit {
  start : Int
  end : Int
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
  before_len : Int
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
pub(all) enum UpdateOrigin {
  Local(String?)
  Remote
  Undo
  Redo
} derive(Eq, Debug)

///|
pub(all) enum UndoPolicy {
  NewGroup
  JoinPrevious
  NoHistory
} derive(Eq, Debug)

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
  {
    state: TextState::new(writer),
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
  { version: self.state.version(), text: self.state.text(), }
}

///|
pub fn Editor::version(self : Editor) -> Version {
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
fn Editor::change(
  self : Editor,
  origin : UpdateOrigin,
  action : (Int) -> SyncReport? raise EditError,
) -> Edit {
  if !self.available {
    return Invalidated(Unavailable)
  }
  let before = self.state.version()
  let before_len = try {
    let length = self.state.inner.utf16_len()
    self.state.inner.begin_text_change()
    length
  } catch {
    error => {
      self.available = false
      return Invalidated(
        Engine(TextError::from_document_error(error, () => self.state.len())),
      )
    }
  }
  let result = Ok(action(before_len)) catch { error => Err(error) }
  let changes = self.state.inner.finish_text_change()
  let after = self.state.version()
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
    (Some(_), Err(error)) if before == after &&
      (
        error is (ReversedRange | InvalidText | InvalidChange(_) | StaleVersion) ||
        (origin is Remote && error is Engine(SyncFailed(_)))
      ) => Rejected(error)
    _ => {
      self.available = false
      self.undo_history.clear()
      let error = match result {
        Ok(_) => EditError::Unavailable
        Err(error) => error
      }
      Invalidated(error)
    }
  }
}

///|
/// Single-replacement convenience API. The default is a new undo group.
pub fn Editor::edit(
  self : Editor,
  expected : Version,
  edit : Utf16Edit,
  undo? : UndoPolicy = NewGroup,
  label? : String,
) -> Edit {
  self.edit_with(
    expected,
    length => {
      if edit.end < edit.start {
        raise ReversedRange
      }
      if !is_well_formed_utf16(edit.text) {
        raise InvalidText
      }
      if edit.start < 0 || edit.start > length {
        raise InvalidChange(InvalidBoundary(offset=edit.start))
      }
      if edit.end > length {
        raise InvalidChange(InvalidBoundary(offset=edit.end))
      }
      // Normalization removes empty replacements, but the single-edit API still
      // validates their supplied coordinate before discarding them.
      if edit.start == edit.end && edit.text == "" {
        let boundary = self.state.inner.scalar_at_utf16(edit.start) catch {
          error =>
            raise Engine(
              TextError::from_document_error(error, () => self.state.len()),
            )
        }
        if boundary is None {
          raise InvalidChange(InvalidBoundary(offset=edit.start))
        }
      }
      ChangeSet::new([
        Keep(edit.start),
        Replace(edit.end - edit.start, edit.text),
        Keep(length - edit.end),
      ]) catch {
        error => raise InvalidChange(error)
      }
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
  undo? : UndoPolicy = NewGroup,
  label? : String,
) -> Edit {
  self.edit_with(base, _ => changes, undo, label)
}

///|
fn Editor::edit_with(
  self : Editor,
  expected : Version,
  build : (Int) -> ChangeSet raise EditError,
  undo : UndoPolicy,
  label : String?,
) -> Edit {
  self.change(Local(label), length => {
    if expected != self.state.version() {
      raise StaleVersion
    }
    let changes = build(length)
    if changes.length() != length {
      raise InvalidChange(LengthMismatch)
    }
    let plans : Array[(Int, Int, String)] = []
    let mut position = 0
    for section in changes.sections() {
      match section {
        Keep(n) => position += n
        Replace(n, text) => {
          let start = self.state.inner.scalar_at_utf16(position) catch {
            error =>
              raise Engine(
                TextError::from_document_error(error, () => self.state.len()),
              )
          }
          let end = self.state.inner.scalar_at_utf16(position + n) catch {
            error =>
              raise Engine(
                TextError::from_document_error(error, () => self.state.len()),
              )
          }
          guard start is Some(start) else {
            raise InvalidChange(InvalidBoundary(offset=position))
          }
          guard end is Some(end) else {
            raise InvalidChange(InvalidBoundary(offset=position + n))
          }
          plans.push((start, end, text))
          position += n
        }
      }
    }
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
pub fn Editor::receive(self : Editor, message : SyncMessage) -> Edit {
  self.change(Remote, _ => {
    let report = self.state.sync().apply(message) catch {
        error => raise Engine(error)
      }
    Some(report)
  })
}

///|
pub extend UpdateOrigin with Eq::{equal, not_equal}

///|
pub extend UpdateOrigin with @debug.Debug::{to_repr}

///|
pub extend UndoPolicy with Eq::{equal, not_equal}

///|
pub extend UndoPolicy with @debug.Debug::{to_repr}
