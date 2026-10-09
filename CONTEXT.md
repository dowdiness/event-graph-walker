# Event Graph Editing Context

This context defines the domain language for local collaborative text editing, shared-document convergence, and local undo history.

## Local Editing

**Local edit request**:
A user-visible request to insert, delete, or replace content in the local document.
_Avoid_: transaction, CRDT operation

**Recoverable edit failure**:
A normal user-facing failure caused by invalid local input or position. It occurs before commit and leaves the shared document and local edit history unchanged.
_Avoid_: synchronization failure, internal failure

**Edit commit**:
The successful completion of a local edit request as one user-visible change. One commit may emit multiple CRDT operations.
_Avoid_: partial edit, rollback

**Invalid local text**:
Text supplied to a local edit that is not a valid Unicode scalar sequence. It is a recoverable local edit failure, not a synchronization failure.
_Avoid_: invalid sync content

**Recoverable Edit Atomicity**:
The guarantee that a recoverable edit failure has no observable document or local-history effect, while a successful edit request completes as one user-visible change.
_Avoid_: full transactional rollback

## Shared Document

**Shared document projection**:
The reflection of operations recorded in causal history in the local materialized document state. Projection failure does not undo the causal-history commit that recorded an operation.
_Avoid_: causal-history commit

**CRDT operation**:
A causal operation that changes shared document state. A local edit request or compensating edit may emit multiple CRDT operations.
_Avoid_: edit, transaction

**Duplicate remote operation**:
A retransmission of the same immutable CRDT operation under the same operation identity. It creates neither another pending operation nor another causal-history entry.
_Avoid_: identity conflict, repeated apply

**Operation identity conflict**:
Two remote operation payloads that claim the same operation identity but differ in content, parents, or origins. It is a protocol violation, not a duplicate remote operation.
_Avoid_: duplicate operation

**Pending remote operation**:
A received remote CRDT operation not yet committed to causal history. Its dependencies may be absent, or it may be ready but awaiting commit. It remains eligible for later application unless rejected.
_Avoid_: buffered operation, queued operation

**Dependency-ready remote operation**:
A received remote CRDT operation whose causal parents and origin references have all been recorded in causal history. Dependency readiness does not establish that its content or referenced document targets are semantically valid.
_Avoid_: ready operation, valid remote operation

**Remote operation preflight**:
Validation that a dependency-ready remote CRDT operation has acceptable content and semantically valid document targets before application to causal history.
_Avoid_: dependency check, readiness check

**Rejected change-application attempt**:
An attempt to apply remote operations that failed preflight. The affected pending operations are removed, but the operation identity is not permanently blacklisted and may be evaluated again if received later.
_Avoid_: rejected identity, invalid tombstone

**Apply changes**:
A checked action for one attempt to apply received and pending changes to causal history. Creating the action does not change history. Executing it may commit a valid prefix before an internal failure; it does not promise an all-or-nothing batch.
_Avoid_: plan, transaction, committed batch

**Pending changes**:
The collection of received remote operations not yet committed to causal history, including both dependency-blocked and ready-but-uncommitted operations.
_Avoid_: planner, blocked-only queue

**Applying changes to causal history**:
The local commitment of dependency-ready remote CRDT operations after preflight. Once recorded, an operation is not rolled back by a later internal projection failure.
_Avoid_: projection, merge commit, remote operation admission

**Partial change-application failure**:
An internal failure after a valid prefix has already been committed to causal history. That prefix must be projected before the failure propagates; the failed operation and later operations remain pending.
_Avoid_: batch rollback, partial success

**Document Convergence**:
The guarantee that peers receiving the same valid CRDT operations eventually reach the same shared document state.
_Avoid_: undo-history convergence

**Compensating edit**:
A new local action that reverses the visible effect of earlier CRDT operations, such as undo or redo. It does not erase those earlier operations.
_Avoid_: history rollback

**Internal invariant failure**:
A failure indicating an implementation or state inconsistency rather than invalid user input. It is outside Recoverable Edit Atomicity; already-applied valid CRDT operations are not rolled back.
_Avoid_: recoverable edit failure

## Local History

**Undo group**:
A set of local CRDT operations treated as one unit by local undo. Successive user requests may belong to the same group.
_Avoid_: undo operation

**Local edit history**:
Per-agent information used to offer undo and redo for local actions. It is not shared document state and is not expected to converge between peers.
_Avoid_: replicated history

**Stale undo target**:
A target recorded in local history whose visible effect is already absent or no longer applicable in the requested undo direction. It is an expected no-op and must not be confused with a target that is merely unavailable because causal data has not arrived.
_Avoid_: missing operation, not ready

**Local History Best-Effort**:
The guarantee that undo and redo preserve shared-document convergence but do not promise atomic recovery of an internal failure. A stale undo target may be skipped; a structurally missing target is an internal failure, and local history is invalidated rather than used to issue further operations.
_Avoid_: transactional undo
