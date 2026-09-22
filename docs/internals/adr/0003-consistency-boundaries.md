---
status: accepted
---

# Separate local atomicity, document convergence, and local history

The editing system uses three distinct consistency contracts: **Recoverable Edit Atomicity** for normal user-facing local failures, **Document Convergence** for valid CRDT operations exchanged between peers, and **Local History Best-Effort** for per-agent undo/redo. Recoverable edit failures leave the document and local history unchanged; valid CRDT operations are never rolled back and peers converge after receiving the same operations; undo/redo is represented by compensating edits and is not expected to converge as history. A **Stale undo target** is an expected no-op when the target's visible effect is already absent or no longer applicable. A structurally missing target is not stale: it is an internal invariant failure. Such a failure is outside recoverable atomicity; already-applied CRDT operations remain, the failure is propagated, and local history is invalidated so it cannot issue stale operations.
