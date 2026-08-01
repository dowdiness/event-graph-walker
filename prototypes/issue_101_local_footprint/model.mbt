///|
priv struct CandidateEvidence {
  source_unchanged : Bool
  candidate_deterministic : Bool
  version_matches : Bool
  canonical_bytes_match : Bool
  source_pending_operations : Int
  delta_operations : Int
  expected_operations : Int
}

///|
priv enum CandidateDecision {
  AcceptExactCrdtCandidate
  RejectStaleHead
  RejectInvalidEvidence
}

///|
fn decide_candidate(evidence : CandidateEvidence) -> CandidateDecision {
  if !evidence.source_unchanged ||
    !evidence.candidate_deterministic ||
    evidence.source_pending_operations != 0 ||
    evidence.delta_operations != evidence.expected_operations {
    RejectInvalidEvidence
  } else if !evidence.version_matches || !evidence.canonical_bytes_match {
    RejectStaleHead
  } else {
    AcceptExactCrdtCandidate
  }
}

///|
priv struct BoundEvidence {
  has_public_preapply_estimator : Bool
  generated_metadata_is_bounded : Bool
  no_underestimation_verified : Bool
}

///|
priv enum BoundDecision {
  BoundProven
  BoundUnavailable
}

///|
fn decide_bound(evidence : BoundEvidence) -> BoundDecision {
  if evidence.has_public_preapply_estimator &&
    evidence.generated_metadata_is_bounded &&
    evidence.no_underestimation_verified {
    BoundProven
  } else {
    BoundUnavailable
  }
}
