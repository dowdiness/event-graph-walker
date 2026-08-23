///|
/// Test-only Candidate A self-contained Fast-forward reducer.
///
/// The reducer owns only the validated Document Snapshot sidecar and the bounded
/// incoming region.  Provider capabilities deliberately stop at the shell;
/// this file has no provider dependency.
enum WorkingStateAdmissionOutcome {
  Complete
  Duplicate
  Pending(missing~ : RawIdentity)
  Partial(missing~ : RawIdentity, reason~ : String)
  Rejected(reason~ : String)
} derive(Eq, Debug)

///|
struct WorkingState {
  document_text : String
  snapshot : OrdinarySnapshot
  committed : Map[String, OrdinaryEventMetaV2]
  text_by_identity : Map[String, String]
  writer_metas : Map[String, Array[OrdinaryEventMetaV2]]
  pending : Map[String, OrdinaryEventMetaV2]
  capture_enabled : Bool
  committed_event_count : Int
}

///|
struct WorkingStateAdmissionResult {
  state : WorkingState
  outcome : WorkingStateAdmissionOutcome
  committed : Array[OrdinaryEventMetaV2]
  reads : OrdinaryReadAccounting
}

///|
struct WorkingStateKnownRecord {
  event_digest_v2 : Bytes
  causal_rank_timestamp : Int
}

///|
fn working_state_zero_reads() -> OrdinaryReadAccounting {
  {
    metadata_queries: 0,
    payload_queries: 0,
    full_history_queries: 0,
    scan_records_visited: 0,
  }
}

///|
fn working_state_copy_meta(meta : OrdinaryEventMetaV2) -> OrdinaryEventMetaV2 {
  {
    ..meta,
    declared_parents: meta.declared_parents.copy(),
    semantic_references: meta.semantic_references.copy(),
  }
}

///|
fn working_state_copy_meta_array(
  metas : Array[OrdinaryEventMetaV2],
) -> Array[OrdinaryEventMetaV2] {
  metas.map(working_state_copy_meta)
}

///|
fn working_state_copy_map(
  metas : Map[String, OrdinaryEventMetaV2],
) -> Map[String, OrdinaryEventMetaV2] {
  let result : Map[String, OrdinaryEventMetaV2] = Default::default()
  for key, meta in metas {
    result[key] = working_state_copy_meta(meta)
  }
  result
}

///|
fn working_state_copy_writer_map(
  groups : Map[String, Array[OrdinaryEventMetaV2]],
) -> Map[String, Array[OrdinaryEventMetaV2]] {
  let result : Map[String, Array[OrdinaryEventMetaV2]] = Default::default()
  for agent, metas in groups {
    result[agent] = working_state_copy_meta_array(metas)
  }
  result
}

///|
fn working_state_copy_state(state : WorkingState) -> WorkingState {
  {
    document_text: state.document_text,
    snapshot: copy_ordinary_snapshot(state.snapshot),
    committed: working_state_copy_map(state.committed),
    text_by_identity: state.text_by_identity.copy(),
    writer_metas: working_state_copy_writer_map(state.writer_metas),
    pending: working_state_copy_map(state.pending),
    capture_enabled: state.capture_enabled,
    committed_event_count: state.committed_event_count,
  }
}

///|
fn working_state_begin_from_snapshot(
  snapshot : OrdinarySnapshot,
  document_text : String,
) -> WorkingState {
  {
    document_text,
    snapshot: copy_ordinary_snapshot(snapshot),
    committed: Default::default(),
    text_by_identity: Default::default(),
    writer_metas: Default::default(),
    pending: Default::default(),
    capture_enabled: true,
    committed_event_count: 0,
  }
}

///|
fn working_state_pending_identities(state : WorkingState) -> Array[RawIdentity] {
  let result : Array[RawIdentity] = []
  for _, meta in state.pending {
    result.push(meta.identity)
  }
  result.sort_by(compare_raw_identity)
  result
}

///|
fn working_state_frontier(state : WorkingState) -> Array[RawIdentity] {
  state.snapshot.exact_raw_heads.copy()
}

///|
fn working_state_visible_projection(text : String) -> Json {
  Json::object({
    "text": text.to_json(),
    "text_sha256": sha256_hex(try! strict_utf8(text)).to_json(),
    "scalar_length": (try! unicode_scalar_length(text)).to_json(),
  })
}

///|
fn working_state_known_record(
  state : WorkingState,
  identity : RawIdentity,
) -> WorkingStateKnownRecord? {
  let key = raw_identity_key(identity)
  match state.committed.get(key) {
    Some(meta) =>
      Some({
        event_digest_v2: meta.event_digest_v2,
        causal_rank_timestamp: meta.causal_rank_timestamp,
      })
    None => {
      for record in state.snapshot.exact_head_records {
        if record.identity == identity {
          return Some({
            event_digest_v2: record.event_digest_v2,
            causal_rank_timestamp: record.causal_rank_timestamp,
          })
        }
      }
      None
    }
  }
}

///|
fn working_state_known_text(
  state : WorkingState,
  identity : RawIdentity,
) -> String? {
  match state.text_by_identity.get(raw_identity_key(identity)) {
    Some(text) => Some(text)
    None => {
      for head in state.snapshot.exact_raw_heads {
        if head == identity {
          return Some(state.document_text)
        }
      }
      None
    }
  }
}

///|
fn working_state_same_meta(
  left : OrdinaryEventMetaV2,
  right : OrdinaryEventMetaV2,
) -> Bool {
  left.identity == right.identity &&
  left.body == right.body &&
  left.kind == right.kind &&
  left.event_digest_v2 == right.event_digest_v2 &&
  left.body_digest == right.body_digest &&
  left.causal_rank_timestamp == right.causal_rank_timestamp &&
  left.declared_parents == right.declared_parents &&
  left.implicit_predecessor == right.implicit_predecessor &&
  left.semantic_references == right.semantic_references &&
  left.payload_byte_length == right.payload_byte_length
}

///|
fn working_state_reject_reason(
  state : WorkingState,
  incoming : OrdinaryEventMetaV2,
) -> String? {
  let key = raw_identity_key(incoming.identity)
  match state.committed.get(key) {
    Some(existing) => {
      if working_state_same_meta(existing, incoming) {
        return Some("duplicate")
      }
      return Some("conflicting_identity")
    }
    None => ()
  }
  match state.pending.get(key) {
    Some(existing) => {
      if working_state_same_meta(existing, incoming) {
        return Some("duplicate")
      }
      return Some("conflicting_identity")
    }
    None => ()
  }
  None
}

///|
fn working_state_validate_shape(
  incoming : OrdinaryEventMetaV2,
) -> Unit raise R0CodecError {
  validate_raw_identity(incoming.identity)
  guard incoming.body is Some(body) else {
    raise R0CodecError::InvalidValue(detail="body_missing")
  }
  if incoming.kind != event_kind(body) {
    raise R0CodecError::InvalidValue(detail="kind_body_mismatch")
  }
  if incoming.semantic_references.length() != 0 {
    raise R0CodecError::InvalidValue(detail="undelete_unsupported")
  }
  let body_bytes = encode_canonical_body(body)
  if incoming.payload_byte_length != body_bytes.length() {
    raise R0CodecError::InvalidValue(detail="payload_length_mismatch")
  }
  if incoming.body_digest != _canonical_body_digest(body) {
    raise R0CodecError::InvalidValue(detail="body_digest_mismatch")
  }
  if incoming.causal_rank_timestamp < 0 {
    raise R0CodecError::InvalidValue(detail="negative_rank")
  }
  if encode_event_digest_v2(
      incoming.identity,
      incoming.body_digest,
      incoming.causal_rank_timestamp,
      incoming.declared_parents,
      incoming.implicit_predecessor,
      incoming.semantic_references,
    ) !=
    incoming.event_digest_v2 {
    raise R0CodecError::InvalidValue(detail="event_digest_mismatch")
  }
  for index, item in incoming.declared_parents {
    let (identity, digest) = item
    validate_raw_identity(identity)
    require_digest(digest, "invalid parent digest")
    if index > 0 &&
      compare_raw_identity(incoming.declared_parents[index - 1].0, identity) >=
      0 {
      raise R0CodecError::InvalidValue(detail="parents_not_sorted_unique")
    }
  }
  match incoming.implicit_predecessor {
    None =>
      if incoming.identity.sequence != 0 {
        raise R0CodecError::InvalidValue(detail="predecessor_missing")
      }
    Some((identity, digest)) => {
      validate_raw_identity(identity)
      require_digest(digest, "invalid predecessor digest")
      if incoming.identity.sequence == 0 ||
        identity.agent != incoming.identity.agent ||
        identity.sequence != incoming.identity.sequence - 1 {
        raise R0CodecError::InvalidValue(detail="predecessor_not_contiguous")
      }
    }
  }
}

///|
/// Return whether a predecessor is reachable from the declared parent closure.
/// The walk is over only the bounded incoming region and exact resident heads.
fn working_state_closure_contains(
  state : WorkingState,
  parents : Array[(RawIdentity, Bytes)],
  target : RawIdentity,
) -> Bool {
  let todo : Array[RawIdentity] = parents.map(item => item.0)
  let seen : Set[String] = Set([])
  while !todo.is_empty() {
    let identity = todo[0]
    todo.remove(0) |> ignore
    let key = raw_identity_key(identity)
    if seen.add_and_check(key) {
      if identity == target {
        return true
      }
      match state.committed.get(key) {
        Some(meta) =>
          for parent in meta.declared_parents {
            todo.push(parent.0)
          }
        None => ()
      }
    }
  }
  false
}

///|
fn working_state_writer_expected_sequence(
  state : WorkingState,
  agent : String,
) -> Int? {
  match state.writer_metas.get(agent) {
    Some(metas) => Some(metas.length())
    None => {
      for writer in state.snapshot.writer_commitments {
        if writer.agent == agent {
          return Some(writer.leaf_count)
        }
      }
      Some(0)
    }
  }
}

///|
fn working_state_missing_dependency(
  state : WorkingState,
  incoming : OrdinaryEventMetaV2,
) -> RawIdentity? {
  for item in incoming.declared_parents {
    let (identity, _) = item
    if working_state_known_record(state, identity) is None {
      return Some(identity)
    }
  }
  match incoming.implicit_predecessor {
    Some((identity, _)) if working_state_known_record(state, identity) is None =>
      Some(identity)
    _ => None
  }
}

///|
fn working_state_apply_text(
  parent_text : String,
  body : CanonicalBody,
) -> String raise R0CodecError {
  let scalar_length = unicode_scalar_length(parent_text)
  match body {
    InsertScalar(position, scalar) => {
      if position < 0 || position > scalar_length {
        raise R0CodecError::InvalidValue(detail="insert_position_out_of_bounds")
      }
      let offset = if position == scalar_length {
        parent_text.length()
      } else {
        parent_text.offset_of_nth_char(position).unwrap()
      }
      let builder = StringBuilder::new()
      builder.write_stringview(
        parent_text.view(start_offset=0, end_offset=offset),
      )
      builder.write_string(scalar)
      builder.write_stringview(parent_text.view(start_offset=offset))
      builder.to_string()
    }
    DeleteScalar(position) => {
      if position < 0 || position >= scalar_length {
        raise R0CodecError::InvalidValue(detail="delete_position_out_of_bounds")
      }
      let start = parent_text.offset_of_nth_char(position).unwrap()
      let end = if position + 1 == scalar_length {
        parent_text.length()
      } else {
        parent_text.offset_of_nth_char(position + 1).unwrap()
      }
      let builder = StringBuilder::new()
      builder.write_stringview(
        parent_text.view(start_offset=0, end_offset=start),
      )
      builder.write_stringview(parent_text.view(start_offset=end))
      builder.to_string()
    }
    Undelete(_) =>
      raise R0CodecError::InvalidValue(detail="undelete_unsupported")
  }
}

///|
fn working_state_update_snapshot(
  state : WorkingState,
  incoming : OrdinaryEventMetaV2,
  document_text : String,
) -> OrdinarySnapshot {
  let old_heads = state.snapshot.exact_head_records
  let next_heads : Array[OrdinaryHeadRecord] = []
  for record in old_heads {
    let is_parent = incoming.declared_parents.any(item => {
      item.0 == record.identity
    })
    if !is_parent {
      next_heads.push(record)
    }
  }
  next_heads.push({
    identity: incoming.identity,
    event_digest_v2: incoming.event_digest_v2,
    causal_rank_timestamp: incoming.causal_rank_timestamp,
  })
  next_heads.sort_by((left, right) => {
    compare_raw_identity(left.identity, right.identity)
  })
  let next_raw_heads = next_heads.map(record => record.identity)
  let next_writers = state.snapshot.writer_commitments.copy()
  for agent, metas in state.writer_metas {
    let commitment = try! writer_commitment(
      agent,
      working_state_copy_meta_array(metas),
    )
    let mut found : Int? = None
    for index, writer in next_writers {
      if writer.agent == agent {
        found = Some(index)
      }
    }
    match found {
      None => next_writers.push(commitment)
      Some(index) => next_writers[index] = commitment
    }
  }
  next_writers.sort_by((left, right) => {
    compare_utf8_bytes(left.agent, right.agent)
  })
  let text_bytes = try! strict_utf8(document_text)
  let without_commit : OrdinarySnapshot = {
    document_id_sha256: state.snapshot.document_id_sha256,
    graph_root_v2: try! encode_graph_root(next_heads),
    exact_raw_heads: next_raw_heads,
    exact_raw_heads_sha256: try! encode_exact_heads_hash(next_raw_heads),
    exact_head_records: next_heads,
    writer_commitments: next_writers,
    document_text_byte_length: text_bytes.length(),
    document_text_scalar_length: try! unicode_scalar_length(document_text),
    document_text_sha256: sha256(text_bytes),
    snapshot_commit_id: Bytes::new(0),
  }
  {
    ..without_commit,
    snapshot_commit_id: try! derive_snapshot_commit_id(without_commit),
  }
}

///|
enum WorkingStateTryCommit {
  Ready(WorkingState, OrdinaryEventMetaV2)
  Missing(RawIdentity)
  Invalid(String)
}

///|
fn working_state_try_commit(
  state : WorkingState,
  incoming : OrdinaryEventMetaV2,
) -> WorkingStateTryCommit {
  let shaped : Result[Unit, String] = Ok(working_state_validate_shape(incoming)) catch {
    R0CodecError::InvalidValue(detail~) => Err(detail)
    R0CodecError::MalformedEncoding(detail~) => Err(detail)
  }
  match shaped {
    Err(reason) => return WorkingStateTryCommit::Invalid(reason)
    Ok(_) => ()
  }
  match working_state_missing_dependency(state, incoming) {
    Some(missing) => return WorkingStateTryCommit::Missing(missing)
    None => ()
  }
  for item in incoming.declared_parents {
    let (identity, digest) = item
    guard working_state_known_record(state, identity) is Some(record) else {
      return WorkingStateTryCommit::Missing(identity)
    }
    if record.event_digest_v2 != digest {
      return WorkingStateTryCommit::Invalid("parent_digest_mismatch")
    }
  }
  match incoming.implicit_predecessor {
    None => ()
    Some((identity, digest)) => {
      guard working_state_known_record(state, identity) is Some(record) else {
        return WorkingStateTryCommit::Missing(identity)
      }
      if record.event_digest_v2 != digest {
        return WorkingStateTryCommit::Invalid("predecessor_digest_mismatch")
      }
      if !working_state_closure_contains(
          state,
          incoming.declared_parents,
          identity,
        ) {
        return WorkingStateTryCommit::Invalid("predecessor_not_reachable")
      }
    }
  }
  let expected_rank = if incoming.declared_parents.is_empty() {
    if !state.snapshot.exact_head_records.is_empty() {
      return WorkingStateTryCommit::Invalid("parent_rank_relation")
    }
    0
  } else {
    let mut maximum = 0
    let mut first = true
    for item in incoming.declared_parents {
      let record = working_state_known_record(state, item.0).unwrap()
      if first || record.causal_rank_timestamp > maximum {
        maximum = record.causal_rank_timestamp
        first = false
      }
    }
    if maximum >= 0x7fff_ffff {
      return WorkingStateTryCommit::Invalid("rank_exhausted")
    }
    maximum + 1
  }
  if incoming.causal_rank_timestamp != expected_rank {
    return WorkingStateTryCommit::Invalid("rank_relation")
  }
  let expected_sequence = working_state_writer_expected_sequence(
    state,
    incoming.identity.agent,
  ).unwrap()
  if incoming.identity.sequence != expected_sequence {
    return WorkingStateTryCommit::Invalid("identity_sequence_not_contiguous")
  }
  if state.writer_metas.get(incoming.identity.agent) is None {
    for writer in state.snapshot.writer_commitments {
      if writer.agent == incoming.identity.agent {
        return WorkingStateTryCommit::Invalid("writer_history_not_hot")
      }
    }
  }
  let parent_text = if incoming.declared_parents.is_empty() {
    state.document_text
  } else {
    let first_parent = working_state_known_text(
      state,
      incoming.declared_parents[0].0,
    ).unwrap()
    for item in incoming.declared_parents {
      let other = working_state_known_text(state, item.0).unwrap()
      if other != first_parent {
        return WorkingStateTryCommit::Invalid("parent_projection_divergence")
      }
    }
    first_parent
  }
  let body = incoming.body.unwrap()
  let next_text : Result[String, String] = Ok(
    working_state_apply_text(parent_text, body),
  ) catch {
    R0CodecError::InvalidValue(detail~) => Err(detail)
    R0CodecError::MalformedEncoding(detail~) => Err(detail)
  }
  let next_text = match next_text {
    Err(reason) => return WorkingStateTryCommit::Invalid(reason)
    Ok(text) => text
  }
  let next = working_state_copy_state(state)
  let stored = working_state_copy_meta(incoming)
  let key = raw_identity_key(incoming.identity)
  next.committed[key] = stored
  next.text_by_identity[key] = next_text
  let group = next.writer_metas.get(incoming.identity.agent).unwrap_or([])
  let next_group = working_state_copy_meta_array(group)
  next_group.push(working_state_copy_meta(incoming))
  next.writer_metas[incoming.identity.agent] = next_group
  let next_snapshot = working_state_update_snapshot(next, incoming, next_text)
  let final_state = {
    ..next,
    document_text: next_text,
    snapshot: next_snapshot,
    committed_event_count: next.committed_event_count + 1,
  }
  WorkingStateTryCommit::Ready(final_state, working_state_copy_meta(incoming))
}

///|
fn working_state_result(
  state : WorkingState,
  outcome : WorkingStateAdmissionOutcome,
  committed : Array[OrdinaryEventMetaV2],
) -> WorkingStateAdmissionResult {
  {
    state: working_state_copy_state(state),
    outcome,
    committed: working_state_copy_meta_array(committed),
    reads: working_state_zero_reads(),
  }
}

///|
fn working_state_add_pending(
  state : WorkingState,
  incoming : OrdinaryEventMetaV2,
) -> WorkingState {
  let next = working_state_copy_state(state)
  next.pending[raw_identity_key(incoming.identity)] = working_state_copy_meta(
    incoming,
  )
  { ..next, capture_enabled: false }
}

///|
struct WorkingStateDrainResult {
  state : WorkingState
  committed : Array[OrdinaryEventMetaV2]
  missing : RawIdentity?
  invalid : String?
}

///|
fn working_state_drain_pending(
  state : WorkingState,
  committed : Array[OrdinaryEventMetaV2],
) -> WorkingStateDrainResult {
  let mut next = working_state_copy_state(state)
  let drained = committed.copy()
  let mut progress = true
  let mut first_invalid : String? = None
  while progress && first_invalid is None {
    progress = false
    let pending = next.pending.to_array()
    pending.sort_by((left, right) => {
      compare_raw_identity(left.1.identity, right.1.identity)
    })
    for item in pending {
      let (key, meta) = item
      match working_state_try_commit(next, meta) {
        WorkingStateTryCommit::Ready(updated, committed_meta) => {
          next = updated
          next.pending.remove(key)
          drained.push(committed_meta)
          progress = true
        }
        WorkingStateTryCommit::Missing(_) => ()
        WorkingStateTryCommit::Invalid(reason) => {
          first_invalid = Some(reason)
          break
        }
      }
    }
  }
  let mut first_missing : RawIdentity? = None
  if first_invalid is None {
    let pending = next.pending.to_array()
    pending.sort_by((left, right) => {
      compare_raw_identity(left.1.identity, right.1.identity)
    })
    for item in pending {
      match working_state_try_commit(next, item.1) {
        WorkingStateTryCommit::Missing(missing) =>
          if first_missing is None {
            first_missing = Some(missing)
          }
        WorkingStateTryCommit::Invalid(reason) => {
          first_invalid = Some(reason)
          break
        }
        WorkingStateTryCommit::Ready(_, _) => {
          first_invalid = Some("pending_drain_incomplete")
          break
        }
      }
    }
  }
  next = {
    ..next,
    capture_enabled: next.pending.is_empty() && first_invalid is None,
  }
  {
    state: next,
    committed: drained,
    missing: first_missing,
    invalid: first_invalid,
  }
}

///|
fn working_state_admit_batch_unchecked(
  state : WorkingState,
  incoming : Array[OrdinaryEventMetaV2],
) -> WorkingStateAdmissionResult {
  let mut next = working_state_copy_state(state)
  let committed : Array[OrdinaryEventMetaV2] = []
  let mut first_rejection : String? = None
  let mut saw_duplicate = false
  for original in incoming {
    let meta = working_state_copy_meta(original)
    match working_state_reject_reason(next, meta) {
      Some("duplicate") => {
        saw_duplicate = true
        continue
      }
      Some(reason) => {
        first_rejection = Some(reason)
        break
      }
      None => ()
    }
    match working_state_try_commit(next, meta) {
      WorkingStateTryCommit::Ready(updated, committed_meta) => {
        next = updated
        committed.push(committed_meta)
        let drained = working_state_drain_pending(next, committed)
        next = drained.state
        committed.clear()
        for item in drained.committed {
          committed.push(item)
        }
        match drained.invalid {
          Some(reason) => {
            first_rejection = Some(reason)
            break
          }
          None => ()
        }
      }
      WorkingStateTryCommit::Missing(_) =>
        next = working_state_add_pending(next, meta)
      WorkingStateTryCommit::Invalid(reason) => {
        first_rejection = Some(reason)
        break
      }
    }
  }
  let drained = working_state_drain_pending(next, committed)
  next = drained.state
  committed.clear()
  for item in drained.committed {
    committed.push(item)
  }
  if first_rejection is None {
    first_rejection = drained.invalid
  }
  match first_rejection {
    Some(reason) => {
      next = { ..next, capture_enabled: false }
      let outcome = if committed.length() > 0 {
        WorkingStateAdmissionOutcome::Partial(
          missing=drained.missing.unwrap_or(
            RawIdentity(agent="rejected", sequence=0),
          ),
          reason~,
        )
      } else {
        WorkingStateAdmissionOutcome::Rejected(reason~)
      }
      working_state_result(next, outcome, committed)
    }
    None =>
      match drained.missing {
        Some(missing) => {
          next = { ..next, capture_enabled: false }
          let outcome = if committed.length() > 0 {
            WorkingStateAdmissionOutcome::Partial(missing~, reason="pending")
          } else {
            WorkingStateAdmissionOutcome::Pending(missing~)
          }
          working_state_result(next, outcome, committed)
        }
        None => {
          next = { ..next, capture_enabled: true }
          let outcome = if committed.is_empty() && saw_duplicate {
            WorkingStateAdmissionOutcome::Duplicate
          } else {
            WorkingStateAdmissionOutcome::Complete
          }
          working_state_result(next, outcome, committed)
        }
      }
  }
}

///|
fn working_state_admit_one(
  state : WorkingState,
  incoming : OrdinaryEventMetaV2,
) -> WorkingStateAdmissionResult {
  working_state_admit_batch(state, [incoming])
}

///|
/// Every incoming entry point must cover all pre-region exact heads. Separate
/// roots cannot satisfy this requirement by splitting aggregate head coverage.
fn working_state_validate_entry_coverage(
  state : WorkingState,
  incoming : Array[OrdinaryEventMetaV2],
) -> String? {
  if incoming.is_empty() {
    return Some("empty_fast_forward_region")
  }
  let incoming_identities : Set[String] = Set([])
  for meta in incoming {
    if !incoming_identities.add_and_check(raw_identity_key(meta.identity)) {
      return Some("duplicate_incoming_identity")
    }
  }
  let mut entry_count = 0
  for meta in incoming {
    let is_entry = !meta.declared_parents.any(parent => {
      incoming_identities.contains(raw_identity_key(parent.0))
    })
    if is_entry {
      entry_count += 1
      for head in state.snapshot.exact_raw_heads {
        if !meta.declared_parents.any(parent => parent.0 == head) {
          return Some("entry_point_does_not_cover_heads")
        }
      }
    }
  }
  if entry_count == 0 {
    return Some("incoming_region_has_no_entry_point")
  }
  None
}

///|
fn working_state_admit_batch(
  state : WorkingState,
  incoming : Array[OrdinaryEventMetaV2],
) -> WorkingStateAdmissionResult {
  let new_events = incoming.filter(meta => {
    working_state_reject_reason(state, meta) is None
  })
  if new_events.is_empty() {
    return working_state_admit_batch_unchecked(state, incoming)
  }
  match working_state_validate_entry_coverage(state, new_events) {
    Some(reason) =>
      working_state_result(
        state,
        WorkingStateAdmissionOutcome::Rejected(reason~),
        [],
      )
    None => working_state_admit_batch_unchecked(state, incoming)
  }
}

///|
fn working_state_admit_region(
  state : WorkingState,
  incoming : Array[OrdinaryEventMetaV2],
) -> WorkingStateAdmissionResult {
  working_state_admit_batch(state, incoming)
}

///|
/// Build a deterministic region with a non-empty resident head.  It contains
/// both positional inserts and deletes at every requested scale.
#warnings("-unused_value")
fn working_state_scaled_case(
  region_count : Int,
) -> (GeneratedFixture, WorkingState, Array[OrdinaryEventMetaV2]) raise {
  let builder = FixtureBuilder::new()
  let base = builder.insert("r0-base", [], 0, "a")
  for index = 0; index < region_count; index = index + 1 {
    let parents = builder.chain_parents()
    if builder.visible.is_empty() || index % 3 != 0 {
      builder.insert(
        "r0-fast-forward",
        parents,
        builder.visible.length(),
        if index % 2 == 0 {
          "é"
        } else {
          "🙂"
        },
      )
      |> ignore
    } else {
      builder.delete("r0-fast-forward", parents, 0) |> ignore
    }
  }
  let fixture : GeneratedFixture = {
    fixture_id: "F-01-fast-forward-" + region_count.to_string(),
    document_id: "loomark-r0-fixture-F-01-fast-forward-" +
    region_count.to_string(),
    events: builder.events,
    replay_order: stable_topological_order(builder.events),
    final_text: visible_text(builder.visible),
  }
  let overlay = build_nonempty_overlay(fixture)
  let prefix : GeneratedFixture = {
    ..fixture,
    events: [base],
    replay_order: [base.identity],
    final_text: "a",
  }
  let base_overlay = build_nonempty_overlay(prefix)
  let region : Array[OrdinaryEventMetaV2] = []
  for index in 1..<overlay.metas.length() {
    region.push(working_state_copy_meta(overlay.metas[index]))
  }
  (
    fixture,
    working_state_begin_from_snapshot(base_overlay.snapshot, "a"),
    region,
  )
}

///|
#warnings("-unused_value")
fn working_state_source_equal_case() -> (
  GeneratedFixture,
  WorkingState,
  Array[OrdinaryEventMetaV2],
) raise {
  let builder = FixtureBuilder::new()
  let base = builder.insert("r0-base", [], 0, "x")
  let (deleted, _) = builder.delete(
    "r0-fast-forward",
    builder.chain_parents(),
    0,
  )
  builder.insert("r0-fast-forward", [deleted.identity], 0, "x") |> ignore
  let fixture : GeneratedFixture = {
    fixture_id: "F-02-source-equal",
    document_id: "loomark-r0-fixture-F-02-source-equal",
    events: builder.events,
    replay_order: stable_topological_order(builder.events),
    final_text: visible_text(builder.visible),
  }
  let overlay = build_nonempty_overlay(fixture)
  let prefix : GeneratedFixture = {
    ..fixture,
    events: [base],
    replay_order: [base.identity],
    final_text: "x",
  }
  let base_overlay = build_nonempty_overlay(prefix)
  (
    fixture,
    working_state_begin_from_snapshot(base_overlay.snapshot, "x"),
    [overlay.metas[1], overlay.metas[2]],
  )
}

///|
fn working_state_next_meta(
  state : WorkingState,
  writer : String,
  sequence : Int,
  body : CanonicalBody,
) -> OrdinaryEventMetaV2 raise R0CodecError {
  let parents = state.snapshot.exact_head_records.map(record => {
    (record.identity, record.event_digest_v2)
  })
  parents.sort_by((left, right) => compare_raw_identity(left.0, right.0))
  let mut maximum_rank : Int? = None
  for record in state.snapshot.exact_head_records {
    maximum_rank = Some(
      match maximum_rank {
        None => record.causal_rank_timestamp
        Some(current) => current.max(record.causal_rank_timestamp)
      },
    )
  }
  let rank = match maximum_rank {
    None => 0
    Some(value) => {
      if value >= 0x7fff_ffff {
        raise R0CodecError::InvalidValue(detail="rank_exhausted")
      }
      value + 1
    }
  }
  let predecessor = if sequence == 0 {
    None
  } else {
    guard state.committed.get(
        raw_identity_key(RawIdentity(agent=writer, sequence=sequence - 1)),
      )
      is Some(previous) else {
      raise R0CodecError::InvalidValue(
        detail="working state predecessor absent",
      )
    }
    Some((previous.identity, previous.event_digest_v2))
  }
  ordinary_event_meta(
    RawIdentity(agent=writer, sequence~),
    body,
    rank,
    parents,
    predecessor,
    [],
  )
}

///|
fn working_state_region_from_candidate(
  state : WorkingState,
  count : Int,
) -> Array[OrdinaryEventMetaV2] raise R0CodecError {
  let mut working = working_state_copy_state(state)
  let region : Array[OrdinaryEventMetaV2] = []
  for sequence = 0; sequence < count; sequence = sequence + 1 {
    let scalar_length = unicode_scalar_length(working.document_text)
    let body = if sequence % 3 == 2 && scalar_length > 0 {
      DeleteScalar(0)
    } else {
      InsertScalar(scalar_length, if sequence % 2 == 0 { "é" } else { "🙂" })
    }
    let meta = working_state_next_meta(
      working, "r0-candidate-fast-forward", sequence, body,
    )
    let admitted = working_state_admit_one(working, meta)
    guard admitted.outcome is WorkingStateAdmissionOutcome::Complete else {
      raise R0CodecError::InvalidValue(
        detail="generated fast-forward region rejected",
      )
    }
    working = admitted.state
    region.push(meta)
  }
  region
}

///|
fn working_state_source_equal_from_candidate(
  state : WorkingState,
) -> Array[OrdinaryEventMetaV2] raise R0CodecError {
  let scalar_length = unicode_scalar_length(state.document_text)
  if scalar_length == 0 {
    let inserted = working_state_next_meta(
      state,
      "r0-candidate-source-equal",
      0,
      InsertScalar(0, "x"),
    )
    let inserted_state = working_state_admit_one(state, inserted)
    let deleted = working_state_next_meta(
      inserted_state.state,
      "r0-candidate-source-equal",
      1,
      DeleteScalar(0),
    )
    return [inserted, deleted]
  }
  let first_end = if scalar_length == 1 {
    state.document_text.length()
  } else {
    state.document_text.offset_of_nth_char(1).unwrap()
  }
  let first_scalar = state.document_text
    .view(start_offset=0, end_offset=first_end)
    .to_owned()
  let deleted = working_state_next_meta(
    state,
    "r0-candidate-source-equal",
    0,
    DeleteScalar(0),
  )
  let deleted_state = working_state_admit_one(state, deleted)
  let inserted = working_state_next_meta(
    deleted_state.state,
    "r0-candidate-source-equal",
    1,
    InsertScalar(0, first_scalar),
  )
  [deleted, inserted]
}

///|
#warnings("-unused_value")
fn working_state_capture(state : WorkingState) -> Bytes raise R0CodecError {
  if !state.capture_enabled {
    raise R0CodecError::InvalidValue(detail="capture_disabled")
  }
  encode_candidate(state.snapshot, state.document_text)
}

///|
fn working_state_observation_json(
  producer : String,
  case_id : String,
  outcome : WorkingStateAdmissionOutcome,
  result : WorkingStateAdmissionResult,
) -> Json {
  let outcome_json = match outcome {
    WorkingStateAdmissionOutcome::Complete =>
      Json::object({ "kind": "complete".to_json() })
    WorkingStateAdmissionOutcome::Duplicate =>
      Json::object({ "kind": "duplicate".to_json() })
    WorkingStateAdmissionOutcome::Pending(missing~) =>
      Json::object({
        "kind": "pending".to_json(),
        "missing": (missing.agent + ":" + missing.sequence.to_string()).to_json(),
      })
    WorkingStateAdmissionOutcome::Partial(missing~, reason~) =>
      Json::object({
        "kind": "partial".to_json(),
        "missing": (missing.agent + ":" + missing.sequence.to_string()).to_json(),
        "reason": reason.to_json(),
      })
    WorkingStateAdmissionOutcome::Rejected(reason~) =>
      Json::object({ "kind": "rejected".to_json(), "reason": reason.to_json() })
  }
  let pending = working_state_pending_identities(result.state)
  Json::object({
    "schema_version": (1).to_json(),
    "producer": producer.to_json(),
    "record": "working_state_observation".to_json(),
    "candidate": "A".to_json(),
    "case_id": case_id.to_json(),
    "outcome": outcome_json,
    "committed_event_count": result.state.committed_event_count.to_json(),
    "committed_batch_count": result.committed.length().to_json(),
    "pending": pending
    .map(item => (item.agent + ":" + item.sequence.to_string()).to_json())
    .to_json(),
    "capture_enabled": result.state.capture_enabled.to_json(),
    "frontier": working_state_frontier(result.state)
    .map(item => (item.agent + ":" + item.sequence.to_string()).to_json())
    .to_json(),
    "snapshot_commit_id": bytes_hex(result.state.snapshot.snapshot_commit_id).to_json(),
    "text": result.state.document_text.to_json(),
    "text_sha256": sha256_hex(try! strict_utf8(result.state.document_text)).to_json(),
    "reads": Json::object({
      "metadata_queries": result.reads.metadata_queries.to_json(),
      "payload_queries": result.reads.payload_queries.to_json(),
      "full_history_queries": result.reads.full_history_queries.to_json(),
      "scan_records_visited": result.reads.scan_records_visited.to_json(),
    }),
  })
}

///|
fn working_state_observations(
  run_id : String,
  producer : String,
  candidate_snapshot : OrdinarySnapshot,
  candidate_text : String,
) -> Array[Json] raise {
  let observations : Array[Json] = []
  for count in [1, 10, 100] {
    let state = working_state_begin_from_snapshot(
      candidate_snapshot, candidate_text,
    )
    let region = working_state_region_from_candidate(state, count)
    let result = working_state_admit_region(state, region)
    observations.push(
      working_state_observation_json(
        producer,
        run_id + ":F-01-" + count.to_string(),
        result.outcome,
        result,
      ),
    )
  }
  let source_state = working_state_begin_from_snapshot(
    candidate_snapshot, candidate_text,
  )
  let source_region = working_state_source_equal_from_candidate(source_state)
  let before_projection = working_state_visible_projection(
    source_state.document_text,
  )
  let source_result = working_state_admit_region(source_state, source_region)
  let after_projection = working_state_visible_projection(
    source_result.state.document_text,
  )
  if before_projection != after_projection ||
    source_state.snapshot.snapshot_commit_id ==
    source_result.state.snapshot.snapshot_commit_id {
    raise R0CodecError::InvalidValue(
      detail="source-equal projection/frontier mismatch",
    )
  }
  observations.push(
    working_state_observation_json(
      producer,
      run_id + ":F-02-source-equal",
      source_result.outcome,
      source_result,
    ),
  )
  let (_, pending_state, pending_region) = working_state_pending_case()
  let child = pending_region[1]
  let pending_result = working_state_admit_one(pending_state, child)
  let drained = working_state_admit_one(pending_result.state, pending_region[0])
  if pending_result.state.capture_enabled ||
    !drained.state.capture_enabled ||
    drained.state.pending.length() != 0 {
    raise R0CodecError::InvalidValue(detail="pending drain lifecycle mismatch")
  }
  observations.push(
    working_state_observation_json(
      producer,
      run_id + ":D-04-pending",
      pending_result.outcome,
      pending_result,
    ),
  )
  observations.push(
    working_state_observation_json(
      producer,
      run_id + ":D-04-drain",
      drained.outcome,
      drained,
    ),
  )
  let partial = working_state_partial_case()
  observations.push(
    working_state_observation_json(
      producer,
      run_id + ":D-05-partial",
      partial.outcome,
      partial,
    ),
  )
  observations
}

///|
fn working_state_pending_case() -> (
  GeneratedFixture,
  WorkingState,
  Array[OrdinaryEventMetaV2],
) raise {
  let builder = FixtureBuilder::new()
  builder.insert("r0-fast-forward", [], 0, "p") |> ignore
  builder.insert("r0-fast-forward", builder.chain_parents(), 1, "c") |> ignore
  let fixture : GeneratedFixture = {
    fixture_id: "D-04-pending",
    document_id: "loomark-r0-fixture-D-04-pending",
    events: builder.events,
    replay_order: stable_topological_order(builder.events),
    final_text: visible_text(builder.visible),
  }
  let overlay = build_nonempty_overlay(fixture)
  let empty = empty_snapshot(fixture.document_id, "")
  (fixture, working_state_begin_from_snapshot(empty, ""), overlay.metas)
}

///|
fn working_state_partial_case() -> WorkingStateAdmissionResult raise {
  let (fixture, state, region) = working_state_pending_case()
  let missing = RawIdentity(agent="r0-missing", sequence=0)
  let suffix = ordinary_event_meta(
    RawIdentity(agent="r0-suffix", sequence=0),
    InsertScalar(1, "s"),
    1,
    [(missing, Bytes::new(32))],
    None,
    [],
  )
  ignore(fixture)
  working_state_admit_batch(state, [region[0], suffix])
}
