module TextSyncScenarios {
  import TextSyncCore.* from "TextSyncCore"

  type Permutation = { id: int, order: List[str] }
  type ScheduleCase = {
    id: int,
    sourceOrder: List[str],
    peerOrder: List[str],
    network: Set[Delivery],
  }

  pure def raw(agent: str, sequence: int): RawVersion = {
    agent: agent,
    sequence: sequence,
  }

  pure def insert(
    id: RawVersion,
    parents: Set[RawVersion],
    content: str,
    left: OptionalIdentity,
    right: OptionalIdentity,
  ): Operation = {
    id: id,
    parents: parents,
    kind: "insert",
    content: content,
    hasContent: true,
    originLeft: left,
    originRight: right,
  }

  pure def deleteLike(
    id: RawVersion,
    parents: Set[RawVersion],
    kind: str,
    target: RawVersion,
  ): Operation = {
    id: id,
    parents: parents,
    kind: kind,
    content: "",
    hasContent: false,
    originLeft: SomeIdentity(target),
    originRight: NoIdentity,
  }

  pure val PARENT = raw("shared-agent", 0)
  pure val CHILD = raw("shared-agent", 2)
  pure val SPARSE_ROOT = raw("shared-agent", 7)
  pure val PARENT_OP = insert(PARENT, Set(), "x", NoIdentity, NoIdentity)
  pure val CHILD_OP = insert(CHILD, Set(PARENT), "x", NoIdentity, NoIdentity)
  pure val SPARSE_ROOT_OP = insert(
    SPARSE_ROOT, Set(), "x", NoIdentity, NoIdentity,
  )
  pure val SCHEDULE_OPERATIONS = Set(PARENT_OP, CHILD_OP, SPARSE_ROOT_OP)
  pure val MESSAGE_IDS = Set("parent", "child", "root")

  pure val PERMUTATIONS: Set[Permutation] = Set(
    { id: 0, order: ["parent", "child", "root"] },
    { id: 1, order: ["parent", "root", "child"] },
    { id: 2, order: ["child", "parent", "root"] },
    { id: 3, order: ["child", "root", "parent"] },
    { id: 4, order: ["root", "parent", "child"] },
    { id: 5, order: ["root", "child", "parent"] },
  )

  pure def scheduleNetwork(
    sourceOrder: List[str],
    peerOrder: List[str],
  ): Set[Delivery] = Set(
    { messageId: sourceOrder[0], receiver: "source", rank: 0 },
    { messageId: sourceOrder[1], receiver: "source", rank: 1 },
    { messageId: sourceOrder[2], receiver: "source", rank: 2 },
    { messageId: peerOrder[0], receiver: "peer", rank: 0 },
    { messageId: peerOrder[1], receiver: "peer", rank: 1 },
    { messageId: peerOrder[2], receiver: "peer", rank: 2 },
  )

  pure def scheduleCase(
    source: Permutation,
    peer: Permutation,
  ): ScheduleCase = {
    id: source.id * 6 + peer.id,
    sourceOrder: source.order,
    peerOrder: peer.order,
    network: scheduleNetwork(source.order, peer.order),
  }

  pure val CASES: Set[ScheduleCase] = PERMUTATIONS
    .map(source => PERMUTATIONS.map(peer => scheduleCase(source, peer)))
    .flatten()
  pure val REQUIRED_IDS = CASES.map(schedule => schedule.id)

  pure def validOrder(order: List[str]): bool =
    order.length() == 3 and Set(order[0], order[1], order[2]) == MESSAGE_IDS

  pure def orderMessage(order: List[str], rank: int): str =
    if (rank == 0) order[0]
    else if (rank == 1) order[1]
    else order[2]

  pure def receiverDeliveriesMatch(
    network: Set[Delivery],
    receiver: str,
    order: List[str],
  ): bool = {
    val deliveries = network.filter(delivery => delivery.receiver == receiver)
    deliveries.size() == 3 and
    deliveries.map(delivery => delivery.messageId) == MESSAGE_IDS and
    deliveries.map(delivery => delivery.rank) == Set(0, 1, 2) and
    deliveries.forall(delivery =>
      delivery.messageId == orderMessage(order, delivery.rank)
    )
  }

  pure def validCase(schedule: ScheduleCase): bool =
    validOrder(schedule.sourceOrder) and
    validOrder(schedule.peerOrder) and
    schedule.network.size() == 6 and
    schedule.network.forall(delivery =>
      (delivery.receiver == "source" or delivery.receiver == "peer") and
      MESSAGE_IDS.contains(delivery.messageId) and
      delivery.rank >= 0 and delivery.rank < 3
    ) and
    receiverDeliveriesMatch(
      schedule.network, "source", schedule.sourceOrder,
    ) and
    receiverDeliveriesMatch(schedule.network, "peer", schedule.peerOrder)

  pure def catalogIsComplete(
    permutations: Set[Permutation],
    cases: Set[ScheduleCase],
  ): bool =
    permutations.size() == 6 and
    permutations.forall(permutation => validOrder(permutation.order)) and
    permutations.map(permutation => permutation.id).size() == 6 and
    permutations.map(permutation => permutation.order).size() == 6 and
    cases.size() == 36 and
    cases.map(schedule => schedule.id).size() == 36 and
    cases.forall(validCase)

  pure val catalogValid = catalogIsComplete(PERMUTATIONS, CASES)

  pure def scheduleFixture(stage: int): Event =
    if (stage == 0) buildFixture("parent", Set(PARENT_OP), Set(PARENT))
    else if (stage == 1) buildFixture("child", Set(CHILD_OP), Set(CHILD))
    else buildFixture("root", Set(SPARSE_ROOT_OP), Set(SPARSE_ROOT))

  pure def eligibleDeliveries(state: ModelState): Set[Delivery] =
    state.network.filter(candidate =>
      state.network.forall(other =>
        other.receiver != candidate.receiver or other.rank >= candidate.rank
      )
    )

  var s: ModelState

  action initSchedule = {
    nondet selected = CASES.oneOf()
    s' = emptyState(selected.id, REQUIRED_IDS, selected.network)
  }

  action buildScheduleFixture = all {
    s.stage >= 0,
    s.stage < 3,
    s' = reduce(s, scheduleFixture(s.stage)),
  }

  action deliverSchedule = all {
    s.stage >= 3,
    s.stage < 9,
    nondet selected = eligibleDeliveries(s).oneOf()
    s' = reduce(
      s,
      deliver(selected.messageId, selected.receiver, selected.rank),
    ),
  }

  action deliverImplicitSequenceMutation = all {
    s.stage >= 3,
    s.stage < 9,
    nondet selected = eligibleDeliveries(s).oneOf()
    s' = reduceDeliverMutation(
      s,
      deliver(selected.messageId, selected.receiver, selected.rank),
      "implicit-sequence-parent",
    ),
  }

  action deliverPrematureMutation = all {
    s.stage >= 3,
    s.stage < 9,
    nondet selected = eligibleDeliveries(s).oneOf()
    s' = reduceDeliverMutation(
      s,
      deliver(selected.messageId, selected.receiver, selected.rank),
      "premature-admission",
    ),
  }

  action scheduleStep = any { buildScheduleFixture, deliverSchedule }
  action implicitSequenceMutationStep = any {
    buildScheduleFixture,
    deliverImplicitSequenceMutation,
  }
  action prematureMutationStep = any {
    buildScheduleFixture,
    deliverPrematureMutation,
  }

  val scheduleSafety =
    catalogValid and coreSafety(s) and
    s.stage >= 0 and s.stage <= 9 and
    s.requiredScheduleIds == REQUIRED_IDS and
    (s.stage < 9 or {
      s.network == Set() and
      s.source.pending == Set() and
      s.peer.pending == Set() and
      s.source.admitted == SCHEDULE_OPERATIONS and
      s.peer.admitted == SCHEDULE_OPERATIONS
    })

  pure val INSERT = raw("alice", 0)
  pure val DELETE = raw("bob", 0)
  pure val UNDELETE = raw("carol", 0)
  pure val ROOT = raw("dave", 0)
  pure val EXTRA = raw("erin", 0)
  pure val ORIGIN_TARGET = raw("frank", 0)
  pure val ORIGIN_ONLY = raw("grace", 0)

  pure val INSERT_OP = insert(INSERT, Set(), "A", NoIdentity, NoIdentity)
  pure val DELETE_OP = deleteLike(
    DELETE, Set(INSERT), "delete", INSERT,
  )
  pure val UNDELETE_OP = deleteLike(
    UNDELETE, Set(DELETE), "undelete", INSERT,
  )
  pure val ROOT_OP = insert(ROOT, Set(), "B", NoIdentity, NoIdentity)
  pure val EXTRA_OP = insert(
    EXTRA,
    Set(UNDELETE, ROOT),
    "C",
    SomeIdentity(INSERT),
    SomeIdentity(ROOT),
  )
  pure val ORIGIN_TARGET_OP = insert(
    ORIGIN_TARGET, Set(), "T", NoIdentity, NoIdentity,
  )
  pure val ORIGIN_ONLY_OP = insert(
    ORIGIN_ONLY,
    Set(),
    "G",
    SomeIdentity(ORIGIN_TARGET),
    NoIdentity,
  )
  pure val COMPLETE_OPERATIONS = Set(
    INSERT_OP, DELETE_OP, UNDELETE_OP, ROOT_OP, EXTRA_OP,
  )
  pure val SOURCE_OPERATIONS =
    COMPLETE_OPERATIONS.union(Set(ORIGIN_TARGET_OP, ORIGIN_ONLY_OP))

  pure val CONTENT_CONFLICT = { ...EXTRA_OP, content: "X" }
  pure val PARENTS_CONFLICT = { ...EXTRA_OP, parents: Set(UNDELETE) }
  pure val LEFT_CONFLICT = { ...EXTRA_OP, originLeft: SomeIdentity(ROOT) }
  pure val RIGHT_CONFLICT = { ...EXTRA_OP, originRight: SomeIdentity(INSERT) }

  pure def checkpointOperations(
    state: ModelState,
    checkpointId: str,
  ): Set[Operation] = {
    val checkpoint = checkpointById(state.checkpoints, checkpointId)
    state.source.admitted.filter(operation =>
      checkpoint.knowledge.contains(operation.id)
    )
  }

  pure def insertVisible(
    operations: Set[Operation],
    identity: RawVersion,
  ): bool = {
    val deleted = operations.exists(operation =>
      operation.kind == "delete" and
      operation.originLeft == SomeIdentity(identity)
    )
    val undeleted = operations.exists(operation =>
      operation.kind == "undelete" and
      operation.originLeft == SomeIdentity(identity)
    )
    operations.exists(operation =>
      operation.id == identity and operation.kind == "insert"
    ) and (not(deleted) or undeleted)
  }

  pure def boundedCheckpointText(
    state: ModelState,
    checkpointId: str,
  ): str = {
    val operations = checkpointOperations(state, checkpointId)
    val hasA = insertVisible(operations, INSERT)
    val hasB = insertVisible(operations, ROOT)
    if (hasA and hasB) "AB"
    else if (hasA) "A"
    else if (hasB) "B"
    else ""
  }

  pure def namedEvent(state: ModelState): Event = {
    val stage = state.stage
    if (stage == 0) captureCheckpoint("source", "empty")
    else if (stage == 1) buildFixture("insert", Set(INSERT_OP), Set(INSERT))
    else if (stage == 2) buildFixture("delete", Set(DELETE_OP), Set(DELETE))
    else if (stage == 3) buildFixture("undelete", Set(UNDELETE_OP), Set(UNDELETE))
    else if (stage == 4) buildFixture("complete-root", Set(ROOT_OP), Set(ROOT))
    else if (stage == 5) buildFixture("extra", Set(EXTRA_OP), Set(EXTRA))
    else if (stage == 6) deliver("delete", "peer", -1)
    else if (stage == 7) deliver("insert", "peer", -1)
    else if (stage == 8) deliver("delete", "peer", -1)
    else if (stage == 9) deliver("undelete", "peer", -1)
    else if (stage == 10) deliver("complete-root", "peer", -1)
    else if (stage == 11) deliver("extra", "peer", -1)
    else if (stage == 12) deliver("insert", "source", -1)
    else if (stage == 13) captureCheckpoint("source", "historical")
    else if (stage == 14) deliver("delete", "source", -1)
    else if (stage == 15) deliver("undelete", "source", -1)
    else if (stage == 16) deliver("complete-root", "source", -1)
    else if (stage == 17) captureCheckpoint("source", "multi-head")
    else if (stage == 18) requestDelta("source", "historical", "historical-delta")
    else if (stage == 19) deliver("historical-delta", "peer", -1)
    else if (stage == 20) deliver("extra", "source", -1)
    else if (stage == 21) requestAll("source", "all")
    else if (stage == 22) requestDelta("source", "multi-head", "fresh-delta")
    else if (stage == 23) requestDeltaClaim(
      "source", "overclaim", identities(COMPLETE_OPERATIONS), Set(EXTRA),
    )
    else if (stage == 24) checkout(
      "source", "empty", boundedCheckpointText(state, "empty"),
    )
    else if (stage == 25) checkout(
      "source", "historical", boundedCheckpointText(state, "historical"),
    )
    else if (stage == 26) checkout(
      "source", "multi-head", boundedCheckpointText(state, "multi-head"),
    )
    else if (stage == 27) buildFixture(
      "origin-target", Set(ORIGIN_TARGET_OP), Set(ORIGIN_TARGET),
    )
    else if (stage == 28) buildFixture(
      "origin-only", Set(ORIGIN_ONLY_OP), Set(ORIGIN_ONLY),
    )
    else if (stage == 29) deliver("origin-only", "source", -1)
    else if (stage == 30) deliver("origin-target", "source", -1)
    else if (stage == 31) buildFixture(
      "content-conflict", Set(CONTENT_CONFLICT), Set(EXTRA),
    )
    else if (stage == 32) deliver("content-conflict", "source", -1)
    else if (stage == 33) buildFixture(
      "parents-conflict", Set(PARENTS_CONFLICT), Set(EXTRA),
    )
    else if (stage == 34) deliver("parents-conflict", "source", -1)
    else if (stage == 35) buildFixture(
      "left-conflict", Set(LEFT_CONFLICT), Set(EXTRA),
    )
    else if (stage == 36) deliver("left-conflict", "source", -1)
    else if (stage == 37) buildFixture(
      "right-conflict", Set(RIGHT_CONFLICT), Set(EXTRA),
    )
    else deliver("right-conflict", "source", -1)
  }

  action initNamed = s' = emptyState(-1, Set(), Set())

  action namedStep = all {
    s.stage >= 0,
    s.stage < 39,
    s' = reduce(s, namedEvent(s)),
  }

  val namedSafety =
    coreSafety(s) and s.stage >= 0 and s.stage <= 39 and
    (s.stage < 12 or s.peer.admitted == COMPLETE_OPERATIONS) and
    (s.stage < 21 or s.stage >= 31 or
      s.source.admitted == COMPLETE_OPERATIONS) and
    (s.stage != 30 or s.source.pending == Set(ORIGIN_ONLY_OP)) and
    (s.stage < 31 or s.source.admitted == SOURCE_OPERATIONS) and
    (s.stage < 31 or s.source.pending == Set())

  val flatMaximumMutation = sparseDeltaIsExact(
    Set(0, 2, 7),
    Set(0, 7),
    flatMaximumDelta(Set(0, 2, 7), Set(0, 7)),
  )

  pure val DELETED_CASES = CASES.filter(schedule => schedule.id != 0)
  val catalogDeletionMutation = catalogIsComplete(PERMUTATIONS, DELETED_CASES)
}
