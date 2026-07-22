/// Public one-peer policy is exercised through this integration package.
/// The shell translates its generic events into semantic public methods.

///|
priv enum PolicyInput {
  PolicyBegin
  PolicyVersionCompared(Bool)
  PolicyBeginFullRecovery
  PolicyFullSyncRequested
  PolicyLocalVersionAdvanced
  PolicyApplied(@peer_sync.ApplyDisposition)
  PolicyFailed(@peer_sync.FailureDisposition)
}

///|
fn policy_transition(
  state : @peer_sync.State,
  input : PolicyInput,
) -> (@peer_sync.State, Array[@peer_sync.Decision]) {
  match input {
    PolicyBegin => @peer_sync.State::handshake_started(state)
    PolicyVersionCompared(equal) =>
      @peer_sync.State::version_compared(state, equal)
    PolicyBeginFullRecovery => @peer_sync.State::full_recovery_required(state)
    PolicyFullSyncRequested => @peer_sync.State::full_sync_requested(state)
    PolicyLocalVersionAdvanced =>
      @peer_sync.State::local_version_advanced(state)
    PolicyApplied(disposition) => @peer_sync.State::applied(state, disposition)
    PolicyFailed(disposition) => @peer_sync.State::failed(state, disposition)
  }
}
