# Detect RawVersion identity conflicts in OpLog

**Date:** 2026-07-26

**Status:** Filed as [Issue #94](https://github.com/dowdiness/event-graph-walker/issues/94)

**Parent research:** Issue #88

**Policy:** [ADR 0005](../adr/0005-rawversion-identity-conflicts.md)

This proposal was filed as [Issue #94](https://github.com/dowdiness/event-graph-walker/issues/94). Implementation is tracked there.

## Goal and seam

Text and container sync already reject a different payload under an admitted or pending `RawVersion`. OpLog does not: batch validation rejects all repeats, and admission skips known identities before payload comparison (`internal/oplog/oplog.mbt:272-301`, `:474-505`; `internal/oplog/remote_admission_planner.mbt:560-629`). Direct OpLog, Document, and Branch calls can therefore hide a conflict that the façades would reject.

Add one private, structural classifier in `internal/oplog`. For operations sharing a `RawVersion`, it compares sorted parents with multiplicity, exact content, and both origins. It ignores parent order and destination-local `lv`. It uses neither hashes nor serialization.

Where should the admitted payload come from without teaching the planner about CausalGraph? OpLog can resolve `RawVersion -> lv -> Op` before invoking the planner. The planner then compares only the full operations it already owns in staged and pending nodes. All checks finish before `begin_remote_plan`; `try_apply_remote` remains a commit shell for an already conflict-free plan.

## Existing API First

| Candidate | Use |
|---|---|
| `RawVersion` `Eq`, `Compare`, `Hash` (`internal/core/version.mbt:22-25`, `:76-87`) | Identity keys and parent sorting |
| Planner pending/staged maps (`internal/oplog/remote_admission_planner.mbt:8-18`, `:94-105`) | Authoritative unadmitted payloads |
| `CausalGraph::raw_to_lv` + `OpLog::get_op` (`internal/causal_graph/graph.mbt:89-95`; `internal/oplog/oplog.mbt:163-181`) | Admitted payload recovery |
| `Failure::ConflictingIdentity` (`sync/types.mbt:18-24`) | Existing façade report |
| `Map`, `HashSet`, `Option`, `Result`, `ArrayView`, `Op` accessors | Existing collection and checked-flow machinery |

Two nearby mechanisms do not fit. `remote_admission_same_operation` includes `lv` and parent-array order because it validates plan integrity (`internal/oplog/remote_admission_planner.mbt:154-165`). Text's `op_payload_key` has the right semantics but is package-private and allocates a string (`text/sync.mbt:47-67`). Container compares richer records. Bytes, digests, snapshots, and retained indexes add storage obligations without improving current evidence.

The only new definitions are the private classifier and `OpLogError::ConflictingIdentity(raw)`. The error contains no content or digest. Its exported appearance in `internal/oplog/pkg.generated.mbti` is intentional; every exhaustive `OpLogError` match must be reviewed.

## Work

1. Pin logical equality with white-box tests: different `lv` and parent order are equal; different parents, content, or either origin conflict.
2. Add the private classifier in `internal/oplog`.
3. Change batch validation so identical repeats collapse and differing repeats raise the typed conflict, without weakening parent/frontier closure checks.
4. Add OpLog preflight for graph-admitted identities using `raw_to_lv` and `get_op`; keep the planner's admitted-status callback graph-agnostic.
5. Compare repeats in fast staging, then canonical-pending and overlay-staged operations in general preparation. Preserve compatibility order, arrivals, generation, compaction, and the planner's sole ownership of pending membership.
6. Keep conflict detection out of commit. An intervening admission invalidates the plan before registration; no `try_apply_remote` fallback may discover a late conflict.
7. Let Document and Branch continue wrapping `OpLogError`. Update only text façade conversion to the existing shared failure. Do not import `sync` into lower packages or alter container record errors.
8. Add focused and generated coverage without extending PR #90's lifecycle grammar or PR #91's compression grammar. Extend PR #92-style delivery assertions only where identical and conflicting payloads must diverge. Keep JSON and canonical-byte fixtures unchanged.

Likely production files are `internal/oplog/{errors,remote_admission_planner,oplog}.mbt` and `text/errors.mbt`. No production change is expected in `sync`, `container`, `peer_sync`, Document/Branch projection, `internal/core`, or `OpRun` codecs.

## Test matrix

| Entry state | Delivery | Expected result | State that must remain stable |
|---|---|---|---|
| Incoming batch | same payload; different `lv` or parent order | one candidate/admission | one graph identity, one log op, no pending |
| Incoming batch | parent, content, or origin differs | typed conflict | graph, log, frontier, planner generation |
| Fast staging | identical repeat | one candidate | compatibility order |
| Fast staging | conflicting repeat | preparation fails | planner, graph, log |
| General overlay | conflicting staged repeat after fast fallback | preparation fails | overlay discarded; canonical planner unchanged |
| Canonical pending | identical repeat | no-op; original retained | payload, arrival, dependencies, pending count |
| Canonical pending | conflicting repeat | typed conflict | original node and waiter state |
| Admitted history | identical repeat with another local `lv` | admitted no-op | op count, frontier, projection |
| Admitted history | any logical field conflicts | typed conflict | admitted payload and all shared state |
| Rejected pending | later payload under the identity | evaluated as fresh | no tombstone |
| Conflict retry | conflict again, then authoritative payload | conflict, then duplicate no-op | identity never poisoned |
| One batch | ready prefix followed by conflict | zero admissions | graph, log, frontier, projection |
| Separate calls | conflict after earlier success | later call fails | earlier admission remains |
| Document / Branch | admitted or pending conflict | wrapped typed failure; no projection/advance | graph, log, planner, frontier, cache, tree; cursor keeps current attempt behavior |
| Text sync | conflict within message, pending, or admitted | existing non-retryable shared failure | version, text, pending; peer terminal |
| Container sync | record conflict within message, pending, or admitted | existing shared failure | document, version, pending |
| Sync replay | identical operation | duplicate report/no-op | no second admission |
| Export/import | same operation receives different destination LVs | no conflict | logical export and canonical bytes |
| Modified import | same identity, changed logical field | conflict | receiver state |
| `OpRun` JSON | `start_lv` round trip | outside sync comparison | existing codec fixtures |
| Causal-graph commit failure | no identity conflict | existing `PartialRemoteAdmission` | committed prefix projected once |

Existing duplicate/retry tests remain; add different-`lv` cases where PR #92 currently reuses the exact same `Op`.

## Acceptance

- Every matrix row has deterministic coverage; generated delivery distinguishes identical and conflicting payloads without changing planner lifecycle or compression grammars.
- Identical retransmission is a no-op before admission, while pending, and after admission. Parent order and destination-local `lv` do not change that result.
- Conflict at every lower entry point completes before `begin_remote_plan`, raises the shared identity, and leaves graph, log, planner, frontier, Fugue, cache, and branch state unchanged. Document cursor clearing keeps its existing attempt-local behavior.
- A conflict after a ready input admits zero operations and never uses `PartialRemoteAdmission`. Earlier, separate admissions are not rolled back.
- Conflict and rejection retain no tombstone. A later authoritative payload is evaluated normally.
- No new retained map, digest, snapshot, persistence field, JSON/canonical-byte field, or public `Op` equality appears. Text/container schema-1 bytes and peer-terminal classification remain unchanged.
- PR #91 compression generators, grammar, codecs, and assertions remain unchanged. Every exhaustive `OpLogError` match found by `moon ide find-references` is updated or confirmed exhaustive.
- `moon check --deny-warn`, targeted tests, and full tests pass. `moon info` shows only the intended `internal/oplog/pkg.generated.mbti` variant, with no trait-bound or unrelated interface drift.

## Validation

Run from the Event Graph Walker module root, serializing all `moon ide` calls:

```bash
NEW_MOON_MOD=0 moon ide doc "@oplog.OpLogError" "@oplog.OpLog::prepare_remote"
NEW_MOON_MOD=0 moon ide outline internal/oplog
NEW_MOON_MOD=0 moon ide peek-def remote_admission_same_operation
NEW_MOON_MOD=0 moon ide find-references OpLogError
NEW_MOON_MOD=0 moon test internal/oplog
NEW_MOON_MOD=0 moon test internal/document
NEW_MOON_MOD=0 moon test internal/branch
NEW_MOON_MOD=0 moon test text
NEW_MOON_MOD=0 moon test container
NEW_MOON_MOD=0 moon test peer_sync internal/peer_sync_integration
NEW_MOON_MOD=0 moon check --deny-warn
NEW_MOON_MOD=0 moon test
NEW_MOON_MOD=0 moon fmt
NEW_MOON_MOD=0 moon info
```

Inspect `.mbti` diffs after `moon info`. Issue #87 owns retained-ready performance measurement; Issue #72 owns application-adapter receipts; Canopy gitlink work remains separate.
