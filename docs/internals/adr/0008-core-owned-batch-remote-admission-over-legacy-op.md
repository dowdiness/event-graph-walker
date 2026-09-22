---
status: accepted
---

# Core-owned batch remote admission over legacy operations

> **Text causality update:** ADR 0009 supersedes this ADR's implicit
> same-agent predecessor and sequence-ancestry rules. Ownership, atomic
> admission, pending settlement, and projection-recovery decisions remain in
> force.

The accepted pending-owner decision in ADR 0004 establishes EGW core as the sole owner of document-local pending membership, causal validation, and pending replay. Before changing the authority payload or wire format, the production text path will therefore move semantic admission responsibility into the core while retaining the existing origin-based `@core.Op` payload.

## Decision

The legacy-operation transition is split into four independently validated boundaries:

1. **P0 — semantic parity:** core preparation proves same-agent sequence ancestry through declared parents, requires every origin/delete/undelete target to identify an Insert, preserves complete identity equality, distinguishes current-message rejection from retained-pending invalid-root cleanup, and enforces a complete-transition pending forecast without mutating state during preparation. A hard pending invariant across complete and partial commit outcomes remains deferred.
2. **P1 — typed transition boundary:** `PreparedAdmission` records the prospective, generation-bound transition; `AdmissionOutcome` and `AdmissionReceipt` record the actual complete or partial ownership result after the commit attempt; the boundary owns the hard pending-limit contract.
3. **P2 — batch shell:** Document performs one core admission transition and one projection finalization for an incomplete incoming batch; the complete-frontier closure contract of `merge_remote` is not reused for a partial admission subset.
4. **P3 — façade cutover:** SyncSession retains wire/schema/format/limit compatibility only; it does not retain a second pending queue, planner, H-sized admission map, or per-operation remote commit loop.

The implicit same-agent predecessor is an applicability/validation dependency only. It is never added to the operation's declared causal parents or used to redefine graph ancestry. Semantic validation runs before the first authority mutation. A retained pending operation that becomes invalid, together with its pending dependents, is discarded; an invalid operation first introduced by the current message rejects that message atomically. Projection failure after authority commit is a derived-state recovery problem, not remote invalidity and not an authority rollback.

## Non-decisions

This phase does not introduce `TextReplica`, position-based `TextEvent` authority, a canonical wire/archive migration, a permanent compatibility lifter, a Plain projection, or a full generic planner. A dependency-indexed pending kernel may be explored separately, but it cannot block the text-specific production path or absorb container-specific validation rules.

## Consequences

The phase can be implemented and differentially tested against the existing model without waiting for real-archive liftability percentages. The legacy payload remains compatible while pending ownership and transaction boundaries become correct. The later canonical-payload decision must still use a representative archive/wire corpus; the absence of a checked-in real corpus is not evidence of universal liftability.
