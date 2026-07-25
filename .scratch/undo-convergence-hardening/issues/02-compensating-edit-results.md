# 02 — Make compensating edits report Applied or Stale

**What to build:** Move target-state classification behind the Undoable Interface so UndoManager handles named Applied and Stale outcomes without knowing visibility, tombstones, local versions, or Fugue details.

**Blocked by:** #01 — Prevent poisoned causal state on target preflight failure.

**Status:** ready-for-agent

- [ ] The undo Module owns the named compensating-edit result.
- [ ] Delete and undelete classify visible, deleted, and structurally missing targets symmetrically.
- [ ] Applied creates exactly one compensating CRDT operation.
- [ ] Stale creates no CRDT operation and no synchronization delta.
- [ ] UndoManager records opposite history only for Applied outcomes.
- [ ] Undo Delete and Redo Insert do not emit undelete operations when the target is already visible.
