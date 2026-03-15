///| TextDoc - Main entry point for user-friendly text CRDT API

///|
/// A collaborative text document with automatic conflict resolution
pub(all) struct TextDoc {
  priv inner : @document.Document
}

///|
/// Create a new empty document with the given agent ID
pub fn TextDoc::new(agent_id : String) -> TextDoc {
  TextDoc::{ inner: @document.Document::new(agent_id) }
}

///|
/// Get the current text content
pub fn TextDoc::text(self : TextDoc) -> String {
  self.inner.to_text()
}

///|
/// Get the current text length (number of visible characters).
/// This is O(1) as it uses cached count, not string reconstruction.
pub fn TextDoc::len(self : TextDoc) -> Int {
  self.inner.visible_count()
}

///|
/// Check if document is empty
pub fn TextDoc::is_empty(self : TextDoc) -> Bool {
  self.len() == 0
}

///|
/// Insert text at the given position
pub fn TextDoc::insert(
  self : TextDoc,
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
pub fn TextDoc::delete(self : TextDoc, pos : Pos) -> Unit raise TextError {
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
pub fn TextDoc::delete_range(
  self : TextDoc,
  range : Range,
) -> Unit raise TextError {
  let doc_len = self.len()
  let (start, end) = checked_range_bounds(range, doc_len)
  try {
    self.inner.delete_range(start, end)
  } catch {
    err => raise TextError::from_document_error(err, doc_len)
  }
}

///|
/// Replace the half-open range `[start, end)` with `text`.
pub fn TextDoc::replace_range(
  self : TextDoc,
  range : Range,
  text : String,
) -> Unit raise TextError {
  let doc_len = self.len()
  let (start, end) = checked_range_bounds(range, doc_len)
  try {
    self.inner.replace_range(start, end, text)
  } catch {
    err => raise TextError::from_document_error(err, doc_len)
  }
}

///|
/// Get the current version of the document
pub fn TextDoc::version(self : TextDoc) -> Version {
  Version::from_frontier(self.inner.get_frontier())
}

///|
/// Get a sync session for this document
pub fn TextDoc::sync(self : TextDoc) -> SyncSession {
  SyncSession::{ doc: self }
}

///|
/// Checkout a historical view at a specific version
pub fn TextDoc::checkout(
  self : TextDoc,
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
pub impl Show for TextDoc with output(self, logger) {
  logger.write_string("TextDoc { text: \"")
  logger.write_string(truncate_display(self.text()))
  logger.write_string("\", version: ")
  self.version().to_frontier().output(logger)
  logger.write_string(" }")
}

///|
fn checked_range_bounds(range : Range, doc_len : Int) -> (Int, Int) raise TextError {
  let start = range.start.value()
  let end = range.end.value()
  if end < start || end > doc_len {
    raise TextError::InvalidPosition(pos=end, len=doc_len)
  }
  (start, end)
}
