module TextSyncDistributed {
  import TextSyncCore.* from "TextSyncCore"

  type Message = {
    id: str,
    operations: Set[int],
  }

  type State = {
    stage: int,
    sourceKnowledge: Set[int],
    sourceFrontier: Set[int],
    sourcePending: int,
    peerKnowledge: Set[int],
    peerFrontier: Set[int],
    peerPending: int,
    checkpointKnowledge: Set[int],
    delta: Set[int],
    messages: Set[Message],
    lastEvent: Event,
  }

  pure val SOURCE = "source"
  pure val PEER = "peer"
  pure val AGENT = "shared-agent"
  pure val SOURCE_MESSAGE = "source-all"
  pure val PEER_MESSAGE = "peer-sparse"
  pure val DELTA_MESSAGE = "source-delta"
  pure val PEER_CHECKPOINT = "peer-v1"
  pure val SOURCE_OPERATIONS = Set(0, 2, 7)
  pure val PEER_OPERATIONS = Set(0, 7)

  var s: State

  action init = s' = {
    stage: 0,
    sourceKnowledge: Set(),
    sourceFrontier: Set(),
    sourcePending: 0,
    peerKnowledge: Set(),
    peerFrontier: Set(),
    peerPending: 0,
    checkpointKnowledge: Set(),
    delta: Set(),
    messages: Set(),
    lastEvent: NO_EVENT,
  }

  action buildSourceFixture = all {
    s.stage == 0,
    s' = {
      ...s,
      stage: 1,
      messages: s.messages.union(Set({
        id: SOURCE_MESSAGE,
        operations: SOURCE_OPERATIONS,
      })),
      lastEvent: event(
        "BuildFixture",
        SOURCE_MESSAGE,
        "",
        "",
        "",
        "",
        -1,
        "x",
        "Success",
        SOURCE_OPERATIONS,
        Set(),
      ),
    },
  }

  action deliverSourceFixture = all {
    s.stage == 1,
    s' = {
      ...s,
      stage: 2,
      sourceKnowledge: SOURCE_OPERATIONS,
      sourceFrontier: SOURCE_OPERATIONS,
      lastEvent: event(
        "Deliver",
        SOURCE_MESSAGE,
        "",
        SOURCE,
        "",
        "",
        -1,
        "",
        "Success",
        Set(),
        SOURCE_OPERATIONS,
      ),
    },
  }

  action buildPeerFixture = all {
    s.stage == 2,
    s' = {
      ...s,
      stage: 3,
      messages: s.messages.union(Set({
        id: PEER_MESSAGE,
        operations: PEER_OPERATIONS,
      })),
      lastEvent: event(
        "BuildFixture",
        PEER_MESSAGE,
        "",
        "",
        "",
        "",
        -1,
        "x",
        "Success",
        PEER_OPERATIONS,
        Set(),
      ),
    },
  }

  action deliverPeerFixture = all {
    s.stage == 3,
    s' = {
      ...s,
      stage: 4,
      peerKnowledge: PEER_OPERATIONS,
      peerFrontier: PEER_OPERATIONS,
      lastEvent: event(
        "Deliver",
        PEER_MESSAGE,
        "",
        PEER,
        "",
        "",
        -1,
        "",
        "Success",
        Set(),
        PEER_OPERATIONS,
      ),
    },
  }

  action capturePeerCheckpoint = all {
    s.stage == 4,
    s' = {
      ...s,
      stage: 5,
      checkpointKnowledge: s.peerKnowledge,
      lastEvent: event(
        "CaptureCheckpoint",
        "",
        "",
        PEER,
        PEER_CHECKPOINT,
        "",
        -1,
        "",
        "Success",
        Set(),
        s.peerKnowledge,
      ),
    },
  }

  def requestDelta(nextDelta: Set[int]): State = {
    ...s,
    stage: 6,
    delta: nextDelta,
    messages: s.messages.union(Set({
      id: DELTA_MESSAGE,
      operations: nextDelta,
    })),
    lastEvent: event(
      "RequestDelta",
      DELTA_MESSAGE,
      "",
      "",
      PEER_CHECKPOINT,
      SOURCE,
      -1,
      "",
      "Success",
      nextDelta,
      s.checkpointKnowledge,
    ),
  }

  action requestExactDelta = all {
    s.stage == 5,
    s' = requestDelta(exactDelta(s.sourceKnowledge, s.checkpointKnowledge)),
  }

  action requestFlatMaximumDelta = all {
    s.stage == 5,
    s' = requestDelta(
      flatMaximumDelta(s.sourceKnowledge, s.checkpointKnowledge),
    ),
  }

  action replayStep =
    if (s.stage == 0) buildSourceFixture
    else if (s.stage == 1) deliverSourceFixture
    else if (s.stage == 2) buildPeerFixture
    else if (s.stage == 3) deliverPeerFixture
    else if (s.stage == 4) capturePeerCheckpoint
    else if (s.stage == 5) requestExactDelta
    else s' = s

  action mutationStep =
    if (s.stage == 0) buildSourceFixture
    else if (s.stage == 1) deliverSourceFixture
    else if (s.stage == 2) buildPeerFixture
    else if (s.stage == 3) deliverPeerFixture
    else if (s.stage == 4) capturePeerCheckpoint
    else if (s.stage == 5) requestFlatMaximumDelta
    else s' = s

  action step = any {
    buildSourceFixture,
    deliverSourceFixture,
    buildPeerFixture,
    deliverPeerFixture,
    capturePeerCheckpoint,
    requestExactDelta,
  }

  val boundedState =
    s.stage >= 0 and s.stage <= 6 and
    s.sourceKnowledge.subseteq(SOURCE_OPERATIONS) and
    s.sourceFrontier.subseteq(s.sourceKnowledge) and
    s.sourcePending == 0 and
    s.peerKnowledge.subseteq(PEER_OPERATIONS) and
    s.peerFrontier.subseteq(s.peerKnowledge) and
    s.peerPending == 0 and
    s.checkpointKnowledge.subseteq(PEER_OPERATIONS)

  val exactSparseDelta =
    s.stage < 6 or
    s.delta == exactDelta(s.sourceKnowledge, s.checkpointKnowledge)

  val sparseGapExported = s.stage < 6 or s.delta.contains(2)

  val safety = boundedState and exactSparseDelta and sparseGapExported
}
