///|
test "R-01 empty PaperBranch candidate validates from immutable bytes with zero reads" {
  let fixture : GeneratedFixture = {
    fixture_id: "R-01-empty",
    document_id: "r0-empty",
    events: [],
    replay_order: [],
    final_text: "",
  }
  let capture = try! capture_paper_branch_candidate(fixture)
  assert_eq(capture.candidate_bytes.length(), 171)
  assert_eq(
    sha256_hex(capture.candidate_bytes),
    "aa331d6dfec5e2d2d0edc419452f233403dbf71886d1b7b73f0fe5d0270d35ae",
  )
  assert_eq(
    bytes_hex(capture.snapshot_commit_id),
    "8c07d65c899f24ee76b2d2ef27d5826b5f5531aee5157ee7a945c1c8e77d6548",
  )
  let restored = try! validate_paper_branch_candidate(capture.candidate_bytes)
  assert_eq(restored.document_text, "")
  assert_eq(restored.snapshot.exact_head_records.length(), 0)
  assert_eq(restored.snapshot.writer_commitments.length(), 0)
  assert_eq(
    bytes_hex(restored.snapshot.snapshot_commit_id),
    bytes_hex(capture.snapshot_commit_id),
  )
  assert_eq(restored.reads.metadata_queries, 0)
  assert_eq(restored.reads.payload_queries, 0)
  assert_eq(restored.reads.full_history_queries, 0)
  assert_eq(restored.reads.scan_records_visited, 0)
}

///|
test "R-01 non-empty PaperBranch candidate validates ranked heads and writer commitment" {
  let fixture = try! generate_fixture("S-linear", 4)
  let capture = try! capture_paper_branch_candidate(fixture)
  assert_eq(capture.candidate_bytes.length(), 292)
  assert_eq(
    sha256_hex(capture.candidate_bytes),
    "e532a7f6ab09fd02dad57aebd672fd501f09379fa1b950aedc1022e8cf08cb21",
  )
  assert_eq(
    bytes_hex(capture.snapshot_commit_id),
    "ae67919336e77c5d9ba163bfb2cc5146221880c7323c828a65b448fbf2fd1daf",
  )
  let restored = try! validate_paper_branch_candidate(capture.candidate_bytes)
  assert_eq(restored.document_text, "aéé")
  assert_eq(restored.snapshot.exact_head_records.length(), 1)
  let head = restored.snapshot.exact_head_records[0]
  assert_eq(head.identity, RawIdentity(agent="r0-a", sequence=3))
  assert_eq(head.causal_rank_timestamp, 3)
  assert_eq(
    bytes_hex(head.event_digest_v2),
    "72ef94f94a71a2df7dce81269804dffd8dab2fed10aa8beab75fa9d453485504",
  )
  assert_eq(restored.snapshot.writer_commitments.length(), 1)
  let writer = restored.snapshot.writer_commitments[0]
  assert_eq(writer.agent, "r0-a")
  assert_eq(writer.leaf_count, 4)
  assert_eq(
    bytes_hex(writer.event_meta_mmr_root_v2),
    "6b5b5cfb8b8cf92c27e3b2c610113b0301c504a289f568ae28ddcd60f8dca3b1",
  )
  assert_eq(restored.reads.metadata_queries, 0)
  assert_eq(restored.reads.payload_queries, 0)
  assert_eq(restored.reads.full_history_queries, 0)
  assert_eq(restored.reads.scan_records_visited, 0)
}

///|
fn corrupt_candidate_byte(candidate : Bytes, offset : Int) -> Bytes {
  let bytes = candidate.to_array()
  bytes[offset] = (bytes[offset].to_int() ^ 0x01).to_byte()
  Bytes::from_array(bytes)
}

///|
test "R-02 changed writer root rejects against the published commit before editability" {
  let fixture = try! generate_fixture("S-linear", 4)
  let capture = try! capture_paper_branch_candidate(fixture)
  let corrupt = corrupt_candidate_byte(capture.candidate_bytes, 226)
  try
    validate_published_paper_branch_candidate(
      corrupt,
      expected_snapshot_commit_id_hex=bytes_hex(capture.snapshot_commit_id),
    )
  catch {
    R0CodecError::InvalidValue(detail="snapshot commit ID mismatch") => ()
    _ => fail("wrong corruption detector")
  } noraise {
    _ => fail("corrupt writer root crossed the publication boundary")
  }
}

///|
test "R-04 and L-01 fresh restore allocates a distinct writer and inserts without reads" {
  let fixture = try! generate_fixture("S-linear", 4)
  let capture = try! capture_paper_branch_candidate(fixture)
  let restored = try! validate_published_paper_branch_candidate(
    capture.candidate_bytes,
    expected_snapshot_commit_id_hex=bytes_hex(capture.snapshot_commit_id),
  )
  let first = try! begin_ordinary_paper_branch(
    restored,
    fresh_writer="r0-fresh-1",
  )
  let second = try! begin_ordinary_paper_branch(
    restored,
    fresh_writer="r0-fresh-2",
  )
  assert_eq(
    first.snapshot.snapshot_commit_id,
    second.snapshot.snapshot_commit_id,
  )
  assert_true(first.fresh_writer != second.fresh_writer)
  let edited = try! apply_local_insert(first, position=4, scalar="Z")
  assert_eq(first.document_text, "aéé")
  assert_eq(edited.state.document_text, "aééZ")
  assert_eq(edited.event.identity, RawIdentity(agent="r0-fresh-1", sequence=0))
  assert_eq(edited.event.causal_rank_timestamp, 4)
  assert_eq(edited.event.declared_parents.length(), 1)
  assert_eq(
    bytes_hex(edited.event.event_digest_v2),
    "5fd2683daf30dc56c67f9740df5a671fa137334a78bede90e2f1a7957d9eda76",
  )
  assert_eq(edited.state.snapshot.exact_head_records.length(), 1)
  assert_eq(edited.state.snapshot.writer_commitments.length(), 2)
  let local_writer = edited.state.snapshot.writer_commitments[1]
  assert_eq(local_writer.agent, "r0-fresh-1")
  assert_eq(local_writer.leaf_count, 1)
  assert_eq(
    bytes_hex(local_writer.event_meta_mmr_root_v2),
    "49478184a5fd8ad0b453c0a6bd4e47f79a48cb3a1c56cde7f083b844e09e1fc3",
  )
  assert_eq(edited.reads.metadata_queries, 0)
  assert_eq(edited.reads.payload_queries, 0)
  assert_eq(edited.reads.full_history_queries, 0)
}

///|
test "L-02 and L-03 local delete and sequential edit preserve scalar and writer continuity" {
  let fixture = try! generate_fixture("S-linear", 4)
  let capture = try! capture_paper_branch_candidate(fixture)
  let restored = try! validate_published_paper_branch_candidate(
    capture.candidate_bytes,
    expected_snapshot_commit_id_hex=bytes_hex(capture.snapshot_commit_id),
  )
  let delete_branch = try! begin_ordinary_paper_branch(
    restored,
    fresh_writer="r0-fresh-delete",
  )
  let deleted = try! apply_local_delete(delete_branch, position=1)
  assert_eq(deleted.state.document_text, "aé")
  assert_eq(deleted.event.identity.sequence, 0)
  assert_eq(deleted.event.causal_rank_timestamp, 4)
  assert_eq(
    bytes_hex(deleted.event.event_digest_v2),
    "b031b75d4522c9663e8b0b2ee19a3642ee424cbd082d058bf0e46d0d00c28f5f",
  )
  let sequential_branch = try! begin_ordinary_paper_branch(
    restored,
    fresh_writer="r0-fresh-1",
  )
  let inserted = try! apply_local_insert(
    sequential_branch,
    position=4,
    scalar="Z",
  )
  let second = try! apply_local_delete(inserted.state, position=0)
  assert_eq(second.state.document_text, "ééZ")
  assert_eq(second.event.identity, RawIdentity(agent="r0-fresh-1", sequence=1))
  assert_eq(second.event.causal_rank_timestamp, 5)
  assert_eq(
    second.event.implicit_predecessor.map(item => item.0),
    Some(RawIdentity(agent="r0-fresh-1", sequence=0)),
  )
  assert_eq(
    bytes_hex(second.event.event_digest_v2),
    "b34f6f8e8a6adc9656e2da6f462d6a5c67e3a292c21b1bd81460f501624e1336",
  )
  let local_writer = second.state.snapshot.writer_commitments[1]
  assert_eq(local_writer.leaf_count, 2)
  assert_eq(
    bytes_hex(local_writer.event_meta_mmr_root_v2),
    "1367b3cd88d053b029e7afb3854bb6b5728451bb4afe7ad3c5101456362aef77",
  )
  assert_eq(second.reads.metadata_queries, 0)
  assert_eq(second.reads.payload_queries, 0)
  assert_eq(second.reads.full_history_queries, 0)
}

///|
test "R-05 duplicate declared parent is a canonical-profile negative" {
  let fixture = try! generate_fixture("S-linear", 4)
  let events = fixture.events.copy()
  let duplicated = events[3].parents[0]
  events[3] = { ..events[3], parents: [duplicated, duplicated] }
  let invalid = { ..fixture, events, }
  try capture_paper_branch_candidate(invalid) catch {
    R0CodecError::InvalidValue(detail="duplicate_declared_parent_unsupported") =>
      ()
    _ => fail("wrong duplicate-parent detector")
  } noraise {
    _ => fail("duplicate declared parents produced a digest alias")
  }
}

///|
test "L-04 rank exhaustion is pure and L-05 pre-capture undo never guesses a target" {
  let fixture = try! generate_fixture("S-linear", 4)
  let capture = try! capture_paper_branch_candidate(fixture)
  let restored = try! validate_paper_branch_candidate(capture.candidate_bytes)
  let branch = try! begin_ordinary_paper_branch(
    restored,
    fresh_writer="r0-fresh-negative",
  )
  let head = branch.snapshot.exact_head_records[0]
  let exhausted_heads = [{ ..head, causal_rank_timestamp: 0x7fff_ffff }]
  let exhausted_snapshot_without_commit : OrdinarySnapshot = {
    ..branch.snapshot,
    graph_root_v2: try! encode_graph_root(exhausted_heads),
    exact_head_records: exhausted_heads,
    snapshot_commit_id: Bytes::new(0),
  }
  let exhausted_snapshot = {
    ..exhausted_snapshot_without_commit,
    snapshot_commit_id: try! derive_snapshot_commit_id(
      exhausted_snapshot_without_commit,
    ),
  }
  let exhausted_branch = { ..branch, snapshot: exhausted_snapshot }
  try apply_local_insert(exhausted_branch, position=4, scalar="Z") catch {
    R0CodecError::InvalidValue(detail="rank_exhausted") => ()
    _ => fail("wrong rank exhaustion detector")
  } noraise {
    _ => fail("maximum rank emitted a local event")
  }
  assert_eq(exhausted_branch.document_text, branch.document_text)
  assert_eq(exhausted_branch.fresh_writer_metas.length(), 0)
  let undo = request_pre_capture_undo(branch)
  assert_eq(undo.reason, "pre_capture_undo_receipt_absent")
  assert_eq(undo.state.document_text, branch.document_text)
  assert_eq(undo.state.fresh_writer_metas.length(), 0)
  assert_eq(undo.reads.metadata_queries, 0)
  assert_eq(undo.reads.payload_queries, 0)
  assert_eq(undo.reads.full_history_queries, 0)
}

///|
test "capture rejects fixture body bytes that differ from the canonical body" {
  let fixture = try! generate_fixture("S-linear", 4)
  let events = fixture.events.copy()
  events[0] = { ..events[0], canonical_body_bytes: b"wrong" }
  let invalid = { ..fixture, events, }
  try capture_paper_branch_candidate(invalid) catch {
    R0CodecError::InvalidValue(detail="canonical body bytes mismatch") => ()
    _ => fail("wrong canonical-body mismatch detector")
  } noraise {
    _ => fail("fixture body bytes disagreed with the committed body")
  }
}

///|
test "snapshot rejects writer leaf counts outside signed R0 bounds" {
  let fixture = try! generate_fixture("S-linear", 4)
  let capture = try! capture_paper_branch_candidate(fixture)
  let restored = try! validate_paper_branch_candidate(capture.candidate_bytes)
  let writers = restored.snapshot.writer_commitments.copy()
  writers[0] = { ..writers[0], leaf_count: 0x8000_0000 }
  let invalid = { ..restored.snapshot, writer_commitments: writers }
  try validate_snapshot(invalid) catch {
    R0CodecError::InvalidValue(detail="writer leaf count outside R0 bounds") =>
      ()
    _ => fail("wrong writer leaf-count detector")
  } noraise {
    _ => fail("oversized writer membership range was accepted")
  }
}

///|
test "native capture is cross-checked through typed EGW authority admission" {
  let fixture = try! generate_fixture("S-linear", 4)
  let capture = try! capture_paper_branch_candidate(fixture)
  let evidence = try! validate_capture_against_egw_authority(
    fixture,
    capture.candidate_bytes,
  )
  assert_eq(evidence.committed_events, 4)
  assert_eq(evidence.pending_after_count, 0)
  assert_eq(evidence.authority_text, fixture.final_text)
  assert_eq(evidence.exact_heads, [RawIdentity(agent="r0-a", sequence=3)])
  assert_eq(evidence.head_ranks, [3])
  assert_true(evidence.used_typed_admission_receipts)
  assert_eq(evidence.full_history_walks, 0)
}
