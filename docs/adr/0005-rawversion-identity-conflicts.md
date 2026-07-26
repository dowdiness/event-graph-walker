---
status: proposed
---

# Reject RawVersion identity conflicts without retaining conflict evidence

A `RawVersion` names one operation by `agent` and `seq`. Receiving that operation again is a no-op. Receiving another logical payload under the same name is a protocol violation: reject the admission attempt before planner registration or shared-state mutation. Compare payloads already retained by the receiver; add no digest, tombstone, index, or wire field.

## Evidence

An `Op` carries more than its `RawVersion`: destination-local `lv`, parents, content, and left/right origins (`internal/core/version.mbt:22-25`; `internal/core/operation.mbt:18-25`). ADR 0004 settles identical retransmission but leaves different-payload detection open (`docs/adr/0004-canonical-pending-remote-owner.md`, "Duplicates and identity conflicts").

The public sync façades already know the difference. Text sync compares sorted parents, content, and origins while omitting `lv`; it checks both the incoming message and pending/admitted history (`text/sync.mbt:47-67`, `:394-407`, `:1090-1152`). Container sync applies the same rule to its richer records (`container/sync_protocol.mbt:76-115`, `:1141-1208`). Both raise `Failure::ConflictingIdentity`, which peer sync treats as terminal (`sync/types.mbt:18-24`; `peer_sync/peer_sync.mbt:208-220`).

The lower path does not. Batch validation rejects all repeated identities, while planner preparation and final application skip known identities before comparing payloads (`internal/oplog/oplog.mbt:272-301`, `:474-505`; `internal/oplog/remote_admission_planner.mbt:560-629`). Façade-only detection therefore protects normal sync but not direct OpLog, Document, or Branch callers.

A retained digest looks tempting only until the current owners are inspected. Pending nodes already hold the full `Op`. Admitted operations remain recoverable through `CausalGraph::raw_to_lv` and `OpLog::get_op` (`internal/oplog/remote_admission_planner.mbt:37-44`; `internal/causal_graph/graph.mbt:89-95`; `internal/oplog/oplog.mbt:163-181`). The unresolved case is not today's admission path, but a future one that prunes those payloads.

## Decision

For OpLog, the immutable logical operation is:

- `agent` and `seq`, forming the `RawVersion`;
- parents sorted by `RawVersion`, with multiplicity preserved;
- the exact content variant and insert string;
- exact `origin_left` and `origin_right` options.

Parent order is not semantic. Duplicate parents are still malformed and are not normalized away (`text/sync.mbt:270-337`). Destination-local `lv` is not part of the comparison: two receivers may allocate different LVs for the same operation, and the existing text wire already omits it (`text/sync.mbt:47-67`, `:1270-1325`). The planner's current full-operation comparator includes `lv` because it protects an opaque plan; it cannot define this equality (`internal/oplog/remote_admission_planner.mbt:154-165`).

Classification has two outcomes:

- matching logical payload: omit the retransmission without admission, pending membership, or diagnostic;
- differing logical payload: raise a typed conflict for the shared `RawVersion` and reject the complete attempt.

Every comparison completes before `begin_remote_plan`:

- OpLog compares repeated batch entries and graph-admitted identities;
- the graph-agnostic planner compares overlay-staged and canonical-pending identities;
- an identical repeat collapses to one candidate; a conflict changes neither the authoritative payload nor planner membership;
- a conflict after a ready candidate still admits no prefix. `PartialRemoteAdmission` remains reserved for a causal-graph failure after commit begins (`internal/oplog/oplog.mbt:372-404`).

Conflict evidence is attempt-scoped. No identity is blacklisted, so an authoritative retransmission can be evaluated later. Existing preflight rejection likewise forgets rejected pending payloads (`internal/oplog/remote_admission_planner.mbt:286-310`, `:390-429`).

`internal/oplog` owns lower comparison because it owns pending and admitted history. Document and Branch wrap the typed OpLog failure and project nothing because no admission occurred (`internal/document/document.mbt:607-856`; `internal/branch/branch.mbt:225-279`). Text and container retain their earlier functional checks and wire formats. Only façade code maps the lower error to the shared sync failure; peer and application shells own isolation, logging, metrics, and reporting. Error values and default logs carry the `RawVersion`, not operation content.

Attempt-local bookkeeping is outside shared-state atomicity. In particular, Document keeps its existing cursor-clearing behavior on a failed apply attempt.

## Alternatives

| Policy | What it protects | Retention cost | Retry and compatibility |
|---|---|---|---|
| Façade-only | Text/container sync, but not direct lower callers | None | Current wire and peer-terminal behavior |
| **On-demand full-payload comparison** | Incoming, staged, pending, admitted, and direct lower callers | None while full history remains | Attempt-scoped; no wire change or partial prefix |
| Retained digest or tombstone | Can survive future payload pruning | Hash versioning, collision, compaction, persistence, migration | Risks poisoning an identity and introduces new atomicity rules |

Façade-only leaves a real lower-interface gap. Digest retention solves a pruning problem the repository does not yet have. On-demand comparison closes the present gap without deciding future persistence.

## Consequences

The guarantee lasts only while an authoritative full payload remains pending or admitted. If log pruning, snapshot restore, or identity-only persistence removes it, the repository must decide what canonical evidence survives and how it is versioned. The generic `OpRun` JSON field `start_lv` does not answer that question; it is not sync identity (`internal/core/op_run_json.mbt:42-89`).

A future implementation may add `OpLogError::ConflictingIdentity(raw)`. That is an intentional exported `.mbti` change, even though the comparator stays private. Richer commit/report receipts remain Issue #72's concern. Issue #87 retains performance measurement, and PRs #90, #91, and #92 retain their property scopes.

This proposed ADR changes no production code, error surface, persistence, or wire format. Implementation is scoped in `docs/plans/2026-07-26-rawversion-identity-conflict-implementation-issue.md`.
