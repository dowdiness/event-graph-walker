module TextSyncComplete {
  import TextSyncCore.* from "TextSyncCore"

  pure def raw(agent: str): RawVersion = { agent: agent, sequence: 0 }

  pure val INSERT = raw("alice")
  pure val DELETE = raw("bob")
  pure val UNDELETE = raw("carol")
  pure val ROOT = raw("dave")
  pure val EXTRA = raw("erin")

  pure val INSERT_OP: Operation = {
    id: INSERT,
    parents: Set(),
    kind: "insert",
    content: "A",
    hasContent: true,
    originLeft: NoIdentity,
    originRight: NoIdentity,
  }

  pure val DELETE_OP: Operation = {
    id: DELETE,
    parents: Set(INSERT),
    kind: "delete",
    content: "",
    hasContent: false,
    originLeft: SomeIdentity(INSERT),
    originRight: NoIdentity,
  }

  pure val UNDELETE_OP: Operation = {
    id: UNDELETE,
    parents: Set(DELETE),
    kind: "undelete",
    content: "",
    hasContent: false,
    originLeft: SomeIdentity(INSERT),
    originRight: NoIdentity,
  }

  pure val ROOT_OP: Operation = {
    id: ROOT,
    parents: Set(),
    kind: "insert",
    content: "B",
    hasContent: true,
    originLeft: NoIdentity,
    originRight: NoIdentity,
  }

  pure val EXTRA_OP: Operation = {
    id: EXTRA,
    parents: Set(UNDELETE, ROOT),
    kind: "insert",
    content: "C",
    hasContent: true,
    originLeft: SomeIdentity(INSERT),
    originRight: SomeIdentity(ROOT),
  }

  pure val BASE_OPS = Set(INSERT_OP, DELETE_OP, UNDELETE_OP, ROOT_OP)
  pure val ALL_OPS = BASE_OPS.union(Set(EXTRA_OP))
  pure val BASE = Set(INSERT, DELETE, UNDELETE, ROOT)
  pure val ALL = BASE.union(Set(EXTRA))
  pure val MULTI_FRONTIER = Set(UNDELETE, ROOT)
  pure val ALL_FRONTIER = Set(EXTRA)

  type State = {
    stage: int,
    sourceKnowledge: Set[int],
    sourceFrontier: Set[int],
    sourceIdentities: Set[RawVersion],
    sourceFrontierIdentities: Set[RawVersion],
    sourcePending: int,
    sourceText: str,
    peerKnowledge: Set[int],
    peerFrontier: Set[int],
    peerIdentities: Set[RawVersion],
    peerFrontierIdentities: Set[RawVersion],
    peerPending: int,
    peerText: str,
    exported: Set[Operation],
    lastEvent: Event,
  }

  var s: State

  action init = s' = {
    stage: 0,
    sourceKnowledge: Set(),
    sourceFrontier: Set(),
    sourceIdentities: Set(),
    sourceFrontierIdentities: Set(),
    sourcePending: 0,
    sourceText: "",
    peerKnowledge: Set(),
    peerFrontier: Set(),
    peerIdentities: Set(),
    peerFrontierIdentities: Set(),
    peerPending: 0,
    peerText: "",
    exported: Set(),
    lastEvent: NO_EVENT,
  }

  pure def fixture(messageId: str, operation: Operation): Event =
    withFixture(
      event("BuildFixture", messageId, "", "", "", "", -1, "", "Success", Set(), Set()),
      Set(operation),
      Set(operation.id),
    )

  pure def delivery(
    messageId: str,
    receiver: str,
    outcome: str,
  ): Event = event(
    "Deliver", messageId, "", receiver, "", "", -1, "", outcome,
    Set(), Set(),
  )

  action buildInsert = all { s.stage == 0, s' = { ...s, stage: 1, lastEvent: fixture("insert", INSERT_OP) } }
  action buildDelete = all { s.stage == 1, s' = { ...s, stage: 2, lastEvent: fixture("delete", DELETE_OP) } }
  action buildUndelete = all { s.stage == 2, s' = { ...s, stage: 3, lastEvent: fixture("undelete", UNDELETE_OP) } }
  action buildRoot = all { s.stage == 3, s' = { ...s, stage: 4, lastEvent: fixture("root", ROOT_OP) } }

  action deleteBeforeTarget = all {
    s.stage == 4,
    s' = { ...s, stage: 5, peerPending: 1, lastEvent: delivery("delete", "peer", "Pending") },
  }

  action deliverTarget = all {
    s.stage == 5,
    s' = {
      ...s,
      stage: 6,
      peerIdentities: Set(INSERT, DELETE),
      peerFrontierIdentities: Set(DELETE),
      peerPending: 0,
      peerText: "",
      lastEvent: delivery("insert", "peer", "AppliedPending"),
    },
  }

  action captureDeleted = all {
    s.stage == 6,
    s' = {
      ...s,
      stage: 7,
      lastEvent: event("CaptureCheckpoint", "", "", "peer", "deleted", "", -1, "", "Success", Set(), Set()),
    },
  }

  action deliverUndelete = all {
    s.stage == 7,
    s' = {
      ...s,
      stage: 8,
      peerIdentities: Set(INSERT, DELETE, UNDELETE),
      peerFrontierIdentities: Set(UNDELETE),
      peerText: "A",
      lastEvent: delivery("undelete", "peer", "Success"),
    },
  }

  action checkoutDeleted = all {
    s.stage == 8,
    s' = {
      ...s,
      stage: 9,
      lastEvent: withExpectedText(
        event("Checkout", "", "", "peer", "deleted", "", -1, "", "Success", Set(), Set()),
        "",
      ),
    },
  }

  action deliverPeerRoot = all {
    s.stage == 9,
    s' = {
      ...s,
      stage: 10,
      peerIdentities: BASE,
      peerFrontierIdentities: MULTI_FRONTIER,
      peerText: "AB",
      lastEvent: delivery("root", "peer", "Success"),
    },
  }

  action captureMulti = all {
    s.stage == 10,
    s' = {
      ...s,
      stage: 11,
      lastEvent: event("CaptureCheckpoint", "", "", "peer", "multi", "", -1, "", "Success", Set(), Set()),
    },
  }

  action sourceInsert = all {
    s.stage == 11,
    s' = { ...s, stage: 12, sourceIdentities: Set(INSERT), sourceFrontierIdentities: Set(INSERT), sourceText: "A", lastEvent: delivery("insert", "source", "Success") },
  }
  action sourceDelete = all {
    s.stage == 12,
    s' = { ...s, stage: 13, sourceIdentities: Set(INSERT, DELETE), sourceFrontierIdentities: Set(DELETE), sourceText: "", lastEvent: delivery("delete", "source", "Success") },
  }
  action sourceUndelete = all {
    s.stage == 13,
    s' = { ...s, stage: 14, sourceIdentities: Set(INSERT, DELETE, UNDELETE), sourceFrontierIdentities: Set(UNDELETE), sourceText: "A", lastEvent: delivery("undelete", "source", "Success") },
  }
  action sourceRoot = all {
    s.stage == 14,
    s' = { ...s, stage: 15, sourceIdentities: BASE, sourceFrontierIdentities: MULTI_FRONTIER, sourceText: "AB", lastEvent: delivery("root", "source", "Success") },
  }

  action buildExtra = all { s.stage == 15, s' = { ...s, stage: 16, lastEvent: fixture("extra", EXTRA_OP) } }
  action sourceExtra = all {
    s.stage == 16,
    s' = { ...s, stage: 17, sourceIdentities: ALL, sourceFrontierIdentities: ALL_FRONTIER, sourceText: "ACB", lastEvent: delivery("extra", "source", "Success") },
  }

  action requestDelta = all {
    s.stage == 17,
    s' = {
      ...s,
      stage: 18,
      exported: Set(EXTRA_OP),
      lastEvent: withFixture(
        event("RequestDelta", "delta", "", "", "multi", "source", -1, "", "Success", Set(), Set()),
        Set(EXTRA_OP),
        Set(EXTRA),
      ),
    },
  }

  action requestOverclaim = all {
    s.stage == 18,
    s' = {
      ...s,
      stage: 19,
      exported: Set(),
      lastEvent: withVersionClaim(
        event("RequestDeltaClaim", "overclaim", "", "", "", "source", -1, "", "Success", Set(), Set()),
        ALL,
        ALL_FRONTIER,
      ),
    },
  }

  action deliverDelta = all {
    s.stage == 19,
    s' = {
      ...s,
      stage: 20,
      peerIdentities: ALL,
      peerFrontierIdentities: ALL_FRONTIER,
      peerText: "ACB",
      lastEvent: delivery("delta", "peer", "Success"),
    },
  }

  action checkoutMulti = all {
    s.stage == 20,
    s' = {
      ...s,
      stage: 21,
      lastEvent: withExpectedText(
        event("Checkout", "", "", "peer", "multi", "", -1, "", "Success", Set(), Set()),
        "AB",
      ),
    },
  }

  action step = any {
    buildInsert,
    buildDelete,
    buildUndelete,
    buildRoot,
    deleteBeforeTarget,
    deliverTarget,
    captureDeleted,
    deliverUndelete,
    checkoutDeleted,
    deliverPeerRoot,
    captureMulti,
    sourceInsert,
    sourceDelete,
    sourceUndelete,
    sourceRoot,
    buildExtra,
    sourceExtra,
    requestDelta,
    deliverDelta,
    requestOverclaim,
    checkoutMulti,
  }

  val identitySafety =
    uniqueOperationIdentities(ALL_OPS) and
    ALL_OPS.forall(operationShapeValid) and
    s.sourceIdentities.subseteq(ALL) and s.peerIdentities.subseteq(ALL)

  val admissionSafety =
    admittedDependenciesReady(ALL_OPS, s.sourceIdentities) and
    admittedDependenciesReady(ALL_OPS, s.peerIdentities) and
    (s.peerPending == 0 or s.peerIdentities == Set())

  val versionExactness =
    s.sourceFrontierIdentities == maximalFrontier(ALL_OPS, s.sourceIdentities) and
    s.peerFrontierIdentities == maximalFrontier(ALL_OPS, s.peerIdentities)

  val deltaExactness =
    (s.stage < 18 or s.stage >= 19 or s.exported == Set(EXTRA_OP)) and
    (s.stage < 19 or s.exported == Set()) and
    (s.stage != 19 or not(s.peerIdentities.contains(EXTRA)))

  val deliveryConvergence =
    s.stage < 20 or {
      s.sourceIdentities == s.peerIdentities and
      s.sourceFrontierIdentities == s.peerFrontierIdentities and
      s.sourceText == s.peerText
    }

  val implementationCorrespondence =
    s.stage >= 0 and s.stage <= 21 and
    Set(
      "Init", "BuildFixture", "Deliver", "CaptureCheckpoint",
      "RequestDelta", "RequestDeltaClaim", "Checkout",
    ).contains(s.lastEvent.name)

  pure val ORIGIN_CONFLICT: Operation = {
    ...EXTRA_OP,
    originLeft: SomeIdentity(ROOT),
    originRight: SomeIdentity(INSERT),
  }

  val identityConflictMutation =
    uniqueOperationIdentities(ALL_OPS.union(Set(ORIGIN_CONFLICT)))

  val nullContentMutation = operationShapeValid({
    ...DELETE_OP,
    hasContent: true,
    content: "",
  })

  val safety =
    identitySafety and admissionSafety and versionExactness and deltaExactness and
    deliveryConvergence and implementationCorrespondence
}
