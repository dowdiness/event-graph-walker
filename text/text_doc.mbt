///| TextState - Main entry point for user-friendly text CRDT API

///|
/// A collaborative text document with automatic conflict resolution
pub(all) struct TextState {
  priv inner : @document.Document
}

///|
pub impl @debug.Debug for TextState with to_repr(self) {
  @debug.Repr::literal("TextState(len=" + self.len().to_string() + ")")
}

///|
/// Create a new empty document with the given agent ID
pub fn TextState::new(agent_id : String) -> TextState {
  TextState::{ inner: @document.Document::new(agent_id) }
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
  let doc_len = self.len()
  let pos_val = pos.value()
  if pos_val > doc_len {
    raise TextError::InvalidPosition(pos=pos_val, len=doc_len)
  }
  try {
    let _ = self.inner.insert(pos_val, text)
  } catch {
    err => raise TextError::from_document_error(err, doc_len)
  }
}

///|
/// Delete a single character at the given position
pub fn TextState::delete(self : TextState, pos : Pos) -> Unit raise TextError {
  let doc_len = self.len()
  let pos_val = pos.value()
  if pos_val >= doc_len {
    raise TextError::InvalidPosition(pos=pos_val, len=doc_len)
  }
  try {
    let _ = self.inner.delete(pos_val)
  } catch {
    err => raise TextError::from_document_error(err, doc_len)
  }
}

///|
/// Delete the half-open range `[start, end)`.
pub fn TextState::delete_range(
  self : TextState,
  range : Range,
) -> Unit raise TextError {
  let doc_len = self.len()
  let (start, end) = checked_range_bounds(range, doc_len)
  self.inner.delete_range(start, end) catch {
    err => raise TextError::from_document_error(err, doc_len)
  }
}

///|
/// Replace the half-open range `[start, end)` with `text`.
pub fn TextState::replace_range(
  self : TextState,
  range : Range,
  text : String,
) -> Unit raise TextError {
  let doc_len = self.len()
  let (start, end) = checked_range_bounds(range, doc_len)
  self.inner.replace_range(start, end, text) catch {
    err => raise TextError::from_document_error(err, doc_len)
  }
}

///|
/// Get the current version of the document
pub fn TextState::version(self : TextState) -> Version {
  Version::from_frontier(self.inner.get_frontier())
}

///|
/// Get a sync session for this document
pub fn TextState::sync(self : TextState) -> SyncSession {
  SyncSession::{ doc: self }
}

///|
/// Checkout a historical view at a specific version
pub fn TextState::checkout(
  self : TextState,
  version : Version,
) -> TextView raise TextError {
  try {
    let branch = self.inner.checkout_branch(version.to_frontier())
    TextView::from_branch(branch)
  } catch {
    err => raise TextError::from_document_error(err, self.len())
  }
}

///|
pub impl Show for TextState with output(self, logger) {
  logger.write_string("TextState { text: \"")
  logger.write_string(truncate_display(self.text()))
  logger.write_string("\", version: ")
  self.version().to_frontier().output(logger)
  logger.write_string(" }")
}

///|
fn checked_range_bounds(
  range : Range,
  doc_len : Int,
) -> (Int, Int) raise TextError {
  let start = range.start.value()
  let end = range.end.value()
  if end < start || end > doc_len {
    raise TextError::InvalidPosition(pos=end, len=doc_len)
  }
  (start, end)
}
