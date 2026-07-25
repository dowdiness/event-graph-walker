---
status: accepted
---

# Give pending remote operations one canonical owner

Pending membership, operation identity, and arrival metadata must change together. A private Remote Admission Planner is proposed as their sole owner. Its operation storage, reverse dependency map, unresolved counts, and deterministic ready queue are internal representations; any of them may be discarded and rebuilt from the planner's canonical pending membership and arrival metadata. No pending representation outside the planner is authoritative.

The planner operates only on `RawVersion` identities, operation dependencies, and explicit admitted-status input supplied by OpLog. It does not import or query CausalGraph, Document, or Fugue state. CausalGraph lookup and mutation remain in the OpLog imperative shell, while planner transitions remain deterministic for the same explicit state and events.

Document must preflight the complete prospective pending-first drain before admission begins. For each dependency-ready operation, the planner keeps the operation pending until OpLog has successfully committed its causal-graph and operation-log mutation; only then may the planner resolve that operation and wake its dependents. A later internal projection failure does not return an admitted operation to pending.

A standalone authoritative `pending : Array[Op]` with genuinely disposable indexes remains a valid alternative. The planner-owned design is preferred only if it gives one interface responsibility for membership, order, duplicate handling, rejection, retry, and cleanup while retaining the measured incremental-planning benefit.

## Prepared admission

Preparing incoming operations is non-mutating and uses a temporary preparation overlay rather than cloning or reversibly mutating canonical planner state. The overlay contains staged incoming nodes, hypothetical unresolved-count deltas, planned identities, ordering metadata, and the additional waiter relationships needed by the prospective batch. It reads existing pending membership and indexes but writes nothing back. Its cost scales with incoming operations and dependency edges actually examined or woken, not with an unconditional copy of all pending state.

OpLog returns an opaque, single-use `RemoteAdmissionPlan` containing pending additions, the complete compatibility-ordered ready plan, and a planner generation token. Document can inspect a read-only view of its planned operations for complete preflight, but cannot construct or mutate the plan. On success, Document gives that same capability back to OpLog for commit; OpLog does not replan from raw incoming operations. A failed preflight registers none of the incoming operations; it may still issue an explicit rejection transition that removes invalid roots and their transitive dependents from existing pending membership. Commit rejects reuse or a generation mismatch rather than applying a stale plan.

## Compatibility order

The production planner must reproduce the existing pending-first repeated fixed-point order. Existing pending operations precede incoming operations. Each round scans the remaining operations in arrival order; an operation planned earlier in that round can satisfy a later operation, while an earlier operation unblocked by a later one waits for the next round. Already admitted or already planned identities are omitted. Rounds continue until no operation progresses. The prototype's `(round, input index)` priority is the compatibility oracle, not a new ordering rule.

## Admission failure

Admission is committed one operation at a time in compatibility order. `OpLog::commit_remote` keeps the existing concrete checked `OpLogError` boundary: normal success returns the committed operations, while `PartialRemoteAdmission` carries the successfully committed prefix and typed causal-graph cause. `StaleRemoteAdmissionPlan` and `ConsumedRemoteAdmissionPlan` fail before mutation. These variants belong in `OpLogError` because existing Document and Branch catch sites already handle OpLog admission failures together.

Document and Branch catch only `PartialRemoteAdmission`, project or advance the committed prefix exactly once, and then re-raise the same typed OpLog failure through their existing error wrappers; unknown errors are not swallowed. The failed operation and all later operations remain pending, the prepared batch becomes stale, and the next attempt prepares again from current state. There is no batch rollback.

This recovery is valid only while failure of the current operation occurs before that operation mutates shared state. The current causal-graph path validates parents before mutation. If a future commit step can fail after partially mutating one operation, it must provide rollback or be treated as unrecoverable corruption rather than using `PartialRemoteAdmission`.

## Rejection and retry

Rejection is scoped to the current remote admission attempt, not permanently to its `RawVersion`. Preflight rejection removes the invalid pending operation and its transitive pending dependents, but records no permanent identity tombstone. A later delivery of the same identity is evaluated again through normal duplicate checks and preflight.

## Duplicates and identity conflicts

A duplicate is the retransmission of the same immutable operation under the same `RawVersion`. Registering a duplicate that is pending or already admitted is a no-op and never creates another planner node or admission. A different payload claiming an existing `RawVersion` is an operation identity conflict, not a duplicate. Detecting or retaining evidence of identity conflicts is a separate protocol-hardening decision and is outside this planner migration.

## Bounded cleanup

Admission or rejection removes an operation from canonical pending membership immediately but may leave inactive nodes, waiter edges, or ready-queue entries in disposable internal indexes. Stale entries are ignored and can never revive an inactive operation. At a quiescent boundary after a drain, the planner deterministically rebuilds its internal indexes from live pending membership and arrival metadata when stale retention crosses a configured threshold. The threshold is selected by benchmark, but must bound retained stale state relative to live pending state rather than relying on the pending set eventually becoming empty.

## Migration validation

The existing fixed-point planner remains only as a test oracle during migration. Deterministic examples and randomized differential tests compare its planned order and remaining pending membership with the new planner across duplicates, known and unknown dependencies, origins, rejection and retry, admission failure, stale entries, and compaction. Production runtime never shadow-executes both planners and never retains a second pending authority. After cutover, the oracle is test-only or removed once equivalent coverage no longer depends on production code.

## Acceptance conditions

Differential tests must cover compatibility order, complete-plan preflight, admission failure, rejection and retry, stale queue entries, and compaction with live pending operations. Release-mode planner benchmarks on wasm-gc and JS must compare the test-only fixed-point oracle and new planner in the same process and scenario. The new planner must be at least 50 times faster for a reverse chain of 10,000 operations and 10 times faster for four reverse chains of 250, while small and in-order workloads show no median regression greater than 20%. The integrated Document reverse-chain workload at 10,000 operations must improve by at least 5 times against a baseline recorded immediately before cutover on the same machine with the same command; no benchmark-only legacy admission adapter is added across the Document/OpLog boundary. Compaction must not restore fixed-point scanning to the hot path.
