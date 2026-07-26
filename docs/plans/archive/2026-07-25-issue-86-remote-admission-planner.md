# Issue #86 production plan: remote admission planner

**Status:** completed and archived (2026-07-26)
**Decision:** [ADR-0004](../../adr/0004-canonical-pending-remote-owner.md)
**Scope:** `internal/oplog`, `internal/document`, and compatibility validation in `internal/branch`
**Completion:** production cutover through `aa9fe59`; accepted optimization and evidence through `516d753`

> This plan is complete. The
> [gate optimization follow-up](./2026-07-26-issue-86-planner-gate-optimization.md)
> is archived beside it. Final measurements are recorded in
> [ADR 0004](../../adr/0004-canonical-pending-remote-owner.md) and
> [Issue #86](https://github.com/dowdiness/event-graph-walker/issues/86#issuecomment-5082623153).
> One implementation detail differs from the stronger cost wording below: the
> general overlay copies the disposable ready queue, but it does not clone
> canonical pending membership or node metadata.

## Goal

Replace repeated fixed-point scans of pending remote operations with a canonical, graph-agnostic Remote Admission Planner while preserving all observable behavior:

- pending-first repeated fixed-point order
- complete Document preflight before admission
- duplicate no-op behavior
- attempt-scoped rejection and retry
- per-operation commit without batch rollback
- Document convergence and existing public OpLog/Branch call shapes

The planner benchmark must improve reverse-chain planning by at least 50x at 10,000 operations and branching planning by at least 10x, without a median regression above 20% for small or in-order workloads. The integrated Document reverse-chain workload must improve by at least 5x.

## Non-goals

- Detecting operation identity conflicts beyond existing validation
- Permanent rejected-identity tombstones
- Changing CRDT, Fugue, causal-graph, or wire semantics
- Using `dowdiness/incr` inside the planner
- Running the old and new planners together in production
- Removing `OpLog::plan_remote`, `OpLog::apply_remote`, `OpLog::discard_pending_dependents`, or Branch convenience APIs

## Architecture

### Functional core

The planner owns pending membership, operation identity, arrival ordinals, unresolved counts, reverse waiters, lifecycle state, and disposable scheduling indexes. It accepts only explicit `RawVersion` dependency status and planner events; it never queries CausalGraph, Document, or Fugue.

Preparation is non-mutating. A temporary overlay holds staged incoming nodes, hypothetical unresolved-count deltas, planned identities, ordering metadata, and additional waiter relationships. Local mutation used to build this returned overlay is allowed because it has no externally observable effect. Preparation must not clone or scan all pending state unconditionally.

The planner's mutable facade applies deterministic transitions to canonical in-memory state. It performs no I/O or graph mutation.

### Imperative shell

OpLog queries CausalGraph for admitted identities, performs causal-graph and operation-log commits, and notifies the planner only after each operation commit succeeds. Document validates content and performs complete target preflight before giving the same opaque prepared plan back to OpLog for commit.

`RemoteAdmissionPlan` is opaque and single-use. It contains a planner generation, staged incoming transitions, and compatibility-ordered operations. Its public accessor returns `ArrayView[@core.Op]`; callers cannot construct it or mutate its backing arrays.

### Compatibility order

Candidates consist of existing pending operations followed by incoming operations. Each round scans remaining candidates in arrival order. An operation planned earlier in a round may unblock a later candidate in that round; an earlier candidate unblocked by a later one waits for the next round. The ready priority is therefore `(round, arrival ordinal)`. MoonBit's mutable `PriorityQueue` is max-first, so production uses reversed comparison or negative keys. Map iteration order never participates in scheduling.

### Commit and failure

After successful complete preflight, OpLog validates the plan generation, marks the plan consumed, registers all staged incoming operations, and commits ready operations in plan order. After each causal-graph and operation-log commit succeeds, OpLog resolves that identity in the planner and wakes dependents.

`commit_remote` keeps the existing concrete `OpLogError` boundary. Normal success returns committed operations. `PartialRemoteAdmission` carries the successfully committed prefix and typed causal-graph cause; stale and consumed plan variants fail before mutation. Document and Branch catch only `PartialRemoteAdmission`, project or advance its prefix exactly once, then re-raise the same error through their existing typed wrappers. Unknown errors are rethrown. The failed operation and later operations remain pending.

This path is valid only while failure of the current operation occurs before that operation mutates shared state. If a future commit step can fail after partial mutation, it requires rollback or corruption handling instead of `PartialRemoteAdmission`.

### Cleanup

Admission or rejection removes canonical pending membership immediately. Internal inactive nodes, waiter edges, and queue entries may remain temporarily and are ignored. At a quiescent boundary, OpLog asks the planner to compact when stale retention crosses a benchmark-selected threshold relative to live pending state. Rebuilds preserve arrival ordinals and use an explicit admitted-status capability.

## Existing API First

### Reused project APIs

- `@core.RawVersion` (`internal/core/version.mbt`): identity key; reuse `Eq`, `Hash`, and `Compare`.
- `@core.Op` (`internal/core/operation.mbt`): reuse `parents_iter`, `origin_left`, `origin_right`, `agent`, `seq`, and content predicates.
- `CausalGraph::raw_to_lv` and `add_version_with_seq` (`internal/causal_graph/graph.mbt`): OpLog shell lookup and commit.
- `Branch::from_tree_and_oplog` and `Branch::advance` (`internal/branch/branch.mbt`): preserve merge projection by capturing the pre-commit frontier and advancing once after commit.
- Existing `OpLog::plan_remote`, `apply_remote`, and `discard_pending_dependents`: retain as compatibility wrappers.

### Reused MoonBit core APIs

- `Map`: keyed ownership and reverse lookup; never use iteration order for admission order.
- `@hashset.HashSet`: temporary deduplication, planned identities, and rejection closure.
- Mutable `@priority_queue.PriorityQueue`: deterministic ready scheduling with max-first ordering accounted for explicitly.
- `ArrayView`: read-only plan inspection without exposing mutable backing arrays.
- `Option` and checked errors/`Result`: explicit missing, stale, consumed, and failure states.
- `Array` and `Iter`: owned node storage and allocation-free parent iteration.

### Checked but not used

- Core `Queue`: FIFO cannot reproduce the current round/index order.
- Immutable priority queue/maps: persistence adds no value to the encapsulated mutable planner state.
- `dowdiness/incr`: reactive derivation does not model admission ownership, commit acknowledgement, or rejection lifecycle.
- Existing causal-graph topological sorting: useful precedent, but it schedules admitted LVs rather than pending `RawVersion` dependencies.

### New definitions and responsibility

- `RemoteAdmissionPlanner`: private canonical pending owner and deterministic transition facade.
- `RemoteAdmissionPlan`: opaque cross-package preflight/commit capability.
- Private preparation-overlay, node, ready-entry, and transition types: represent non-mutating preparation and exact lifecycle changes.
- New concrete `OpLogError` variants: stale plan, consumed plan, and `PartialRemoteAdmission(committed, causal_graph_cause)`. Reusing `OpLogError` preserves existing Document and Branch catch boundaries.

Before implementation, confirm concrete signatures with serialized `moon ide doc`, `outline`, `peek-def`, and `find-references` calls. In particular verify `PriorityQueue::push/pop`, `Map::get/set/remove`, `ArrayView`, OpLog callers, and Branch merge callers.

## Green commit sequence

Every commit must pass `moon check --deny-warn` and its targeted tests. No commit intentionally introduces failing tests.

### Commit 1 — Freeze the fixed-point oracle and immediate baselines

**Files**

- New `internal/oplog/remote_admission_oracle_wbtest.mbt`
- `internal/oplog/oplog_test.mbt`
- Existing benchmark files only if a missing baseline scenario must be added

**Work**

Copy the current fixed-point algorithm into a white-box test-only oracle without refactoring production. Add deterministic characterization for adversarial before/after-parent order, reverse chains, branching, joins, parents plus origins, graph-known dependencies, identical duplicates, unknown remaining operations, rejection closure, and retry.

Compare the test-only oracle with current `plan_remote` so the copied oracle cannot drift at creation. Generate deterministic scenario matrices rather than relying only on hand-picked cases.

Immediately record pre-cutover wasm-gc and JS planner baselines and the Document reverse-10,000 baseline using the existing commands and machine. Attach raw results to Issue #86.

**Validation**

- `moon test internal/oplog`
- `moon bench --release internal/oplog/oplog_benchmark.mbt`
- `moon bench --release --target js internal/oplog/oplog_benchmark.mbt`
- `moon bench --release internal/document/document_benchmark.mbt`
- `moon bench --release --target js internal/document/document_benchmark.mbt`

**Rollback**

Delete the new oracle file and revert only added characterization/baseline fixtures.

### Commit 2 — Add the isolated private planner and preparation overlay

**Files**

- New `internal/oplog/remote_admission_planner.mbt`
- New `internal/oplog/remote_admission_planner_wbtest.mbt`
- `internal/oplog/moon.pkg`

**Work**

Add the private planner without wiring it into OpLog. Use custom constructors (`Type::Type`) rather than `::new`. Add the preparation overlay, unique dependency normalization, persistent arrival ordinals, unresolved counts, reverse waiters, max-first priority scheduling, duplicate suppression, attempt-scoped rejection closure, and explicit admitted-status input.

Do not keep a second copy of every admitted graph identity. Dependencies already known to OpLog are supplied explicitly during preparation; successful commits later arrive as planner events.

Differentially compare prepared order and remaining pending membership with the test-only oracle. Include generated DAGs and origin edges. Assert that Map traversal order cannot affect output.

**Validation**

- `moon check --deny-warn`
- `moon test internal/oplog`

**Rollback**

Remove the two planner files and the priority-queue import; production remains untouched.

### Commit 3 — Complete planner lifecycle and bounded compaction

**Files**

- `internal/oplog/remote_admission_planner.mbt`
- `internal/oplog/remote_admission_planner_wbtest.mbt`

**Work**

Add deterministic canonical transitions for staged registration, successful admission acknowledgement, plan invalidation, transitive rejection, retry, and stale-entry skipping. Prove at the planner-transition level that stale/consumed transitions occur before mutation and that a successful admission prefix remains identifiable when a later transition is not acknowledged. Implement quiescent compaction as a rebuild from live membership and original arrival ordinals using explicit admitted status.

Use the measured policy `weighted stale >= max(1024, 2 * live pending)`. The 10,000-entry matched lifecycle showed about 2–3 ms additional JS cost and noise-level wasm-gc cost at the trigger point. Tests must pin the floor and ratio boundaries, compact with live unresolved operations, and preserve subsequent prepared order and pending membership.

**Validation**

- `moon test internal/oplog`
- Targeted release benchmark for compaction candidates on wasm-gc and JS

**Rollback**

Revert lifecycle/compaction additions; the isolated planner is still not used by production.

### Commit 4 — Cut OpLog pending ownership over atomically

**Files**

- `internal/oplog/oplog.mbt`
- `internal/oplog/errors.mbt`
- `internal/oplog/remote_admission_planner.mbt`
- `internal/oplog/oplog_test.mbt`
- `internal/oplog/oplog_properties_wbtest.mbt`
- `internal/oplog/pkg.generated.mbti`

**Work**

Replace `OpLog.pending` with one planner field in the same commit. Add opaque `pub struct RemoteAdmissionPlan` with private fields and constructor, a read-only `operations() -> ArrayView[@core.Op]`, `OpLog::prepare_remote`, and `OpLog::commit_remote`.

Keep existing public methods as wrappers:

- `plan_remote` prepares and returns a defensive owning copy for compatibility.
- `apply_remote` prepares and commits without Document semantic preflight, preserving its lower-level contract.
- `discard_pending_dependents` delegates to planner rejection.
- `has_pending` delegates to canonical membership.

Add concrete `OpLogError` variants for stale plans, consumed plans, and `PartialRemoteAdmission(committed, causal_graph_cause)`. Keep `commit_remote` on the existing `raise OpLogError` boundary. Factor the package-private commit loop around an explicit single-operation commit capability so white-box tests can inject a failure after a successful prefix; the production call supplies the existing graph/oplog commit operation.

Commit validates generation and single use. It applies overlay registration, then commits operations one at a time through the existing graph/oplog shell. Planner admission acknowledgement occurs only after each existing commit operation succeeds. Normal success returns the committed operations. A later failure raises `OpLogError::PartialRemoteAdmission` with the committed prefix and typed causal-graph cause, invalidates the plan, and leaves failed/later nodes pending. Stale and consumed variants carry no prefix because they fail before mutation.

**Validation**

- `moon fmt`
- `moon info`
- Review `internal/oplog/pkg.generated.mbti` for intended additions and no bound widening
- `moon check --deny-warn`
- `moon test internal/oplog`
- `git diff --check`

**Rollback**

Revert this commit as one unit; do not attempt a partial dual-owner rollback.

### Commit 5 — Prove public lifecycle equivalence

**Files**

- `internal/oplog/oplog_test.mbt`
- `internal/oplog/oplog_properties_wbtest.mbt`
- `internal/oplog/remote_admission_oracle_wbtest.mbt`

**Work**

Run the public prepare/commit and compatibility wrappers through differential scenarios against the test-only oracle. Cover complete order, remaining membership, graph-known dependencies, parents/origins deduplication, identical duplicate no-op, unknown pending operations, stale and consumed plans, pre-commit generation mismatch, rejection/retry, `PartialRemoteAdmission` payload accuracy after a fault-injected successful prefix, stale queue entries, and compaction.

Production must not call the oracle.

**Validation**

- `moon test internal/oplog`
- `moon check --deny-warn`

**Rollback**

Revert tests only; Commit 4 remains independently green on its focused tests.

### Commit 6 — Migrate Document single-operation ingress

**Files**

- `internal/document/document.mbt`
- `internal/document/document_test.mbt`
- Relevant white-box ingress tests
- `internal/document/errors.mbt` only if generated signatures require documentation changes; reuse `DocumentError::OpLog` rather than adding a parallel wrapper

**Work**

Change target preflight to accept `ArrayView[@core.Op]`. Refactor `Document::apply_remote` to validate content, prepare once, preflight the complete plan view, and commit that same plan. On normal success, project each returned operation exactly once. On `OpLogError::PartialRemoteAdmission`, project the error's committed prefix exactly once and then re-raise the same OpLog error through `DocumentError::OpLog`; rethrow unknown errors.

A preflight failure registers no incoming operation. Existing pending invalid roots and transitive dependents are rejected through the compatibility wrapper before the error propagates.

Factor a private typed-error adapter using `try ... catch ... noraise`: it converts only `PartialRemoteAdmission` into a local committed-prefix-plus-deferred-error value, rethrows unknown errors, and lets the caller project before re-raising. Fault-injected Document tests must prove prefix projection occurs exactly once before the typed error escapes.

**Validation**

- `moon test internal/document`
- `moon test internal/oplog`
- `moon check --deny-warn`

**Rollback**

Revert Document files; OpLog compatibility wrappers keep the previous path valid.

### Commit 7 — Migrate Document merge while preserving Branch semantics

**Files**

- `internal/document/document.mbt`
- `internal/document/document_test.mbt`
- `internal/branch/branch.mbt`
- `internal/branch/branch_merge.mbt`
- `internal/branch/branch_merge_test.mbt`

**Work**

For `Document::merge_remote`, validate the batch, prepare once, and complete-preflight the plan view. Capture `Branch::from_tree_and_oplog` before commit so it retains the pre-commit frontier. Invalidate the Document cache before admission and commit the same plan. On success or `OpLogError::PartialRemoteAdmission`, advance the captured Branch to the current OpLog frontier exactly once; after a partial outcome, re-raise the same OpLog failure through the existing wrapper only after that advance. Do not call the raw-operation merge helper after commit, and rethrow unknown errors.

Keep `Branch::merge_remote_ops` and package-level `merge_remote_ops` signatures, but migrate their internals to prepare/commit directly. Capture the Branch frontier before commit. On success or `PartialRemoteAdmission`, advance to the current OpLog frontier exactly once; after a partial outcome, re-raise through `BranchError::OpLog`. Unknown errors are rethrown. This avoids losing an admitted prefix behind the compatibility wrapper.

Add fault-injected Document and Branch tests for a successful prefix followed by commit failure. Assert tree/frontier projection of the prefix, failed/later pending membership, one projection only, and the final typed error.

**Validation**

- `moon test internal/document`
- `moon test internal/branch`
- `moon test internal/oplog`
- `moon check --deny-warn`

**Rollback**

Revert Document/Branch integration together; Commit 6 remains a smaller validated path.

### Commit 8 — Install final benchmark gates and cutover evidence

**Files**

- `internal/oplog/oplog_benchmark.mbt`
- `internal/document/document_benchmark.mbt`
- Benchmark-only fixed-point oracle code in the OpLog benchmark file
- ADR or Issue #86 evidence comment if the selected compaction threshold must be recorded

**Work**

In one process, compare the benchmark-only fixed-point oracle and production planner on identical generated inputs. Benchmark reverse 100/1,000/10,000, four reverse chains of 250, small ready batches, in-order batches, duplicate-heavy batches, and compaction thresholds. Equality guards run outside timed closures.

Run Document reverse-10,000 after cutover and compare it with Commit 1's same-machine, same-command baseline; do not add a legacy Document/OpLog adapter.

Required gates:

- planner reverse-10,000: at least 50x faster on wasm-gc and JS
- planner branches 4x250: at least 10x faster on wasm-gc and JS
- small/in-order median regression: no more than 20%
- Document reverse-10,000: at least 5x faster than the immediate pre-cutover baseline

Benchmark results are evidence gates, not timing assertions in normal tests or compilation.

**Validation**

- `moon bench --release internal/oplog/oplog_benchmark.mbt`
- `moon bench --release --target js internal/oplog/oplog_benchmark.mbt`
- `moon bench --release internal/document/document_benchmark.mbt`
- `moon bench --release --target js internal/document/document_benchmark.mbt`
- Full `moon test`

**Rollback**

If any gate fails, stop. Keep the fixed-point oracle and revert the production cutover commits rather than weakening the accepted gate without a new decision.

### Commit 9 — Remove the isolated prototype and finalize documentation

**Files**

- Delete `internal/oplog/prototype_issue_86/`
- `docs/adr/0004-canonical-pending-remote-owner.md` only for measured threshold/consequence updates
- Issue #86 and plan status

**Work**

Delete the isolated prototype only after all its semantic assertions and benchmark scenarios exist in production tests or benchmark-only oracle fixtures. Preserve prototype evidence in git history and Issue #86. Keep the fixed-point implementation only in white-box tests and benchmarks while it remains useful as an oracle; no production source may reference it.

Update this plan to completed/archive state following repository convention and record final raw benchmark output on Issue #86.

**Validation**

- `moon fmt`
- `moon info`
- Inspect every changed `.mbti`; no unintended public API removal or trait-bound widening
- `moon check --deny-warn`
- Full `moon test`
- wasm-gc and JS benchmark gates
- `git diff --check`
- `git diff --stat` confirms only intended files

**Rollback**

Restore the prototype directory from its dedicated commit if evidence migration is incomplete.

## Required scenario matrix

The deterministic and generated differential suites must include:

- reverse linear chains at several sizes
- multiple independent reverse chains
- joins with more than one parent
- dependencies repeated across parents and origins
- origin-only dependencies
- graph-known dependencies
- unknown dependencies that remain pending
- identical duplicates while pending and after admission
- invalid root plus transitive dependents
- retry of a rejected identity
- ready nodes before and after the dependency's arrival index
- stale and consumed plans
- generation mismatch
- successful admission prefix followed by internal failure
- stale queue entries
- compaction while unrelated live pending operations remain

Operation identity conflicts are not generated as valid duplicate cases; they remain out of scope.

## Production cutover checklist

- [x] Exact fixed-point oracle exists only in white-box tests and benchmarks.
- [x] No production call path shadow-runs the oracle.
- [x] Remote Admission Planner is the only owner of pending membership.
- [x] Planner code imports no CausalGraph, Document, Fugue, filesystem, clock, or network capability.
- [x] Preparation does not clone canonical pending membership; ADR 0004 records the general path's disposable ready-queue copy.
- [x] `RemoteAdmissionPlan` is opaque, single-use, generation-checked, and exposes only `ArrayView`.
- [x] Complete Document preflight occurs before registration or admission.
- [x] Planner resolution follows successful OpLog commit, never readiness alone.
- [x] `OpLogError::PartialRemoteAdmission` carries the exact committed prefix and typed causal-graph cause.
- [x] Document applies or advances that prefix before re-raising; unknown errors are rethrown.
- [x] Document merge captures the pre-commit Branch/frontier and projects once.
- [x] Existing public OpLog and Branch convenience methods remain compatible.
- [x] Rejection is attempt-scoped; no permanent identity tombstone exists.
- [x] Compaction bounds stale retention relative to live pending state.
- [x] All `.mbti` changes are intentional.
- [x] Full tests pass and all performance gates hold on wasm-gc and JS as specified.
- [x] Prototype evidence was migrated before prototype deletion.
