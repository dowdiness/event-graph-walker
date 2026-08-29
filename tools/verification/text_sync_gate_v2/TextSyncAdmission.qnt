module TextSyncAdmission {
  import TextSyncCore.* from "TextSyncCore"

  type State = {
    stage: int,
    sourceKnowledge: Set[int],
    sourceFrontier: Set[int],
    sourcePending: int,
    peerKnowledge: Set[int],
    peerFrontier: Set[int],
    peerPending: int,
    conflicts: int,
    lastEvent: Event,
  }

  pure val CHILD = Set(2)
  pure val PARENT = Set(0)
  pure val ADMITTED = Set(0, 2)

  var s: State

  action init = s' = {
    stage: 0,
    sourceKnowledge: Set(),
    sourceFrontier: Set(),
    sourcePending: 0,
    peerKnowledge: Set(),
    peerFrontier: Set(),
    peerPending: 0,
    conflicts: 0,
    lastEvent: NO_EVENT,
  }

  action buildChild = all {
    s.stage == 0,
    s' = {
      ...s,
      stage: 1,
      lastEvent: event(
        "BuildFixture", "child", "", "", "", "", 0, "x", "Success",
        CHILD, Set(),
      ),
    },
  }

  action deliverChildPending = all {
    s.stage == 1,
    s' = {
      ...s,
      stage: 2,
      sourcePending: 1,
      lastEvent: event(
        "Deliver", "child", "", "source", "", "", -1, "", "Pending",
        Set(), Set(),
      ),
    },
  }

  action deliverChildPrematurely = all {
    s.stage == 1,
    s' = {
      ...s,
      stage: 2,
      sourceKnowledge: CHILD,
      sourceFrontier: CHILD,
      lastEvent: event(
        "Deliver", "child", "", "source", "", "", -1, "", "Success",
        Set(), CHILD,
      ),
    },
  }

  action buildParent = all {
    s.stage == 2,
    s' = {
      ...s,
      stage: 3,
      lastEvent: event(
        "BuildFixture", "parent", "", "", "", "", -1, "x", "Success",
        PARENT, Set(),
      ),
    },
  }

  action deliverParent = all {
    s.stage == 3,
    s' = {
      ...s,
      stage: 4,
      sourceKnowledge: ADMITTED,
      sourceFrontier: CHILD,
      sourcePending: 0,
      lastEvent: event(
        "Deliver", "parent", "", "source", "", "", -1, "", "AppliedPending",
        Set(), ADMITTED,
      ),
    },
  }

  action duplicateChild = all {
    s.stage == 4,
    s' = {
      ...s,
      stage: 5,
      lastEvent: event(
        "DuplicateMessage", "child", "child-duplicate", "", "", "", -1, "",
        "Success", Set(), ADMITTED,
      ),
    },
  }

  action deliverDuplicate = all {
    s.stage == 5,
    s' = {
      ...s,
      stage: 6,
      lastEvent: event(
        "Deliver", "child-duplicate", "", "source", "", "", -1, "",
        "Duplicate", Set(), ADMITTED,
      ),
    },
  }

  action buildConflict = all {
    s.stage == 6,
    s' = {
      ...s,
      stage: 7,
      lastEvent: event(
        "BuildFixture", "child-conflict", "", "", "", "", 0, "y", "Success",
        CHILD, ADMITTED,
      ),
    },
  }

  action deliverConflict = all {
    s.stage == 7,
    s' = {
      ...s,
      stage: 8,
      conflicts: 1,
      lastEvent: event(
        "Deliver", "child-conflict", "", "source", "", "", -1, "", "Conflict",
        Set(), ADMITTED,
      ),
    },
  }

  action replayStep =
    if (s.stage == 0) buildChild
    else if (s.stage == 1) deliverChildPending
    else if (s.stage == 2) buildParent
    else if (s.stage == 3) deliverParent
    else if (s.stage == 4) duplicateChild
    else if (s.stage == 5) deliverDuplicate
    else if (s.stage == 6) buildConflict
    else if (s.stage == 7) deliverConflict
    else s' = s

  action mutationStep =
    if (s.stage == 0) buildChild
    else if (s.stage == 1) deliverChildPrematurely
    else replayStep

  action step = replayStep

  val declaredParentClosure =
    not(s.sourceKnowledge.contains(2)) or s.sourceKnowledge.contains(0)

  val pendingIsolation =
    s.sourcePending == 0 or {
      s.sourceKnowledge == Set() and s.sourceFrontier == Set()
    }

  val exactFrontier =
    if (s.sourceKnowledge.contains(2)) {
      s.sourceFrontier == Set(2)
    } else {
      s.sourceFrontier == s.sourceKnowledge
    }

  val conflictAtomicity = s.conflicts == 0 or {
    s.sourceKnowledge == ADMITTED and
    s.sourceFrontier == CHILD and
    s.sourcePending == 0
  }

  val boundedState =
    s.stage >= 0 and s.stage <= 8 and
    s.sourceKnowledge.subseteq(ADMITTED) and
    s.sourcePending >= 0 and s.sourcePending <= 1 and
    s.peerKnowledge == Set() and s.peerFrontier == Set() and
    s.peerPending == 0 and s.conflicts >= 0 and s.conflicts <= 1

  val safety =
    boundedState and declaredParentClosure and pendingIsolation and
    exactFrontier and conflictAtomicity
}
