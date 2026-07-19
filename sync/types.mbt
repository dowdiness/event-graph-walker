///| Shared synchronization limits and failure classifications.

///|
/// The kind of resource limit enforced while decoding or preparing a message.
pub(all) enum LimitKind {
  EncodedBytes
  DecodedOperations
  PendingOperations
  ParentsPerOperation
} derive(Debug, Eq)

///|
pub impl Show for LimitKind with fn output(self, logger) {
  logger.write_string(@debug.to_string(self))
}

///|
/// A programmatic classification for synchronization failures.
pub(all) suberror Failure {
  MalformedMessage(detail~ : String)
  InvalidContent(detail~ : String)
  MissingDependency(replica_id~ : String, sequence~ : Int)
  ConflictingIdentity(replica_id~ : String, sequence~ : Int)
  LimitExceeded(kind~ : LimitKind, limit~ : Int, actual~ : Int)
}

///|
pub impl Show for Failure with fn output(self, logger) {
  match self {
    MalformedMessage(detail~) =>
      logger.write_string("MalformedMessage(\{detail})")
    InvalidContent(detail~) => logger.write_string("InvalidContent(\{detail})")
    MissingDependency(replica_id~, sequence~) =>
      logger.write_string("MissingDependency(\{replica_id}, \{sequence})")
    ConflictingIdentity(replica_id~, sequence~) =>
      logger.write_string("ConflictingIdentity(\{replica_id}, \{sequence})")
    LimitExceeded(kind~, limit~, actual~) => {
      logger.write_string("LimitExceeded(")
      kind.output(logger)
      logger.write_string(", \{limit}, \{actual})")
    }
  }
}

///|
/// Resource limits used when decoding and applying synchronization messages.
///
/// Values are immutable after construction. Call `Limits(...)` to override
/// defaults for an individual state instance.
pub(all) struct Limits {
  priv max_encoded_bytes : Int
  priv max_decoded_operations : Int
  priv max_pending_operations : Int
  priv max_parents_per_operation : Int
} derive(Debug, Eq)

///|
/// Construct limits, using protocol defaults for omitted values.
///
/// Every supplied value must be non-negative.
pub fn Limits::Limits(
  max_encoded_bytes? : Int = 16 * 1024 * 1024,
  max_decoded_operations? : Int = 100000,
  max_pending_operations? : Int = 10000,
  max_parents_per_operation? : Int = 256,
) -> Limits raise Failure {
  if max_encoded_bytes < 0 {
    raise Failure::LimitExceeded(
      kind=LimitKind::EncodedBytes,
      limit=0,
      actual=max_encoded_bytes,
    )
  }
  if max_decoded_operations < 0 {
    raise Failure::LimitExceeded(
      kind=LimitKind::DecodedOperations,
      limit=0,
      actual=max_decoded_operations,
    )
  }
  if max_pending_operations < 0 {
    raise Failure::LimitExceeded(
      kind=LimitKind::PendingOperations,
      limit=0,
      actual=max_pending_operations,
    )
  }
  if max_parents_per_operation < 0 {
    raise Failure::LimitExceeded(
      kind=LimitKind::ParentsPerOperation,
      limit=0,
      actual=max_parents_per_operation,
    )
  }
  {
    max_encoded_bytes,
    max_decoded_operations,
    max_pending_operations,
    max_parents_per_operation,
  }
}

///|
/// Default synchronization limits.
pub impl Default for Limits with fn default() {
  {
    max_encoded_bytes: 16 * 1024 * 1024,
    max_decoded_operations: 100000,
    max_pending_operations: 10000,
    max_parents_per_operation: 256,
  }
}

///|
pub fn Limits::max_encoded_bytes(self : Limits) -> Int {
  self.max_encoded_bytes
}

///|
pub fn Limits::max_decoded_operations(self : Limits) -> Int {
  self.max_decoded_operations
}

///|
pub fn Limits::max_pending_operations(self : Limits) -> Int {
  self.max_pending_operations
}

///|
pub fn Limits::max_parents_per_operation(self : Limits) -> Int {
  self.max_parents_per_operation
}
