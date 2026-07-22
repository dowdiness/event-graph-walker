/// Generic test-only lifecycle shell.
///
/// Peer IDs, admission, connectivity, retry budget, scheduling, and fan-out
/// live here. Payload T is opaque to this shell. Runtime recovery and terminal
/// metadata are updated only from public policy decisions.

///|
priv struct PeerMetadata {
  policy : @peer_sync.State
  connected : Bool
  retry_count : Int
  shell_exhausted : Bool
  recovering : Bool
  terminal : Bool
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
priv enum Event {
  PeerAvailable(String)
  PeerDisconnected(String)
  VersionCompared(String, Bool)
  FullSyncRequested(String)
  LocalCommitted
  Applied(String, @peer_sync.ApplyDisposition)
  Failed(String, @peer_sync.FailureDisposition)
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
  ReportFailure(String)
  Escalate(String)
}

///|
/// Timeout retries belong to the shell, not the one-peer policy.
let recovery_retry_limit : Int = 2

///|
fn emit_policy_decisions(
  peer : String,
  policy_decisions : Array[@peer_sync.Decision],
  decisions : Array[Decision],
  recovering : Bool,
  retry_count : Int,
  terminal : Bool,
) -> (Bool, Int, Bool) {
  let mut next_recovering = recovering
  let mut next_retry_count = retry_count
  let mut next_terminal = terminal
  policy_decisions.each(decision => {
    match decision {
      @peer_sync.Decision::SendVersion => decisions.push(SendVersion(peer))
      @peer_sync.Decision::RequestFullSync => {
        next_recovering = true
        decisions.push(RequestFullSync(peer))
      }
      @peer_sync.Decision::SendFullSync => decisions.push(SendFullSync(peer))
      @peer_sync.Decision::SendIncrementalSync =>
        decisions.push(SendIncrementalSync(peer))
      @peer_sync.Decision::ReportRecovered => {
        next_recovering = false
        next_retry_count = 0
        decisions.push(ReportRecovered(peer))
      }
      @peer_sync.Decision::ReportFailure => decisions.push(ReportFailure(peer))
      @peer_sync.Decision::Escalate => {
        next_recovering = false
        next_terminal = true
        decisions.push(Escalate(peer))
      }
    }
  })
  (next_recovering, next_retry_count, next_terminal)
}

///|
fn apply_to_peer(
  peers : Map[String, PeerMetadata],
  peer : String,
  input : PolicyInput,
  decisions : Array[Decision],
) -> Unit {
  match peers.get(peer) {
    Some(metadata) =>
      if metadata.connected &&
        metadata.shell_exhausted is false &&
        metadata.terminal is false {
        let (policy, policy_decisions) = policy_transition(
          metadata.policy,
          input,
        )
        let (recovering, retry_count, terminal) = emit_policy_decisions(
          peer,
          policy_decisions,
          decisions,
          metadata.recovering,
          metadata.retry_count,
          metadata.terminal,
        )
        peers[peer] = {
          policy,
          connected: metadata.connected,
          retry_count,
          shell_exhausted: metadata.shell_exhausted,
          recovering,
          terminal,
        }
      }
    None => ()
  }
}

///|
/// The shell translates lifecycle events into public policy inputs.
fn transition(state : State, event : Event) -> (State, Array[Decision]) {
  let peers = state.peers.copy()
  let decisions : Array[Decision] = []
  let _ = match event {
    PeerAvailable(peer) =>
      match peers.get(peer) {
        None => {
          peers[peer] = {
            policy: @peer_sync.State::State(),
            connected: true,
            retry_count: 0,
            shell_exhausted: false,
            recovering: false,
            terminal: false,
          }
          apply_to_peer(peers, peer, PolicyBegin, decisions)
        }
        Some(_) => ()
      }
    PeerDisconnected(peer) =>
      match peers.get(peer) {
        Some(metadata) =>
          if metadata.connected {
            peers[peer] = {
              policy: metadata.policy,
              connected: false,
              retry_count: metadata.retry_count,
              shell_exhausted: metadata.shell_exhausted,
              recovering: metadata.recovering,
              terminal: metadata.terminal,
            }
          }
        None => ()
      }
    VersionCompared(peer, equal) =>
      apply_to_peer(peers, peer, PolicyVersionCompared(equal), decisions)
    FullSyncRequested(peer) =>
      apply_to_peer(peers, peer, PolicyFullSyncRequested, decisions)
    LocalCommitted =>
      peers.each(fn(peer, metadata) {
        if metadata.connected &&
          metadata.shell_exhausted is false &&
          metadata.terminal is false {
          let (policy, policy_decisions) = policy_transition(
            metadata.policy,
            PolicyLocalVersionAdvanced,
          )
          let (recovering, retry_count, terminal) = emit_policy_decisions(
            peer,
            policy_decisions,
            decisions,
            metadata.recovering,
            metadata.retry_count,
            metadata.terminal,
          )
          peers[peer] = {
            policy,
            connected: metadata.connected,
            retry_count,
            shell_exhausted: metadata.shell_exhausted,
            recovering,
            terminal,
          }
        }
      })
    Applied(peer, disposition) =>
      apply_to_peer(peers, peer, PolicyApplied(disposition), decisions)
    Failed(peer, disposition) =>
      apply_to_peer(peers, peer, PolicyFailed(disposition), decisions)
    RecoveryTimedOut(peer) =>
      match peers.get(peer) {
        Some(metadata) =>
          if metadata.connected &&
            metadata.shell_exhausted is false &&
            metadata.terminal is false &&
            metadata.recovering {
            if metadata.retry_count < recovery_retry_limit {
              peers[peer] = {
                policy: metadata.policy,
                connected: metadata.connected,
                retry_count: metadata.retry_count + 1,
                shell_exhausted: false,
                recovering: metadata.recovering,
                terminal: metadata.terminal,
              }
              decisions.push(RetryFullSync(peer))
            } else {
              peers[peer] = {
                policy: metadata.policy,
                connected: metadata.connected,
                retry_count: metadata.retry_count,
                shell_exhausted: true,
                recovering: metadata.recovering,
                terminal: metadata.terminal,
              }
              decisions.push(ReportRecoveryExhausted(peer))
            }
          }
        None => ()
      }
    Reconnect(peer) =>
      match peers.get(peer) {
        Some(metadata) =>
          if metadata.connected is false &&
            metadata.shell_exhausted is false &&
            metadata.terminal is false {
            peers[peer] = {
              policy: metadata.policy,
              connected: true,
              retry_count: 0,
              shell_exhausted: false,
              recovering: metadata.recovering,
              terminal: metadata.terminal,
            }
            apply_to_peer(peers, peer, PolicyBeginFullRecovery, decisions)
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
priv enum Scheduled[T] {
  Deliver(T)
  TransportDisconnected(String)
  TransportReconnected(String)
  PeerLeft(String)
}

///|
priv struct Scheduler[T] {
  ready : Array[Scheduled[T]]
  delayed : Array[Scheduled[T]]
}

///|
fn[T] Scheduler::new() -> Scheduler[T] {
  { ready: [], delayed: [] }
}

///|
fn[T] Scheduler::deliver(self : Scheduler[T], envelope : T) -> Unit {
  self.ready.push(Deliver(envelope))
}

///|
fn[T] Scheduler::delay(self : Scheduler[T], envelope : T) -> Unit {
  self.delayed.push(Deliver(envelope))
}

///|
fn[T] Scheduler::duplicate(self : Scheduler[T], envelope : T) -> Unit {
  self.ready.push(Deliver(envelope))
  self.ready.push(Deliver(envelope))
}

///|
fn[T] Scheduler::drop_next(self : Scheduler[T]) -> Unit {
  let _ = self.ready.pop().unwrap()
}

///|
fn[T] Scheduler::release_delayed(self : Scheduler[T]) -> Unit {
  self.delayed.each(event => self.ready.push(event))
  self.delayed.clear()
}

///|
fn[T] Scheduler::disconnect(self : Scheduler[T], peer : String) -> Unit {
  self.ready.push(TransportDisconnected(peer))
}

///|
fn[T] Scheduler::reconnect(self : Scheduler[T], peer : String) -> Unit {
  self.ready.push(TransportReconnected(peer))
}

///|
fn[T] Scheduler::peer_left(self : Scheduler[T], peer : String) -> Unit {
  self.ready.push(PeerLeft(peer))
}

///|
fn[T] Scheduler::next(self : Scheduler[T]) -> Scheduled[T] {
  self.ready.pop().unwrap()
}

///|
fn[T] Scheduler::take_delivery(self : Scheduler[T]) -> T raise {
  match Scheduler::next(self) {
    Deliver(envelope) => envelope
    _ => fail("scheduler next item is not a delivery")
  }
}

///|
fn[T] Scheduler::is_empty(self : Scheduler[T]) -> Bool {
  self.ready.length() == 0 && self.delayed.length() == 0
}
