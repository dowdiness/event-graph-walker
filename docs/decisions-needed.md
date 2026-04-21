# Decisions Needed

Items from `/moonbit-housekeeping triage` classified as `needs-human-review`. Resolve each by either acting on it or moving it to an explicit "won't do" note.

---

### RLE standalone module extraction — revive, abandon, or update design?

**Source:** `docs/RLE_DESIGN_PLAN.md`, branch `work/claude`, closed PR #5
**Context:** PR #5 `refactor(rle): extract rle into standalone CRDT-independent module` was CLOSED (not merged) on 2026-02-07. The `work/claude` branch is 73 days stale with no follow-up. `docs/RLE_DESIGN_PLAN.md` still reads as active design intent. `OPTIMIZATION_ROADMAP.md` lists RLE as "Future Work" (3–5 days). `rle/` package no longer exists at root.
**Blocks:** Nothing directly. Relevant only if someone revisits run-length encoding optimization.
**Evidence:**
- PR #5 status: closed (not merged)
- Branch `work/claude` last commit 2026-02-07, 73 days ago
- Worktree `/home/antisatori/ghq/github.com/dowdiness/egw` still checked out on this branch
- `docs/RLE_DESIGN_PLAN.md` exists but is inconsistent with closed PR
**Options:**
1. Revive — reopen PR #5 or create a new branch
2. Abandon — delete `docs/RLE_DESIGN_PLAN.md` (or move to `docs/archive/`), prune `work/claude` branch, remove `egw` worktree
3. Park — update `RLE_DESIGN_PLAN.md` with a status note ("deferred pending motivation from benchmarks")
**Added:** 2026-04-21

---

### Non-pre-authorized stale branches/worktrees — prune?

**Source:** Triage prune_candidates not covered by the initial prune authorization
**Context:** The `/moonbit-housekeeping triage` run surfaced two items beyond the 6 merged branches + 1 orphan worktree that were auto-pruned. These are non-merged stale items that need a human decision.
**Blocks:** Nothing directly; git ops hygiene.
**Evidence:**
- Branch `fix/undo-abort-on-empty-stack` — last commit 2026-03-22 (30 days), no open PR, probably superseded by merged undo work
- Branch `work/claude` — last commit 2026-02-07 (73 days), closed PR #5 (RLE; see decision above)
- Worktree `/home/antisatori/ghq/github.com/dowdiness/egw` checked out on `work/claude`
**Options:**
1. Decide RLE question first (above), then prune together
2. Prune `fix/undo-abort-on-empty-stack` now if clearly superseded; keep `work/claude` pending RLE decision
**Added:** 2026-04-21
