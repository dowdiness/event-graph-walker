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

---

### v0.2.0 mooncakes publish — dep chain plan

**Source:** `moon publish --dry-run` on 2026-04-22; `moon.mod.json` path-only deps
**Context:** v0.2.0 is landed on `main` (commits `0d99084`, `0f80444`) with full CHANGELOG + independent Codex review. Git tag + GitHub release were **yanked** because `moon publish --dry-run` fails: `dowdiness/btree` (and three other deps) use `path` without `version`. Mooncakes publish needs every transitive dep to resolve to a published version.
**Blocks:** mooncakes publish of `dowdiness/event-graph-walker@0.2.0`. Library is consumable via git/submodule today but not via `moon add`.
**Evidence:**
- `moon.mod.json` deps: `dowdiness/btree` (v0.1.0 local), `dowdiness/rle` (v0.1.0 local), `dowdiness/order-tree` (v0.1.0 local), `dowdiness/alga` (v0.2.0 local, has own github repo)
- None are on mooncakes yet (v0.1.0 of event-graph-walker shipped self-contained, before these deps were introduced)
- `project_v0_2_0_publish_blocker.md` memory has the full publish order and re-cut procedure
**Options:**
1. Publish the dep chain (rle → btree → alga → order-tree → event-graph-walker), each with own CHANGELOG/tag/release/publish. 2–4 hours across the chain. Preserves the "CRDT-independent library" direction.
2. Vendor rle/btree/order-tree/alga back under `event-graph-walker/internal/` so the module is self-contained for mooncakes. Large unwind.
3. Hybrid: add `{ "path": "...", "version": "0.1.0" }` form alongside path — still requires deps to be on mooncakes, just decouples dev from publish.
**Recommendation:** Option 1 when the user returns; the refactor direction is deliberate.
**Added:** 2026-04-22
