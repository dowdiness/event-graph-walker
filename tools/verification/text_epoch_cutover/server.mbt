///|
priv enum Phase {
  Active
  Quiescing
}

///|
pub struct SubmitOutcome {
  priv epoch : Int
  priv cursor : Int
  priv applied_operations : Int
  priv duplicate_operations : Int
  priv pending_operations : Int
  priv replay : Bool
}

///|
pub fn SubmitOutcome::epoch(self : SubmitOutcome) -> Int {
  self.epoch
}

///|
pub fn SubmitOutcome::cursor(self : SubmitOutcome) -> Int {
  self.cursor
}

///|
pub fn SubmitOutcome::applied_operations(self : SubmitOutcome) -> Int {
  self.applied_operations
}

///|
pub fn SubmitOutcome::duplicate_operations(self : SubmitOutcome) -> Int {
  self.duplicate_operations
}

///|
pub fn SubmitOutcome::pending_operations(self : SubmitOutcome) -> Int {
  self.pending_operations
}

///|
pub fn SubmitOutcome::is_replay(self : SubmitOutcome) -> Bool {
  self.replay
}

///|
priv struct StoredReceipt {
  epoch : Int
  client_instance_id : String
  submission_sequence : Int
  canonical_request : Bytes
  outcome : SubmitOutcome
}

///|
pub struct LogEntry {
  priv epoch : Int
  priv cursor : Int
  priv canonical_request : String
}

///|
pub fn LogEntry::epoch(self : LogEntry) -> Int {
  self.epoch
}

///|
pub fn LogEntry::cursor(self : LogEntry) -> Int {
  self.cursor
}

///|
pub fn LogEntry::request_json(self : LogEntry) -> String {
  self.canonical_request
}

///|
priv struct ArchivedGeneration {
  epoch : Int
  document : @text.TextState
  log : Array[LogEntry]
}

///|
/// In-memory reference shell for the epoch protocol.
///
/// A production adapter must commit the EGW mutation, log entry, cursor, and
/// receipt in one durable transaction before acknowledging the submission.
pub struct Server {
  priv document_id : String
  priv mut epoch : Int
  priv mut cursor : Int
  priv mut phase : Phase
  priv mut cutover_text : String?
  priv mut document : @text.TextState
  priv mut log : Array[LogEntry]
  priv mut receipts : Array[StoredReceipt]
  priv mut archives : Array[ArchivedGeneration]
}

///|
pub fn Server::Server(
  document_id : String,
  epoch~ : Int,
  server_agent~ : String,
) -> Server raise ProtocolError {
  if document_id == "" {
    raise ProtocolError::InvalidDocumentId
  }
  if epoch < 0 {
    raise ProtocolError::InvalidEpoch(epoch)
  }
  let document = map_text(() => @text.TextState::new(server_agent))
  {
    document_id,
    epoch,
    cursor: 0,
    phase: Active,
    cutover_text: None,
    document,
    log: [],
    receipts: [],
    archives: [],
  }
}

///|
pub fn Server::document_id(self : Server) -> String {
  self.document_id
}

///|
pub fn Server::epoch(self : Server) -> Int {
  self.epoch
}

///|
pub fn Server::cursor(self : Server) -> Int {
  self.cursor
}

///|
pub fn Server::text(self : Server) -> String {
  self.document.text()
}

///|
pub fn Server::is_quiescing(self : Server) -> Bool {
  self.phase is Quiescing
}

///|
fn require_current_epoch(
  current_epoch : Int,
  requested_epoch : Int,
) -> Unit raise ProtocolError {
  if requested_epoch != current_epoch {
    raise ProtocolError::StaleEpoch(
      expected=current_epoch,
      actual=requested_epoch,
    )
  }
}

///|
fn decide_submission_identity(
  current_epoch : Int,
  requested_epoch : Int,
  client_instance_id : String,
  submission_sequence : Int,
) -> Unit raise ProtocolError {
  require_current_epoch(current_epoch, requested_epoch)
  if client_instance_id == "" || submission_sequence < 0 {
    raise ProtocolError::InvalidSubmissionIdentity
  }
}

///|
fn decide_begin_cutover(
  current_epoch : Int,
  phase : Phase,
  pending_operations : Int,
  expected_epoch : Int,
) -> Unit raise ProtocolError {
  require_current_epoch(current_epoch, expected_epoch)
  if phase is Quiescing {
    raise ProtocolError::CutoverAlreadyStarted(current_epoch)
  }
  if pending_operations > 0 {
    raise ProtocolError::PendingOperations(pending_operations)
  }
}

///|
fn decide_finish_cutover(
  current_epoch : Int,
  phase : Phase,
  expected_epoch : Int,
) -> Unit raise ProtocolError {
  require_current_epoch(current_epoch, expected_epoch)
  if phase is Active {
    raise ProtocolError::CutoverNotStarted(current_epoch)
  }
}

///|
pub fn Server::begin_cutover(
  self : Server,
  expected_epoch~ : Int,
) -> Unit raise ProtocolError {
  decide_begin_cutover(
    self.epoch,
    self.phase,
    self.document.sync().pending_sync_count(),
    expected_epoch,
  )
  self.cutover_text = Some(self.document.text())
  self.phase = Quiescing
}

///|
pub fn Server::cancel_cutover(
  self : Server,
  expected_epoch~ : Int,
) -> Unit raise ProtocolError {
  decide_finish_cutover(self.epoch, self.phase, expected_epoch)
  self.cutover_text = None
  self.phase = Active
}

///|
pub fn Server::publish_cutover(
  self : Server,
  expected_epoch~ : Int,
  baseline~ : Baseline,
) -> Unit raise ProtocolError {
  decide_finish_cutover(self.epoch, self.phase, expected_epoch)
  let source_text = match self.cutover_text {
    Some(text) => text
    None => raise ProtocolError::CutoverNotStarted(self.epoch)
  }
  if baseline.text() != source_text {
    raise ProtocolError::BaselineSourceMismatch
  }
  let next_epoch = self.epoch + 1
  let next_document = baseline.apply_to(
    "epoch-server:\{self.document_id}:\{next_epoch}",
  )
  let next_log : Array[LogEntry] = []
  for index, canonical_request in baseline.pages {
    next_log.push({ epoch: next_epoch, cursor: index + 1, canonical_request })
  }
  let next_archives = self.archives.copy()
  next_archives.push({
    epoch: self.epoch,
    document: self.document,
    log: self.log.copy(),
  })
  self.archives = next_archives
  self.epoch = next_epoch
  self.cursor = next_log.length()
  self.document = next_document
  self.log = next_log
  self.cutover_text = None
  self.phase = Active
}

///|
pub fn Server::has_archived_epoch(self : Server, epoch : Int) -> Bool {
  self.archives.any(archive => archive.epoch == epoch)
}

///|
pub fn Server::archived_text(self : Server, epoch : Int) -> String? {
  match self.archives.search_by(archive => archive.epoch == epoch) {
    Some(index) => Some(self.archives[index].document.text())
    None => None
  }
}

///|
pub fn Server::archived_entry_count(self : Server, epoch : Int) -> Int? {
  match self.archives.search_by(archive => archive.epoch == epoch) {
    Some(index) => Some(self.archives[index].log.length())
    None => None
  }
}

///|
fn replayed(outcome : SubmitOutcome) -> SubmitOutcome {
  {
    epoch: outcome.epoch,
    cursor: outcome.cursor,
    applied_operations: outcome.applied_operations,
    duplicate_operations: outcome.duplicate_operations,
    pending_operations: outcome.pending_operations,
    replay: true,
  }
}

///|
priv enum ReceiptDecision {
  NewSubmission
  Replay(SubmitOutcome)
  Conflict
}

///|
fn decide_receipt(
  receipts : ArrayView[StoredReceipt],
  epoch : Int,
  client_instance_id : String,
  submission_sequence : Int,
  canonical_request : Bytes,
) -> ReceiptDecision {
  for receipt in receipts {
    if receipt.epoch == epoch &&
      receipt.client_instance_id == client_instance_id &&
      receipt.submission_sequence == submission_sequence {
      if receipt.canonical_request == canonical_request {
        return Replay(replayed(receipt.outcome))
      }
      return Conflict
    }
  }
  NewSubmission
}

///|
fn rebuild_document(
  document_id : String,
  epoch : Int,
  log : ArrayView[LogEntry],
) -> @text.TextState raise ProtocolError {
  let document = map_text(() => {
    @text.TextState::new("epoch-rebuild:\{document_id}:\{epoch}")
  })
  for entry in log {
    let message = map_text(() => {
      @text.SyncMessage::from_json_string(entry.canonical_request)
    })
    ignore(map_text(() => document.sync().apply(message)))
  }
  document
}

///|
pub fn Server::submit(
  self : Server,
  epoch~ : Int,
  client_instance_id~ : String,
  submission_sequence~ : Int,
  request_json~ : String,
) -> SubmitOutcome raise ProtocolError {
  decide_submission_identity(
    self.epoch,
    epoch,
    client_instance_id,
    submission_sequence,
  )
  let message = map_text(() => @text.SyncMessage::from_json_string(request_json))
  let canonical_request = message.to_canonical_bytes()
  match
    decide_receipt(
      self.receipts,
      epoch,
      client_instance_id,
      submission_sequence,
      canonical_request,
    ) {
    Replay(outcome) => return outcome
    Conflict =>
      raise ProtocolError::SubmissionConflict(
        client_instance_id~,
        sequence=submission_sequence,
      )
    NewSubmission => ()
  }
  if self.phase is Quiescing {
    raise ProtocolError::Quiescing(self.epoch)
  }
  let canonical_json = message.to_json_string()
  let candidate = rebuild_document(self.document_id, self.epoch, self.log)
  let report = map_text(() => candidate.sync().apply(message))
  let next_cursor = self.cursor + 1
  let outcome : SubmitOutcome = {
    epoch,
    cursor: next_cursor,
    applied_operations: report.applied_operations(),
    duplicate_operations: report.duplicate_operations(),
    pending_operations: report.pending_operations(),
    replay: false,
  }
  let next_log = self.log.copy()
  next_log.push({
    epoch,
    cursor: next_cursor,
    canonical_request: canonical_json,
  })
  let next_receipts = self.receipts.copy()
  next_receipts.push({
    epoch,
    client_instance_id,
    submission_sequence,
    canonical_request,
    outcome,
  })
  self.document = candidate
  self.log = next_log
  self.receipts = next_receipts
  self.cursor = next_cursor
  outcome
}

///|
pub fn Server::lookup_receipt(
  self : Server,
  epoch~ : Int,
  client_instance_id~ : String,
  submission_sequence~ : Int,
  request_json~ : String,
) -> SubmitOutcome? raise ProtocolError {
  if client_instance_id == "" || submission_sequence < 0 {
    raise ProtocolError::InvalidSubmissionIdentity
  }
  let message = map_text(() => @text.SyncMessage::from_json_string(request_json))
  let canonical_request = message.to_canonical_bytes()
  match
    decide_receipt(
      self.receipts,
      epoch,
      client_instance_id,
      submission_sequence,
      canonical_request,
    ) {
    Replay(outcome) => Some(outcome)
    Conflict =>
      raise ProtocolError::SubmissionConflict(
        client_instance_id~,
        sequence=submission_sequence,
      )
    NewSubmission => None
  }
}

///|
pub fn Server::tail_after(
  self : Server,
  epoch~ : Int,
  cursor~ : Int,
) -> Array[LogEntry] raise ProtocolError {
  require_current_epoch(self.epoch, epoch)
  if cursor < 0 || cursor > self.cursor {
    raise ProtocolError::InvalidCursor(requested=cursor, current=self.cursor)
  }
  self.log
  .filter(entry => entry.cursor > cursor)
  .map(entry => {
    epoch: entry.epoch,
    cursor: entry.cursor,
    canonical_request: entry.canonical_request,
  })
}
