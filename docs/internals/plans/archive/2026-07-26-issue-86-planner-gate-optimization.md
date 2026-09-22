# Issue #86: planner gate optimization

**Status:** completed and archived (2026-07-26)
**Date:** 2026-07-26
**Depends on:** ADR 0004 and the completed production cutover through `aa9fe59`
**Evidence:** prototype evidence at `06e7c8d`; production optimization `cc7df51`, `b3288a9`, `f1d3a54`; accepted gates and prototype removal `516d753`
**Final results:** [Issue #86](https://github.com/dowdiness/event-graph-walker/issues/86#issuecomment-5082623153)

> This plan is complete. ADR 0004 records the final split representation,
> consequences, and accepted measurements.

## Goal

Meet ADR 0004's unchanged performance gates without restoring the production
fixed-point planner, introducing a second pending owner, weakening compatibility
order, or moving acknowledgement before graph/log commit.

The first cutover removed quadratic reverse-chain planning but missed branch and
small/in-order gates.

Phase benchmarks found negligible costs in constructors, the OpLog shell, and
`operations().to_owned()`. Staging, priority scheduling, drain, and plan
materialization accounted for most of the measured cost. The reviewed
split-storage prototype then passed semantic validation and the paired median
gates.

Representative paired evidence:

| Scenario | wasm-gc oracle / current / split | JS oracle / current / split |
|---|---:|---:|
| ready 32 | 2.97µs / 20.37µs / 3.06µs | 4.93µs / 37.13µs / 5.62µs |
| in-order 64 | 8.56µs / 60.55µs / 9.32µs | 15.60µs / 118.70µs / 16.32µs |
| branches 4×250 | 15.24ms / 1.47ms / 1.27ms | five paired split speedups: 12.24×, 13.78×, 13.33×, 10.08×, 12.71× |
| reverse 10,000 | 6.45s / 36.40ms / 20.61ms | 8.79s / 51.01ms / 26.02ms |

Ready-1 five-run median regression was 19.1% on wasm-gc and 14.5% on JS.
Matched prepare+begin+ack lifecycle measurements improved in every scenario, so
the prototype does not pass by merely shifting work into begin.

## Constraints

- `RemoteAdmissionPlanner` remains the only pending owner.
- Pending-first repeated fixed-point compatibility order remains exact.
- Planner remains graph-agnostic; OpLog supplies explicit admitted status.
- `RemoteAdmissionPlan` stays opaque, single-use, and generation-checked; only
  `operations() -> ArrayView[Op]` is public.
- Begin validates completely before canonical mutation and never acknowledges.
- OpLog acknowledges each operation only after graph and operation-log commit.
- Partial admission preserves the committed prefix and leaves the suffix pending.
- Identity conflicts remain outside this issue, as stated by ADR 0004.

## Existing API First

Reuse:

- `Array`, `ArrayView`, and `Array::contains` for ordered, small dependency data
  and the read-only public operation view.
- Ephemeral mutable `HashSet` for O(1) planned-identity membership during the
  fast scan and begin validation.
- Existing `Map` indexes and `PriorityQueue` in the canonical planner and
  general overlay; they are not retained redundantly in the prepared plan.
- `Option` matching for origins, `Result`/checked errors at OpLog boundaries,
  and `parents_iter()` to avoid parent-array copies.
- Existing `register_canonical`, `acknowledge_admitted`, rejection, compaction,
  oracle, and OpLog commit shell.

Checked but not selected:

- Immutable `HashSet`: preparation state is disposable and locally mutable.
- `Iter` pipelines: explicit early-exit scans avoid closure/intermediate costs.
- `cmp`/math helpers: no numeric transformation beyond existing round logic.
- A fixed-point fast fallback: forbidden in production and unnecessary.

The private-enum-inside-public-opaque-struct shape is already used by
`peer_sync/peer_sync.mbt` (`priv enum Phase` inside public `State`).

## Architecture and ownership

Preparation is the deterministic core: explicit planner state, incoming ops,
and admitted predicate produce an opaque plan. OpLog is the imperative shell:
it owns CausalGraph lookup/mutation, operation-log mutation, and per-operation
acknowledgement.

The final plan has five private fields: compatibility-ordered `planned`, private
storage, `next_arrival`, `generation`, and `consumed`. `DeferredFast` is a
no-payload storage marker; `planned` is its sole staged/ordered owning array.
`ImmediateGeneral` owns one ordered array of prepared nodes containing operation,
raw identity, arrival, dependencies, waiting dependencies, and unresolved count.

Its staged-node operation and `planned` entry may occupy two array slots, but both
are shallow immutable `Op` values. Operation fields have no mutation API, and
parent ownership is private to `@core.Op`. Begin requires an exact payload match
between the compatibility projection and canonical/staged operation.

Tests must prove that mutating an owning copy returned from
`operations().to_owned()` cannot change either representation. No internal
mutable array is exposed. Canonical registration makes defensive copies where
planner-owned dependency metadata must outlive the consumed plan.

Every graph admission increments planner generation, including admissions with
no waiter. Therefore a generation match plus the explicit admitted predicate is
the consistency boundary between prepare and begin.

## Commit A: use ordered Array dependency normalization

**Files**

- `internal/oplog/remote_admission_planner.mbt`
- `internal/oplog/remote_admission_planner_wbtest.mbt`

**Red–green**

1. Add tests with repeated parents, repeated origins, and parent/origin overlap.
   Pin first-occurrence order.
2. Replace the per-operation normalization `HashSet` with a small local `Array`
   and `contains` checks.
3. Keep fast readiness separate and allocation-free: repeated dependency checks
   are Boolean-idempotent and need no normalized array.

**Invariants**

Normalization still includes parents, left origin, then right origin; each raw
appears once at its first position. General-path waiter counts remain unchanged.

**Validation**

`moon test internal/oplog`; `moon check --deny-warn`; targeted wasm-gc and JS
prototype/gate benchmarks; `git diff --check`.

**Rollback**

Restore the HashSet normalizer. No plan representation changes are included.

## Commit B: compact the general prepared capability

**Files**

- `internal/oplog/remote_admission_planner.mbt`
- `internal/oplog/oplog.mbt`
- `internal/oplog/remote_admission_planner_wbtest.mbt`
- `internal/oplog/oplog_wbtest.mbt`

**Red–green**

1. Add production guards for pending-first planning, unresolved remaining nodes,
   metadata corruption before mutation, and exact planned identity matching.
2. Add private `RemoteAdmissionPreparedNode` and private plan storage with the
   `ImmediateGeneral` variant.
3. Replace `planned_raws`, staged Map, arrivals Map, unresolved Map, waiting Map,
   and staged-order Array in `RemoteAdmissionPlan` with one ordered prepared-node
   array. Keep `planned`, generation, arrival cursor, and consumed state.
4. Leave the general overlay/PQ drain unchanged. Materialize prepared nodes in
   arrival order and transfer dependency-array ownership without duplicate copy.
5. Change private `begin`/`begin_plan` to receive `is_admitted`. OpLog passes
   `raw => graph.raw_to_lv(raw) is Some(_)`.
6. Before mutation, validate consumed/generation, arrivals, unique raws,
   operation payload, normalized dependencies, waiting filter, unresolved count,
   and every planned identity as an exact operation match in either existing
   pending or staged storage; reject a staged raw for which `is_admitted(raw)` is
   now true; register only after the complete validation pass, without
   acknowledging.
7. Rewrite `remaining_raws` over canonical pending order and prepared-node order.
8. Adapt whitebox tests that currently mutate `staged_order`, `staged_arrivals`,
   or staged Maps to corrupt the equivalent prepared node.

**Invariants**

Public signatures and `.mbti` stay unchanged. Pending-not-planned nodes survive.
The failed/later suffix remains pending after partial commit. Corruption tests
cover a planned payload mismatch, staged payload mismatch, newly admitted staged
raw, gapped/duplicate arrival, and inconsistent waiting metadata; every failure
leaves canonical membership, arrival cursor, and generation unchanged.

**Validation**

`moon fmt`; `moon info`; inspect `internal/oplog/pkg.generated.mbti`; `moon test
internal/oplog`; `moon check --deny-warn`; full `moon test`.

**Rollback**

Revert this commit as a unit to the existing multi-collection capability.

## Commit C: add the DeferredFast variant

**Files**

- `internal/oplog/remote_admission_planner.mbt`
- `internal/oplog/remote_admission_planner_wbtest.mbt`
- `internal/oplog/oplog_wbtest.mbt`

**Red–green**

1. Add tests for ready/in-order fast selection, admitted and identical duplicate
   skipping, graph-known dependencies, first-unready fallback, pending-forced
   fallback, repeated dependencies, stale/consumed plans, malformed atomicity,
   unresolved registration, and partial-prefix suffix retention.
2. Add no-payload `DeferredFast` storage.
3. Implement a private fast attempt only when canonical pending is empty. Scan
   once with an ephemeral planned-raw HashSet. Readiness directly checks parents
   and origins against admitted status or earlier planned identities.
4. On the first unready operation, discard all temporary state and rerun the
   unchanged general overlay path from scratch.
5. In DeferredFast begin, treat `planned` as the sole staged order. Build every
   prepared node in a temporary array from the explicit admitted view, validate
   all nodes and planned identities, then register. Set consumed and generation
   once; do not acknowledge.

**Invariants**

The fast scan is valid only when one arrival-order pass equals compatibility
order. General `(round, arrival)` scheduling remains authoritative otherwise.
Plan arrays remain private; callers receive only an `ArrayView`.

**Validation**

Commit B validation plus targeted oracle differential tests and paired lifecycle
benchmarks for ready 1/32, in-order 1/64, duplicates, branches, and reverse 10k.

**Rollback**

Remove DeferredFast and always select ImmediateGeneral; Commit B remains green.

## Commit D: run gates and migrate evidence

**Files**

- `internal/oplog/oplog_benchmark.mbt`
- `internal/oplog/remote_admission_planner_wbtest.mbt`
- `internal/oplog/oplog_wbtest.mbt`
- `internal/document/document_benchmark.mbt` only if a guard needs correction
- remove prototype files only after all evidence is represented elsewhere

Migrate the dedicated prototype's semantic guards into production whitebox tests.
Keep the test-only historical oracle. Add temporary matched lifecycle diagnostics
if needed; compare equal output shapes and keep equality checks outside timing.

The original immediate pre-cutover Document evidence is Issue #86 comment
https://github.com/dowdiness/event-graph-walker/issues/86#issuecomment-5079148866:
8.49s wasm-gc and 11.36s JS for reverse 10,000 at `7238c8b`. Those values are a
recorded run, not a five-run median. Before Commit B, create a temporary detached
git worktree at `7238c8b` and rerun the historical production source five times
per target with the current machine and toolchain. Record commit, `moon version`,
Node version, OS/CPU, raw output, and medians on Issue #86; remove the worktree
afterward. Do not add a legacy adapter to the current branch.

Use the same exact commands for both the historical worktree and post-cutover
branch:

- `moon bench --release --package dowdiness/event-graph-walker/internal/document --file document_benchmark.mbt --index 3`
- the same command with `--target js`

Run each post-cutover scenario five times and use the median. The post-cutover
median must be at least 5× faster than both the original recorded value and the
new five-run historical median. For planner benchmarks, run oracle and production
in the same executable and command five times per target; reverse 10,000 must be
at least 50×, branch 4×250 median at least 10×, and ready 1/32 plus in-order 1/64
median regression at most 20%.

Before Commit B, record five-run medians for the dedicated prototype's matched
prepare+begin+ack lifecycle scenarios on Issue #86. After Commit C, production
lifecycle medians for ready 32, in-order 64, branches, and reverse 10,000 must not
regress more than 20% against those pre-optimization medians. This threshold is
in addition to, not a replacement for, the preparation gates.

Then run `moon fmt`, `moon info`, inspect all `.mbti`, `moon check --deny-warn`,
and full `moon test`. Before deleting prototypes, maintain an explicit mapping
from each retained guard: repeated dependency order, malformed atomicity,
pending-first, unresolved remaining, partial prefix, stale generation, consumed
reuse, prepare order, and lifecycle output to its production test or benchmark.
Delete `internal/oplog/prototype_issue_86/` and the dedicated optimization
benchmark only when every row is covered. Preserve the fixed-point oracle.

Production guard mapping completed before prototype removal:

| Prototype evidence | Retained production guard |
|---|---|
| repeated dependency order | `remote admission dependencies preserve first occurrence order`; `remote admission planner selects fast and general preparation exactly` |
| malformed atomicity | `remote admission begin rejects internal conflicts atomically`; prepared-node corruption and fast reorder tests |
| pending-first | `remote admission general lifecycle preserves pending-first fixed-point order` |
| unresolved remaining | `remote admission general begin registers unresolved nodes` |
| partial prefix | `remote admission preserves committed prefix on injected graph failure`; `remote admission planner preserves an unacknowledged successful prefix remainder` |
| stale generation | `remote admission acknowledgement always invalidates prepared plans`; OpLog stale-plan tests |
| consumed reuse | `remote admission fast plan begins and is consumed exactly once`; `remote admission plan is opaque, read-only, and single use` |
| prepare order | planner differential tests plus paired oracle/production gate benchmarks |
| lifecycle output | `benchmark_assert_lifecycle_equivalence` and the four retained production lifecycle benchmarks |

**Rollback**

If any unchanged gate fails, stop. Revert Commit C first; if the general gate
still fails, revert Commit B. Do not weaken the ADR gate in this plan.

## Commit E: close documentation

Update ADR 0004 with final split-storage rationale and raw measurements. Mark the
original Issue #86 plan and this optimization plan complete/archive them according
to repository convention. Post final commands and benchmark output to Issue #86.
Do not close the issue until the implementation is merged and accepted.

## Final acceptance

- One canonical pending owner; no production fixed-point fallback.
- Exact compatibility order and attempt-scoped rejection/retry.
- Opaque plan still exposes only `ArrayView[Op]`.
- Complete pre-mutation validation; acknowledgement only after successful commit.
- Partial prefix, Document projection, and retained Branch advancement remain exact.
- No unintended `.mbti` drift.
- All planner, lifecycle, and integrated Document gates pass on wasm-gc and JS.
