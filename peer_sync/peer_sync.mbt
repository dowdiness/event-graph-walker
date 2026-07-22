///|
/// Internal phase of the one-peer policy state.
priv enum Phase {
  Bootstrapping
  Recovering
  Idle
  Escalated
}

///|
/// Opaque state for one remote peer's EGW synchronization policy.
///
/// The state contains no peer identity, transport lifecycle, timer, payload,
/// document, or causal-operation queue.
pub struct State {
  priv phase : Phase
  priv full_sync_outstanding : Bool
}

///|
/// Causal meaning of a successful EGW sync apply.
pub enum ApplyDisposition {
  CausallyComplete
  PendingDependencies
} derive(Debug, Eq)

///|
/// Recovery meaning of an EGW synchronization failure.
pub enum FailureDisposition {
  Recoverable
  Terminal
} derive(Debug, Eq)

///|
/// Peer-free action selected by the EGW synchronization policy.
pub enum Decision {
  SendVersion
  RequestFullSync
  SendFullSync
  SendIncrementalSync
  ReportRecovered
  ReportFailure
  Escalate
} derive(Debug, Eq)

///|
/// Private semantic events used to share the transition implementation.
priv enum Event {
  HandshakeStarted
  VersionCompared(Bool)
  FullRecoveryRequired
  FullSyncRequested
  LocalVersionAdvanced
  Applied(ApplyDisposition)
  Failed(FailureDisposition)
}

///|
/// Construct a policy in its initial handshake state.
pub fn State::State() -> State {
  { phase: Bootstrapping, full_sync_outstanding: false }
}

///|
/// Whether this policy may still process semantic synchronization events.
fn State::is_active(self : State) -> Bool {
  match self.phase {
    Escalated => false
    _ => true
  }
}

///|
/// Select a full-sync request once for the current recovery cycle.
fn State::request_full_sync(self : State, decisions : Array[Decision]) -> State {
  if self.full_sync_outstanding {
    self
  } else {
    Array::push(decisions, RequestFullSync)
    { phase: Recovering, full_sync_outstanding: true }
  }
}

///|
/// Apply one private semantic event.
fn State::apply_event(self : State, event : Event) -> (State, Array[Decision]) {
  let decisions : Array[Decision] = []
  if State::is_active(self) is false {
    (self, decisions)
  } else {
    match event {
      HandshakeStarted =>
        if self.phase is Bootstrapping {
          (self, [SendVersion])
        } else {
          (self, decisions)
        }
      VersionCompared(equal) =>
        if equal {
          match self.phase {
            Bootstrapping | Recovering =>
              ({ phase: Idle, full_sync_outstanding: false }, [ReportRecovered])
            Idle | Escalated => (self, decisions)
          }
        } else {
          let next = State::request_full_sync(self, decisions)
          (next, decisions)
        }
      FullRecoveryRequired =>
        ({ phase: Recovering, full_sync_outstanding: true }, [RequestFullSync])
      FullSyncRequested => (self, [SendFullSync])
      LocalVersionAdvanced => (self, [SendIncrementalSync])
      Applied(disposition) =>
        match disposition {
          PendingDependencies => {
            let next = State::request_full_sync(self, decisions)
            (next, decisions)
          }
          CausallyComplete => (self, [SendVersion])
        }
      Failed(disposition) =>
        match disposition {
          Recoverable => {
            Array::push(decisions, ReportFailure)
            let next = State::request_full_sync(self, decisions)
            (next, decisions)
          }
          Terminal =>
            (
              { phase: Escalated, full_sync_outstanding: false },
              [ReportFailure, Escalate],
            )
        }
    }
  }
}

///|
/// Record that the semantic version handshake started.
pub fn State::handshake_started(self : State) -> (State, Array[Decision]) {
  State::apply_event(self, HandshakeStarted)
}

///|
/// Record the result of comparing local and remote EGW versions.
pub fn State::version_compared(
  self : State,
  equal : Bool,
) -> (State, Array[Decision]) {
  State::apply_event(self, VersionCompared(equal))
}

///|
/// Start a new full-recovery cycle after the shell determines that any prior
/// request can no longer complete, such as after reconnect.
pub fn State::full_recovery_required(self : State) -> (State, Array[Decision]) {
  State::apply_event(self, FullRecoveryRequired)
}

///|
/// Record that the remote peer requested a full synchronization message.
pub fn State::full_sync_requested(self : State) -> (State, Array[Decision]) {
  State::apply_event(self, FullSyncRequested)
}

///|
/// Record that the local authoritative EGW version advanced.
pub fn State::local_version_advanced(self : State) -> (State, Array[Decision]) {
  State::apply_event(self, LocalVersionAdvanced)
}

///|
/// Interpret the causal result of applying an EGW synchronization message.
pub fn State::applied(
  self : State,
  disposition : ApplyDisposition,
) -> (State, Array[Decision]) {
  State::apply_event(self, Applied(disposition))
}

///|
/// Interpret a normalized EGW synchronization failure.
pub fn State::failed(
  self : State,
  disposition : FailureDisposition,
) -> (State, Array[Decision]) {
  State::apply_event(self, Failed(disposition))
}

///|
/// Normalize an EGW pending-operation count at a façade edge.
/// Non-positive counts classify as causally complete.
pub fn ApplyDisposition::ApplyDisposition(
  pending_operations : Int,
) -> ApplyDisposition {
  if pending_operations > 0 {
    PendingDependencies
  } else {
    CausallyComplete
  }
}

///|
/// Construct a recoverable peer-sync failure disposition.
pub fn FailureDisposition::recoverable() -> FailureDisposition {
  Recoverable
}

///|
/// Classify a shared EGW synchronization failure for peer recovery.
pub fn FailureDisposition::FailureDisposition(
  failure : @sync.Failure,
) -> FailureDisposition {
  match failure {
    @sync.Failure::MissingDependency(_) => Recoverable
    @sync.Failure::MalformedMessage(_)
    | @sync.Failure::InvalidContent(_)
    | @sync.Failure::ConflictingIdentity(_)
    | @sync.Failure::LimitExceeded(_) => Terminal
  }
}
