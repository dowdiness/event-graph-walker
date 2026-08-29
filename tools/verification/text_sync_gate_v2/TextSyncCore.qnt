module TextSyncCore {
  type RawVersion = { agent: str, sequence: int }

  type OptionalIdentity = NoIdentity | SomeIdentity(RawVersion)

  type Operation = {
    id: RawVersion,
    parents: Set[RawVersion],
    kind: str,
    content: str,
    hasContent: bool,
    originLeft: OptionalIdentity,
    originRight: OptionalIdentity,
  }

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
    exactOperations: Set[Operation],
    exactHeads: Set[RawVersion],
    claimKnowledge: Set[RawVersion],
    claimFrontier: Set[RawVersion],
    expectedText: str,
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
    exactOperations: Set(),
    exactHeads: Set(),
    claimKnowledge: Set(),
    claimFrontier: Set(),
    expectedText: "",
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
    exactOperations: Set(),
    exactHeads: Set(),
    claimKnowledge: Set(),
    claimFrontier: Set(),
    expectedText: "",
  }

  pure def withFixture(
    base: Event,
    operations: Set[Operation],
    heads: Set[RawVersion],
  ): Event = { ...base, exactOperations: operations, exactHeads: heads }

  pure def withVersionClaim(
    base: Event,
    knowledge: Set[RawVersion],
    frontier: Set[RawVersion],
  ): Event =
    { ...base, claimKnowledge: knowledge, claimFrontier: frontier }

  pure def withExpectedText(base: Event, expectedText: str): Event =
    { ...base, expectedText: expectedText }

  pure def optionalIdentitySet(value: OptionalIdentity): Set[RawVersion] =
    match value {
      | NoIdentity => Set()
      | SomeIdentity(identity) => Set(identity)
    }

  pure def dependencies(operation: Operation): Set[RawVersion] =
    operation.parents
      .union(optionalIdentitySet(operation.originLeft))
      .union(optionalIdentitySet(operation.originRight))

  pure def operationShapeValid(operation: Operation): bool =
    if (operation.kind == "insert") operation.hasContent
    else if (operation.kind == "delete" or operation.kind == "undelete")
      not(operation.hasContent) and operation.originLeft != NoIdentity
    else false

  pure def uniqueOperationIdentities(operations: Set[Operation]): bool =
    operations.forall(left =>
      operations.forall(right => left.id != right.id or left == right)
    )

  pure def admittedDependenciesReady(
    operations: Set[Operation],
    admitted: Set[RawVersion],
  ): bool = operations
    .filter(operation => admitted.contains(operation.id))
    .forall(operation => dependencies(operation).subseteq(admitted))

  pure def maximalFrontier(
    operations: Set[Operation],
    admitted: Set[RawVersion],
  ): Set[RawVersion] = admitted.filter(candidate =>
    operations
      .filter(operation => admitted.contains(operation.id))
      .forall(operation => not(dependencies(operation).contains(candidate)))
  )

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
