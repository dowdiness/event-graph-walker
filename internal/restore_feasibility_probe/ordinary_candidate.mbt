///|
/// The resident R0 snapshot fields, kept separate from the derived commit ID.
struct OrdinaryHeadRecord {
  identity : RawIdentity
  event_digest_v2 : Bytes
  causal_rank_timestamp : Int
}

///|
struct OrdinaryWriterCommitment {
  agent : String
  leaf_count : Int
  tip_event_digest_v2 : Bytes
  event_meta_mmr_root_v2 : Bytes
}

///|
struct OrdinarySnapshot {
  document_id_sha256 : Bytes
  graph_root_v2 : Bytes
  exact_raw_heads : Array[RawIdentity]
  exact_raw_heads_sha256 : Bytes
  exact_head_records : Array[OrdinaryHeadRecord]
  writer_commitments : Array[OrdinaryWriterCommitment]
  document_text_byte_length : Int
  document_text_scalar_length : Int
  document_text_sha256 : Bytes
  snapshot_commit_id : Bytes
}

///|
struct OrdinaryCandidateCapture {
  candidate_bytes : Bytes
  snapshot_commit_id : Bytes
}

///|
struct OrdinaryReadAccounting {
  metadata_queries : Int
  payload_queries : Int
  full_history_queries : Int
  scan_records_visited : Int
}

///|
struct OrdinaryRestoredCandidate {
  document_text : String
  snapshot : OrdinarySnapshot
  reads : OrdinaryReadAccounting
}

///|
fn require_digest(value : Bytes, detail : String) -> Unit raise R0CodecError {
  if value.length() != 32 {
    raise R0CodecError::MalformedEncoding(detail~)
  }
}

///|
fn require_nonnegative(value : Int, detail : String) -> Unit raise R0CodecError {
  if value < 0 {
    raise R0CodecError::MalformedEncoding(detail~)
  }
}

///|
fn R0Decoder::_remaining(self : R0Decoder) -> Int {
  self.bytes.length() - self.position
}

///|
fn R0Decoder::_read_exact(
  self : R0Decoder,
  length : Int,
) -> Bytes raise R0CodecError {
  if length < 0 || length > self._remaining() {
    raise R0CodecError::MalformedEncoding(detail="length exceeds input")
  }
  let result = self.bytes
    .view(start=self.position, end=self.position + length)
    .to_owned()
  self.position = self.position + length
  result
}

///|
fn R0Decoder::_read_lp_bytes(self : R0Decoder) -> Bytes raise R0CodecError {
  let length = self._read_uvarint()
  self._read_exact(length)
}

///|
fn R0Decoder::_read_lp_utf8(self : R0Decoder) -> String raise R0CodecError {
  let bytes = self._read_lp_bytes()
  let value = @utf8.decode(bytes.view()) catch {
    _ => raise R0CodecError::MalformedEncoding(detail="invalid UTF-8")
  }
  if strict_utf8(value) != bytes {
    raise R0CodecError::MalformedEncoding(detail="non-canonical UTF-8")
  }
  value
}

///|
fn R0Decoder::_read_digest(
  self : R0Decoder,
  detail : String,
) -> Bytes raise R0CodecError {
  let value = self._read_exact(32)
  require_digest(value, detail)
  value
}

///|
fn R0Decoder::_read_raw_identity(
  self : R0Decoder,
) -> RawIdentity raise R0CodecError {
  let identity = RawIdentity(
    agent=self._read_lp_utf8(),
    sequence=self._read_uvarint(),
  )
  validate_raw_identity(identity)
  identity
}

///|
fn R0Decoder::_read_count(
  self : R0Decoder,
  detail : String,
) -> Int raise R0CodecError {
  let count = self._read_uvarint()
  if count > self._remaining() {
    raise R0CodecError::MalformedEncoding(detail~)
  }
  count
}

///|
fn encode_graph_root(
  heads : Array[OrdinaryHeadRecord],
) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_domain(buffer, "loomark-r0-graph:v2")
  write_uvarint(buffer, heads.length())
  for head in heads {
    validate_raw_identity(head.identity)
    require_digest(head.event_digest_v2, "invalid head event digest")
    require_nonnegative(head.causal_rank_timestamp, "negative head rank")
    write_raw_identity(buffer, head.identity)
    buffer.write_bytes(head.event_digest_v2)
    write_uvarint(buffer, head.causal_rank_timestamp)
  }
  sha256(buffer.to_bytes())
}

///|
fn encode_exact_heads_hash(
  heads : Array[RawIdentity],
) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_domain(buffer, "loomark-r0-heads:v1")
  write_uvarint(buffer, heads.length())
  for identity in heads {
    validate_raw_identity(identity)
    write_raw_identity(buffer, identity)
  }
  sha256(buffer.to_bytes())
}

///|
fn validate_snapshot(snapshot : OrdinarySnapshot) -> Unit raise R0CodecError {
  require_digest(snapshot.document_id_sha256, "invalid document ID digest")
  require_digest(snapshot.graph_root_v2, "invalid graph root")
  require_digest(snapshot.exact_raw_heads_sha256, "invalid exact-head hash")
  require_digest(snapshot.document_text_sha256, "invalid text hash")
  require_nonnegative(
    snapshot.document_text_byte_length,
    "negative document byte length",
  )
  require_nonnegative(
    snapshot.document_text_scalar_length,
    "negative document scalar length",
  )
  if snapshot.exact_raw_heads.length() != snapshot.exact_head_records.length() {
    raise R0CodecError::InvalidValue(detail="head projection length mismatch")
  }
  for index, identity in snapshot.exact_raw_heads {
    validate_raw_identity(identity)
    if index > 0 &&
      compare_raw_identity(snapshot.exact_raw_heads[index - 1], identity) >= 0 {
      raise R0CodecError::InvalidValue(detail="heads are not strictly sorted")
    }
    let record = snapshot.exact_head_records[index]
    if record.identity != identity {
      raise R0CodecError::InvalidValue(detail="head projection mismatch")
    }
    require_digest(record.event_digest_v2, "invalid head event digest")
    require_nonnegative(record.causal_rank_timestamp, "negative head rank")
  }
  for index, writer in snapshot.writer_commitments {
    if writer.agent.length() == 0 {
      raise R0CodecError::InvalidValue(detail="empty writer agent")
    }
    validate_utf16(writer.agent)
    if index > 0 &&
      compare_utf8_bytes(
        snapshot.writer_commitments[index - 1].agent,
        writer.agent,
      ) >=
      0 {
      raise R0CodecError::InvalidValue(detail="writers are not strictly sorted")
    }
    if writer.leaf_count <= 0 || writer.leaf_count > 0x7fff_ffff {
      raise R0CodecError::InvalidValue(
        detail="writer leaf count outside R0 bounds",
      )
    }
    require_digest(writer.tip_event_digest_v2, "invalid writer tip digest")
    require_digest(writer.event_meta_mmr_root_v2, "invalid writer MMR root")
  }
  for index, writer in snapshot.writer_commitments {
    if index > 0 && snapshot.writer_commitments[index - 1].agent == writer.agent {
      raise R0CodecError::InvalidValue(detail="duplicate writer commitment")
    }
  }
  for identity in snapshot.exact_raw_heads {
    let mut matching_writer : OrdinaryWriterCommitment? = None
    for writer in snapshot.writer_commitments {
      if writer.agent == identity.agent {
        matching_writer = Some(writer)
      }
    }
    guard matching_writer is Some(writer) else {
      raise R0CodecError::InvalidValue(detail="head writer is absent")
    }
    if identity.sequence != writer.leaf_count - 1 {
      raise R0CodecError::InvalidValue(detail="head is not writer tip")
    }
  }
  for record in snapshot.exact_head_records {
    let mut matching_writer : OrdinaryWriterCommitment? = None
    for writer in snapshot.writer_commitments {
      if writer.agent == record.identity.agent {
        matching_writer = Some(writer)
      }
    }
    guard matching_writer is Some(writer) else {
      raise R0CodecError::InvalidValue(detail="head writer is absent")
    }
    if record.identity.sequence != writer.leaf_count - 1 ||
      record.event_digest_v2 != writer.tip_event_digest_v2 {
      raise R0CodecError::InvalidValue(detail="head does not equal writer tip")
    }
  }
  if snapshot.exact_raw_heads_sha256 !=
    encode_exact_heads_hash(snapshot.exact_raw_heads) {
    raise R0CodecError::InvalidValue(detail="exact-head hash mismatch")
  }
  if snapshot.graph_root_v2 != encode_graph_root(snapshot.exact_head_records) {
    raise R0CodecError::InvalidValue(detail="graph root mismatch")
  }
}

///|
fn encode_snapshot_fields(
  snapshot : OrdinarySnapshot,
) -> Bytes raise R0CodecError {
  validate_snapshot(snapshot)
  let buffer = Buffer()
  buffer.write_bytes(snapshot.document_id_sha256)
  buffer.write_bytes(snapshot.graph_root_v2)
  write_uvarint(buffer, snapshot.exact_raw_heads.length())
  for identity in snapshot.exact_raw_heads {
    write_raw_identity(buffer, identity)
  }
  buffer.write_bytes(snapshot.exact_raw_heads_sha256)
  write_uvarint(buffer, snapshot.exact_head_records.length())
  for record in snapshot.exact_head_records {
    write_raw_identity(buffer, record.identity)
    buffer.write_bytes(record.event_digest_v2)
    write_uvarint(buffer, record.causal_rank_timestamp)
  }
  write_uvarint(buffer, snapshot.writer_commitments.length())
  for writer in snapshot.writer_commitments {
    write_lp_utf8(buffer, writer.agent)
    write_uvarint(buffer, writer.leaf_count)
    buffer.write_bytes(writer.tip_event_digest_v2)
    buffer.write_bytes(writer.event_meta_mmr_root_v2)
  }
  write_uvarint(buffer, snapshot.document_text_byte_length)
  write_uvarint(buffer, snapshot.document_text_scalar_length)
  buffer.write_bytes(snapshot.document_text_sha256)
  buffer.to_bytes()
}

///|
fn derive_snapshot_commit_id(
  snapshot : OrdinarySnapshot,
) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_domain(buffer, "loomark-r0-snapshot:v2")
  buffer.write_bytes(encode_snapshot_fields(snapshot))
  sha256(buffer.to_bytes())
}

///|
fn encode_candidate(
  snapshot : OrdinarySnapshot,
  text : String,
) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_domain(buffer, "loomark-r0-paper-branch-candidate:v1")
  write_lp_utf8(buffer, text)
  buffer.write_bytes(encode_snapshot_fields(snapshot))
  buffer.to_bytes()
}

///|
struct OrdinaryEventMetaV2 {
  identity : RawIdentity
  body : CanonicalBody
  kind : Int
  event_digest_v2 : Bytes
  body_digest : Bytes
  causal_rank_timestamp : Int
  declared_parents : Array[(RawIdentity, Bytes)]
  implicit_predecessor : (RawIdentity, Bytes)?
  semantic_references : Array[(Int, RawIdentity, Bytes, Int)]
  payload_byte_length : Int
}

///|
fn event_kind(body : CanonicalBody) -> Int {
  match body {
    InsertScalar(_, _) => 1
    DeleteScalar(_) => 2
    Undelete(_) => 3
  }
}

///|
fn encode_event_digest_v2(
  identity : RawIdentity,
  body_digest : Bytes,
  rank : Int,
  parents : Array[(RawIdentity, Bytes)],
  predecessor : (RawIdentity, Bytes)?,
  references : Array[(Int, RawIdentity, Bytes, Int)],
) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_domain(buffer, "loomark-r0-event:v2")
  write_raw_identity(buffer, identity)
  require_digest(body_digest, "invalid body digest")
  buffer.write_bytes(body_digest)
  require_nonnegative(rank, "negative event rank")
  write_uvarint(buffer, rank)
  write_uvarint(buffer, parents.length())
  for item in parents {
    let (parent, digest) = item
    write_raw_identity(buffer, parent)
    require_digest(digest, "invalid parent digest")
    buffer.write_bytes(digest)
  }
  match predecessor {
    None => buffer.write_byte(b'\x00')
    Some((predecessor_identity, digest)) => {
      buffer.write_byte(b'\x01')
      write_raw_identity(buffer, predecessor_identity)
      require_digest(digest, "invalid predecessor digest")
      buffer.write_bytes(digest)
    }
  }
  write_uvarint(buffer, references.length())
  for item in references {
    let (role, reference, digest, required_kind) = item
    buffer.write_byte(role.to_byte())
    write_raw_identity(buffer, reference)
    require_digest(digest, "invalid semantic reference digest")
    buffer.write_bytes(digest)
    buffer.write_byte(required_kind.to_byte())
  }
  sha256(buffer.to_bytes())
}

///|
fn encode_event_meta_v2(meta : OrdinaryEventMetaV2) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_raw_identity(buffer, meta.identity)
  if meta.kind < 0 || meta.kind > 0xff {
    raise R0CodecError::InvalidValue(detail="invalid event kind")
  }
  buffer.write_byte(meta.kind.to_byte())
  require_digest(meta.event_digest_v2, "invalid event digest")
  buffer.write_bytes(meta.event_digest_v2)
  require_digest(meta.body_digest, "invalid body digest")
  buffer.write_bytes(meta.body_digest)
  require_nonnegative(meta.causal_rank_timestamp, "negative event rank")
  write_uvarint(buffer, meta.causal_rank_timestamp)
  write_uvarint(buffer, meta.declared_parents.length())
  for item in meta.declared_parents {
    let (parent, digest) = item
    write_raw_identity(buffer, parent)
    require_digest(digest, "invalid parent digest")
    buffer.write_bytes(digest)
  }
  match meta.implicit_predecessor {
    None => buffer.write_byte(b'\x00')
    Some((predecessor, digest)) => {
      buffer.write_byte(b'\x01')
      write_raw_identity(buffer, predecessor)
      require_digest(digest, "invalid predecessor digest")
      buffer.write_bytes(digest)
    }
  }
  write_uvarint(buffer, meta.semantic_references.length())
  for item in meta.semantic_references {
    let (role, reference, digest, required_kind) = item
    buffer.write_byte(role.to_byte())
    write_raw_identity(buffer, reference)
    require_digest(digest, "invalid semantic reference digest")
    buffer.write_bytes(digest)
    buffer.write_byte(required_kind.to_byte())
  }
  require_nonnegative(meta.payload_byte_length, "negative payload length")
  write_uvarint(buffer, meta.payload_byte_length)
  buffer.to_bytes()
}

///|
fn meta_leaf_hash_v2(meta : OrdinaryEventMetaV2) -> Bytes raise R0CodecError {
  let buffer = Buffer()
  write_domain(buffer, "loomark-r0-meta-leaf:v2")
  buffer.write_bytes(encode_event_meta_v2(meta))
  sha256(buffer.to_bytes())
}

///|
fn writer_commitment(
  agent : String,
  metas : Array[OrdinaryEventMetaV2],
) -> OrdinaryWriterCommitment raise R0CodecError {
  if metas.is_empty() {
    raise R0CodecError::InvalidValue(detail="empty writer metadata")
  }
  metas.sort_by((left, right) => {
    left.identity.sequence.compare(right.identity.sequence)
  })
  for index, meta in metas {
    if meta.identity.sequence != index {
      raise R0CodecError::InvalidValue(
        detail="writer sequences are not contiguous",
      )
    }
  }
  let leaves = metas.map(meta => meta_leaf_hash_v2(meta))
  let mmr = R0Mmr::_from_leaf_hashes(leaves)
  {
    agent,
    leaf_count: metas.length(),
    tip_event_digest_v2: metas[metas.length() - 1].event_digest_v2,
    event_meta_mmr_root_v2: mmr._writer_root(agent),
  }
}

///|
fn build_nonempty_snapshot(
  fixture : GeneratedFixture,
) -> OrdinarySnapshot raise R0CodecError {
  let events_by_key : Map[String, FixtureEvent] = Default::default()
  for event in fixture.events {
    validate_raw_identity(event.identity)
    let key = raw_identity_key(event.identity)
    if events_by_key.contains(key) {
      raise R0CodecError::InvalidValue(detail="duplicate event identity")
    }
    events_by_key[key] = event
  }
  let metas_by_key : Map[String, OrdinaryEventMetaV2] = Default::default()
  let replayed : Map[String, Bool] = Default::default()
  let metas : Array[OrdinaryEventMetaV2] = []
  for identity in fixture.replay_order {
    let key = raw_identity_key(identity)
    guard events_by_key.get(key) is Some(event) else {
      raise R0CodecError::InvalidValue(
        detail="replay order references missing event",
      )
    }
    if replayed.contains(key) {
      raise R0CodecError::InvalidValue(detail="duplicate replay identity")
    }
    let sorted_parents = event.parents.copy()
    sorted_parents.sort_by(compare_raw_identity)
    for index, parent in sorted_parents {
      validate_raw_identity(parent)
      if index > 0 && sorted_parents[index - 1] == parent {
        raise R0CodecError::InvalidValue(
          detail="duplicate_declared_parent_unsupported",
        )
      }
    }
    let parent_records : Array[(RawIdentity, Bytes)] = []
    let max_parent_rank : Int? = None
    let mut maximum_parent_rank : Int? = max_parent_rank
    for parent in sorted_parents {
      guard metas_by_key.get(raw_identity_key(parent)) is Some(parent_meta) else {
        raise R0CodecError::InvalidValue(
          detail="replay order is not topological",
        )
      }
      parent_records.push((parent, parent_meta.event_digest_v2))
      maximum_parent_rank = Some(
        match maximum_parent_rank {
          None => parent_meta.causal_rank_timestamp
          Some(current) => current.max(parent_meta.causal_rank_timestamp)
        },
      )
    }
    let rank = match maximum_parent_rank {
      None => 0
      Some(parent_rank) => {
        if parent_rank >= 0x7fff_ffff {
          raise R0CodecError::InvalidValue(detail="event rank exhausted")
        }
        parent_rank + 1
      }
    }
    let predecessor = if event.identity.sequence == 0 {
      None
    } else {
      let predecessor_identity = RawIdentity(
        agent=event.identity.agent,
        sequence=event.identity.sequence - 1,
      )
      guard metas_by_key.get(raw_identity_key(predecessor_identity))
        is Some(predecessor_meta) else {
        raise R0CodecError::InvalidValue(detail="missing implicit predecessor")
      }
      Some((predecessor_identity, predecessor_meta.event_digest_v2))
    }
    let references : Array[(Int, RawIdentity, Bytes, Int)] = match event.body {
      Undelete(target) => {
        guard metas_by_key.get(raw_identity_key(target)) is Some(target_meta) else {
          raise R0CodecError::InvalidValue(detail="missing undelete target")
        }
        if target_meta.kind != 1 {
          raise R0CodecError::InvalidValue(
            detail="undelete target is not insert",
          )
        }
        [(1, target, target_meta.event_digest_v2, 1)]
      }
      _ => []
    }
    let canonical_body_bytes = encode_canonical_body(event.body)
    if canonical_body_bytes != event.canonical_body_bytes {
      raise R0CodecError::InvalidValue(detail="canonical body bytes mismatch")
    }
    let body_digest = _canonical_body_digest(event.body)
    let event_digest_v2 = encode_event_digest_v2(
      event.identity,
      body_digest,
      rank,
      parent_records,
      predecessor,
      references,
    )
    let meta : OrdinaryEventMetaV2 = {
      identity: event.identity,
      body: event.body,
      kind: event_kind(event.body),
      event_digest_v2,
      body_digest,
      causal_rank_timestamp: rank,
      declared_parents: parent_records,
      implicit_predecessor: predecessor,
      semantic_references: references,
      payload_byte_length: canonical_body_bytes.length(),
    }
    metas_by_key[key] = meta
    replayed[key] = true
    metas.push(meta)
  }
  if metas.length() != fixture.events.length() {
    raise R0CodecError::InvalidValue(detail="replay order is incomplete")
  }
  let head_map : Map[String, RawIdentity] = Default::default()
  for meta in metas {
    head_map[raw_identity_key(meta.identity)] = meta.identity
  }
  for meta in metas {
    for item in meta.declared_parents {
      let (parent, _) = item
      head_map.remove(raw_identity_key(parent))
    }
  }
  let head_records : Array[OrdinaryHeadRecord] = []
  for _, identity in head_map {
    let meta = metas_by_key[raw_identity_key(identity)]
    head_records.push({
      identity,
      event_digest_v2: meta.event_digest_v2,
      causal_rank_timestamp: meta.causal_rank_timestamp,
    })
  }
  head_records.sort_by((left, right) => {
    compare_raw_identity(left.identity, right.identity)
  })
  let exact_raw_heads = head_records.map(record => record.identity)
  let writer_groups : Map[String, Array[OrdinaryEventMetaV2]] = Default::default()
  for meta in metas {
    let group = writer_groups.get(meta.identity.agent).unwrap_or([])
    group.push(meta)
    writer_groups[meta.identity.agent] = group
  }
  let writer_commitments : Array[OrdinaryWriterCommitment] = []
  for agent, group in writer_groups {
    writer_commitments.push(writer_commitment(agent, group))
  }
  writer_commitments.sort_by((left, right) => {
    compare_utf8_bytes(left.agent, right.agent)
  })
  let text_bytes = strict_utf8(fixture.final_text)
  let snapshot : OrdinarySnapshot = {
    document_id_sha256: sha256(strict_utf8(fixture.document_id)),
    graph_root_v2: encode_graph_root(head_records),
    exact_raw_heads,
    exact_raw_heads_sha256: encode_exact_heads_hash(exact_raw_heads),
    exact_head_records: head_records,
    writer_commitments,
    document_text_byte_length: text_bytes.length(),
    document_text_scalar_length: unicode_scalar_length(fixture.final_text),
    document_text_sha256: sha256(text_bytes),
    snapshot_commit_id: Bytes::new(0),
  }
  { ..snapshot, snapshot_commit_id: derive_snapshot_commit_id(snapshot) }
}

///|
fn empty_snapshot(
  document_id : String,
  text : String,
) -> OrdinarySnapshot raise R0CodecError {
  let document_id_bytes = strict_utf8(document_id)
  let text_bytes = strict_utf8(text)
  let heads : Array[OrdinaryHeadRecord] = []
  let exact_raw_heads : Array[RawIdentity] = []
  let snapshot : OrdinarySnapshot = {
    document_id_sha256: sha256(document_id_bytes),
    graph_root_v2: encode_graph_root(heads),
    exact_raw_heads,
    exact_raw_heads_sha256: encode_exact_heads_hash(exact_raw_heads),
    exact_head_records: heads,
    writer_commitments: [],
    document_text_byte_length: text_bytes.length(),
    document_text_scalar_length: unicode_scalar_length(text),
    document_text_sha256: sha256(text_bytes),
    snapshot_commit_id: Bytes::new(0),
  }
  { ..snapshot, snapshot_commit_id: derive_snapshot_commit_id(snapshot) }
}

///|
fn decode_snapshot(
  decoder : R0Decoder,
  text : String,
) -> OrdinarySnapshot raise R0CodecError {
  let document_id_sha256 = decoder._read_digest("invalid document ID digest")
  let graph_root_v2 = decoder._read_digest("invalid graph root")
  let head_count = decoder._read_count("head count exceeds input")
  let exact_raw_heads : Array[RawIdentity] = []
  for _ in 0..<head_count {
    exact_raw_heads.push(decoder._read_raw_identity())
  }
  let exact_raw_heads_sha256 = decoder._read_digest("invalid exact-head hash")
  let record_count = decoder._read_count("head-record count exceeds input")
  let exact_head_records : Array[OrdinaryHeadRecord] = []
  for _ in 0..<record_count {
    exact_head_records.push({
      identity: decoder._read_raw_identity(),
      event_digest_v2: decoder._read_digest("invalid head event digest"),
      causal_rank_timestamp: decoder._read_uvarint(),
    })
  }
  let writer_count = decoder._read_count("writer count exceeds input")
  let writer_commitments : Array[OrdinaryWriterCommitment] = []
  for _ in 0..<writer_count {
    writer_commitments.push({
      agent: decoder._read_lp_utf8(),
      leaf_count: decoder._read_uvarint(),
      tip_event_digest_v2: decoder._read_digest("invalid writer tip digest"),
      event_meta_mmr_root_v2: decoder._read_digest("invalid writer MMR root"),
    })
  }
  let document_text_byte_length = decoder._read_uvarint()
  let document_text_scalar_length = decoder._read_uvarint()
  let document_text_sha256 = decoder._read_digest("invalid text hash")
  let snapshot : OrdinarySnapshot = {
    document_id_sha256,
    graph_root_v2,
    exact_raw_heads,
    exact_raw_heads_sha256,
    exact_head_records,
    writer_commitments,
    document_text_byte_length,
    document_text_scalar_length,
    document_text_sha256,
    snapshot_commit_id: Bytes::new(0),
  }
  validate_snapshot(snapshot)
  let text_bytes = strict_utf8(text)
  if snapshot.document_text_byte_length != text_bytes.length() ||
    snapshot.document_text_scalar_length != unicode_scalar_length(text) ||
    snapshot.document_text_sha256 != sha256(text_bytes) {
    raise R0CodecError::InvalidValue(detail="document text commitment mismatch")
  }
  let snapshot_commit_id = derive_snapshot_commit_id(snapshot)
  { ..snapshot, snapshot_commit_id, }
}

///|
fn capture_paper_branch_candidate(
  fixture : GeneratedFixture,
) -> OrdinaryCandidateCapture raise R0CodecError {
  if fixture.events.length() == 0 && fixture.replay_order.length() == 0 {
    if fixture.final_text == "" {
      let snapshot = empty_snapshot(fixture.document_id, fixture.final_text)
      return {
        candidate_bytes: encode_candidate(snapshot, fixture.final_text),
        snapshot_commit_id: snapshot.snapshot_commit_id,
      }
    }
    raise R0CodecError::InvalidValue(
      detail="fixture is not a settled candidate",
    )
  }
  let snapshot = build_nonempty_snapshot(fixture)
  {
    candidate_bytes: encode_candidate(snapshot, fixture.final_text),
    snapshot_commit_id: snapshot.snapshot_commit_id,
  }
}

///|
fn validate_paper_branch_candidate(
  candidate_bytes : Bytes,
) -> OrdinaryRestoredCandidate raise R0CodecError {
  let decoder = R0Decoder::_new(candidate_bytes)
  let domain = decoder._read_lp_utf8()
  if domain != "loomark-r0-paper-branch-candidate:v1" {
    raise R0CodecError::MalformedEncoding(detail="wrong candidate domain")
  }
  let document_text = decoder._read_lp_utf8()
  let snapshot = decode_snapshot(decoder, document_text)
  decoder._finish()
  if snapshot.snapshot_commit_id != derive_snapshot_commit_id(snapshot) {
    raise R0CodecError::InvalidValue(detail="snapshot commit ID mismatch")
  }
  {
    document_text,
    snapshot,
    reads: {
      metadata_queries: 0,
      payload_queries: 0,
      full_history_queries: 0,
      scan_records_visited: 0,
    },
  }
}

///|
fn validate_published_paper_branch_candidate(
  candidate_bytes : Bytes,
  expected_snapshot_commit_id_hex~ : String,
) -> OrdinaryRestoredCandidate raise R0CodecError {
  if expected_snapshot_commit_id_hex.length() != 64 ||
    !expected_snapshot_commit_id_hex.all(char => {
      (char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')
    }) {
    raise R0CodecError::InvalidValue(
      detail="invalid expected snapshot commit ID",
    )
  }
  let restored = validate_paper_branch_candidate(candidate_bytes)
  if bytes_hex(restored.snapshot.snapshot_commit_id) !=
    expected_snapshot_commit_id_hex {
    raise R0CodecError::InvalidValue(detail="snapshot commit ID mismatch")
  }
  restored
}

///|
/// Immutable local runtime state for a validated candidate and one fresh writer.
struct OrdinaryPaperBranchState {
  document_text : String
  snapshot : OrdinarySnapshot
  fresh_writer : String
  fresh_writer_metas : Array[OrdinaryEventMetaV2]
}

///|
/// Pure local insert transition and its explicit provider-read accounting.
struct OrdinaryLocalInsertResult {
  state : OrdinaryPaperBranchState
  event : OrdinaryEventMetaV2
  reads : OrdinaryReadAccounting
}

///|
/// Pure local delete transition and its explicit provider-read accounting.
struct OrdinaryLocalDeleteResult {
  state : OrdinaryPaperBranchState
  event : OrdinaryEventMetaV2
  reads : OrdinaryReadAccounting
}

///|
/// R0 bounded negative that preserves the unmodified branch.
struct OrdinaryNegativeResult {
  state : OrdinaryPaperBranchState
  reason : String
  reads : OrdinaryReadAccounting
}

///|
fn copy_ordinary_snapshot(snapshot : OrdinarySnapshot) -> OrdinarySnapshot {
  {
    ..snapshot,
    exact_raw_heads: snapshot.exact_raw_heads.copy(),
    exact_head_records: snapshot.exact_head_records.copy(),
    writer_commitments: snapshot.writer_commitments.copy(),
  }
}

///|
fn begin_ordinary_paper_branch(
  restored : OrdinaryRestoredCandidate,
  fresh_writer~ : String,
) -> OrdinaryPaperBranchState raise R0CodecError {
  let writer_identity = RawIdentity(agent=fresh_writer, sequence=0)
  validate_raw_identity(writer_identity)
  for writer in restored.snapshot.writer_commitments {
    if writer.agent == fresh_writer {
      raise R0CodecError::InvalidValue(detail="writer ID collides")
    }
  }
  {
    document_text: restored.document_text,
    snapshot: copy_ordinary_snapshot(restored.snapshot),
    fresh_writer,
    fresh_writer_metas: [],
  }
}

///|
fn apply_local_insert(
  state : OrdinaryPaperBranchState,
  position~ : Int,
  scalar~ : String,
) -> OrdinaryLocalInsertResult raise R0CodecError {
  let scalar_length = unicode_scalar_length(state.document_text)
  if position < 0 || position > scalar_length {
    raise R0CodecError::InvalidValue(
      detail="insert position outside document bounds",
    )
  }
  if unicode_scalar_length(scalar) != 1 {
    raise R0CodecError::InvalidValue(detail="insert body must be one scalar")
  }
  let mut maximum_rank : Int? = None
  let parents : Array[(RawIdentity, Bytes)] = []
  for record in state.snapshot.exact_head_records {
    parents.push((record.identity, record.event_digest_v2))
    maximum_rank = Some(
      match maximum_rank {
        None => record.causal_rank_timestamp
        Some(current) => current.max(record.causal_rank_timestamp)
      },
    )
  }
  parents.sort_by((left, right) => compare_raw_identity(left.0, right.0))
  let rank = match maximum_rank {
    None => 0
    Some(current) => {
      if current >= 0x7fff_ffff {
        raise R0CodecError::InvalidValue(detail="rank_exhausted")
      }
      current + 1
    }
  }
  let sequence = state.fresh_writer_metas.length()
  let identity = RawIdentity(agent=state.fresh_writer, sequence~)
  let body = InsertScalar(position, scalar)
  let predecessor = if sequence == 0 {
    None
  } else {
    let predecessor_meta = state.fresh_writer_metas[sequence - 1]
    Some((predecessor_meta.identity, predecessor_meta.event_digest_v2))
  }
  let body_digest = _canonical_body_digest(body)
  let event_digest_v2 = encode_event_digest_v2(
    identity,
    body_digest,
    rank,
    parents,
    predecessor,
    [],
  )
  let canonical_body_bytes = encode_canonical_body(body)
  let event : OrdinaryEventMetaV2 = {
    identity,
    body,
    kind: event_kind(body),
    event_digest_v2,
    body_digest,
    causal_rank_timestamp: rank,
    declared_parents: parents.copy(),
    implicit_predecessor: predecessor,
    semantic_references: [],
    payload_byte_length: canonical_body_bytes.length(),
  }
  let fresh_writer_metas = state.fresh_writer_metas.copy()
  fresh_writer_metas.push(event)
  let offset = if position == scalar_length {
    state.document_text.length()
  } else {
    state.document_text.offset_of_nth_char(position).unwrap()
  }
  let text_builder = StringBuilder::new()
  text_builder.write_stringview(
    state.document_text.view(start_offset=0, end_offset=offset),
  )
  text_builder.write_string(scalar)
  text_builder.write_stringview(state.document_text.view(start_offset=offset))
  let document_text = text_builder.to_string()
  let text_bytes = strict_utf8(document_text)
  let local_record : OrdinaryHeadRecord = {
    identity,
    event_digest_v2,
    causal_rank_timestamp: rank,
  }
  let exact_head_records = [local_record]
  let exact_raw_heads = [identity]
  let local_writer = writer_commitment(
    state.fresh_writer,
    fresh_writer_metas.copy(),
  )
  let writer_commitments = state.snapshot.writer_commitments.copy()
  let mut local_writer_index : Int? = None
  for index, writer in writer_commitments {
    if writer.agent == state.fresh_writer {
      local_writer_index = Some(index)
    }
  }
  match local_writer_index {
    None => writer_commitments.push(local_writer)
    Some(index) => writer_commitments[index] = local_writer
  }
  writer_commitments.sort_by((left, right) => {
    compare_utf8_bytes(left.agent, right.agent)
  })
  let snapshot_without_commit : OrdinarySnapshot = {
    document_id_sha256: state.snapshot.document_id_sha256,
    graph_root_v2: encode_graph_root(exact_head_records),
    exact_raw_heads,
    exact_raw_heads_sha256: encode_exact_heads_hash(exact_raw_heads),
    exact_head_records,
    writer_commitments,
    document_text_byte_length: text_bytes.length(),
    document_text_scalar_length: scalar_length + 1,
    document_text_sha256: sha256(text_bytes),
    snapshot_commit_id: Bytes::new(0),
  }
  let snapshot : OrdinarySnapshot = {
    ..snapshot_without_commit,
    snapshot_commit_id: derive_snapshot_commit_id(snapshot_without_commit),
  }
  {
    state: {
      document_text,
      snapshot,
      fresh_writer: state.fresh_writer,
      fresh_writer_metas,
    },
    event,
    reads: {
      metadata_queries: 0,
      payload_queries: 0,
      full_history_queries: 0,
      scan_records_visited: 0,
    },
  }
}

///|
fn request_pre_capture_undo(
  state : OrdinaryPaperBranchState,
) -> OrdinaryNegativeResult {
  {
    state: {
      document_text: state.document_text,
      snapshot: copy_ordinary_snapshot(state.snapshot),
      fresh_writer: state.fresh_writer,
      fresh_writer_metas: state.fresh_writer_metas.copy(),
    },
    reason: "pre_capture_undo_receipt_absent",
    reads: {
      metadata_queries: 0,
      payload_queries: 0,
      full_history_queries: 0,
      scan_records_visited: 0,
    },
  }
}

///|
fn apply_local_delete(
  state : OrdinaryPaperBranchState,
  position~ : Int,
) -> OrdinaryLocalDeleteResult raise R0CodecError {
  let scalar_length = unicode_scalar_length(state.document_text)
  if position < 0 || position >= scalar_length {
    raise R0CodecError::InvalidValue(
      detail="delete position outside document bounds",
    )
  }
  let mut maximum_rank : Int? = None
  let parents : Array[(RawIdentity, Bytes)] = []
  for record in state.snapshot.exact_head_records {
    parents.push((record.identity, record.event_digest_v2))
    maximum_rank = Some(
      match maximum_rank {
        None => record.causal_rank_timestamp
        Some(current) => current.max(record.causal_rank_timestamp)
      },
    )
  }
  parents.sort_by((left, right) => compare_raw_identity(left.0, right.0))
  let rank = match maximum_rank {
    None => 0
    Some(current) => {
      if current >= 0x7fff_ffff {
        raise R0CodecError::InvalidValue(detail="rank_exhausted")
      }
      current + 1
    }
  }
  let sequence = state.fresh_writer_metas.length()
  let identity = RawIdentity(agent=state.fresh_writer, sequence~)
  let body = DeleteScalar(position)
  let predecessor = if sequence == 0 {
    None
  } else {
    let predecessor_meta = state.fresh_writer_metas[sequence - 1]
    Some((predecessor_meta.identity, predecessor_meta.event_digest_v2))
  }
  let body_digest = _canonical_body_digest(body)
  let event_digest_v2 = encode_event_digest_v2(
    identity,
    body_digest,
    rank,
    parents,
    predecessor,
    [],
  )
  let canonical_body_bytes = encode_canonical_body(body)
  let event : OrdinaryEventMetaV2 = {
    identity,
    body,
    kind: event_kind(body),
    event_digest_v2,
    body_digest,
    causal_rank_timestamp: rank,
    declared_parents: parents.copy(),
    implicit_predecessor: predecessor,
    semantic_references: [],
    payload_byte_length: canonical_body_bytes.length(),
  }
  let fresh_writer_metas = state.fresh_writer_metas.copy()
  fresh_writer_metas.push(event)
  let start_offset = state.document_text.offset_of_nth_char(position).unwrap()
  let end_offset = if position + 1 == scalar_length {
    state.document_text.length()
  } else {
    state.document_text.offset_of_nth_char(position + 1).unwrap()
  }
  let text_builder = StringBuilder::new()
  text_builder.write_stringview(
    state.document_text.view(start_offset=0, end_offset=start_offset),
  )
  text_builder.write_stringview(
    state.document_text.view(start_offset=end_offset),
  )
  let document_text = text_builder.to_string()
  let text_bytes = strict_utf8(document_text)
  let local_record : OrdinaryHeadRecord = {
    identity,
    event_digest_v2,
    causal_rank_timestamp: rank,
  }
  let exact_head_records = [local_record]
  let exact_raw_heads = [identity]
  let local_writer = writer_commitment(
    state.fresh_writer,
    fresh_writer_metas.copy(),
  )
  let writer_commitments = state.snapshot.writer_commitments.copy()
  let mut local_writer_index : Int? = None
  for index, writer in writer_commitments {
    if writer.agent == state.fresh_writer {
      local_writer_index = Some(index)
    }
  }
  match local_writer_index {
    None => writer_commitments.push(local_writer)
    Some(index) => writer_commitments[index] = local_writer
  }
  writer_commitments.sort_by((left, right) => {
    compare_utf8_bytes(left.agent, right.agent)
  })
  let snapshot_without_commit : OrdinarySnapshot = {
    document_id_sha256: state.snapshot.document_id_sha256,
    graph_root_v2: encode_graph_root(exact_head_records),
    exact_raw_heads,
    exact_raw_heads_sha256: encode_exact_heads_hash(exact_raw_heads),
    exact_head_records,
    writer_commitments,
    document_text_byte_length: text_bytes.length(),
    document_text_scalar_length: scalar_length - 1,
    document_text_sha256: sha256(text_bytes),
    snapshot_commit_id: Bytes::new(0),
  }
  let snapshot : OrdinarySnapshot = {
    ..snapshot_without_commit,
    snapshot_commit_id: derive_snapshot_commit_id(snapshot_without_commit),
  }
  {
    state: {
      document_text,
      snapshot,
      fresh_writer: state.fresh_writer,
      fresh_writer_metas,
    },
    event,
    reads: {
      metadata_queries: 0,
      payload_queries: 0,
      full_history_queries: 0,
      scan_records_visited: 0,
    },
  }
}
