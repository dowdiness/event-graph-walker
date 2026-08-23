///|
/// Evidence returned by the typed EGW authority cross-check.
struct EgwAuthorityEvidence {
  committed_events : Int
  pending_after_count : Int
  authority_text : String
  exact_heads : Array[RawIdentity]
  head_ranks : Array[Int]
  used_typed_admission_receipts : Bool
  full_history_walks : Int
}

///|
/// Compare raw identities by their canonical UTF-8 agent bytes.
fn authority_compare_raw(
  left : @core.RawVersion,
  right : @core.RawVersion,
) -> Int {
  match compare_utf8_bytes(left.agent, right.agent) {
    0 => left.seq.compare(right.seq)
    other => other
  }
}

///|
/// Compare raw identity arrays without relying on String's UTF-16 ordering.
fn authority_same_raw_versions(
  left : Array[@core.RawVersion],
  right : Array[@core.RawVersion],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  let sorted_left = left.copy()
  let sorted_right = right.copy()
  sorted_left.sort_by(authority_compare_raw)
  sorted_right.sort_by(authority_compare_raw)
  for index, raw in sorted_left {
    if raw != sorted_right[index] {
      return false
    }
  }
  true
}

///|
/// The committed operation must preserve the canonical remote operation
/// identity, ancestry, payload, and origins; only its local LV may change.
fn authority_same_operation(expected : @core.Op, committed : @core.Op) -> Bool {
  if expected.agent() != committed.agent() || expected.seq() != committed.seq() {
    return false
  }
  if !authority_same_raw_versions(expected.parents(), committed.parents()) {
    return false
  }
  if expected.origin_left() != committed.origin_left() ||
    expected.origin_right() != committed.origin_right() {
    return false
  }
  match (expected.content(), committed.content()) {
    (@core.Insert(expected_text), @core.Insert(committed_text)) =>
      expected_text == committed_text
    (@core.Delete, @core.Delete) => true
    (@core.Undelete, @core.Undelete) => true
    _ => false
  }
}

///|
/// Validate candidate bytes first, then replay the canonical fixture through
/// production Document text and a separate typed OpLog authority.
fn validate_capture_against_egw_authority(
  fixture : GeneratedFixture,
  candidate_bytes : Bytes,
) -> EgwAuthorityEvidence raise R0CodecError {
  let candidate = validate_paper_branch_candidate(candidate_bytes)
  let document = @document.Document::new(fixture.document_id)
  let authority = @oplog.OpLog(fixture.document_id)
  let admitted : Array[@core.RawVersion] = []
  let mut current_frontier : Array[@core.RawVersion] = []
  let mut current_visible : Array[@core.RawVersion]? = Some([])
  let mut committed_events = 0
  let mut pending_after_count = 0
  for identity in fixture.replay_order {
    let mut selected : FixtureEvent? = None
    for event in fixture.events {
      if event.identity == identity {
        selected = Some(event)
      }
    }
    guard selected is Some(event) else {
      raise R0CodecError::InvalidValue(
        detail="replay order references missing event",
      )
    }
    let follows_current = legacy_same_frontier(
      event.parents.map(legacy_raw),
      current_frontier,
    )
    let operation = lower_legacy_oracle_event(
      document, admitted, event, current_frontier, current_visible,
    )
    try! document.apply_remote(operation)
    admitted.push(legacy_raw(event.identity))
    current_frontier = legacy_advance_frontier(current_frontier, event)
    current_visible = if follows_current {
      match current_visible {
        Some(visible) => legacy_advance_visible(visible, event)
        None => None
      }
    } else {
      None
    }

    let frontier_before = authority.get_frontier()
    let prepared = try! authority.prepare_remote([operation])
    let outcome = try! authority.commit_admission(prepared)
    match outcome {
      @oplog.AdmissionOutcome::Complete(receipt) => {
        let committed = receipt.committed().to_owned()
        if committed.length() != 1 ||
          !authority_same_operation(operation, committed[0]) {
          raise R0CodecError::InvalidValue(
            detail="typed admission committed an unexpected operation",
          )
        }
        if receipt.frontier_before().to_array() != frontier_before.to_array() {
          raise R0CodecError::InvalidValue(
            detail="typed admission frontier-before mismatch",
          )
        }
        if receipt.frontier_after().to_array() !=
          authority.get_frontier().to_array() {
          raise R0CodecError::InvalidValue(
            detail="typed admission frontier-after mismatch",
          )
        }
        if receipt.pending_after_count() != 0 {
          raise R0CodecError::InvalidValue(
            detail="typed admission retained pending operations",
          )
        }
        committed_events = committed_events + committed.length()
        pending_after_count = receipt.pending_after_count()
      }
      @oplog.AdmissionOutcome::Partial(..) =>
        raise R0CodecError::InvalidValue(
          detail="typed admission did not complete",
        )
    }
  }

  let authority_text = document.to_text()
  if authority_text != fixture.final_text ||
    candidate.document_text != authority_text {
    raise R0CodecError::InvalidValue(detail="authority text mismatch")
  }
  let raw_heads = try! authority.get_frontier_raw()
  raw_heads.sort_by(authority_compare_raw)
  let exact_heads = raw_heads.map(raw => {
    RawIdentity(agent=raw.agent, sequence=raw.seq)
  })
  if candidate.snapshot.exact_raw_heads != exact_heads {
    raise R0CodecError::InvalidValue(detail="authority head mismatch")
  }
  let graph = authority.causal_graph()
  let head_ranks : Array[Int] = []
  for raw in raw_heads {
    guard graph.raw_to_lv(raw) is Some(lv) else {
      raise R0CodecError::InvalidValue(
        detail="authority head has no local version",
      )
    }
    guard graph.get_entry(lv) is Some(entry) else {
      raise R0CodecError::InvalidValue(
        detail="authority head has no graph entry",
      )
    }
    head_ranks.push(entry.timestamp)
  }
  let candidate_ranks = candidate.snapshot.exact_head_records.map(record => {
    record.causal_rank_timestamp
  })
  if candidate_ranks != head_ranks {
    raise R0CodecError::InvalidValue(detail="authority head rank mismatch")
  }
  {
    committed_events,
    pending_after_count,
    authority_text,
    exact_heads,
    head_ranks,
    used_typed_admission_receipts: true,
    full_history_walks: 0,
  }
}
