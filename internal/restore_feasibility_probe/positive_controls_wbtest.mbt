///|
test "X-01 through X-05 isolate every evidence counter family" {
  let source = try! @text.TextState::new("positive-controls")
  try! source.insert(@text.Pos::at(0), "a")
  try! source.insert(@text.Pos::at(1), "😀")
  try! source.insert(@text.Pos::at(2), "z")
  let history = try! source.sync().export_all()
  let detector = EvidenceDetector::new(history)
  let rows = positive_control_observations(
    detector,
    source.text(),
    history_events=3,
    history_bytes=11,
    metadata_bytes=32,
    proof_bytes=64,
    payload_bytes=5,
  )
  assert_eq(rows.length(), 5)
  let x01 = rows[0]
  assert_eq(x01.case_id, "X-01")
  assert_eq(x01.logical_queries, 1)
  assert_eq(x01.physical_reads, 1)
  assert_eq(x01.metadata_records, 3)
  assert_eq(x01.metadata_bytes, 32)
  assert_eq(x01.proof_bytes, 64)
  assert_eq(x01.requested_identities, 0)
  assert_eq(x01.payload_bytes, 0)
  assert_eq(x01.scan_records_visited, 0)
  assert_eq(x01.full_history_events, 0)
  assert_eq(x01.utf16_code_units, 0)
  assert_false(x01.rejected)
  let x02 = rows[1]
  assert_eq(x02.case_id, "X-02")
  assert_eq(x02.logical_queries, 1)
  assert_eq(x02.physical_reads, 1)
  assert_eq(x02.requested_identities, 2)
  assert_eq(x02.payload_events, 2)
  assert_eq(x02.payload_bytes, 5)
  assert_eq(x02.metadata_records, 0)
  assert_eq(x02.proof_bytes, 0)
  assert_eq(x02.scan_records_visited, 0)
  assert_eq(x02.full_history_events, 0)
  assert_eq(x02.utf16_code_units, 0)
  assert_false(x02.rejected)
  let x03 = rows[2]
  assert_eq(x03.case_id, "X-03")
  assert_eq(x03.logical_queries, 1)
  assert_eq(x03.physical_reads, 0)
  assert_eq(x03.scan_records_visited, 3)
  assert_true(x03.rejected)
  assert_eq(x03.metadata_records, 0)
  assert_eq(x03.payload_events, 0)
  assert_eq(x03.full_history_events, 0)
  assert_eq(x03.utf16_code_units, 0)
  let x04 = rows[3]
  assert_eq(x04.case_id, "X-04")
  assert_eq(x04.logical_queries, 1)
  assert_eq(x04.physical_reads, 1)
  assert_eq(x04.full_history_events, 3)
  assert_eq(x04.full_history_bytes, 11)
  assert_eq(x04.metadata_records, 0)
  assert_eq(x04.payload_events, 0)
  assert_eq(x04.scan_records_visited, 0)
  assert_eq(x04.utf16_code_units, 0)
  assert_false(x04.rejected)
  let x05 = rows[4]
  assert_eq(x05.case_id, "X-05")
  assert_eq(x05.logical_queries, 0)
  assert_eq(x05.physical_reads, 0)
  assert_eq(x05.utf16_code_units, 4)
  assert_eq(x05.unicode_scalars, 3)
  assert_eq(x05.metadata_records, 0)
  assert_eq(x05.payload_events, 0)
  assert_eq(x05.scan_records_visited, 0)
  assert_eq(x05.full_history_events, 0)
  assert_false(x05.rejected)
}
