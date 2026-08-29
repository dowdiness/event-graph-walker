# EGW Text Sync Gate V2

Gate V2 checks schema-2 causal authority rules in a bounded raw Quint model and
replays generated ITF traces through the public MoonBit text API.

The canonical design is
[`docs/research/2026-08-29-text-sync-gate-v2-design.md`](../../../docs/research/2026-08-29-text-sync-gate-v2-design.md).

## Current milestone

The implemented vertical slices cover sparse delta and admission atomicity:

| Boundary | Covered case |
|---|---|
| Identity shape | `(shared-agent,0)`, `(shared-agent,2)`, `(shared-agent,7)` |
| Sequence causality | sparse root identities remain independent |
| Peer knowledge | exact sparse set `{0,7}` |
| Delta | missing identity `{2}` is exported from a fresh peer checkpoint |
| Pending | child `(shared-agent,2)` arrives before declared parent `(shared-agent,0)` |
| Pending release | parent delivery admits both parent and pending child |
| Duplicate | equivalent child delivery is idempotent |
| Conflict | same identity with different exact content is rejected without Version/frontier/pending mutation |
| Wire ingress | independently constructed schema-2 JSON parsed by `SyncMessage::from_json_string` |
| Production observation | Version frontier/ranges, text, pending count, SyncReport, exact exported operation set, and canonical-byte round-trip stability |
| Exact operations | multi-agent identity, arbitrary parent set, insert/delete/undelete, exact content, directional origins |
| Checkpoints | historical empty-text checkout and multi-head checkout after later edits |
| Delta | fresh multi-head checkpoint exports the exact missing operation; external overclaim omits the claimed operation |
| Delivery schedules | all 36 canonical order pairs for three fixed messages across two independent replicas |
| Coverage authority | every required `scheduleId` must occur in the fixed-seed ITF corpus before replay passes |
| Model mutations | flat per-agent maximum, premature admission, implicit sequence parent, exact-origin identity conflict, and delete null-content corruption are detected |
| Replay mutations | altered expected Version and incomplete schedule coverage diverge |

The single entry point also reruns the existing Version codec/resource/sparse
contracts and Gate V0’s 15 hand-written traces plus the 1,000-case official
corpus in both delivery modes.

The schedule catalog covers every per-replica order pair for its fixed
parent/child/concurrent-root fixture. `TextSyncComplete.qnt` separately covers
an exact multi-agent insert/delete/undelete chain, missing-target pending
release, left/right directional origins, historical and multi-head checkout,
fresh-peer delta, and external overclaim. Bounds remain fixture-specific; this
is not a claim over unbounded operation graphs.

## Run

```bash
cd tools/verification/text_sync_gate_v2
./run.sh --dev
# After committing the exact candidate:
./run.sh --candidate
```

The script pins Quint 0.32.0 through `package-lock.json`. Bounded verification
uses Apalache 0.62.2 under Java 21; when the active Java is not 21, the script
uses `nix shell nixpkgs#jdk21_headless` if available. Candidate mode refuses a
dirty worktree so the reported commit identifies the tested source exactly.

The suite is native-only and outside the root workspace. It does not add a
production package dependency or public test hook.

## Evidence boundaries

- Quint proves only the recorded finite bounds.
- The replay driver imports the public `text` package and imports public `sync`
  only to classify the `Failure` carried by `TextError::SyncFailed`; it imports
  no `internal/*` package.
- Visible Fugue ordering remains the responsibility of
  `tools/verification/text_reference`.
- Concrete Version cardinality and byte limits remain the responsibility of the
  existing text resource tests.
