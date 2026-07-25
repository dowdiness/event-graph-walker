///| User-friendly error types with diagnostics

///|
/// User-facing error type for the text facade
pub(all) suberror TextError {
  EmptyReplicaId
  InvalidPosition(pos~ : Int, len~ : Int)
  InvalidText(detail~ : String)
  InvalidRange(start~ : Int, end~ : Int)
  SyncFailed(@sync.Failure)
  VersionNotFound
  Internal(detail~ : String)
}

///|
/// User-facing short message
pub fn TextError::message(self : TextError) -> String {
  match self {
    EmptyReplicaId => "Replica ID must not be empty"
    InvalidPosition(pos~, len~) =>
      "Invalid position: \{pos} is out of bounds for text of length \{len}"
    InvalidText(detail~) => "Invalid text: \{detail}"
    InvalidRange(start~, end~) =>
      "Invalid range: start \{start} is after end \{end}"
    SyncFailed(@sync.Failure::MissingDependency(replica_id~, sequence~)) =>
      "Sync failed: missing dependency - \{replica_id}:\{sequence}"
    SyncFailed(@sync.Failure::MalformedMessage(detail~)) =>
      "Sync failed: malformed message - \{detail}"
    SyncFailed(@sync.Failure::InvalidContent(detail~)) =>
      "Sync failed: invalid content - \{detail}"
    SyncFailed(@sync.Failure::ConflictingIdentity(replica_id~, sequence~)) =>
      "Sync failed: conflicting identity - \{replica_id}:\{sequence}"
    SyncFailed(@sync.Failure::LimitExceeded(kind~, limit~, actual~)) =>
      "Sync failed: \{kind} limit \{limit} exceeded by \{actual}"
    VersionNotFound => "Version not found in document history"
    Internal(detail~) => "Internal error: \{detail}"
  }
}

///|
/// Actionable guidance for the user
pub fn TextError::help(self : TextError) -> String {
  match self {
    EmptyReplicaId => "Supply a globally unique, non-empty replica ID"
    InvalidPosition(pos=_, len~) =>
      "Use a position between 0 and \{len} (inclusive for insert, exclusive for delete)"
    InvalidText(_) => "Provide valid Unicode text without lone surrogates"
    InvalidRange(_) => "Construct ranges with start less than or equal to end"
    SyncFailed(@sync.Failure::MissingDependency(_)) =>
      "Sync more operations from the peer and retry"
    SyncFailed(@sync.Failure::MalformedMessage(_)) =>
      "Discard this message and consider isolating the peer"
    SyncFailed(@sync.Failure::InvalidContent(_)) =>
      "Discard this message and consider isolating the peer"
    SyncFailed(@sync.Failure::ConflictingIdentity(_)) =>
      "Use a fresh globally unique replica ID and discard the conflicting message"
    SyncFailed(@sync.Failure::LimitExceeded(_)) =>
      "Reject the message or construct the state with appropriate sync limits"
    VersionNotFound => "The version may not be synced yet. Try syncing first."
    Internal(_) => "Please report this bug with the debug output"
  }
}

///|
/// Full detail for logs/debugging
pub fn TextError::debug(self : TextError) -> String {
  match self {
    EmptyReplicaId => "TextError::EmptyReplicaId"
    InvalidPosition(pos~, len~) =>
      "TextError::InvalidPosition { pos: \{pos}, len: \{len} }"
    InvalidText(detail~) => "TextError::InvalidText { detail: \{detail} }"
    InvalidRange(start~, end~) =>
      "TextError::InvalidRange { start: \{start}, end: \{end} }"
    SyncFailed(failure) => "TextError::SyncFailed { reason: \{failure} }"
    VersionNotFound => "TextError::VersionNotFound"
    Internal(detail~) => "TextError::Internal { detail: \{detail} }"
  }
}

///|
/// Whether this error can be retried
pub fn TextError::is_retryable(self : TextError) -> Bool {
  match self {
    EmptyReplicaId => false
    InvalidPosition(_) => false
    InvalidText(_) => false
    InvalidRange(_) => false
    SyncFailed(@sync.Failure::MissingDependency(_)) => true
    SyncFailed(@sync.Failure::MalformedMessage(_)) => false
    SyncFailed(@sync.Failure::InvalidContent(_)) => false
    SyncFailed(@sync.Failure::ConflictingIdentity(_)) => false
    SyncFailed(@sync.Failure::LimitExceeded(_)) => false
    VersionNotFound => true
    Internal(_) => false
  }
}

///|
/// Convert from DocumentError to TextError
fn TextError::from_document_error(
  err : @document.DocumentError,
  doc_len : Int,
) -> TextError {
  match err {
    InvalidPosition(pos~) => TextError::InvalidPosition(pos~, len=doc_len)
    MissingOrigin(raw~) =>
      TextError::SyncFailed(
        @sync.Failure::MissingDependency(replica_id=raw.agent, sequence=raw.seq),
      )
    OpLog(oplog_err) => TextError::from_oplog_error(oplog_err)
    Fugue(@fugue.FugueError::MissingItem(id~)) =>
      TextError::Internal(detail="fugue error: missing item id=\{id}")
    Branch(branch_err) => TextError::from_branch_error(branch_err)
    ContentError(reason~) => {
      let detail = match reason {
        @document.ContentErrorReason::MalformedUtf16 =>
          "insert contains malformed UTF-16"
        @document.ContentErrorReason::MultipleCodepoints =>
          "insert must contain exactly one Unicode scalar value"
      }
      TextError::SyncFailed(@sync.Failure::InvalidContent(detail~))
    }
  }
}

///|
/// Convert from OpLogError to TextError
fn TextError::from_oplog_error(err : @oplog.OpLogError) -> TextError {
  match err {
    MissingLocalVersion(lv~) =>
      TextError::Internal(detail="missing local version: \{lv}")
    MissingOrigin =>
      TextError::SyncFailed(
        @sync.Failure::MalformedMessage(
          detail="delete operation missing origin",
        ),
      )
    MissingRemoteParent(raw~) =>
      TextError::SyncFailed(
        @sync.Failure::MissingDependency(replica_id=raw.agent, sequence=raw.seq),
      )
    MissingRemoteFrontier(raw~) =>
      TextError::SyncFailed(
        @sync.Failure::MissingDependency(replica_id=raw.agent, sequence=raw.seq),
      )
    DuplicateOperation(raw~) =>
      TextError::SyncFailed(
        @sync.Failure::MalformedMessage(
          detail="duplicate operation in batch: \{raw}",
        ),
      )
    StaleRemoteAdmissionPlan =>
      TextError::Internal(detail="stale remote admission plan")
    ConsumedRemoteAdmissionPlan =>
      TextError::Internal(detail="consumed remote admission plan")
    InvalidRemoteAdmissionPlan =>
      TextError::Internal(detail="invalid remote admission plan")
    PartialRemoteAdmission(committed=_, error~) =>
      TextError::from_oplog_error(@oplog.OpLogError::CausalGraphError(error~))
    CausalGraphError(error~) =>
      match error {
        @causal_graph.CausalGraphError::MissingParent(lv~) =>
          TextError::SyncFailed(
            @sync.Failure::MalformedMessage(
              detail="causal graph missing parent at local version \{lv}",
            ),
          )
        @causal_graph.CausalGraphError::MissingEntry(lv~) =>
          TextError::Internal(detail="causal graph: missing entry at lv=\{lv}")
      }
  }
}

///|
/// Convert from BranchError to TextError
fn TextError::from_branch_error(err : @branch.BranchError) -> TextError {
  match err {
    MissingOp(lv~) => TextError::Internal(detail="missing op at lv: \{lv}")
    MissingOrigin(raw~) =>
      TextError::SyncFailed(
        @sync.Failure::MissingDependency(replica_id=raw.agent, sequence=raw.seq),
      )
    OpLog(oplog_err) => TextError::from_oplog_error(oplog_err)
    Fugue(@fugue.FugueError::MissingItem(id~)) =>
      TextError::Internal(detail="fugue error: missing item id=\{id}")
  }
}
