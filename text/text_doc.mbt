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
  priv mut pending_sync_records : Array[StructuralOp]
  priv mut cached_version : Version?
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
  TextState::{
    inner: @document.Document::new(agent_id),
    sync_limits: limits,
    pending_sync_records: [],
    cached_version: Some(Version::empty()),
  }
}

///|
fn TextState::advance_cached_version(self : TextState, op : @core.Op) -> Unit {
  match self.cached_version {
    Some(version) =>
      self.cached_version = Some(version.advance(op.agent(), op.seq()))
    None => ()
  }
}

///|
fn TextState::invalidate_cached_version(self : TextState) -> Unit {
  self.cached_version = None
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
  let plan = plan_insert(pos.value(), text, doc_len)
  if plan.text.length() == 0 {
    return
  }
  try {
    let op = self.inner.insert(plan.position, plan.text)
    self.advance_cached_version(op)
  } catch {
    err => {
      self.invalidate_cached_version()
      raise TextError::from_document_error(err, doc_len)
    }
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
    let op = self.inner.delete(pos_val)
    self.advance_cached_version(op)
  } catch {
    err => {
      self.invalidate_cached_version()
      raise TextError::from_document_error(err, doc_len)
    }
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
    err => {
      self.invalidate_cached_version()
      raise TextError::from_document_error(err, doc_len)
    }
  }
  if start != end {
    self.invalidate_cached_version()
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
  let plan = plan_insert(start, text, doc_len)
  if start == end && plan.text.length() > 0 {
    // Mirror Document::replace_range so its cursor reset remains observable.
    self.inner.delete_range(start, end) catch {
      err => {
        self.invalidate_cached_version()
        raise TextError::from_document_error(err, doc_len)
      }
    }
    let op = self.inner.insert(start, plan.text) catch {
      err => {
        self.invalidate_cached_version()
        raise TextError::from_document_error(err, doc_len)
      }
    }
    self.advance_cached_version(op)
    return
  }
  self.inner.replace_range(start, end, plan.text) catch {
    err => {
      self.invalidate_cached_version()
      raise TextError::from_document_error(err, doc_len)
    }
  }
  if start != end || plan.text.length() > 0 {
    self.invalidate_cached_version()
  }
}

///|
/// Get the current version of the document
pub fn TextState::version(self : TextState) -> Version {
  match self.cached_version {
    Some(version) => version
    None => {
      let version = Version::from_ops(self.inner.get_all_ops())
      self.cached_version = Some(version)
      version
    }
  }
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
  let frontier : Array[Int] = []
  for entry in version.entries {
    let raw = @core.RawVersion::new(entry.replica_id, entry.sequence)
    match self.inner.raw_to_lv(raw) {
      Some(lv) => frontier.push(lv)
      None => raise TextError::VersionNotFound
    }
  }
  try {
    let branch = self.inner.checkout_branch(
      @core.Frontier::from_array_dedup(frontier),
    )
    TextView::from_branch(branch, version)
  } catch {
    err => raise TextError::from_document_error(err, self.len())
  }
}

///|
pub impl Show for TextState with fn output(self, logger) {
  logger.write_string("TextState { text: \"")
  logger.write_string(truncate_display(self.text()))
  logger.write_string("\", version: ")
  self.version().output(logger)
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
