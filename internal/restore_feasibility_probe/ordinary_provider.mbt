///|
/// Capture-only overlay shared by the resident snapshot and provider fixture.
struct OrdinaryOverlay {
  snapshot : OrdinarySnapshot
  metas : Array[OrdinaryEventMetaV2]
  full_history_bytes : Bytes
}

///|
/// Raw immutable records retained by the provider shell, never exposed to the core.
struct OrdinaryProviderMetaRecord {
  identity : RawIdentity
  meta_bytes : Bytes
  proof_bytes : Bytes
}

///|
struct OrdinaryProviderPayloadRecord {
  identity : RawIdentity
  body_bytes : Bytes
}

///|
/// Exact operation accounting for the three provider capabilities.
struct OrdinaryProviderCounters {
  mut logical_query_count : Int
  mut physical_read_calls : Int
  mut requested_id_count : Int
  mut returned_record_count : Int
  mut metadata_records : Int
  mut payload_events : Int
  mut physical_bytes : Int
  mut framing_bytes : Int
  mut metadata_bytes : Int
  mut proof_bytes : Int
  mut payload_bytes : Int
  mut index_nodes_read : Int
  planner_metadata_nodes_visited : Int
  mut resident_records_visited : Int
  resident_text_code_units_visited : Int
  resident_text_scalars_visited : Int
  scan_records_visited : Int
  mut full_history_events : Int
  mut full_history_bytes : Int
}

///|
struct OrdinaryProvider {
  snapshot_commit_id : Bytes
  meta_records : Array[OrdinaryProviderMetaRecord]
  payload_records : Array[OrdinaryProviderPayloadRecord]
  meta_index : Map[String, OrdinaryProviderMetaRecord]
  payload_index : Map[String, OrdinaryProviderPayloadRecord]
  full_history_bytes : Bytes
  metadata_unavailable : Bool
  payload_unavailable : Bool
  counters : OrdinaryProviderCounters
}

///|
enum MetaLookupResult {
  Found(Bytes, Bytes)
  MissingInAuthenticatedRange
  Unavailable
  Corrupt
}

///|
enum PayloadReadResult {
  Found(Bytes)
  Missing
  Unavailable
  Corrupt
}

///|
fn empty_provider_counters() -> OrdinaryProviderCounters {
  {
    logical_query_count: 0,
    physical_read_calls: 0,
    requested_id_count: 0,
    returned_record_count: 0,
    metadata_records: 0,
    payload_events: 0,
    physical_bytes: 0,
    framing_bytes: 0,
    metadata_bytes: 0,
    proof_bytes: 0,
    payload_bytes: 0,
    index_nodes_read: 0,
    planner_metadata_nodes_visited: 0,
    resident_records_visited: 0,
    resident_text_code_units_visited: 0,
    resident_text_scalars_visited: 0,
    scan_records_visited: 0,
    full_history_events: 0,
    full_history_bytes: 0,
  }
}

///|
fn validate_sorted_unique_identities(
  identities : Array[RawIdentity],
) -> Unit raise R0CodecError {
  for index, identity in identities {
    validate_raw_identity(identity)
    if index > 0 && compare_raw_identity(identities[index - 1], identity) >= 0 {
      raise R0CodecError::InvalidValue(
        detail="provider request is not sorted-unique",
      )
    }
  }
}

///|
fn encode_mmr_proof(proof : R0MmrProof) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_uvarint(buffer, proof.leaf_position)
  write_uvarint(buffer, proof.containing_peak_height)
  write_uvarint(buffer, proof.siblings.length())
  for sibling in proof.siblings {
    if sibling.direction != 0 && sibling.direction != 1 {
      raise R0CodecError::InvalidValue(detail="invalid proof direction")
    }
    buffer.write_byte(sibling.direction.to_byte())
    require_digest(sibling.digest, "invalid proof sibling digest")
    buffer.write_bytes(sibling.digest)
  }
  write_uvarint(buffer, proof.other_peaks.length())
  for peak in proof.other_peaks {
    if peak.height < 0 {
      raise R0CodecError::InvalidValue(detail="negative proof peak height")
    }
    write_uvarint(buffer, peak.height)
    require_digest(peak.digest, "invalid proof peak digest")
    buffer.write_bytes(peak.digest)
  }
  buffer.to_bytes()
}

///|
fn decode_mmr_proof(bytes : Bytes) -> R0MmrProof raise R0CodecError {
  let decoder = R0Decoder::_new(bytes)
  let leaf_position = decoder._read_uvarint()
  let containing_peak_height = decoder._read_uvarint()
  let sibling_count = decoder._read_count("proof sibling count exceeds input")
  let siblings : Array[MmrSibling] = []
  for _ in 0..<sibling_count {
    let direction = decoder.read_byte().to_int()
    if direction != 0 && direction != 1 {
      raise R0CodecError::MalformedEncoding(detail="invalid proof direction")
    }
    siblings.push({
      direction,
      digest: decoder._read_digest("invalid proof sibling digest"),
    })
  }
  let other_peak_count = decoder._read_count("proof peak count exceeds input")
  let other_peaks : Array[MmrPeak] = []
  for _ in 0..<other_peak_count {
    other_peaks.push({
      height: decoder._read_uvarint(),
      start: 0,
      digest: decoder._read_digest("invalid proof peak digest"),
    })
  }
  decoder._finish()
  if sibling_count != containing_peak_height {
    raise R0CodecError::MalformedEncoding(detail="proof sibling count mismatch")
  }
  {
    leaf_position,
    containing_peak_height,
    siblings,
    other_peaks,
    declared_sibling_count: sibling_count,
    declared_other_peak_count: other_peak_count,
    trailing_byte: false,
  }
}

///|
fn decode_event_meta_v2(
  bytes : Bytes,
) -> OrdinaryEventMetaV2 raise R0CodecError {
  let decoder = R0Decoder::_new(bytes)
  let identity = decoder._read_raw_identity()
  let kind = decoder.read_byte().to_int()
  if kind < 1 || kind > 3 {
    raise R0CodecError::MalformedEncoding(detail="invalid event kind")
  }
  let event_digest_v2 = decoder._read_digest("invalid event digest")
  let body_digest = decoder._read_digest("invalid body digest")
  let rank = decoder._read_uvarint()
  let parent_count = decoder._read_count("parent count exceeds input")
  let parents : Array[(RawIdentity, Bytes)] = []
  for index in 0..<parent_count {
    let parent = decoder._read_raw_identity()
    if index > 0 && compare_raw_identity(parents[index - 1].0, parent) >= 0 {
      raise R0CodecError::MalformedEncoding(
        detail="parents are not sorted-unique",
      )
    }
    parents.push((parent, decoder._read_digest("invalid parent digest")))
  }
  let predecessor = match decoder.read_byte() {
    0 => None
    1 =>
      Some(
        (
          decoder._read_raw_identity(),
          decoder._read_digest("invalid predecessor digest"),
        ),
      )
    _ =>
      raise R0CodecError::MalformedEncoding(detail="invalid predecessor option")
  }
  let reference_count = decoder._read_count("reference count exceeds input")
  let references : Array[(Int, RawIdentity, Bytes, Int)] = []
  for _ in 0..<reference_count {
    let role = decoder.read_byte().to_int()
    let reference = decoder._read_raw_identity()
    let digest = decoder._read_digest("invalid reference digest")
    let required_kind = decoder.read_byte().to_int()
    if role != 1 || required_kind != 1 {
      raise R0CodecError::MalformedEncoding(
        detail="invalid semantic reference tag",
      )
    }
    references.push((role, reference, digest, required_kind))
  }
  let payload_byte_length = decoder._read_uvarint()
  decoder._finish()
  if encode_event_digest_v2(
      identity, body_digest, rank, parents, predecessor, references,
    ) !=
    event_digest_v2 {
    raise R0CodecError::InvalidValue(detail="event digest mismatch")
  }
  {
    identity,
    body: None,
    kind,
    event_digest_v2,
    body_digest,
    causal_rank_timestamp: rank,
    declared_parents: parents,
    implicit_predecessor: predecessor,
    semantic_references: references,
    payload_byte_length,
  }
}

///|
fn resident_writer_for(
  snapshot : OrdinarySnapshot,
  identity : RawIdentity,
) -> OrdinaryWriterCommitment raise R0CodecError {
  for writer in snapshot.writer_commitments {
    if writer.agent == identity.agent {
      if identity.sequence >= writer.leaf_count {
        raise R0CodecError::InvalidValue(
          detail="identity is outside writer range",
        )
      }
      return writer
    }
  }
  raise R0CodecError::InvalidValue(detail="writer is absent")
}

///|
fn build_ordinary_capture_overlay(
  fixture : GeneratedFixture,
) -> OrdinaryOverlay raise R0CodecError {
  if fixture.events.is_empty() && fixture.replay_order.is_empty() {
    let snapshot = empty_snapshot(fixture.document_id, fixture.final_text)
    { snapshot, metas: [], full_history_bytes: Bytes::new(0) }
  } else {
    build_nonempty_overlay(fixture)
  }
}

///|
fn OrdinaryProviderCounters::total(self : OrdinaryProviderCounters) -> Int {
  self.logical_query_count +
  self.physical_read_calls +
  self.requested_id_count +
  self.returned_record_count +
  self.metadata_records +
  self.payload_events +
  self.physical_bytes +
  self.framing_bytes +
  self.metadata_bytes +
  self.proof_bytes +
  self.payload_bytes +
  self.index_nodes_read +
  self.planner_metadata_nodes_visited +
  self.resident_records_visited +
  self.resident_text_code_units_visited +
  self.resident_text_scalars_visited +
  self.scan_records_visited +
  self.full_history_events +
  self.full_history_bytes
}

///|
fn meta_result_is_found(result : MetaLookupResult) -> Bool {
  match result {
    MetaLookupResult::Found(meta, proof) =>
      meta.length() >= 0 && proof.length() >= 0
    MetaLookupResult::MissingInAuthenticatedRange
    | MetaLookupResult::Unavailable
    | MetaLookupResult::Corrupt => false
  }
}

///|
fn payload_result_is_found(result : PayloadReadResult) -> Bool {
  match result {
    PayloadReadResult::Found(bytes) => bytes.length() >= 0
    PayloadReadResult::Missing
    | PayloadReadResult::Unavailable
    | PayloadReadResult::Corrupt => false
  }
}

///|
fn encode_provider_fixture(
  overlay : OrdinaryOverlay,
) -> Bytes raise R0CodecError {
  let writer_groups : Map[String, Array[OrdinaryEventMetaV2]] = Default::default()
  for meta in overlay.metas {
    let group = writer_groups.get(meta.identity.agent).unwrap_or([])
    group.push(meta)
    writer_groups[meta.identity.agent] = group
  }
  let writer_mmrs : Map[String, R0Mmr] = Default::default()
  for agent, group in writer_groups {
    group.sort_by((left, right) => {
      left.identity.sequence.compare(right.identity.sequence)
    })
    writer_mmrs[agent] = R0Mmr::_from_leaf_hashes(
      group.map(meta => meta_leaf_hash_v2(meta)),
    )
  }
  let meta_records : Array[OrdinaryProviderMetaRecord] = []
  for meta in overlay.metas {
    let mmr = writer_mmrs[meta.identity.agent]
    let proof = try! mmr._inclusion_proof(meta.identity.sequence)
    meta_records.push({
      identity: meta.identity,
      meta_bytes: encode_event_meta_v2(meta),
      proof_bytes: encode_mmr_proof(proof),
    })
  }
  meta_records.sort_by((left, right) => {
    compare_raw_identity(left.identity, right.identity)
  })
  let payload_records : Array[OrdinaryProviderPayloadRecord] = []
  for meta in overlay.metas {
    payload_records.push({
      identity: meta.identity,
      body_bytes: encode_canonical_body(meta.body.unwrap()),
    })
  }
  payload_records.sort_by((left, right) => {
    compare_raw_identity(left.identity, right.identity)
  })
  let buffer = Buffer()
  write_domain(buffer, "loomark-r0-provider-fixture:v1")
  require_digest(
    overlay.snapshot.snapshot_commit_id,
    "invalid provider snapshot ID",
  )
  buffer.write_bytes(overlay.snapshot.snapshot_commit_id)
  write_uvarint(buffer, meta_records.length())
  for record in meta_records {
    write_raw_identity(buffer, record.identity)
    write_lp_bytes(buffer, record.meta_bytes)
    write_lp_bytes(buffer, record.proof_bytes)
  }
  write_uvarint(buffer, payload_records.length())
  for record in payload_records {
    write_raw_identity(buffer, record.identity)
    write_lp_bytes(buffer, record.body_bytes)
  }
  write_lp_bytes(buffer, overlay.full_history_bytes)
  buffer.to_bytes()
}

///|
fn OrdinaryProvider::new(bytes : Bytes) -> OrdinaryProvider raise R0CodecError {
  let decoder = R0Decoder::_new(bytes)
  let domain = decoder._read_lp_utf8()
  if domain != "loomark-r0-provider-fixture:v1" {
    raise R0CodecError::MalformedEncoding(
      detail="wrong provider fixture domain",
    )
  }
  let snapshot_commit_id = decoder._read_digest("invalid provider snapshot ID")
  let meta_count = decoder._read_count("metadata record count exceeds input")
  let meta_records : Array[OrdinaryProviderMetaRecord] = []
  for index in 0..<meta_count {
    let identity = decoder._read_raw_identity()
    let meta_bytes = decoder._read_lp_bytes()
    let decoded = decode_event_meta_v2(meta_bytes)
    if decoded.identity != identity {
      raise R0CodecError::InvalidValue(detail="metadata identity mismatch")
    }
    let proof_bytes = decoder._read_lp_bytes()
    ignore(decode_mmr_proof(proof_bytes))
    if index > 0 &&
      compare_raw_identity(meta_records[index - 1].identity, identity) >= 0 {
      raise R0CodecError::InvalidValue(detail="metadata records are not sorted")
    }
    meta_records.push({ identity, meta_bytes, proof_bytes })
  }
  let payload_count = decoder._read_count("payload record count exceeds input")
  let payload_records : Array[OrdinaryProviderPayloadRecord] = []
  for index in 0..<payload_count {
    let identity = decoder._read_raw_identity()
    let body_bytes = decoder._read_lp_bytes()
    if index > 0 &&
      compare_raw_identity(payload_records[index - 1].identity, identity) >= 0 {
      raise R0CodecError::InvalidValue(detail="payload records are not sorted")
    }
    payload_records.push({ identity, body_bytes })
  }
  let full_history_bytes = decoder._read_lp_bytes()
  decoder._finish()
  let meta_index : Map[String, OrdinaryProviderMetaRecord] = Map([])
  for record in meta_records {
    meta_index[raw_identity_key(record.identity)] = record
  }
  let payload_index : Map[String, OrdinaryProviderPayloadRecord] = Map([])
  for record in payload_records {
    payload_index[raw_identity_key(record.identity)] = record
  }
  {
    snapshot_commit_id,
    meta_records,
    payload_records,
    meta_index,
    payload_index,
    full_history_bytes,
    metadata_unavailable: false,
    payload_unavailable: false,
    counters: empty_provider_counters(),
  }
}

///|
fn OrdinaryProvider::_check_snapshot(
  self : OrdinaryProvider,
  snapshot_commit_id : Bytes,
) -> Bool {
  snapshot_commit_id == self.snapshot_commit_id
}

///|
fn OrdinaryProvider::lookup_event_meta_batch(
  self : OrdinaryProvider,
  snapshot_commit_id : Bytes,
  identities : Array[RawIdentity],
) -> Array[MetaLookupResult] raise R0CodecError {
  validate_sorted_unique_identities(identities)
  if !self._check_snapshot(snapshot_commit_id) {
    return identities.map(_ => MetaLookupResult::Corrupt)
  }
  self.counters.logical_query_count += 1
  self.counters.physical_read_calls += 1
  self.counters.requested_id_count += identities.length()
  if self.metadata_unavailable {
    return identities.map(_ => MetaLookupResult::Unavailable)
  }
  let _unused_unavailable = MetaLookupResult::Unavailable
  ignore(_unused_unavailable)
  let results : Array[MetaLookupResult] = []
  let mut returned_bytes = 0
  let mut framing_bytes = 0
  for identity in identities {
    match self.meta_index.get(raw_identity_key(identity)) {
      Some(record) => {
        returned_bytes += record.meta_bytes.length() +
          record.proof_bytes.length()
        framing_bytes += encode_uvarint(record.meta_bytes.length()).length() +
          encode_uvarint(record.proof_bytes.length()).length()
        let proof = try! decode_mmr_proof(record.proof_bytes)
        self.counters.index_nodes_read += proof.siblings.length() +
          proof.other_peaks.length()
        results.push(
          MetaLookupResult::Found(record.meta_bytes, record.proof_bytes),
        )
      }
      None => results.push(MetaLookupResult::MissingInAuthenticatedRange)
    }
  }
  self.counters.metadata_records += results.fold(init=0, (total, result) => {
    match result {
      MetaLookupResult::Found(_, _) => total + 1
      _ => total
    }
  })
  self.counters.returned_record_count += results.fold(init=0, (total, result) => {
    match result {
      MetaLookupResult::Found(_, _) => total + 1
      _ => total
    }
  })
  self.counters.metadata_bytes += results.fold(init=0, (total, result) => {
    match result {
      MetaLookupResult::Found(meta, _) => total + meta.length()
      _ => total
    }
  })
  self.counters.proof_bytes += results.fold(init=0, (total, result) => {
    match result {
      MetaLookupResult::Found(_, proof) => total + proof.length()
      _ => total
    }
  })
  self.counters.framing_bytes += framing_bytes
  self.counters.physical_bytes += returned_bytes + framing_bytes
  ignore(results.map(meta_result_is_found))
  ignore(self.counters.total())
  results
}

///|
#warnings("-unused_value")
fn OrdinaryProvider::read_event_payload_batch(
  self : OrdinaryProvider,
  snapshot_commit_id : Bytes,
  identities : Array[RawIdentity],
) -> Array[PayloadReadResult] raise R0CodecError {
  validate_sorted_unique_identities(identities)
  if !self._check_snapshot(snapshot_commit_id) {
    return identities.map(_ => PayloadReadResult::Corrupt)
  }
  self.counters.logical_query_count += 1
  self.counters.physical_read_calls += 1
  self.counters.requested_id_count += identities.length()
  if self.payload_unavailable {
    return identities.map(_ => PayloadReadResult::Unavailable)
  }
  let _unused_unavailable = PayloadReadResult::Unavailable
  ignore(_unused_unavailable)
  let results : Array[PayloadReadResult] = []
  let mut returned_bytes = 0
  let mut framing_bytes = 0
  for identity in identities {
    match self.payload_index.get(raw_identity_key(identity)) {
      Some(record) => {
        returned_bytes += record.body_bytes.length()
        framing_bytes += encode_uvarint(record.body_bytes.length()).length()
        results.push(PayloadReadResult::Found(record.body_bytes))
      }
      None => results.push(PayloadReadResult::Missing)
    }
  }
  self.counters.payload_events += results.fold(init=0, (total, result) => {
    match result {
      PayloadReadResult::Found(_) => total + 1
      _ => total
    }
  })
  self.counters.returned_record_count += results.fold(init=0, (total, result) => {
    match result {
      PayloadReadResult::Found(_) => total + 1
      _ => total
    }
  })
  self.counters.payload_bytes += returned_bytes
  self.counters.framing_bytes += framing_bytes
  self.counters.physical_bytes += returned_bytes + framing_bytes
  ignore(results.map(payload_result_is_found))
  ignore(self.counters.total())
  results
}

///|
#warnings("-unused_value")
fn OrdinaryProvider::read_full_history(
  self : OrdinaryProvider,
  snapshot_commit_id : Bytes,
) -> Bytes raise R0CodecError {
  if !self._check_snapshot(snapshot_commit_id) {
    raise R0CodecError::InvalidValue(detail="full-history snapshot mismatch")
  }
  self.counters.logical_query_count += 1
  self.counters.physical_read_calls += 1
  self.counters.full_history_events += self.payload_records.length()
  self.counters.full_history_bytes += self.full_history_bytes.length()
  let framing_bytes = encode_uvarint(self.full_history_bytes.length()).length()
  self.counters.framing_bytes += framing_bytes
  self.counters.physical_bytes += self.full_history_bytes.length() +
    framing_bytes
  ignore(self.counters.total())
  self.full_history_bytes
}

///|
#warnings("-unused_value")
fn lookup_event_meta_tier0_then_provider(
  snapshot : OrdinarySnapshot,
  provider : OrdinaryProvider,
  identities : Array[RawIdentity],
) -> Array[MetaLookupResult] raise R0CodecError {
  validate_sorted_unique_identities(identities)
  let in_range : Array[RawIdentity] = []
  for identity in identities {
    let mut present = false
    for writer in snapshot.writer_commitments {
      provider.counters.resident_records_visited += 1
      if writer.agent == identity.agent && identity.sequence < writer.leaf_count {
        present = true
      }
    }
    if present {
      ignore(resident_writer_for(snapshot, identity))
      in_range.push(identity)
    }
  }
  let fetched = if in_range.is_empty() {
    []
  } else {
    provider.lookup_event_meta_batch(snapshot.snapshot_commit_id, in_range)
  }
  let results : Array[MetaLookupResult] = []
  let mut fetched_index = 0
  for identity in identities {
    let mut present = false
    for writer in snapshot.writer_commitments {
      provider.counters.resident_records_visited += 1
      if writer.agent == identity.agent && identity.sequence < writer.leaf_count {
        present = true
      }
    }
    if present {
      results.push(fetched[fetched_index])
      fetched_index += 1
    } else {
      results.push(MetaLookupResult::MissingInAuthenticatedRange)
    }
  }
  results
}
