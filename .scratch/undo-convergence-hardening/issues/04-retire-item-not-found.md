# 04 — Retire the legacy ItemNotFound path

**What to build:** Complete the migration to named Applied/Stale compensating-edit results, remove obsolete ItemNotFound plumbing at the next intentional public Interface-breaking release, and align the documented consistency contract.

**Blocked by:** #02 — Make compensating edits report Applied or Stale; #03 — Preserve valid CRDT prefixes after Internal failures.

**Status:** done

- [x] No production Adapter emits ItemNotFound for stale targets.
- [x] Legacy ItemNotFound handling is removed from the public Undoable contract and Manager.
- [x] Generated Interfaces contain only the intended removal.
- [x] Context, ADRs, Undo design documentation, and examples describe the same contracts.
- [x] The full validation suite passes.
