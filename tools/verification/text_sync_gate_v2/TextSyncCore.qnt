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

  type Message = {
    id: str,
    operations: Set[Operation],
    heads: Set[RawVersion],
  }

  type Checkpoint = {
    id: str,
    knowledge: Set[RawVersion],
    frontier: Set[RawVersion],
  }

  type Replica = {
    admitted: Set[Operation],
    pending: Set[Operation],
  }

  type Delivery = { messageId: str, receiver: str, rank: int }

  type Event = {
    name: str,
    messageId: str,
    newMessageId: str,
    receiver: str,
    checkpointId: str,
    sender: str,
    expectedOutcome: str,
    expectedConflictIdentity: OptionalIdentity,
    expectedApplied: int,
    expectedDuplicate: int,
    expectedPending: int,
    exactOperations: Set[Operation],
    exactHeads: Set[RawVersion],
    claimKnowledge: Set[RawVersion],
    claimFrontier: Set[RawVersion],
    expectedText: str,
    deliveryRank: int,
    sourceKnowledge: Set[RawVersion],
    sourceFrontier: Set[RawVersion],
    sourcePending: int,
    peerKnowledge: Set[RawVersion],
    peerFrontier: Set[RawVersion],
    peerPending: int,
  }

  type ModelState = {
    stage: int,
    source: Replica,
    peer: Replica,
    messages: Set[Message],
    checkpoints: Set[Checkpoint],
    network: Set[Delivery],
    scheduleId: int,
    requiredScheduleIds: Set[int],
    lastEvent: Event,
  }

  // Eight passes are complete for the gate's at-most-eight-operation authority
  // bound: each pass can release the next level of a finite acyclic chain.
  pure val RELEASE_OPERATION_BOUND = 8

  pure val EMPTY_REPLICA: Replica = { admitted: Set(), pending: Set() }

  pure val NO_EVENT: Event = {
    name: "Init",
    messageId: "",
    newMessageId: "",
    receiver: "",
    checkpointId: "",
    sender: "",
    expectedOutcome: "Success",
    expectedConflictIdentity: NoIdentity,
    expectedApplied: 0,
    expectedDuplicate: 0,
    expectedPending: 0,
    exactOperations: Set(),
    exactHeads: Set(),
    claimKnowledge: Set(),
    claimFrontier: Set(),
    expectedText: "",
    deliveryRank: -1,
    sourceKnowledge: Set(),
    sourceFrontier: Set(),
    sourcePending: 0,
    peerKnowledge: Set(),
    peerFrontier: Set(),
    peerPending: 0,
  }

  pure def emptyState(
    scheduleId: int,
    requiredScheduleIds: Set[int],
    network: Set[Delivery],
  ): ModelState = {
    stage: 0,
    source: EMPTY_REPLICA,
    peer: EMPTY_REPLICA,
    messages: Set(),
    checkpoints: Set(),
    network: network,
    scheduleId: scheduleId,
    requiredScheduleIds: requiredScheduleIds,
    lastEvent: NO_EVENT,
  }

  pure def baseEvent(name: str): Event = { ...NO_EVENT, name: name }

  pure def buildFixture(
    messageId: str,
    operations: Set[Operation],
    heads: Set[RawVersion],
  ): Event = {
    ...NO_EVENT,
    name: "BuildFixture",
    messageId: messageId,
    exactOperations: operations,
    exactHeads: heads,
  }

  pure def deliver(messageId: str, receiver: str, rank: int): Event = {
    ...NO_EVENT,
    name: "Deliver",
    messageId: messageId,
    receiver: receiver,
    deliveryRank: rank,
  }

  pure def captureCheckpoint(receiver: str, checkpointId: str): Event = {
    ...NO_EVENT,
    name: "CaptureCheckpoint",
    receiver: receiver,
    checkpointId: checkpointId,
  }

  pure def requestDelta(
    sender: str,
    checkpointId: str,
    messageId: str,
  ): Event = {
    ...NO_EVENT,
    name: "RequestDelta",
    sender: sender,
    checkpointId: checkpointId,
    messageId: messageId,
  }

  pure def requestDeltaClaim(
    sender: str,
    messageId: str,
    knowledge: Set[RawVersion],
    frontier: Set[RawVersion],
  ): Event = {
    ...NO_EVENT,
    name: "RequestDeltaClaim",
    sender: sender,
    messageId: messageId,
    claimKnowledge: knowledge,
    claimFrontier: frontier,
  }

  pure def requestAll(sender: str, messageId: str): Event = {
    ...NO_EVENT,
    name: "RequestAll",
    sender: sender,
    messageId: messageId,
  }

  pure def checkout(receiver: str, checkpointId: str, text: str): Event = {
    ...NO_EVENT,
    name: "Checkout",
    receiver: receiver,
    checkpointId: checkpointId,
    expectedText: text,
  }

  pure def duplicateMessage(messageId: str, newMessageId: str): Event = {
    ...NO_EVENT,
    name: "DuplicateMessage",
    messageId: messageId,
    newMessageId: newMessageId,
  }

  pure def optionalIdentitySet(value: OptionalIdentity): Set[RawVersion] =
    match value {
      | NoIdentity => Set()
      | SomeIdentity(identity) => Set(identity)
    }

  pure def admissionDependencies(operation: Operation): Set[RawVersion] =
    operation.parents
      .union(optionalIdentitySet(operation.originLeft))
      .union(optionalIdentitySet(operation.originRight))

  pure def operationShapeValid(operation: Operation): bool =
    if (operation.kind == "insert") operation.hasContent
    else if (operation.kind == "delete" or operation.kind == "undelete")
      not(operation.hasContent) and operation.originLeft != NoIdentity
    else false

  pure def identities(operations: Set[Operation]): Set[RawVersion] =
    operations.map(operation => operation.id)

  pure def replicaKnowledge(replica: Replica): Set[RawVersion] =
    identities(replica.admitted)

  pure def allKnown(replica: Replica): Set[Operation] =
    replica.admitted.union(replica.pending)

  pure def uniqueOperationIdentities(operations: Set[Operation]): bool =
    operations.forall(left =>
      operations.forall(right => left.id != right.id or left == right)
    )

  pure def conflictingIdentities(
    known: Set[Operation],
    incoming: Set[Operation],
  ): Set[RawVersion] = incoming
    .filter(operation =>
      known.exists(existing =>
        existing.id == operation.id and existing != operation
      ) or
      incoming.exists(other =>
        other.id == operation.id and other != operation
      )
    )
    .map(operation => operation.id)

  pure def hasIdentityConflict(
    known: Set[Operation],
    incoming: Set[Operation],
  ): bool = conflictingIdentities(known, incoming) != Set() or
    not(uniqueOperationIdentities(incoming))

  pure def maximalFrontier(
    operations: Set[Operation],
    admitted: Set[RawVersion],
  ): Set[RawVersion] = admitted.filter(candidate =>
    operations
      .filter(operation => admitted.contains(operation.id))
      .forall(operation => not(operation.parents.contains(candidate)))
  )

  pure def replicaFrontier(replica: Replica): Set[RawVersion] =
    maximalFrontier(replica.admitted, replicaKnowledge(replica))

  pure def releaseOnce(replica: Replica): Replica = {
    val knowledge = replicaKnowledge(replica)
    val ready = replica.pending.filter(operation =>
      admissionDependencies(operation).subseteq(knowledge)
    )
    {
      admitted: replica.admitted.union(ready),
      pending: replica.pending.exclude(ready),
    }
  }

  pure def releaseAll(replica: Replica): Replica = {
    val r1 = releaseOnce(replica)
    val r2 = releaseOnce(r1)
    val r3 = releaseOnce(r2)
    val r4 = releaseOnce(r3)
    val r5 = releaseOnce(r4)
    val r6 = releaseOnce(r5)
    val r7 = releaseOnce(r6)
    releaseOnce(r7)
  }

  pure def operationByIdentity(
    operations: Set[Operation],
    identity: RawVersion,
  ): Set[Operation] = operations.filter(operation => operation.id == identity)

  pure def freshOperations(
    replica: Replica,
    incoming: Set[Operation],
  ): Set[Operation] = {
    val known = allKnown(replica)
    incoming.filter(operation =>
      operationByIdentity(known, operation.id) == Set()
    )
  }

  pure def admitMessage(replica: Replica, incoming: Set[Operation]): Replica =
    releaseAll({
      admitted: replica.admitted,
      pending: replica.pending.union(freshOperations(replica, incoming)),
    })

  pure def releaseOnceWithImplicitSequenceParent(replica: Replica): Replica = {
    val knowledge = replicaKnowledge(replica)
    val ready = replica.pending.filter(operation => {
      val implicit = if (operation.id.sequence > 0)
        Set({
          agent: operation.id.agent,
          sequence: operation.id.sequence - 1,
        })
      else
        Set()
      admissionDependencies(operation).union(implicit).subseteq(knowledge)
    })
    {
      admitted: replica.admitted.union(ready),
      pending: replica.pending.exclude(ready),
    }
  }

  pure def admitWithImplicitSequenceParent(
    replica: Replica,
    incoming: Set[Operation],
  ): Replica = {
    val initial = {
      admitted: replica.admitted,
      pending: replica.pending.union(freshOperations(replica, incoming)),
    }
    val r1 = releaseOnceWithImplicitSequenceParent(initial)
    val r2 = releaseOnceWithImplicitSequenceParent(r1)
    val r3 = releaseOnceWithImplicitSequenceParent(r2)
    releaseOnceWithImplicitSequenceParent(r3)
  }

  pure def admitPrematurely(
    replica: Replica,
    incoming: Set[Operation],
  ): Replica = {
    admitted: replica.admitted.union(freshOperations(replica, incoming)),
    pending: replica.pending,
  }

  pure def messageById(messages: Set[Message], id: str): Message =
    messages.filter(message => message.id == id).getOnlyElement()

  pure def checkpointById(
    checkpoints: Set[Checkpoint],
    id: str,
  ): Checkpoint = checkpoints
    .filter(checkpoint => checkpoint.id == id)
    .getOnlyElement()

  pure def replicaByName(state: ModelState, name: str): Replica =
    if (name == "source") state.source else state.peer

  pure def replaceReplica(
    state: ModelState,
    name: str,
    replica: Replica,
  ): ModelState = if (name == "source")
    { ...state, source: replica }
  else
    { ...state, peer: replica }

  pure def replaceMessage(
    messages: Set[Message],
    message: Message,
  ): Set[Message] = messages
    .filter(existing => existing.id != message.id)
    .union(Set(message))

  pure def replaceCheckpoint(
    checkpoints: Set[Checkpoint],
    checkpoint: Checkpoint,
  ): Set[Checkpoint] = checkpoints
    .filter(existing => existing.id != checkpoint.id)
    .union(Set(checkpoint))

  pure def withReport(
    event: Event,
    outcome: str,
    applied: int,
    duplicate: int,
    pending: int,
    operations: Set[Operation],
    heads: Set[RawVersion],
  ): Event = {
    ...event,
    expectedOutcome: outcome,
    expectedApplied: applied,
    expectedDuplicate: duplicate,
    expectedPending: pending,
    exactOperations: operations,
    exactHeads: heads,
  }

  pure def reduceDeliver(state: ModelState, event: Event): ModelState = {
    val message = messageById(state.messages, event.messageId)
    val before = replicaByName(state, event.receiver)
    val known = allKnown(before)
    val duplicate = message.operations
      .filter(operation => known.contains(operation))
      .size()
    val remainingNetwork = state.network.filter(delivery => not(
      delivery.messageId == event.messageId and
      delivery.receiver == event.receiver and
      delivery.rank == event.deliveryRank
    ))
    if (hasIdentityConflict(known, message.operations)) {
      {
        ...state,
        stage: state.stage + 1,
        network: remainingNetwork,
        lastEvent: {
          ...withReport(
            event, "Conflict", 0, 0, before.pending.size(),
            message.operations, message.heads,
          ),
          expectedConflictIdentity: SomeIdentity(
            conflictingIdentities(known, message.operations).getOnlyElement(),
          ),
        },
      }
    } else {
      val after = admitMessage(before, message.operations)
      val applied = after.admitted.size() - before.admitted.size()
      val pending = after.pending.size()
      val outcome = if (applied == 0 and duplicate > 0) "Duplicate"
        else if (applied == 0 and pending > before.pending.size()) "Pending"
        else if (applied > message.operations.size() - duplicate)
          "AppliedPending"
        else "Success"
      val updatedState = replaceReplica(state, event.receiver, after)
      {
        ...updatedState,
        stage: state.stage + 1,
        network: remainingNetwork,
        lastEvent: withReport(
          event, outcome, applied, duplicate, pending,
          message.operations, message.heads,
        ),
      }
    }
  }

  pure def reduceDeliverMutation(
    state: ModelState,
    event: Event,
    mode: str,
  ): ModelState = {
    val message = messageById(state.messages, event.messageId)
    val before = replicaByName(state, event.receiver)
    val after = if (mode == "implicit-sequence-parent")
      admitWithImplicitSequenceParent(before, message.operations)
    else
      admitPrematurely(before, message.operations)
    val updated = replaceReplica(state, event.receiver, after)
    val remainingNetwork = state.network.filter(delivery => not(
      delivery.messageId == event.messageId and
      delivery.receiver == event.receiver and
      delivery.rank == event.deliveryRank
    ))
    val mutated = {
      ...updated,
      stage: state.stage + 1,
      network: remainingNetwork,
      lastEvent: withReport(
        event,
        "Success",
        after.admitted.size() - before.admitted.size(),
        0,
        after.pending.size(),
        message.operations,
        message.heads,
      ),
    }
    { ...mutated, lastEvent: withObservations(mutated, mutated.lastEvent) }
  }

  pure def exportedMessage(
    state: ModelState,
    sender: str,
    messageId: str,
    peerKnowledge: Set[RawVersion],
  ): Message = {
    val replica = replicaByName(state, sender)
    {
      id: messageId,
      operations: replica.admitted.filter(operation =>
        not(peerKnowledge.contains(operation.id))
      ),
      heads: replicaFrontier(replica),
    }
  }

  pure def reduceUnobserved(state: ModelState, input: Event): ModelState = {
    if (input.name == "BuildFixture") {
      val message: Message = {
        id: input.messageId,
        operations: input.exactOperations,
        heads: input.exactHeads,
      }
      {
        ...state,
        stage: state.stage + 1,
        messages: replaceMessage(state.messages, message),
        lastEvent: withReport(
          input, "Success", 0, 0, 0, message.operations, message.heads,
        ),
      }
    } else if (input.name == "DuplicateMessage") {
      val original = messageById(state.messages, input.messageId)
      val duplicate = { ...original, id: input.newMessageId }
      {
        ...state,
        stage: state.stage + 1,
        messages: replaceMessage(state.messages, duplicate),
        lastEvent: input,
      }
    } else if (input.name == "Deliver") {
      reduceDeliver(state, input)
    } else if (input.name == "CaptureCheckpoint") {
      val replica = replicaByName(state, input.receiver)
      val checkpoint: Checkpoint = {
        id: input.checkpointId,
        knowledge: replicaKnowledge(replica),
        frontier: replicaFrontier(replica),
      }
      {
        ...state,
        stage: state.stage + 1,
        checkpoints: replaceCheckpoint(state.checkpoints, checkpoint),
        lastEvent: input,
      }
    } else if (input.name == "RequestDelta") {
      val checkpoint = checkpointById(state.checkpoints, input.checkpointId)
      val message = exportedMessage(
        state, input.sender, input.messageId, checkpoint.knowledge,
      )
      {
        ...state,
        stage: state.stage + 1,
        messages: replaceMessage(state.messages, message),
        lastEvent: withReport(
          input, "Success", 0, 0, 0, message.operations, message.heads,
        ),
      }
    } else if (input.name == "RequestDeltaClaim") {
      val message = exportedMessage(
        state, input.sender, input.messageId, input.claimKnowledge,
      )
      {
        ...state,
        stage: state.stage + 1,
        messages: replaceMessage(state.messages, message),
        lastEvent: withReport(
          input, "Success", 0, 0, 0, message.operations, message.heads,
        ),
      }
    } else if (input.name == "RequestAll") {
      val message = exportedMessage(
        state, input.sender, input.messageId, Set(),
      )
      {
        ...state,
        stage: state.stage + 1,
        messages: replaceMessage(state.messages, message),
        lastEvent: withReport(
          input, "Success", 0, 0, 0, message.operations, message.heads,
        ),
      }
    } else {
      { ...state, stage: state.stage + 1, lastEvent: input }
    }
  }

  pure def withObservations(state: ModelState, event: Event): Event = {
    ...event,
    sourceKnowledge: replicaKnowledge(state.source),
    sourceFrontier: replicaFrontier(state.source),
    sourcePending: state.source.pending.size(),
    peerKnowledge: replicaKnowledge(state.peer),
    peerFrontier: replicaFrontier(state.peer),
    peerPending: state.peer.pending.size(),
  }

  pure def reduce(state: ModelState, input: Event): ModelState = {
    val updated = reduceUnobserved(state, input)
    { ...updated, lastEvent: withObservations(updated, updated.lastEvent) }
  }

  pure def identitySafety(state: ModelState): bool = {
    val sourceKnown = allKnown(state.source)
    val peerKnown = allKnown(state.peer)
    uniqueOperationIdentities(sourceKnown) and
    uniqueOperationIdentities(peerKnown) and
    sourceKnown.forall(operationShapeValid) and
    peerKnown.forall(operationShapeValid)
  }

  pure def admissionSafety(state: ModelState): bool =
    state.source.admitted.forall(operation =>
      admissionDependencies(operation).subseteq(replicaKnowledge(state.source))
    ) and
    state.peer.admitted.forall(operation =>
      admissionDependencies(operation).subseteq(replicaKnowledge(state.peer))
    )

  pure def pendingIsolation(state: ModelState): bool =
    state.source.pending.forall(operation => not(
      admissionDependencies(operation).subseteq(replicaKnowledge(state.source))
    )) and
    state.peer.pending.forall(operation => not(
      admissionDependencies(operation).subseteq(replicaKnowledge(state.peer))
    ))

  pure def versionExactness(state: ModelState): bool =
    replicaFrontier(state.source).subseteq(replicaKnowledge(state.source)) and
    replicaFrontier(state.peer).subseteq(replicaKnowledge(state.peer)) and
    replicaFrontier(state.source) == maximalFrontier(
      state.source.admitted, replicaKnowledge(state.source),
    ) and
    replicaFrontier(state.peer) == maximalFrontier(
      state.peer.admitted, replicaKnowledge(state.peer),
    )

  pure def releaseBounded(state: ModelState): bool =
    allKnown(state.source).size() <= RELEASE_OPERATION_BOUND and
    allKnown(state.peer).size() <= RELEASE_OPERATION_BOUND

  pure def coreSafety(state: ModelState): bool =
    releaseBounded(state) and identitySafety(state) and
    admissionSafety(state) and pendingIsolation(state) and
    versionExactness(state)

  pure def exactSparseDelta(
    sourceKnowledge: Set[int],
    peerKnowledge: Set[int],
  ): Set[int] = sourceKnowledge.exclude(peerKnowledge)

  pure def sparseDeltaIsExact(
    sourceKnowledge: Set[int],
    peerKnowledge: Set[int],
    observed: Set[int],
  ): bool = observed == exactSparseDelta(sourceKnowledge, peerKnowledge)

  // Deliberate mutation: a per-agent maximum incorrectly implies every lower
  // sequence is known. Sparse sequence 2 is hidden by peer sequence 7.
  pure def flatMaximumDelta(
    sourceKnowledge: Set[int],
    peerKnowledge: Set[int],
  ): Set[int] = sourceKnowledge.filter(sequence =>
    peerKnowledge.forall(peerSequence => peerSequence < sequence)
  )
}
