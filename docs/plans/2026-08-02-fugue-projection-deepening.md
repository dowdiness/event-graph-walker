# Deepen Fugue projection

**Date:** 2026-08-02

**Status:** ready

**Canonical term:** [Shared document projection](../../CONTEXT.md#shared-document)

## Why

Three implementations translate admitted text CRDT operations into Fugue mutations:

- `internal/branch/branch.mbt:55-115,282-354` resolves origins and applies operations during checkout and forward advance.
- `internal/branch/branch_merge.mbt:23-120` repeats the translation while applying an RLE advance set.
- `internal/document/document.mbt:620-764` repeats it again while maintaining the indexed visible state.

Origin resolution, causal metadata lookup, LWW delete/undelete behavior, and error classification can therefore drift across callers. Tests also exercise the same Shared document projection semantics through several package interfaces.

Create one deep in-process module whose interface applies one admitted operation to Fugue. Branch remains a tree-only adapter. Document optionally receives the resulting visibility change and retains ownership of position lookup and incremental index maintenance.

## Scope

### In

- New package `internal/fugue_projection`.
- One deterministic resolution core and one imperative Fugue-mutation shell inside that package.
- Two per-operation entry points:
  - `apply` mutates Fugue and returns `Unit`.
  - `apply_with_visible_change` performs the same mutation and returns `VisibilityChange`.
- `pub(all) VisibilityChange::{BecameVisible, BecameHidden, Unchanged}`.
- `pub(all) FugueProjectionError` owned by the new package.
- Branch, merge-context, and Document adapters.
- Test ownership migration and matched release-mode performance evidence.

### Out

- Remote operation admission, `RemoteAdmissionPlan`, OpLog pending ownership, or sync preflight.
- Branch retreat behavior and delete-winner recomputation.
- Fugue representation or method changes.
- IndexedState or `VisibleRun` representation changes.
- Batch projection interfaces, callbacks, observer traits, mode parameters, or collection results.
- New `BranchError` or `DocumentError` variants.
- Top-level `text`, `container`, peer-sync, JSON, canonical-byte, or wire-format changes.
- A new ADR or GitHub issue. This is a reversible internal refactor; `CONTEXT.md` already records the domain term.

## Current State

- `apply_operation_to_tree` has three references: its definition plus Branch checkout and forward advance (`internal/branch/branch.mbt:55-115,282-354`; confirmed with `moon ide find-references`).
- `MergeContext::apply_operations` owns a second per-operation translation inside its RLE traversal (`internal/branch/branch_merge.mbt:23-120`). Its public interface and RLE traversal must remain stable.
- `Document::project_remote_ops` has two callers for complete and partial remote admission (`internal/document/document.mbt:620-805`). It currently chooses incremental index maintenance only when the admitted prefix has at most three operations and IndexedState is warm.
- Large Document merges invalidate IndexedState and advance a retained Branch (`internal/document/document.mbt:821-859`).
- `BranchError` already represents missing origins, missing operations, OpLog failures, and Fugue failures (`internal/branch/errors.mbt`).
- `DocumentError` already represents missing origins, missing local versions through OpLog, Fugue failures, and Branch failures (`internal/document/errors.mbt`).
- ADR 0003 requires admitted operations and successful projection prefixes not to be rolled back after an internal projection failure (`docs/adr/0003-consistency-boundaries.md`). ADR 0004 requires a partial admitted prefix to be projected exactly once (`docs/adr/0004-canonical-pending-remote-owner.md`).

## Desired State

`internal/fugue_projection` imports only `internal/core`, `internal/causal_graph`, and `internal/fugue`. It does not import OpLog, Branch, Document, sync, or IndexedState.

Its exported interface is intentionally small:

```moonbit
pub fn apply(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> Unit raise FugueProjectionError

pub fn apply_with_visible_change(
  tree : @fugue.FugueTree[String],
  op : @core.Op,
  causal_graph : @causal_graph.CausalGraph,
) -> VisibilityChange raise FugueProjectionError
```

Both the enum and error are `pub(all)` so Document can pattern-match changes and both adapters can translate errors across package seams.

`VisibilityChange` describes the semantic visibility outcome, not the input CRDT operation, a sequence coordinate, or an IndexedState command:

- `BecameVisible(lv, text)`: one item entered the visible sequence.
- `BecameHidden(lv)`: one item left the visible sequence.
- `Unchanged`: Fugue processed the operation but the visible sequence did not change.

Insert and a winning Undelete produce `BecameVisible`; a winning Delete of a visible target produces `BecameHidden`; LWW losses, already-satisfied visibility, and targetless Delete/Undelete produce `Unchanged`. Document derives coordinates through its existing adapters: post-mutation Fugue lookup for `BecameVisible`, and the still-unmodified IndexedState for `BecameHidden`.

`FugueProjectionError` owns:

- `MissingOrigin(raw)`;
- `MissingCausalEntry(lv)`;
- `Fugue(error)`.

Branch and Document translate these faithfully into existing missing-origin, missing-operation/local-version, and Fugue variants. Admission and any successful projection prefix remain committed.

## Error Translation

Adapters must use this exact mapping; do not stringify, collapse, or reclassify an internal invariant failure:

| `FugueProjectionError` | Branch adapter | Document adapter |
| --- | --- | --- |
| `MissingOrigin(raw)` | `BranchError::MissingOrigin(raw)` | `DocumentError::MissingOrigin(raw)` |
| `MissingCausalEntry(lv)` | `BranchError::MissingOp(lv)` | `DocumentError::OpLog(OpLogError::MissingLocalVersion(lv))` |
| `Fugue(error)` | `BranchError::Fugue(error)` | `DocumentError::Fugue(error)` |

No adapter adds a fallback arm that hides a future projection-error variant. An intentional new variant requires updating this table and every exhaustive translator.

## Behavioral Boundary Matrix

| Operation and state | Entry point | Expected result | Mutation/error timing |
| --- | --- | --- | --- |
| Insert with resolvable origins and causal entry | either | tree gains visible item; observed path returns `BecameVisible(op.lv, text)` | origins and causal entry resolve before mutation |
| Delete targets visible item and wins LWW | observed | `BecameHidden(target_lv)` | target and causal entry checked before mutation |
| Delete targets invisible item and wins LWW metadata | observed | `Unchanged` | Fugue metadata may change; visibility does not |
| Delete loses LWW | observed | `Unchanged` | visibility unchanged |
| Undelete targets invisible item and wins LWW | observed | `BecameVisible(target_lv, target_text)` | target and causal entry checked before mutation |
| Undelete targets visible item or loses LWW | observed | `Unchanged` | visibility unchanged |
| Delete/Undelete has no `origin_left` | either | no-op; observed path returns `Unchanged` | preserve current behavior; no causal metadata lookup required |
| Required insert origin cannot resolve | either | `MissingOrigin(raw)` | before tree mutation |
| Insert or targeted Delete/Undelete LV lacks causal entry | either | `MissingCausalEntry(lv)` | before tree mutation |
| Fugue target is absent | either | `Fugue(MissingItem)` | Fugue validates before mutation |
| later operation in a caller-owned loop fails | either | earlier operations remain projected exactly once | no batch rollback and no lost successful prefix |

## Existing API First

### Reuse

| Candidate | Location | Decision |
| --- | --- | --- |
| `FugueTree::insert` | `internal/fugue/tree.mbt:167-178` | Reuse for Insert projection. |
| `FugueTree::delete_with_ts` / `undelete_with_ts` | `internal/fugue/tree.mbt:211-269` | Reuse; their LWW implementation remains authoritative. |
| `FugueTree::visible_count` | `internal/fugue/tree.mbt:126-131` | Reuse only in the observed path to classify visible transitions. |
| `FugueTree` index lookup | `internal/fugue/tree.mbt:93-103` | Reuse in the observed path to obtain revived text; do not use tree traversal for delete coordinates. |
| `FugueTree::lv_to_position` / `IndexedState::lv_to_position` | `internal/fugue/tree.mbt:387-410`; `internal/document/indexed_state.mbt:170-183` | Keep in the Document adapter for current post-insert/pre-delete coordinate behavior; neither enters the new package interface. |
| `CausalGraph::raw_to_lv` / graph index lookup | `internal/causal_graph/graph.mbt` | Reuse for origin and timestamp/agent resolution. |
| `Op` accessors | `internal/core/operation.mbt` | Reuse; do not add operation conversion or equality. |
| `Option` | MoonBit core `option` | Reuse for existing lookups inside deterministic resolution. Do not expose optional change semantics. |
| typed `raise` | existing project error style | Reuse instead of a public `Result`. |

### Checked but not used

- `Result`: typed `raise FugueProjectionError` matches neighboring package interfaces and avoids dual failure channels.
- `ArrayView`, `Array`, and `Iter`: the selected interface is deliberately per-operation so later failure cannot hide earlier successful changes and existing Array/RLE loops remain allocation-free.
- `Map` and `Set`: projection performs no independent membership indexing.
- `StringView`, `Bytes`, `BytesView`, `Buffer`, and `StringBuilder`: projection neither slices nor rebuilds text.
- A projection trait or adapter port: both dependencies are in-process and there is one concrete Fugue implementation; a new port would be hypothetical.

### New-definition responsibility

- `VisibilityChange` describes only the semantic visibility outcome required across the projection seam.
- `FugueProjectionError` classifies failures detected by the owning module.
- A private resolved-operation representation may separate deterministic origin/metadata resolution from mutation. It must not escape the package or duplicate `Op` storage.
- Each outer package may add one private error translator. No new low-level loops are needed.

## Performance Evidence Gate

The structural constraint is necessary but not proof of non-regression:

- `apply` must perform no position lookup, visibility-change construction, callback, or collection allocation.
- `apply_with_visible_change` must not call `FugueTree::lv_to_position`; it returns identity/content only.
- Document retains its current coordinate mechanisms: Fugue lookup after an item becomes visible and IndexedState lookup while its pre-hide view is still intact.
- `apply_with_visible_change` is used only under Document's existing small-prefix/warm-index condition.
- RLE and ArrayView iteration remain in their current callers.

Before production edits, record two independent baseline sets of five release-mode process runs on the same machine and toolchain for both JS and wasm-gc. Record the environment before timing:

| Evidence | Required value |
| --- | --- |
| Baseline and candidate commit | full Git SHA |
| MoonBit toolchain | `moon version --all` output |
| Dependencies | hash of `.mooncakes/.moon-lock` |
| Host | OS/kernel, CPU model, core count, available memory |
| Frequency policy | CPU governor/power mode, or `unavailable` |
| Run conditions | date/time, background workload policy, warm-up policy |
| Command | exact command and target |

Correctness/equality checks run outside timed closures. Benchmark setup must not mutate a shared fixture across samples unless a bounded pool is reset to an equivalent state.

```bash
moon bench --release --target js --package internal/branch
moon bench --release --target wasm-gc --package internal/branch
moon bench --release --target js --package internal/document
moon bench --release --target wasm-gc --package internal/document
```

Before the refactor, add benchmark-only Document cases that exercise warm-index Insert, Delete, and Undelete projection at 1k and 10k items, plus a practical 100k characterization with setup outside the timed closure. Record those alongside Branch checkout, advance, repeated advance, MergeContext apply-50, existing Document small remote apply, and Document large merge scenarios. For each target/scenario:

1. `baseline` is the median of the ten baseline process results.
2. `repeat_spread` is the absolute percentage difference between the two five-run baseline medians.
3. `tolerance = max(5%, repeat_spread)`.
4. Run one five-process candidate set. If its median exceeds `baseline * (1 + tolerance)`, rerun once.
5. Two failing candidate sets reject the package seam or per-operation loop placement; do not merge.

Freeze this selector map before the first baseline. The benchmark-only observed cases are appended in the listed order after the current eleven Document benchmarks; if any index changes, update the map and rerun every baseline and candidate set.

| Key | Package/file/index | Exact benchmark name |
| --- | --- | --- |
| B1 | `internal/branch` / `branch_benchmark.mbt` / `2` | `branch - checkout (1000 ops)` |
| B2 | `internal/branch` / `branch_benchmark.mbt` / `12` | `branch - single advance (50 new ops)` |
| B3 | `internal/branch` / `branch_benchmark.mbt` / `7` | `branch - repeated advance steady-state (10 iterations)` |
| B4 | `internal/branch` / `branch_benchmark.mbt` / `8` | `branch - repeated advance with oplog mutations (10 iterations)` |
| B5 | `internal/branch` / `branch_merge_benchmark.mbt` / `8` | `merge - context apply operations (50 ops)` |
| D1 | `internal/document` / `document_benchmark.mbt` / `11` | `bench: observed Insert (1000-char warm index)` |
| D2 | `internal/document` / `document_benchmark.mbt` / `12` | `bench: observed Insert (10000-char warm index)` |
| D3 | `internal/document` / `document_benchmark.mbt` / `13` | `bench: observed Insert (100000-char warm index)` |
| D4 | `internal/document` / `document_benchmark.mbt` / `14` | `bench: observed Delete (1000-char warm index)` |
| D5 | `internal/document` / `document_benchmark.mbt` / `15` | `bench: observed Delete (10000-char warm index)` |
| D6 | `internal/document` / `document_benchmark.mbt` / `16` | `bench: observed Delete (100000-char warm index)` |
| D7 | `internal/document` / `document_benchmark.mbt` / `17` | `bench: observed Undelete (1000-char warm index)` |
| D8 | `internal/document` / `document_benchmark.mbt` / `18` | `bench: observed Undelete (10000-char warm index)` |
| D9 | `internal/document` / `document_benchmark.mbt` / `19` | `bench: observed Undelete (100000-char warm index)` |
| D10 | `internal/document` / `document_benchmark.mbt` / `7` | `bench: 10 remote inserts + queries (1000-char doc)` |
| D11 | `internal/document` / `document_benchmark.mbt` / `8` | `bench: 10 remote inserts + queries (5000-char doc)` |
| D12 | `internal/document` / `document_benchmark.mbt` / `3` | `bench: merge reverse dependency chain (10000 ops)` |

Run one scenario with the exact selector, substituting target, package, file, and index from the map:

```bash
moon bench --release --target <js|wasm-gc> \
  --package <package> --file <file> --index <index>
```

D1-D9 use five explicit `monotonic_clock_start`/`monotonic_clock_end` samples per process rather than `Bench::bench`: the core bench runner calibrates by invoking a closure repeatedly, which cannot preserve an equivalent one-shot mutable fixture. Each sample constructs, replays, and primes a fresh Document before starting the clock, times exactly one `apply_remote`, then checks correctness after stopping the clock.

Record all five raw process values plus the median in each result cell. Do not aggregate operation kinds or scales into one verdict:

| Target | Scenario key | Baseline A | Baseline B | Spread | Tolerance | Candidate A | Candidate B if needed | Result |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| JS | B1 | | | | | | | |
| JS | B2 | | | | | | | |
| JS | B3 | | | | | | | |
| JS | B4 | | | | | | | |
| JS | B5 | | | | | | | |
| JS | D1 | | | | | | | |
| JS | D2 | | | | | | | |
| JS | D3 | | | | | | | |
| JS | D4 | | | | | | | |
| JS | D5 | | | | | | | |
| JS | D6 | | | | | | | |
| JS | D7 | | | | | | | |
| JS | D8 | | | | | | | |
| JS | D9 | | | | | | | |
| JS | D10 | | | | | | | |
| JS | D11 | | | | | | | |
| JS | D12 | | | | | | | |
| wasm-gc | B1 | | | | | | | |
| wasm-gc | B2 | | | | | | | |
| wasm-gc | B3 | | | | | | | |
| wasm-gc | B4 | | | | | | | |
| wasm-gc | B5 | | | | | | | |
| wasm-gc | D1 | | | | | | | |
| wasm-gc | D2 | | | | | | | |
| wasm-gc | D3 | | | | | | | |
| wasm-gc | D4 | | | | | | | |
| wasm-gc | D5 | | | | | | | |
| wasm-gc | D6 | | | | | | | |
| wasm-gc | D7 | | | | | | | |
| wasm-gc | D8 | | | | | | | |
| wasm-gc | D9 | | | | | | | |
| wasm-gc | D10 | | | | | | | |
| wasm-gc | D11 | | | | | | | |
| wasm-gc | D12 | | | | | | | |

## Steps and Tiny Commits

1. **Prepare the exact base.** Fetch `origin/main`, create a dedicated Event Graph Walker worktree whose HEAD contains it, initialize dependencies, and verify the recorded Canopy submodule identity if the worktree is attached to a parent checkout.
2. **Pin the baseline.** Add only the matched warm-index benchmark cases, run the two five-run baseline sets, and fill the baseline columns above before production behavior edits.
3. **Write the first failing test.** Create the package manifest and the behavioral test matrix in `internal/fugue_projection`; begin with Insert returning `BecameVisible(op.lv, text)`. Confirm red for the missing interface.
4. **Commit 1 — `feat(projection): add deep Fugue projection module`.** Implement the deterministic resolution core, imperative mutation shell, two entry points, enum, typed error, and focused tests. Add matrix rows incrementally through red-green-refactor. Validate only the new package.
5. **Commit 2 — `refactor(branch): use Fugue projection module`.** Add the package import; route checkout, forward advance, and MergeContext's existing RLE loop through tree-only `apply`; translate errors into existing BranchError variants. Preserve public `MergeContext::apply_operations` and retreat behavior.
6. **Commit 3 — `refactor(document): consume visibility changes`.** Add the package import; preserve the current incremental guard; use the observed entry only while incremental maintenance is active and tree-only `apply` otherwise. For `BecameVisible`, retain the current post-mutation Fugue position lookup. For `BecameHidden`, resolve the old position from the still-unmodified IndexedState before deleting its run. Apply each change immediately; on lookup or index-update failure, retain current invalidate-and-fallback behavior.
7. **Commit 4 — `test(projection): enforce semantic ownership`.** Reconcile every test against the inventory below. Keep adapter and integration assertions; do not copy them into the new package. Remove a test only when every assertion belongs to projection semantics and an equivalent matrix test is already green. Record any deletion by test name in the commit message.
8. **Run independent review.** After the targeted loop is green, dispatch `moonbit-reviewer` for package direction, error fidelity, LWW/coordinate semantics, test ownership, mutation timing, `.mbti` risk, and benchmark validity. Resolve every high-confidence finding.
9. **Run candidate evidence.** Execute five candidate runs per target/package, rerun one failing set once, fill the table, and reject or revise the seam if the gate fails.
10. **Synchronize and finalize.** Fetch `origin/main` again; if HEAD no longer contains it, sync and repeat affected tests, review, and performance evidence. Run format/info, inspect interfaces, commit the clean candidate, and execute the final gate.

## Test Migration Inventory

The current suite has no confirmed whole test that should be deleted merely because the new package exists. Use this inventory before changing test ownership:

| Existing test | Owner after refactor | Action |
| --- | --- | --- |
| `internal/branch/branch_test.mbt`: `checkout with single insert`, `checkout with multiple inserts`, `checkout with delete`, `advance branch with new operations`, `branch with complex operations` | Branch interface and frontier behavior | Retain unchanged except adapter-error expectations if needed. |
| `internal/branch/branch_merge_test.mbt`: `merge error - missing op during apply`, `merge error - state unchanged after failure` | MergeContext RLE traversal and missing-OpLog-entry behavior | Retain. These do not belong to Fugue projection. |
| `internal/branch/branch_merge_test.mbt`: `merge error - apply operations succeeds for valid ops` | MergeContext adapter smoke test | Retain one final-text assertion; do not expand it with projection variant assertions. |
| `internal/branch/branch_merge_test.mbt`: `merge_remote_ops - basic concurrent inserts`, `merge_remote_ops - insert and delete`, `merge - simple merge using graph_diff` | Branch merge interface | Retain. |
| `internal/branch/branch_merge_test.mbt`: `retreat then apply with missing item`, `merge - concurrent delete retreat convergence`, `merge - frontier retreat exercises two-count path`, `merge - retreat insert hides items correctly` | Branch retreat and convergence | Retain; retreat is explicitly out of scope. |
| `internal/document/document_test.mbt`: `cache coherent after apply_remote insert: visible count and text correct`, `cache coherent after apply_remote delete: deleted item gone from positions` | Document projection adapter and cache | Retain. |
| `internal/document/indexed_state_wbtest.mbt`: `IndexedState agrees with Fugue after remote apply` | Differential cache adapter | Retain as the primary Insert/Delete/Undelete adapter test. |
| `internal/document/document_wbtest.mbt`: `apply_remote_with projects a partial committed prefix exactly once`, `apply_remote_with rethrows stale admission without projection`, `merge_remote_with advances a partial prefix exactly once` | Admission/projection shell integration | Retain. |
| New boundary-matrix tests | `internal/fugue_projection` | Add direct semantic coverage without IndexedState, Branch frontier, RLE, or OpLog admission assertions. |

Before deleting anything, produce a diff-local checklist of every touched test name and label it `projection`, `adapter`, or `integration`. If no existing test is projection-only, delete none; replace-don't-layer forbids duplicate new assertions, not valuable integration coverage.

## Test Ownership

`internal/fugue_projection` owns:

- origin and causal-entry resolution;
- Insert/Delete/Undelete tree effects;
- LWW-visible classification;
- visibility transition identity and revived content;
- targetless no-ops;
- every `FugueProjectionError` variant;
- parity between `apply` and `apply_with_visible_change` final Fugue state.

`internal/branch` retains:

- checkout and advance frontier behavior;
- RLE traversal and missing-OpLog-entry handling;
- retreat and delete-winner recomputation;
- BranchError translation integration.

`internal/document` retains:

- incremental guard, coordinate lookup, and IndexedState updates;
- cache invalidation/fallback;
- complete and partial admission prefix projection;
- DocumentError translation and Unicode ingress behavior.

## Acceptance Criteria

- [ ] One package owns all per-operation Op→Fugue translation semantics.
- [ ] Branch and MergeContext contain no second origin/timestamp/content dispatch for forward projection.
- [ ] Document contains no second CRDT-operation interpretation; it only selects an entry point, derives adapter-owned coordinates, and adapts `VisibilityChange` to IndexedState.
- [ ] `apply` performs no visible-position lookup or change allocation.
- [ ] `apply_with_visible_change` returns identity/content visibility outcomes without tree-position traversal and applies the same Fugue mutation as `apply`.
- [ ] Every projection error occurs before Fugue mutation and leaves Fugue unchanged.
- [ ] Later failure never rolls back admission or an earlier successful projection prefix.
- [ ] Every `FugueProjectionError` follows the exact translation table; BranchError and DocumentError gain no variants, and top-level interfaces and wire bytes do not change.
- [ ] Dependency direction remains acyclic.
- [ ] Every touched existing test appears in the migration checklist; adapter/integration tests remain, and a projection-only test is removed only after equivalent new-package coverage passes.
- [ ] The performance table is complete and every required scenario passes the evidence gate.
- [ ] Generated interface diffs contain only the intentional new `internal/fugue_projection/pkg.generated.mbti`; no unrelated trait-bound drift appears.

## Validation

Run serially from the Event Graph Walker module root unless noted:

```bash
NEW_MOON_MOD=0 moon ide outline internal/fugue_projection
NEW_MOON_MOD=0 moon ide find-references apply_operation_to_tree
NEW_MOON_MOD=0 moon ide find-references 'Document::project_remote_ops'
NEW_MOON_MOD=0 moon ide find-references 'MergeContext::apply_operations'
NEW_MOON_MOD=0 moon test internal/fugue_projection
NEW_MOON_MOD=0 moon test internal/branch
NEW_MOON_MOD=0 moon test internal/document
just verify
NEW_MOON_MOD=0 moon fmt
NEW_MOON_MOD=0 moon info --frozen
git diff -- '*.mbti'
git diff --check
```

Run the performance commands and evidence procedure above. Then run `moonbit-reviewer` independently.

For an Event Graph Walker PR, require the clean-HEAD root checks, tests, interface inspection, and repository CI. If this work also updates Canopy's submodule pointer, first commit and push the Event Graph Walker change, then from the updated parent worktree run:

```bash
./scripts/validate-pr-ready.sh \
  --target event-graph-walker/internal/fugue_projection \
  --target event-graph-walker/internal/branch \
  --target event-graph-walker/internal/document
./scripts/validate-pr-ready.sh --verify-evidence
```

A rebase, amend, generated-interface change, package-manifest change, submodule-pointer change, or base movement invalidates the final evidence.

## Risks

- A cross-package call in a per-operation hot loop may not inline. The performance gate, not structural reasoning, decides whether the seam is acceptable.
- The observed adapter must derive `BecameHidden` position from IndexedState before mutating that index; a Fugue traversal would change the current hot-path cost.
- Test deletion can hide behavior if ownership is not mapped row-by-row before removal.
- The new package must not acquire OpLog merely to simplify callers; that would leak admission through the seam.

## Open Questions

None. Interface, package ownership, error ownership, visible-change semantics, per-operation processing, test ownership, and performance acceptance were resolved before this plan.
