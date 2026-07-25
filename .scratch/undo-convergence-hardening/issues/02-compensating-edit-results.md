# 02 — Make compensating edits report Applied or Stale

**What to build:** Move target-state classification behind the Undoable Interface so UndoManager handles named Applied and Stale outcomes without knowing visibility, tombstones, local versions, or Fugue details.

**Blocked by:** #01 — Prevent poisoned causal state on target preflight failure.

**Status:** done

- [x] The undo Module owns the named compensating-edit result.
- [x] Delete and undelete classify visible, deleted, and structurally missing targets symmetrically.
- [x] Applied creates exactly one compensating CRDT operation.
- [x] Stale creates no CRDT operation and no synchronization delta.
- [x] UndoManager records opposite history only for Applied outcomes.
- [x] Undo Delete and Redo Insert do not emit undelete operations when the target is already visible.
