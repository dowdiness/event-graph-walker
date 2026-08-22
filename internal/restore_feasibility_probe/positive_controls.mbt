///|
/// One independently observed positive-control result for the Gate R0 evidence
/// detector. Counter families not exercised by the named query stay zero.
struct PositiveControlObservation {
  case_id : String
  logical_queries : Int
  physical_reads : Int
  provider_operations : Int
  provider_bytes : Int
  in_memory_scans : Int
  metadata_records : Int
  metadata_bytes : Int
  proof_bytes : Int
  requested_identities : Int
  payload_events : Int
  payload_bytes : Int
  scan_records_visited : Int
  full_history_events : Int
  full_history_bytes : Int
  utf16_code_units : Int
  unicode_scalars : Int
  rejected : Bool
}

///|
/// X-01: run an authenticated metadata/proof query through the same canonical
/// history provider operation used by candidate evidence.
fn EvidenceDetector::read_metadata_with_proof_control(
  self : EvidenceDetector,
  records~ : Int,
  metadata_bytes~ : Int,
  proof_bytes~ : Int,
) -> Unit {
  self.control_logical_queries = self.control_logical_queries + 1
  ignore(self.fetch_canonical_history())
  self.metadata_records = self.metadata_records + records
  self.metadata_bytes = self.metadata_bytes + metadata_bytes
  self.proof_bytes = self.proof_bytes + proof_bytes
}

///|
/// X-02: run a requested-identity payload batch through the same canonical
/// history provider operation used by candidate evidence.
fn EvidenceDetector::read_payload_batch_control(
  self : EvidenceDetector,
  requested_identities~ : Int,
  payload_events~ : Int,
  payload_bytes~ : Int,
) -> Unit {
  self.control_logical_queries = self.control_logical_queries + 1
  ignore(self.fetch_canonical_history())
  self.requested_identities = self.requested_identities + requested_identities
  self.payload_events = self.payload_events + payload_events
  self.payload_bytes = self.payload_bytes + payload_bytes
}

///|
/// X-03: deliberately violate the provider contract by scanning cold records.
/// This uses the production retained-value scan instrumentation and is rejected,
/// so it performs no canonical-history provider read.
fn EvidenceDetector::scan_cold_records_noncompliantly_control(
  self : EvidenceDetector,
  text : String,
  records~ : Int,
) -> Bool {
  self.control_logical_queries = self.control_logical_queries + 1
  self.scan_resident_value(text)
  self.scan_records_visited = self.scan_records_visited + records
  false
}

///|
/// X-04: run the separately named full-history query through the same
/// canonical-history provider operation used by candidate evidence.
fn EvidenceDetector::read_full_history_control(
  self : EvidenceDetector,
  events~ : Int,
  bytes~ : Int,
) -> Unit {
  self.control_logical_queries = self.control_logical_queries + 1
  ignore(self.fetch_canonical_history())
  self.full_history_events = self.full_history_events + events
  self.full_history_bytes = self.full_history_bytes + bytes
}

///|
/// X-05: visit the resident value through production scan instrumentation,
/// then count UTF-16 code units and Unicode scalars without a provider query.
fn EvidenceDetector::convert_resident_text_control(
  self : EvidenceDetector,
  text : String,
) -> Unit {
  self.scan_resident_value(text)
  let scalar_count = try! unicode_scalar_length(text)
  self.utf16_code_units = self.utf16_code_units + text.length()
  self.unicode_scalars = self.unicode_scalars + scalar_count
}

///|
/// Observe only the shared detector counters advanced since `before`.
fn EvidenceDetector::observe_positive_control(
  self : EvidenceDetector,
  case_id : String,
  before : EvidenceSnapshot,
  rejected? : Bool = false,
) -> PositiveControlObservation {
  {
    case_id,
    logical_queries: self.control_logical_queries -
    before.control_logical_queries,
    physical_reads: self.provider_calls - before.provider_calls,
    provider_operations: self.provider_operations - before.provider_operations,
    provider_bytes: self.provider_bytes - before.provider_bytes,
    in_memory_scans: self.in_memory_scans - before.in_memory_scans,
    metadata_records: self.metadata_records - before.metadata_records,
    metadata_bytes: self.metadata_bytes - before.metadata_bytes,
    proof_bytes: self.proof_bytes - before.proof_bytes,
    requested_identities: self.requested_identities -
    before.requested_identities,
    payload_events: self.payload_events - before.payload_events,
    payload_bytes: self.payload_bytes - before.payload_bytes,
    scan_records_visited: self.scan_records_visited -
    before.scan_records_visited,
    full_history_events: self.full_history_events - before.full_history_events,
    full_history_bytes: self.full_history_bytes - before.full_history_bytes,
    utf16_code_units: self.utf16_code_units - before.utf16_code_units,
    unicode_scalars: self.unicode_scalars - before.unicode_scalars,
    rejected,
  }
}

///|
/// Exercise all five independent operations through the production evidence
/// detector and return their observed snapshot deltas.
fn positive_control_observations(
  detector : EvidenceDetector,
  text : String,
  history_events~ : Int,
  history_bytes~ : Int,
  metadata_bytes~ : Int,
  proof_bytes~ : Int,
  payload_bytes~ : Int,
) -> Array[PositiveControlObservation] {
  let x01_before = detector.snapshot()
  detector.read_metadata_with_proof_control(
    records=history_events,
    metadata_bytes~,
    proof_bytes~,
  )
  let x01 = detector.observe_positive_control("X-01", x01_before)
  let x02_before = detector.snapshot()
  detector.read_payload_batch_control(
    requested_identities=2,
    payload_events=2,
    payload_bytes~,
  )
  let x02 = detector.observe_positive_control("X-02", x02_before)
  let x03_before = detector.snapshot()
  let x03_accepted = detector.scan_cold_records_noncompliantly_control(
    text,
    records=history_events,
  )
  let x03 = detector.observe_positive_control(
    "X-03",
    x03_before,
    rejected=!x03_accepted,
  )
  let x04_before = detector.snapshot()
  detector.read_full_history_control(events=history_events, bytes=history_bytes)
  let x04 = detector.observe_positive_control("X-04", x04_before)
  let x05_before = detector.snapshot()
  detector.convert_resident_text_control(text)
  let x05 = detector.observe_positive_control("X-05", x05_before)
  [x01, x02, x03, x04, x05]
}

///|
fn PositiveControlObservation::to_json(
  self : PositiveControlObservation,
) -> Json {
  Json::object({
    "record": "positive_control".to_json(),
    "logical_queries": self.logical_queries.to_json(),
    "physical_reads": self.physical_reads.to_json(),
    "provider_operations": self.provider_operations.to_json(),
    "provider_bytes": self.provider_bytes.to_json(),
    "in_memory_scans": self.in_memory_scans.to_json(),
    "metadata_records": self.metadata_records.to_json(),
    "metadata_bytes": self.metadata_bytes.to_json(),
    "proof_bytes": self.proof_bytes.to_json(),
    "requested_identities": self.requested_identities.to_json(),
    "payload_events": self.payload_events.to_json(),
    "payload_bytes": self.payload_bytes.to_json(),
    "scan_records_visited": self.scan_records_visited.to_json(),
    "full_history_events": self.full_history_events.to_json(),
    "full_history_bytes": self.full_history_bytes.to_json(),
    "utf16_code_units": self.utf16_code_units.to_json(),
    "unicode_scalars": self.unicode_scalars.to_json(),
    "rejected": self.rejected.to_json(),
  })
}
