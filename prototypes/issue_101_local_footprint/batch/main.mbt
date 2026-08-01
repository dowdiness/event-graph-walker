///|
priv struct Baseline {
  document : @container.Document
  incident : @container.TreeNodeId
  version : @container.Version
  encoded : String
}

///|
fn append_record(
  document : @container.Document,
  incident : @container.TreeNodeId,
  index : Int,
) -> Unit raise {
  let record = document.create_node(parent=incident)
  document.set_property(record, "record_type", "prototype/observation/v1")
  document.set_property(record, "contribution_id", "record-\{index}")
  document.set_property(record, "body", "x".repeat(64))
}

///|
fn build_baseline(contribution_count : Int) -> Baseline raise {
  let document = @container.Document::new("prototype-authority-writer")
  let incident = document.create_node(parent=@container.root_id)
  document.set_property(incident, "record_type", "prototype/incident/v1")
  for index in 0..<contribution_count {
    append_record(document, incident, index)
  }
  {
    document,
    incident,
    version: document.version(),
    encoded: document.sync().export_all().to_json_string(),
  }
}

///|
fn reconstruct_candidate(
  baseline : Baseline,
  contribution_index : Int,
) -> (@container.Document, Int) raise {
  let started = @bench.monotonic_clock_start()
  let candidate = @container.Document::new("prototype-authority-writer")
  let message = candidate.sync().decode_json(baseline.encoded)
  let report = candidate.sync().apply(message)
  if report.pending_operations() != 0 {
    fail("prototype batch restore left pending operations")
  }
  append_record(candidate, baseline.incident, contribution_index)
  let _ = candidate.sync().export_all().to_canonical_bytes()
  let elapsed_us = @bench.monotonic_clock_end(started).to_int()
  (candidate, elapsed_us)
}

///|
fn measure(contribution_count : Int) -> Unit raise {
  let baseline = build_baseline(contribution_count)
  let source_before = baseline.document.sync().export_all().to_canonical_bytes()
  let timings : Array[Int] = []
  let mut candidate_operations = 0
  let mut candidate_bytes = 0
  for _sample in 0..<5 {
    let (candidate, elapsed_us) = reconstruct_candidate(
      baseline, contribution_count,
    )
    let full = candidate.sync().export_all()
    let delta = candidate.sync().export_since(baseline.version)
    if delta.op_count() != 4 {
      fail("prototype batch candidate must emit four operations")
    }
    candidate_operations = full.op_count()
    candidate_bytes = full.to_canonical_bytes().length()
    timings.push(elapsed_us)
  }
  timings.sort()
  let source_after = baseline.document.sync().export_all().to_canonical_bytes()
  if source_before != source_after {
    fail("prototype batch changed its source")
  }
  println(
    "contributions=\{contribution_count} " +
    "operations=\{candidate_operations} " +
    "canonical_bytes=\{candidate_bytes} " +
    "min_us=\{timings[0]} median_us=\{timings[2]} max_us=\{timings[4]}",
  )
}

///|
fn main {
  println("PROTOTYPE #101: same-writer reconstruction timing")
  for contribution_count in [0, 100, 499] {
    try! measure(contribution_count)
  }
}
