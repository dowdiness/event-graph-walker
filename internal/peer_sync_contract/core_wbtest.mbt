/// Private EGW 0.4 peer-sync event/decision contract experiment.
///
/// The reducer stores only peer lifecycle and bounded recovery metadata. Versions,
/// messages, operations, documents, and causal pending state stay in drivers.

///|
priv enum PeerPhase {
  Bootstrapping
  Recovering
  Idle
  Disconnected
  Escalated
}

///|
priv struct PeerMetadata {
  phase : PeerPhase
  full_sync_requested : Bool
  retry_count : Int
}

///|
priv struct State {
  peers : Map[String, PeerMetadata]
}

///|
fn State::empty() -> State {
  { peers: Map([]) }
}

///|
priv struct Observation {
  applied : Int
  duplicates : Int
  pending : Int
}

///|
/// The façades expose different applied-operation counters. They are normalized
/// at the driver edge and never become reducer state.
fn text_observation(report : @text.SyncReport) -> Observation {
  {
    applied: report.applied_operations(),
    duplicates: report.duplicate_operations(),
    pending: report.pending_operations(),
  }
}

///|
fn container_observation(report : @container.SyncReport) -> Observation {
  {
    applied: report.applied_tree_operations() + report.applied_text_operations(),
    duplicates: report.duplicate_operations(),
    pending: report.pending_operations(),
  }
}

///|
priv enum Event {
  PeerAvailable(String)
  PeerDisconnected(String)
  VersionCompared(String, Bool)
  FullSyncRequested(String)
  LocalCommitted
  Applied(String, Observation)
  Failed(String, @sync.Failure)
  RecoveryTimedOut(String)
  Reconnect(String)
  PeerDeparted(String)
}

///|
priv enum Decision {
  SendVersion(String)
  RequestFullSync(String)
  SendFullSync(String)
  SendIncrementalSync(String)
  ReportRecovered(String)
  RetryFullSync(String)
  ReportRecoveryExhausted(String)
  ReportFailure(String, @sync.Failure)
  Escalate(String, @sync.Failure)
}

///|
/// A deliberately small private bound: timeout retries are metadata, not a
/// transport queue or an unbounded retry loop.
let recovery_retry_limit : Int = 2

///|
fn bootstrap_metadata() -> PeerMetadata {
  { phase: Bootstrapping, full_sync_requested: false, retry_count: 0 }
}

///|
fn is_connected(metadata : PeerMetadata) -> Bool {
  match metadata.phase {
    Bootstrapping | Recovering | Idle => true
    Disconnected | Escalated => false
  }
}

///|
fn request_full_sync_if_needed(
  peer : String,
  metadata : PeerMetadata,
  decisions : Array[Decision],
) -> PeerMetadata {
  if metadata.full_sync_requested {
    metadata
  } else {
    decisions.push(RequestFullSync(peer))
    {
      phase: Recovering,
      full_sync_requested: true,
      retry_count: metadata.retry_count,
    }
  }
}

///|
/// Deterministic functional core: peer metadata plus an event produces a copied
/// metadata map and transport/report decisions for the imperative shell.
fn transition(state : State, event : Event) -> (State, Array[Decision]) {
  let peers = state.peers.copy()
  let decisions : Array[Decision] = []
  match event {
    PeerAvailable(peer) =>
      // Admission is the only event that can create a peer. Existing metadata,
      // including Disconnected and Escalated, is deliberately untouched.
      match peers.get(peer) {
        None => {
          peers[peer] = bootstrap_metadata()
          decisions.push(SendVersion(peer))
        }
        Some(_) => ()
      }
    PeerDisconnected(peer) =>
      match peers.get(peer) {
        Some(metadata) =>
          if is_connected(metadata) {
            peers[peer] = {
              phase: Disconnected,
              full_sync_requested: metadata.full_sync_requested,
              retry_count: metadata.retry_count,
            }
          }
        None => ()
      }
    VersionCompared(peer, equal) =>
      match peers.get(peer) {
        Some(metadata) =>
          if is_connected(metadata) {
            if equal {
              match metadata.phase {
                Bootstrapping | Recovering => {
                  peers[peer] = {
                    phase: Idle,
                    full_sync_requested: false,
                    retry_count: 0,
                  }
                  decisions.push(ReportRecovered(peer))
                }
                Idle => ()
                Disconnected | Escalated => ()
              }
            } else {
              peers[peer] = request_full_sync_if_needed(
                peer, metadata, decisions,
              )
            }
          }
        None => ()
      }
    FullSyncRequested(peer) =>
      match peers.get(peer) {
        Some(metadata) =>
          if is_connected(metadata) {
            decisions.push(SendFullSync(peer))
          }
        None => ()
      }
    LocalCommitted =>
      peers.each(fn(peer, metadata) {
        if is_connected(metadata) {
          decisions.push(SendIncrementalSync(peer))
        }
      })
    Applied(peer, observation) =>
      match peers.get(peer) {
        Some(metadata) =>
          if is_connected(metadata) {
            if observation.pending > 0 {
              peers[peer] = request_full_sync_if_needed(
                peer,
                {
                  phase: Recovering,
                  full_sync_requested: metadata.full_sync_requested,
                  retry_count: metadata.retry_count,
                },
                decisions,
              )
            } else {
              // An apply is only an acknowledgement opportunity. Even a
              // non-empty, duplicate-free full sync cannot prove convergence:
              // the shell must compare façade versions afterward.
              peers[peer] = metadata
              decisions.push(SendVersion(peer))
            }
          }
        None => ()
      }
    Failed(peer, failure) =>
      match peers.get(peer) {
        Some(metadata) =>
          if is_connected(metadata) {
            match failure {
              @sync.Failure::MissingDependency(_) => {
                decisions.push(ReportFailure(peer, failure))
                peers[peer] = request_full_sync_if_needed(
                  peer,
                  {
                    phase: Recovering,
                    full_sync_requested: metadata.full_sync_requested,
                    retry_count: metadata.retry_count,
                  },
                  decisions,
                )
              }
              @sync.Failure::MalformedMessage(_)
              | @sync.Failure::InvalidContent(_)
              | @sync.Failure::ConflictingIdentity(_)
              | @sync.Failure::LimitExceeded(_) => {
                peers[peer] = {
                  phase: Escalated,
                  full_sync_requested: false,
                  retry_count: metadata.retry_count,
                }
                decisions.push(ReportFailure(peer, failure))
                decisions.push(Escalate(peer, failure))
              }
            }
          }
        None => ()
      }
    RecoveryTimedOut(peer) =>
      match peers.get(peer) {
        Some(metadata) =>
          match metadata.phase {
            Recovering =>
              if metadata.retry_count < recovery_retry_limit {
                peers[peer] = {
                  phase: Recovering,
                  full_sync_requested: true,
                  retry_count: metadata.retry_count + 1,
                }
                decisions.push(RetryFullSync(peer))
              } else {
                peers[peer] = {
                  phase: Escalated,
                  full_sync_requested: false,
                  retry_count: metadata.retry_count,
                }
                decisions.push(ReportRecoveryExhausted(peer))
              }
            Bootstrapping | Idle | Disconnected | Escalated => ()
          }
        None => ()
      }
    Reconnect(peer) =>
      match peers.get(peer) {
        Some(metadata) =>
          match metadata.phase {
            Disconnected => {
              peers[peer] = {
                phase: Recovering,
                full_sync_requested: true,
                retry_count: 0,
              }
              decisions.push(RequestFullSync(peer))
            }
            Bootstrapping | Recovering | Idle | Escalated => ()
          }
        None => ()
      }
    PeerDeparted(peer) => {
      let _ = peers.remove(peer)
    }
  }
  ({ peers, }, decisions)
}

///|
fn text_failure(error : @text.TextError) -> @sync.Failure? {
  match error {
    @text.TextError::SyncFailed(failure) => Some(failure)
    _ => None
  }
}

///|
fn container_failure(error : @container.DocumentError) -> @sync.Failure? {
  match error {
    @container.DocumentError::SyncFailed(failure) => Some(failure)
    _ => None
  }
}
