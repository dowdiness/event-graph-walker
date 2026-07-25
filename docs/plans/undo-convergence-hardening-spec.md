# Undo/Redo Convergence Hardening Specification

## Problem Statement

A local collaborative text edit has three distinct contracts: Recoverable Edit Atomicity, Document Convergence, and Local History Best-Effort. The local text-edit path now validates recoverable failures before emitting CRDT operations, but the compensating-edit path used by Undo/Redo still exposes document representation details through its Undoable Interface.

Two failure modes remain. First, an unknown target LV can be validated too late, after the Document has advanced its causal graph but before it has a corresponding operation. That can poison subsequent synchronization. Second, Undo/Redo does not symmetrically detect Stale Undo Targets before creating an undelete operation, so a user-visible no-op can emit a new CRDT operation and alter later conflict resolution.

## Solution

Deepen the Undoable Interface so that the Document Module owns target-state classification and the OpLog/FugueTree preflight-and-commit seam, while the TextState Adapter exposes that result through the Undoable Interface. UndoManager should request compensating edits and receive only an applied-versus-stale result; it must not inspect visible positions or Fugue representation details.

The Document Module must validate the target and all causal references before allocating a new local CRDT version. A Stale Undo Target produces no CRDT operation and returns a named `Stale` result. A structurally missing target or any other invariant violation is an Internal failure. Internal failures have two explicit phases: a preflight failure leaves the Document unchanged, while a post-commit failure does not roll back already-applied valid CRDT operations. In both cases the error propagates and all local edit history is invalidated rather than attempting a Document rollback.

## User Stories

1. As a user, I want an invalid local edit to leave the shared document unchanged, so that input mistakes never create synchronization traffic.
2. As a user, I want malformed local text to be reported as an edit error, so that I can distinguish it from a peer synchronization failure.
3. As a user, I want a successful local edit to appear as one user-visible change, even when it emits multiple CRDT operations, so that Undo treats the edit coherently.
4. As a user, I want to undo my insert, so that the inserted content is removed through a compensating CRDT operation.
5. As a user, I want to undo my delete, so that deleted content is restored through a compensating CRDT operation.
6. As a user, I want to redo an undone insert or delete, so that Undo/Redo behaves symmetrically.
7. As a user, I want Undo to do nothing when an inserted target is already absent, so that a stale undo does not create a new operation.
8. As a user, I want Undo of a delete to do nothing when the target is already visible, so that an unnecessary undelete does not become a later conflict winner.
9. As a user, I want Redo of an insert to do nothing when the target is already visible, so that Redo does not emit a duplicate undelete.
10. As a user, I want Redo of a delete to do nothing when the target is already absent, so that Redo does not emit a duplicate delete.
11. As a user, I want a stale Undo/Redo to return a no-op result, so that the UI does not broadcast, adjust the cursor, or mark the document dirty unnecessarily.
12. As a user, I want a stale Undo/Redo group to be consumed locally, so that the local history does not repeatedly attempt an action that can no longer apply.
13. As a user, I want a valid compensating edit to synchronize to peers, so that all peers eventually converge on the same shared document state.
14. As a user, I want a peer that has already performed a conflicting operation to converge after later synchronization, so that local Undo/Redo does not create permanent divergence.
15. As a user, I want an unknown undo target to fail as an internal error rather than as a stale no-op, so that an implementation or state inconsistency is not hidden.
16. As a user, I want a preflight internal failure to leave the shared document unchanged, so that a rejected target cannot poison later synchronization.
17. As a user, I want a post-commit internal Undo/Redo failure to stop further use of all local history, so that stale history cannot issue additional operations.
18. As a user, I want already-applied valid CRDT operations from a post-commit internal failure to remain synchronizable, so that peers can still converge on the valid operation prefix.
19. As a developer, I want a compensating-edit Interface that hides visibility and Fugue details, so that UndoManager does not duplicate Document policy.
20. As a developer, I want target preflight and CRDT commit ordering to live in the Document Module, so that OpLog and FugueTree consistency is maintained in one place.
21. As a developer, I want tests to assert external Document and synchronization behavior, so that the implementation can change without rewriting tests for internal fields.
22. As an operator, I want internal failures to be observable as errors while all local history is disabled, so that a broken history cannot silently corrupt later edits.
23. As a performance-sensitive user, I want the normal local edit and Undo paths to avoid Document copies and rollback snapshots, so that JS and wasm-gc latency remains predictable.

## Implementation Decisions

- The highest external seam is the Undoable Interface between UndoManager and the TextState Adapter. UndoManager will express compensating-edit intent through this Interface and will not inspect visible positions, tombstones, local versions, or Fugue errors.
- The `undo` Module owns `CompensatingEditResult` because it defines the Undoable Interface. The Document Module may use an internal equivalent while enforcing its own OpLog/FugueTree invariants; the TextState Adapter maps that result to the Undoable Interface without exposing Document types to UndoManager.
- The compensating-edit Interface will return a named `CompensatingEditResult` with `Applied` and `Stale` outcomes for delete and undelete requests. `Applied` means that a new compensating CRDT operation was committed; `Stale` means that no operation was needed and no operation was emitted. Internal failures remain raised errors.
- Target-state classification is symmetric:

  | Request | Target state | Result |
  | --- | --- | --- |
  | delete | visible | `Applied` |
  | delete | deleted | `Stale` |
  | delete | structurally missing | `Internal` |
  | undelete | deleted | `Applied` |
  | undelete | visible | `Stale` |
  | undelete | structurally missing | `Internal` |

- `ItemNotFound` will not be the canonical stale result after migration. During the Interface migration it remains as a deprecated public compatibility variant, but no production Adapter emits it; the Manager may translate it to `Stale` for legacy Adapters. After all Adapters migrate, remove it at the next intentional public Interface-breaking release. Neither `Stale` nor legacy `ItemNotFound` may represent a target that is merely unavailable because causal data has not arrived.
- The TextState Adapter will translate the Document Module's applied/stale result and Internal failures into the Undoable Interface without exposing Fugue details.
- The Document Module owns target-state classification and the OpLog/FugueTree preflight-and-commit seam. It must distinguish an eligible target, a stale target, and a structurally missing target before allocating a new local causal version.
- A preflight failure must not advance the causal graph or create an unpaired OpLog state. A post-commit Internal failure is outside rollback guarantees, but every already-applied CRDT operation must remain exportable.
- UndoManager will record the inverse history item only when the Adapter reports `Applied`.
- UndoManager will preserve the existing Local History Best-Effort contract: stale groups are consumed without creating opposite history; any Internal failure restores tracking, clears all local undo and redo history, and propagates the error.
- The Document will not be copied and CRDT history will not be rolled back for Internal failures. Any already-applied valid CRDT operations remain exportable for synchronization.
- Delivery is phased: first harden Document preflight/commit ordering and its public behavior; then migrate the Undoable Interface and symmetric stale handling; finally remove obsolete ItemNotFound plumbing and update documentation.
- The local edit planning core remains separate from the CRDT commit shell. This change does not replace the existing `InsertPlan` approach or introduce materialized input arrays in the normal path.
- The shared document state is the convergence target. Per-agent local edit history is not replicated and is not required to converge between peers.
- No `NotReady` outcome will be introduced unless a concrete Adapter can demonstrate a state where a target is causally unavailable but expected to become available later. Such a state must not be represented by `ItemNotFound`.

## Testing Decisions

- Tests will cross the highest useful Interface and assert external behavior: returned outcome, visible text, version changes, exported synchronization deltas, peer convergence, and local history availability. Tests must not assert private OpLog or Fugue fields when the same behavior is observable through a public Interface.
- The TextState integration Module will test the concrete Document Adapter with two peers. It will cover valid Undo/Redo synchronization, each symmetric stale direction, unknown targets, and the absence of new synchronization deltas for stale outcomes.
- The UndoManager Module will retain generic behavior tests using a FailureProbeDoc Adapter. These tests will cover named applied/stale outcomes, tracking restoration, invalidation of all local history after Internal failure, and partial application behavior under the documented best-effort contract. These tests must not import TextState to test generic Manager behavior.
- The Document Module will test target preflight and commit ordering through its public local-operation Interface. An unknown target must leave the causal version and exportable operation state unchanged when the failure is classified during preflight.
- Existing invalid local text and invalid position tests remain the prior art for Recoverable Edit Atomicity. Existing concurrent sync, stale Undo, round-trip Undo/Redo, and export-since tests remain the prior art for Document Convergence.
- Add a regression test where an unknown target is followed by a normal local edit, then synchronize both peers. The normal edit must be exportable and both peers must converge.
- Add regression tests for Undo Delete when the target is visible and Redo Insert when the target is visible. Both must preserve the source version and produce an empty synchronization delta.
- Add regression tests for Undo Insert when the target is absent and Redo Delete when the target is absent. Both must have the same no-op behavior.
- Add a post-commit Internal failure test through the existing Undoable seam using an Adapter that delegates the first compensating edit to a real TextState and injects failure on a later edit. It must verify that the valid CRDT operation prefix remains exportable from the wrapped TextState, a second peer can apply it, and both peers converge while all local history is disabled. This is test-only behavior and must not add a production failure-injection seam.
- Run `moon check --deny-warn`, affected Module tests, the full test suite, `moon info`, and `git diff --check`. Review generated interfaces for unintended public Interface drift.

## Out of Scope

- Rolling back the entire Document or reconstructing a prior CRDT snapshot.
- Replicating Undo/Redo history between peers.
- Introducing a general transaction system for all Document operations.
- Adding a `NotReady` state without a concrete causal-loading use case and Adapter semantics.
- Changing the local insert validation strategy from the accepted two-pass approach.
- Materializing all input codepoints for normal edits.
- Redesigning cursor, position-cache, or general sync protocol behavior beyond what is required to preserve the stated contracts.
- Publishing user-facing UI changes or new error recovery flows beyond propagating Internal failures and disabling affected local history.

## Further Notes

The central design rule is: **Recoverable Edit Atomicity protects normal local input; Document Convergence protects shared CRDT state; Local History Best-Effort protects the safety of per-agent Undo/Redo without pretending it is a replicated transaction.**

The main risk is not a stale no-op itself. The main risk is allowing a target-state or commit-ordering decision to leak across the Undoable seam, where UndoManager, the TextState Adapter, the Document Module, OpLog, and FugueTree can each make a different interpretation. The deep Interface should make the applied-versus-stale decision once, at the Document Module that owns the relevant state, and expose it through the TextState Adapter as the `CompensatingEditResult` owned by the undo Module.

The implementation is complete only when these acceptance conditions hold: every stale direction produces no new CRDT operation; every preflight rejection preserves causal and exportable state; every post-commit Internal failure clears all local history while preserving the valid CRDT operation prefix; and the affected peers converge after synchronizing that prefix.
