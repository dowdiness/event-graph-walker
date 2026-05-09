///| Document error types

///|
pub(all) suberror DocumentError {
  /// Invalid cursor position for operation
  InvalidPosition(pos~ : Int)
  /// RawVersion could not be resolved to local version
  MissingOrigin(raw~ : @core.RawVersion)
  /// Wrapped error from oplog operations
  OpLog(@oplog.OpLogError)
  /// Wrapped error from fugue tree operations
  Fugue(@fugue.FugueError)
  /// Wrapped error from branch operations
  Branch(@branch.BranchError)
  /// Insert Op carries content that violates the per-codepoint invariant.
  /// Raised from `apply_remote` / `merge_remote` when an ingested Op contains
  /// empty text, malformed UTF-16 (lone surrogate), or more than one codepoint.
  ContentError(reason~ : ContentErrorReason)
}

///|
pub(all) enum ContentErrorReason {
  /// Insert Op text contained a lone surrogate (not part of a valid pair).
  MalformedUtf16
  /// Insert Op text contained more than one Unicode scalar value.
  MultipleCodepoints
} derive(Debug, Eq)

///|
pub impl Show for ContentErrorReason with output(self, logger) {
  logger.write_string(@debug.to_string(self))
}
