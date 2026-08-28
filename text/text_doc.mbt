///| TextState - Main entry point for user-friendly text CRDT API

///|
/// A validated local insert request ready for the imperative CRDT shell.
priv struct InsertPlan {
  position : Int
  text : String
}

///|
fn InsertPlan::InsertPlan(position : Int, text : String) -> InsertPlan {
  { position, text }
}

///|
/// Validate a local insert without touching document state.
fn plan_insert(
  position : Int,
  text : String,
  doc_len : Int,
) -> InsertPlan raise TextError {
  guard position <= doc_len else {
    raise TextError::InvalidPosition(pos=position, len=doc_len)
  }
  guard text.length() != 0 else {
    return InsertPlan::InsertPlan(position, text)
  }
  guard is_well_formed_utf16(text) else {
    raise TextError::InvalidText(detail="malformed UTF-16")
  }
  InsertPlan::InsertPlan(position, text)
}

///|
/// A collaborative text document with automatic conflict resolution
pub(all) struct TextState {
  priv inner : @document.Document
  priv sync_limits : @sync.Limits
}

///|
pub impl @debug.Debug for TextState with fn to_repr(self) {
  @debug.Repr::literal("TextState(len=" + self.len().to_string() + ")")
}

///|
/// Create a new empty document with the given agent ID
pub fn TextState::new(agent_id : String) -> TextState raise TextError {
  TextState::new_with_sync_limits(agent_id, @sync.Limits::default())
}

///|
/// Create a new empty document with explicit synchronization limits.
pub fn TextState::new_with_sync_limits(
  agent_id : String,
  limits : @sync.Limits,
) -> TextState raise TextError {
  if agent_id == "" {
    raise TextError::EmptyReplicaId
  }
  TextState::{ inner: @document.Document::new(agent_id), sync_limits: limits }
}

///|
/// Recover the Document projection before reading it for mutation validation.
fn TextState::prepare_for_mutation(self : TextState) -> Unit raise TextError {
  self.inner.prepare_for_mutation() catch {
    error =>
      raise TextError::from_document_error(error, () => {
        self.inner.visible_count()
      })
  }
}

///|
/// Get the current text content
pub fn TextState::text(self : TextState) -> String {
  self.inner.to_text()
}

///|
/// Get the current text length (number of visible characters).
/// This is O(1) as it uses cached count, not string reconstruction.
pub fn TextState::len(self : TextState) -> Int {
  self.inner.visible_count()
}

///|
/// Check if document is empty
pub fn TextState::is_empty(self : TextState) -> Bool {
  self.len() == 0
}

///|
/// Read-only view of the document's causal DAG.
///
/// The returned `CausalSnapshot` is a live alias — it reflects mutations made
/// to this `TextState` after the call returns. It is not a point-in-time
/// copy; callers needing a stable baseline must capture the fields they care
/// about (e.g. `frontier()`, which already returns a fresh array) before
/// further edits.
pub fn TextState::causal_snapshot(self : TextState) -> @history.CausalSnapshot {
  self.inner.causal_snapshot()
}

///|
/// Insert text at the given position
pub fn TextState::insert(
  self : TextState,
  pos : Pos,
  text : String,
) -> Unit raise TextError {
  self.prepare_for_mutation()
  let doc_len = self.len()
  let plan = plan_insert(pos.value(), text, doc_len)
  if plan.text.length() == 0 {
    return
  }
  ignore(self.inner.insert(plan.position, plan.text)) catch {
    err => raise TextError::from_document_error(err, () => doc_len)
  }
}

///|
/// Delete a single character at the given position
pub fn TextState::delete(self : TextState, pos : Pos) -> Unit raise TextError {
  self.prepare_for_mutation()
  let doc_len = self.len()
  let pos_val = pos.value()
  if pos_val >= doc_len {
    raise TextError::InvalidPosition(pos=pos_val, len=doc_len)
  }
  ignore(self.inner.delete(pos_val)) catch {
    err => raise TextError::from_document_error(err, () => doc_len)
  }
}

///|
/// Delete the half-open range `[start, end)`.
pub fn TextState::delete_range(
  self : TextState,
  range : Range,
) -> Unit raise TextError {
  self.prepare_for_mutation()
  let doc_len = self.len()
  let (start, end) = checked_range_bounds(range, doc_len)
  self.inner.delete_range(start, end) catch {
    err => raise TextError::from_document_error(err, () => doc_len)
  }
}

///|
/// Replace the half-open range `[start, end)` with `text`.
pub fn TextState::replace_range(
  self : TextState,
  range : Range,
  text : String,
) -> Unit raise TextError {
  self.prepare_for_mutation()
  let doc_len = self.len()
  let (start, end) = checked_range_bounds(range, doc_len)
  let plan = plan_insert(start, text, doc_len)
  // Keep replacement and cursor-reset semantics owned by Document.
  self.inner.replace_range(start, end, plan.text) catch {
    err => raise TextError::from_document_error(err, () => doc_len)
  }
}

///|
/// Get the current version of the document
pub fn TextState::version(self : TextState) -> Version {
  Version::from_graph_version(self.inner.current_graph_version())
}

///|
fn TextState::transition_version(self : TextState) -> Version {
  self.version()
}

///|
/// Get a sync session for this document
pub fn TextState::sync(self : TextState) -> SyncSession {
  SyncSession::{
    doc: self,
    prepare_for_mutation_override: None,
    admit_remote_override: None,
  }
}

///|
/// Checkout a historical view at a specific version
pub fn TextState::checkout(
  self : TextState,
  version : Version,
) -> TextView raise TextError {
  let frontier = match self.inner.resolve_graph_version(version.graph()) {
    Some(value) => value
    None => raise TextError::VersionNotFound
  }
  try {
    let branch = self.inner.checkout_branch(frontier)
    TextView::from_branch(branch, version)
  } catch {
    err => raise TextError::from_document_error(err, () => self.len())
  }
}

///|
pub impl Show for TextState with fn output(self, logger) {
  logger.write_string("TextState { text: \"")
  logger.write_string(truncate_display(self.text()))
  logger.write_string("\", version: ")
  Show::output(self.version(), logger)
  logger.write_string(" }")
}

///|
fn checked_range_bounds(
  range : Range,
  doc_len : Int,
) -> (Int, Int) raise TextError {
  let start = range.start().value()
  let end = range.end().value()
  if end > doc_len {
    raise TextError::InvalidPosition(pos=end, len=doc_len)
  }
  (start, end)
}
