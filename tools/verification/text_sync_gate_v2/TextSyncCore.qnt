module TextSyncCore {
  type Event = {
    name: str,
    messageId: str,
    newMessageId: str,
    receiver: str,
    checkpointId: str,
    sender: str,
    parentSequence: int,
    content: str,
    expectedOutcome: str,
    operations: Set[int],
    versionKnowledge: Set[int],
  }

  pure val NO_EVENT = {
    name: "Init",
    messageId: "",
    newMessageId: "",
    receiver: "",
    checkpointId: "",
    sender: "",
    parentSequence: -1,
    content: "",
    expectedOutcome: "Success",
    operations: Set(),
    versionKnowledge: Set(),
  }

  pure def event(
    name: str,
    messageId: str,
    newMessageId: str,
    receiver: str,
    checkpointId: str,
    sender: str,
    parentSequence: int,
    content: str,
    expectedOutcome: str,
    operations: Set[int],
    versionKnowledge: Set[int],
  ): Event = {
    name: name,
    messageId: messageId,
    newMessageId: newMessageId,
    receiver: receiver,
    checkpointId: checkpointId,
    sender: sender,
    parentSequence: parentSequence,
    content: content,
    expectedOutcome: expectedOutcome,
    operations: operations,
    versionKnowledge: versionKnowledge,
  }

  pure def exactDelta(
    sourceKnowledge: Set[int],
    peerKnowledge: Set[int],
  ): Set[int] = sourceKnowledge.exclude(peerKnowledge)

  // Deliberate mutation: a per-agent maximum incorrectly implies every lower
  // sequence is known. Sparse sequence 2 is hidden by peer sequence 7.
  pure def flatMaximumDelta(
    sourceKnowledge: Set[int],
    peerKnowledge: Set[int],
  ): Set[int] = sourceKnowledge.filter(sequence => {
    peerKnowledge.forall(peerSequence => peerSequence < sequence)
  })
}
