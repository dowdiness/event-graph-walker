///|
priv enum BodyProfile {
  AsciiBody
  EscapedBody
  UnicodeBody
}

///|
fn BodyProfile::label(self : BodyProfile) -> String {
  match self {
    AsciiBody => "ascii"
    EscapedBody => "escaped-json"
    UnicodeBody => "unicode"
  }
}

///|
fn BodyProfile::body(self : BodyProfile) -> String {
  match self {
    AsciiBody => "x".repeat(64)
    EscapedBody => "\"\\\n".repeat(21) + "x"
    UnicodeBody => "雪🌙".repeat(16)
  }
}

///|
priv struct CheckpointStats {
  operations : Int
  json_bytes : Int
  canonical_bytes : Int
  json : String
  canonical : Bytes
}

///|
priv struct ExactHead {
  version : @container.Version
  canonical : Bytes
  json : String
}

///|
priv struct CandidateBuild {
  document : @container.Document
  incident : @container.TreeNodeId
  appended : @container.TreeNodeId
  stats : CheckpointStats
  delta : @container.SyncMessage
  elapsed_us : Int
  source_unchanged : Bool
  source_had_local_undo : Bool
  restored_had_prior_undo : Bool
  source_pending_operations : Int
}

///|
priv struct PreparedCandidate {
  build : CandidateBuild
  planned_head : ExactHead
  deterministic : Bool
}

///|
priv struct Runtime {
  mut active : @container.Document
  mut incident : @container.TreeNodeId
  mut contribution_count : Int
  mut selected_scale : Int
  mut profile : BodyProfile
  mut prepared : PreparedCandidate?
  mut last_committed_node_key : String?
  mut last_action : String
  mut result_lines : Array[String]
  mut candidate_verdict : String
  mut bound_verdict : String
}

///|
priv suberror ProbeStop {
  ProbeStop
} derive(Debug)

///|
fn checkpoint_stats(document : @container.Document) -> CheckpointStats raise {
  let message = document.sync().export_all()
  let json = message.to_json_string()
  let canonical = message.to_canonical_bytes()
  {
    operations: message.op_count(),
    json_bytes: @utf8.encode(json).length(),
    canonical_bytes: canonical.length(),
    json,
    canonical,
  }
}

///|
fn exact_head(document : @container.Document) -> ExactHead raise {
  let stats = checkpoint_stats(document)
  { version: document.version(), canonical: stats.canonical, json: stats.json }
}

///|
fn append_record(
  document : @container.Document,
  incident : @container.TreeNodeId,
  index : Int,
  body : String,
) -> @container.TreeNodeId raise {
  let record = document.create_node(parent=incident)
  document.set_property(record, "record_type", "prototype/observation/v1")
  document.set_property(record, "contribution_id", "record-\{index}")
  document.set_property(record, "body", body)
  record
}

///|
fn build_baseline(
  contribution_count : Int,
) -> (@container.Document, @container.TreeNodeId) raise {
  let document = @container.Document::new("prototype-authority-writer")
  let incident = document.create_node(parent=@container.root_id)
  document.set_property(incident, "record_type", "prototype/incident/v1")
  for index in 0..<contribution_count {
    let _ = append_record(document, incident, index, "x".repeat(64))
  }
  (document, incident)
}

///|
fn restore_checkpoint(
  replica_id : String,
  encoded : String,
) -> @container.Document raise {
  let restored = @container.Document::new(replica_id)
  let message = restored.sync().decode_json(encoded)
  let report = restored.sync().apply(message)
  if report.pending_operations() != 0 ||
    restored.sync().pending_sync_count() != 0 {
    fail("prototype restore left pending operations")
  }
  restored
}

///|
fn source_matches_head(
  source : @container.Document,
  head : ExactHead,
) -> (Bool, Bool) raise {
  let current = checkpoint_stats(source)
  (source.version() == head.version, current.canonical == head.canonical)
}

///|
fn build_candidate(
  source : @container.Document,
  incident : @container.TreeNodeId,
  replica_id : String,
  contribution_index : Int,
  body : String,
) -> CandidateBuild raise {
  let source_head = exact_head(source)
  let source_before = checkpoint_stats(source)
  let started = @bench.monotonic_clock_start()
  let candidate = restore_checkpoint(replica_id, source_before.json)
  let restored = checkpoint_stats(candidate)
  let restored_had_prior_undo = candidate.can_undo()
  if candidate.version() != source_head.version ||
    restored.canonical != source_head.canonical {
    fail("prototype candidate did not reproduce the exact source head")
  }
  let appended = append_record(candidate, incident, contribution_index, body)
  let delta = candidate.sync().export_since(source_head.version)
  let stats = checkpoint_stats(candidate)
  let elapsed_us = @bench.monotonic_clock_end(started).to_int()
  let source_after = checkpoint_stats(source)
  {
    document: candidate,
    incident,
    appended,
    stats,
    delta,
    elapsed_us,
    source_unchanged: source.version() == source_head.version &&
    source_after.canonical == source_head.canonical,
    source_had_local_undo: source.can_undo(),
    restored_had_prior_undo,
    source_pending_operations: source.sync().pending_sync_count(),
  }
}

///|
fn Runtime::new(scale : Int) -> Runtime raise {
  let (active, incident) = build_baseline(scale)
  {
    active,
    incident,
    contribution_count: scale,
    selected_scale: scale,
    profile: AsciiBody,
    prepared: None,
    last_committed_node_key: None,
    last_action: "baseline initialized",
    result_lines: [],
    candidate_verdict: "not prepared",
    bound_verdict: "not assessed",
  }
}

///|
fn Runtime::reset(self : Runtime) -> Unit raise {
  let (active, incident) = build_baseline(self.selected_scale)
  self.active = active
  self.incident = incident
  self.contribution_count = self.selected_scale
  self.prepared = None
  self.last_committed_node_key = None
  self.last_action = "baseline reset"
  self.result_lines = []
  self.candidate_verdict = "not prepared"
  self.bound_verdict = "not assessed"
}

///|
fn Runtime::prepare_candidate(self : Runtime) -> Unit raise {
  let body = self.profile.body()
  let planned_head = exact_head(self.active)
  let first = build_candidate(
    self.active,
    self.incident,
    "prototype-authority-writer",
    self.contribution_count,
    body,
  )
  let second = build_candidate(
    self.active,
    self.incident,
    "prototype-authority-writer",
    self.contribution_count,
    body,
  )
  let deterministic = first.stats.canonical == second.stats.canonical &&
    first.delta.to_canonical_bytes() == second.delta.to_canonical_bytes() &&
    first.appended == second.appended
  let (version_matches, canonical_bytes_match) = source_matches_head(
    self.active,
    planned_head,
  )
  let decision = decide_candidate({
    source_unchanged: first.source_unchanged,
    candidate_deterministic: deterministic,
    version_matches,
    canonical_bytes_match,
    source_pending_operations: first.source_pending_operations,
    delta_operations: first.delta.op_count(),
    expected_operations: 4,
  })
  self.prepared = Some({ build: first, planned_head, deterministic })
  self.last_action = "prepared exact same-writer candidate"
  self.candidate_verdict = match decision {
    AcceptExactCrdtCandidate =>
      "READY FOR PROBE: exact CRDT candidate; local history is not equivalent"
    RejectStaleHead => "REJECT: source head changed"
    RejectInvalidEvidence => "INVALID: exact candidate evidence failed"
  }
  self.result_lines = [
    "source_unchanged=\{first.source_unchanged}",
    "deterministic_reconstruction=\{deterministic}",
    "delta_operations=\{first.delta.op_count()} (expected 4)",
    "candidate_operations=\{first.stats.operations}",
    "candidate_json_bytes=\{first.stats.json_bytes}",
    "candidate_canonical_bytes=\{first.stats.canonical_bytes}",
    "first_prepare_us=\{first.elapsed_us} second_prepare_us=\{second.elapsed_us}",
    "candidate_node=\{first.appended.key()}",
    "source_local_undo_available=\{first.source_had_local_undo}",
    "restored_prior_undo_available=\{first.restored_had_prior_undo}",
    "source_pending_operations=\{first.source_pending_operations}",
  ]
}

///|
fn Runtime::candidate_decision(
  self : Runtime,
  prepared : PreparedCandidate,
) -> CandidateDecision raise {
  let (version_matches, canonical_bytes_match) = source_matches_head(
    self.active,
    prepared.planned_head,
  )
  decide_candidate({
    source_unchanged: prepared.build.source_unchanged,
    candidate_deterministic: prepared.deterministic,
    version_matches,
    canonical_bytes_match,
    source_pending_operations: self.active.sync().pending_sync_count(),
    delta_operations: prepared.build.delta.op_count(),
    expected_operations: 4,
  })
}

///|
fn Runtime::commit_candidate_swap(self : Runtime) -> Unit raise {
  guard self.prepared is Some(prepared) else {
    self.last_action = "candidate swap skipped"
    self.result_lines = ["prepare a candidate first with [p]"]
    return
  }
  match self.candidate_decision(prepared) {
    AcceptExactCrdtCandidate => {
      let prior_source_undo_available = self.active.can_undo()
      let prior_source_undo_history_preserved = !prior_source_undo_available ||
        prepared.build.restored_had_prior_undo
      self.active = prepared.build.document
      self.incident = prepared.build.incident
      let active_stats = checkpoint_stats(self.active)
      if active_stats.canonical != prepared.build.stats.canonical ||
        self.active.sync().pending_sync_count() != 0 {
        fail("prototype candidate swap violated its exact-successor invariants")
      }
      self.contribution_count = self.contribution_count + 1
      self.last_committed_node_key = Some(prepared.build.appended.key())
      self.prepared = None
      self.last_action = "committed by replacing active Document with candidate"
      self.candidate_verdict = "PROBE COMMIT: candidate became exact CRDT successor"
      self.result_lines = [
        "active_operations=\{prepared.build.stats.operations}",
        "active_canonical_bytes=\{prepared.build.stats.canonical_bytes}",
        "candidate_command_undo_available=\{self.active.can_undo()}",
        "prior_source_undo_history_preserved=\{prior_source_undo_history_preserved}",
        "next action [n] verifies same-writer continuation",
      ]
    }
    RejectStaleHead => {
      self.prepared = None
      self.last_action = "candidate swap rejected"
      self.candidate_verdict = "REJECTED: exact head fence failed"
      self.result_lines = ["source Version or canonical bytes changed"]
    }
    RejectInvalidEvidence => {
      self.prepared = None
      self.last_action = "candidate swap rejected"
      self.candidate_verdict = "REJECTED: candidate evidence invalid"
      self.result_lines = []
    }
  }
}

///|
fn Runtime::apply_candidate_delta(self : Runtime) -> Unit raise {
  guard self.prepared is Some(prepared) else {
    self.last_action = "delta-back skipped"
    self.result_lines = ["prepare a candidate first with [p]"]
    return
  }
  match self.candidate_decision(prepared) {
    AcceptExactCrdtCandidate => {
      let undo_before = self.active.can_undo()
      let undo_probe = restore_checkpoint(
        "prototype-authority-writer",
        prepared.planned_head.json,
      )
      let _ = undo_probe.sync().apply(prepared.build.delta)
      let candidate_command_recorded_as_local_undo = undo_probe.can_undo()
      let report = self.active.sync().apply(prepared.build.delta)
      let active_stats = checkpoint_stats(self.active)
      let exact_successor = active_stats.canonical ==
        prepared.build.stats.canonical
      let valid_apply = report.applied_tree_operations() == 4 &&
        report.duplicate_operations() == 0 &&
        report.pending_operations() == 0 &&
        self.active.sync().pending_sync_count() == 0 &&
        exact_successor &&
        !candidate_command_recorded_as_local_undo
      if !valid_apply {
        fail("prototype delta-back violated its exact-apply invariants")
      }
      self.contribution_count = self.contribution_count + 1
      self.last_committed_node_key = Some(prepared.build.appended.key())
      self.prepared = None
      self.last_action = "committed candidate delta back to unchanged source"
      self.candidate_verdict = "PROBE COMMIT: delta-back reproduced exact CRDT successor"
      self.result_lines = [
        "applied_tree_operations=\{report.applied_tree_operations()}",
        "duplicate_operations=\{report.duplicate_operations()}",
        "pending_operations=\{report.pending_operations()}",
        "canonical_successor_equal=\{exact_successor}",
        "source_prior_undo_available_before=\{undo_before}",
        "source_prior_undo_available_after=\{self.active.can_undo()}",
        "candidate_command_recorded_as_local_undo=\{candidate_command_recorded_as_local_undo}",
        "next action [n] verifies counter continuation",
      ]
    }
    RejectStaleHead => {
      self.prepared = None
      self.last_action = "delta-back rejected"
      self.candidate_verdict = "REJECTED: exact head fence failed"
      self.result_lines = ["source Version or canonical bytes changed"]
    }
    RejectInvalidEvidence => {
      self.prepared = None
      self.last_action = "delta-back rejected"
      self.candidate_verdict = "REJECTED: candidate evidence invalid"
      self.result_lines = []
    }
  }
}

///|
fn Runtime::make_source_stale(self : Runtime) -> Unit {
  self.active.set_property(
    self.incident,
    "stale_probe",
    "stale-\{self.contribution_count}",
  )
  self.last_action = "mutated source after preparation"
  self.candidate_verdict = "STALE: commit must reject"
  self.result_lines = ["source head advanced by one property operation"]
}

///|
fn Runtime::continue_writer(self : Runtime) -> Unit raise {
  let before = self.active.version()
  let previous_key = self.last_committed_node_key
  let appended = append_record(
    self.active,
    self.incident,
    self.contribution_count,
    self.profile.body(),
  )
  let delta = self.active.sync().export_since(before)
  let unique = match previous_key {
    Some(key) => key != appended.key()
    None => true
  }
  if !unique ||
    delta.op_count() != 4 ||
    self.active.sync().pending_sync_count() != 0 {
    fail(
      "prototype continuation violated writer identity or operation invariants",
    )
  }
  self.contribution_count = self.contribution_count + 1
  self.last_committed_node_key = Some(appended.key())
  self.last_action = "continued active writer after commit"
  self.result_lines = [
    "followup_node=\{appended.key()}",
    "node_identity_unique=\{unique}",
    "followup_delta_operations=\{delta.op_count()} (expected 4)",
    "followup_properties=\{to_repr(self.active.properties(appended))}",
  ]
}

///|
fn Runtime::compare_fresh_replica(self : Runtime) -> Unit raise {
  let authority = build_candidate(
    self.active,
    self.incident,
    "prototype-authority-writer",
    self.contribution_count,
    self.profile.body(),
  )
  let fresh = build_candidate(
    self.active,
    self.incident,
    "prototype-fresh-writer-with-different-length",
    self.contribution_count,
    self.profile.body(),
  )
  let same_operations = authority.stats.operations == fresh.stats.operations
  let same_encoding = authority.stats.canonical == fresh.stats.canonical
  if !same_operations || same_encoding {
    fail("prototype fresh-replica counterexample was not reproduced")
  }
  self.last_action = "compared authority candidate with fresh replica"
  self.result_lines = [
    "same_operation_count=\{same_operations}",
    "authority_canonical_bytes=\{authority.stats.canonical_bytes}",
    "fresh_canonical_bytes=\{fresh.stats.canonical_bytes}",
    "exact_encoding_equal=\{same_encoding}",
    "verdict=fresh replica is not an exact byte oracle",
  ]
}

///|
fn create_then_stop(document : @container.Document) -> Unit raise {
  let _ = document.create_node(parent=@container.root_id)
  raise ProbeStop
}

///|
fn Runtime::probe_transaction(self : Runtime) -> Unit raise {
  let document = @container.Document::new("prototype-transaction")
  let before = checkpoint_stats(document)
  try document.transaction(() => create_then_stop(document)) catch {
    ProbeStop => ()
    error => raise error
  } noraise {
    _ => fail("prototype transaction must raise")
  }
  let after = checkpoint_stats(document)
  if after.operations != before.operations + 1 {
    fail("prototype transaction probe did not retain exactly one operation")
  }
  self.last_action = "raised after one mutation inside Document::transaction"
  self.result_lines = [
    "before_operations=\{before.operations}",
    "after_operations=\{after.operations}",
    "rollback=\{after.operations == before.operations}",
    "verdict=transaction is undo grouping, not dry-run rollback",
  ]
}

///|
fn Runtime::probe_bound(self : Runtime) -> Unit raise {
  let source = checkpoint_stats(self.active)
  let lines : Array[String] = []
  for profile in [AsciiBody, EscapedBody, UnicodeBody] {
    let body = profile.body()
    let candidate = build_candidate(
      self.active,
      self.incident,
      "prototype-authority-writer",
      self.contribution_count,
      body,
    )
    lines.push(
      "\{profile.label()}: body_utf8=\{@utf8.encode(body).length()} " +
      "canonical_growth=\{candidate.stats.canonical_bytes - source.canonical_bytes} " +
      "json_growth=\{candidate.stats.json_bytes - source.json_bytes}",
    )
  }
  let decision = decide_bound({
    has_public_preapply_estimator: false,
    generated_metadata_is_bounded: false,
    no_underestimation_verified: false,
  })
  self.bound_verdict = match decision {
    BoundProven => "PROVEN"
    BoundUnavailable =>
      "UNAVAILABLE: public API exposes exact bytes only after candidate mutation"
  }
  lines.push(
    "private generated metadata includes counters, timestamps, parents, and positions",
  )
  lines.push(
    "verdict=no conservative no-underestimation proof from current public API",
  )
  self.last_action = "compared exact growth across body encodings"
  self.result_lines = lines
}

///|
fn Runtime::measure_reconstruction(self : Runtime) -> Unit raise {
  let timings : Array[Int] = []
  for _sample in 0..<5 {
    let candidate = build_candidate(
      self.active,
      self.incident,
      "prototype-authority-writer",
      self.contribution_count,
      self.profile.body(),
    )
    timings.push(candidate.elapsed_us)
  }
  timings.sort()
  self.last_action = "measured five isolated candidate reconstructions"
  self.result_lines = [
    "scale=\{self.selected_scale} existing contributions",
    "min_us=\{timings[0]}",
    "median_us=\{timings[2]}",
    "max_us=\{timings[4]}",
    "measurement=restore + append 4 ops + full export",
  ]
}

///|
fn render(runtime : Runtime) -> Unit raise {
  println("\u001b[2J\u001b[H")
  let stats = checkpoint_stats(runtime.active)
  println("ISSUE #101 THROWAWAY PROTOTYPE — local footprint evidence")
  println(
    "Question: exact same-writer candidate or provable conservative bound?",
  )
  println("")
  println("CURRENT STATE")
  println("  scale: \{runtime.selected_scale} existing contributions")
  println("  body profile: \{runtime.profile.label()}")
  println("  active operations: \{stats.operations}")
  println("  active canonical bytes: \{stats.canonical_bytes}")
  println("  prepared candidate: \{runtime.prepared is Some(_)}")
  println("  candidate verdict: \{runtime.candidate_verdict}")
  println("  bound verdict: \{runtime.bound_verdict}")
  println("  last action: \{runtime.last_action}")
  println("")
  println("EVIDENCE")
  if runtime.result_lines.is_empty() {
    println("  (run a scenario)")
  } else {
    for line in runtime.result_lines {
      println("  \{line}")
    }
  }
  println("")
  println("ACTIONS — enter one key then Return")
  println("  [0] empty  [1] 100 records  [5] 499 records  [r] reset")
  println("  [a] ASCII  [e] escaped  [u] Unicode  [p] prepare")
  println("  [c] candidate-swap  [d] delta-back  [s] stale  [n] continue")
  println("  [f] fresh replica  [t] transaction  [b] bound  [m] timing")
  println("  [q] quit")
}

///|
async fn main {
  let runtime = Runtime::new(0)
  let mut running = true
  while running {
    render(runtime)
    match @stdio.stdin.read_until("\n") {
      None => running = false
      Some(raw) =>
        match raw.trim().to_owned() {
          "0" => {
            runtime.selected_scale = 0
            runtime.reset()
          }
          "1" => {
            runtime.selected_scale = 100
            runtime.reset()
          }
          "5" => {
            runtime.selected_scale = 499
            runtime.reset()
          }
          "r" => runtime.reset()
          "a" => {
            runtime.profile = AsciiBody
            runtime.last_action = "selected ASCII body"
          }
          "e" => {
            runtime.profile = EscapedBody
            runtime.last_action = "selected escaped body"
          }
          "u" => {
            runtime.profile = UnicodeBody
            runtime.last_action = "selected Unicode body"
          }
          "p" => runtime.prepare_candidate()
          "c" => runtime.commit_candidate_swap()
          "d" => runtime.apply_candidate_delta()
          "s" => runtime.make_source_stale()
          "n" => runtime.continue_writer()
          "f" => runtime.compare_fresh_replica()
          "t" => runtime.probe_transaction()
          "b" => runtime.probe_bound()
          "m" => runtime.measure_reconstruction()
          "q" => running = false
          _ => {
            runtime.last_action = "unknown key"
            runtime.result_lines = ["choose one action listed below"]
          }
        }
    }
  }
  println("PROTOTYPE EXIT — no state persisted")
}
