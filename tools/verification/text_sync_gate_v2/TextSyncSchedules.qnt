module TextSyncSchedules {
  import TextSyncCore.* from "TextSyncCore"

  type Delivery = { messageId: str, receiver: str }
  type ScheduleCase = { id: str, deliveries: List[Delivery] }

  type State = {
    stage: int,
    scheduleId: str,
    requiredScheduleIds: Set[str],
    deliveries: List[Delivery],
    sourceKnowledge: Set[int],
    sourceFrontier: Set[int],
    sourcePending: int,
    peerKnowledge: Set[int],
    peerFrontier: Set[int],
    peerPending: int,
    lastEvent: Event,
  }

  pure val PARENT = 0
  pure val CHILD = 2
  pure val ROOT = 7
  pure val OPERATIONS = Set(PARENT, CHILD, ROOT)
  pure val CASES: Set[ScheduleCase] = Set(
    { id: "s-pcr-p-pcr", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-pcr-p-prc", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-pcr-p-cpr", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-pcr-p-crp", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
    { id: "s-pcr-p-rpc", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-pcr-p-rcp", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
    { id: "s-prc-p-pcr", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-prc-p-prc", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-prc-p-cpr", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-prc-p-crp", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
    { id: "s-prc-p-rpc", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-prc-p-rcp", deliveries: [{ messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
    { id: "s-cpr-p-pcr", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-cpr-p-prc", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-cpr-p-cpr", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-cpr-p-crp", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
    { id: "s-cpr-p-rpc", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-cpr-p-rcp", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
    { id: "s-crp-p-pcr", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-crp-p-prc", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-crp-p-cpr", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-crp-p-crp", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
    { id: "s-crp-p-rpc", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-crp-p-rcp", deliveries: [{ messageId: "child", receiver: "source" }, { messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
    { id: "s-rpc-p-pcr", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-rpc-p-prc", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-rpc-p-cpr", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-rpc-p-crp", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
    { id: "s-rpc-p-rpc", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-rpc-p-rcp", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
    { id: "s-rcp-p-pcr", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-rcp-p-prc", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-rcp-p-cpr", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "root", receiver: "peer" }] },
    { id: "s-rcp-p-crp", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "child", receiver: "peer" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
    { id: "s-rcp-p-rpc", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "parent", receiver: "peer" }, { messageId: "child", receiver: "peer" }] },
    { id: "s-rcp-p-rcp", deliveries: [{ messageId: "root", receiver: "source" }, { messageId: "child", receiver: "source" }, { messageId: "parent", receiver: "source" }, { messageId: "root", receiver: "peer" }, { messageId: "child", receiver: "peer" }, { messageId: "parent", receiver: "peer" }] },
  )
  pure val REQUIRED_IDS = CASES.map(schedule => schedule.id)

  var s: State

  action init = {
    nondet selected = CASES.oneOf()
    s' = {
      stage: 0,
      scheduleId: selected.id,
      requiredScheduleIds: REQUIRED_IDS,
      deliveries: selected.deliveries,
      sourceKnowledge: Set(),
      sourceFrontier: Set(),
      sourcePending: 0,
      peerKnowledge: Set(),
      peerFrontier: Set(),
      peerPending: 0,
      lastEvent: NO_EVENT,
    }
  }

  pure def frontier(knowledge: Set[int]): Set[int] =
    if (knowledge.contains(CHILD)) knowledge.exclude(Set(PARENT))
    else knowledge

  pure def nextKnowledge(
    knowledge: Set[int],
    pending: int,
    messageId: str,
    implicitSequenceParent: bool,
  ): Set[int] =
    if (messageId == "parent" and pending == 1 and not(implicitSequenceParent))
      knowledge.union(Set(PARENT, CHILD))
    else if (messageId == "parent") knowledge.union(Set(PARENT))
    else if (
      messageId == "child" and knowledge.contains(PARENT) and
      not(implicitSequenceParent)
    ) knowledge.union(Set(CHILD))
    else if (messageId == "root") knowledge.union(Set(ROOT))
    else knowledge

  pure def nextPending(
    knowledge: Set[int],
    pending: int,
    messageId: str,
    implicitSequenceParent: bool,
  ): int =
    if (
      messageId == "child" and
      (implicitSequenceParent or not(knowledge.contains(PARENT)))
    ) 1
    else if (
      messageId == "parent" and pending == 1 and not(implicitSequenceParent)
    ) 0
    else pending

  pure def outcome(
    knowledge: Set[int],
    pending: int,
    messageId: str,
    implicitSequenceParent: bool,
  ): str =
    if (
      messageId == "child" and
      (implicitSequenceParent or not(knowledge.contains(PARENT)))
    ) "Pending"
    else if (
      messageId == "parent" and pending == 1 and not(implicitSequenceParent)
    ) "AppliedPending"
    else "Success"

  action buildParent = all {
    s.stage == 0,
    s' = {
      ...s,
      stage: 1,
      lastEvent: event(
        "BuildFixture", "parent", "", "", "", "", -1, "x", "Success",
        Set(PARENT), Set(),
      ),
    },
  }

  action buildChild = all {
    s.stage == 1,
    s' = {
      ...s,
      stage: 2,
      lastEvent: event(
        "BuildFixture", "child", "", "", "", "", PARENT, "x", "Success",
        Set(CHILD), Set(),
      ),
    },
  }

  action buildRoot = all {
    s.stage == 2,
    s' = {
      ...s,
      stage: 3,
      lastEvent: event(
        "BuildFixture", "root", "", "", "", "", -1, "x", "Success",
        Set(ROOT), Set(),
      ),
    },
  }

  def deliveryState(
    delivery: Delivery,
    implicitSequenceParent: bool,
  ): State = {
    val receiverKnowledge = if (delivery.receiver == "source")
      s.sourceKnowledge
    else
      s.peerKnowledge
    val receiverPending = if (delivery.receiver == "source")
      s.sourcePending
    else
      s.peerPending
    val knowledge = nextKnowledge(
      receiverKnowledge,
      receiverPending,
      delivery.messageId,
      implicitSequenceParent,
    )
    val pending = nextPending(
      receiverKnowledge,
      receiverPending,
      delivery.messageId,
      implicitSequenceParent,
    )
    val deliveryOutcome = outcome(
      receiverKnowledge,
      receiverPending,
      delivery.messageId,
      implicitSequenceParent,
    )
    {
      ...s,
      stage: s.stage + 1,
      sourceKnowledge: if (delivery.receiver == "source") knowledge else s.sourceKnowledge,
      sourceFrontier: if (delivery.receiver == "source") frontier(knowledge) else s.sourceFrontier,
      sourcePending: if (delivery.receiver == "source") pending else s.sourcePending,
      peerKnowledge: if (delivery.receiver == "peer") knowledge else s.peerKnowledge,
      peerFrontier: if (delivery.receiver == "peer") frontier(knowledge) else s.peerFrontier,
      peerPending: if (delivery.receiver == "peer") pending else s.peerPending,
      lastEvent: event(
        "Deliver", delivery.messageId, "", delivery.receiver, "", "", -1, "",
        deliveryOutcome, Set(), knowledge,
      ),
    }
  }

  action deliver = all {
    s.stage >= 3,
    s.stage < 9,
    nondet delivery = Set(s.deliveries[s.stage - 3]).oneOf()
    s' = deliveryState(delivery, false)
  }

  action deliverWithImplicitSequenceParent = all {
    s.stage >= 3,
    s.stage < 9,
    nondet delivery = Set(s.deliveries[s.stage - 3]).oneOf()
    s' = deliveryState(delivery, true)
  }

  action step = any { buildParent, buildChild, buildRoot, deliver }

  action mutationStep = any {
    buildParent,
    buildChild,
    buildRoot,
    deliverWithImplicitSequenceParent,
  }

  val identitySafety =
    s.sourceKnowledge.subseteq(OPERATIONS) and s.peerKnowledge.subseteq(OPERATIONS)

  val admissionSafety =
    (not(s.sourceKnowledge.contains(CHILD)) or s.sourceKnowledge.contains(PARENT)) and
    (not(s.peerKnowledge.contains(CHILD)) or s.peerKnowledge.contains(PARENT)) and
    (s.sourcePending == 0 or not(s.sourceKnowledge.contains(CHILD))) and
    (s.peerPending == 0 or not(s.peerKnowledge.contains(CHILD)))

  val versionExactness =
    s.sourceFrontier == frontier(s.sourceKnowledge) and
    s.peerFrontier == frontier(s.peerKnowledge)

  val deliveryConvergence =
    s.stage < 9 or {
      s.sourceKnowledge == OPERATIONS and
      s.peerKnowledge == OPERATIONS and
      s.sourceFrontier == Set(CHILD, ROOT) and
      s.peerFrontier == Set(CHILD, ROOT) and
      s.sourcePending == 0 and s.peerPending == 0
    }

  val boundedState =
    s.stage >= 0 and s.stage <= 9 and
    s.deliveries.length() == 6 and
    s.requiredScheduleIds == REQUIRED_IDS and
    s.sourcePending >= 0 and s.sourcePending <= 1 and
    s.peerPending >= 0 and s.peerPending <= 1

  val safety =
    boundedState and identitySafety and admissionSafety and
    versionExactness and deliveryConvergence
}
