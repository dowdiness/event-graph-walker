# 04 — Retire the legacy ItemNotFound path

**What to build:** Complete the migration to named Applied/Stale compensating-edit results, remove obsolete ItemNotFound plumbing at the next intentional public Interface-breaking release, and align the documented consistency contract.

**Blocked by:** #02 — Make compensating edits report Applied or Stale; #03 — Preserve valid CRDT prefixes after Internal failures.

**Status:** ready-for-agent

- [ ] No production Adapter emits ItemNotFound for stale targets.
- [ ] Legacy ItemNotFound handling is removed or explicitly retained only for compatibility.
- [ ] Generated Interfaces contain no unintended public changes.
- [ ] Context, ADRs, Undo design documentation, and examples describe the same contracts.
- [ ] The full validation suite passes.
