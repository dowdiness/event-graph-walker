# 03 — Preserve valid CRDT prefixes after Internal failures

**What to build:** Make an Internal failure during a compensating edit fail fast while preserving the valid CRDT operation prefix for synchronization and disabling all local Undo/Redo history.

**Blocked by:** #02 — Make compensating edits report Applied or Stale.

**Status:** ready-for-agent

- [ ] Tracking state is restored after an Internal failure.
- [ ] All local undo and redo history is invalidated.
- [ ] Already-applied valid CRDT operations remain exportable.
- [ ] A second peer can apply the valid operation prefix.
- [ ] The affected peers converge after synchronization.
- [ ] No Document snapshot or rollback mechanism is introduced.
