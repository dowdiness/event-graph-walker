# EGW Text Sync Gate V2

Gate V2 checks schema-2 causal authority rules in a bounded raw Quint model and
replays model-derived ITF observations through the public MoonBit text API.

The canonical design is
[`docs/research/2026-08-29-text-sync-gate-v2-design.md`](../../../docs/research/2026-08-29-text-sync-gate-v2-design.md).

## Architecture

`TextSyncCore.qnt` owns one deterministic bounded reducer:

```text
ModelState + Event -> ModelState + Outcome
```

Each replica stores only admitted and pending operations as causal authority.
Knowledge, maximal frontier, pending count, checkpoint contents, exported
delta, message heads, and report counts are derived by the reducer. Release
uses eight passes under an invariant-backed maximum of eight known operations
per replica, sufficient for every acyclic dependency chain in this bounded
domain.
Identity
comparison covers the entire operation: identity, parents, kind, content, and
both directional origins. Conflicts are rejected before mutation.

`TextSyncScenarios.qnt` supplies fixtures and event selection. Its schedule
slice defines the six three-message permutations once and generates their
Cartesian product. Model invariants require six unique permutations, 36 unique
cases, and exactly one delivery of each message to each receiver. Deliveries
are selected from an unordered network set while preserving the selected
per-receiver order.

`replay/main.mbt` executes each emitted event using only public `text` APIs and
public `sync` failure classification. It compares exact Version knowledge and
frontier, pending count, `SyncReport`, checkout text, and complete exported
message observations `{ operations, heads }`. Fixture messages, `export_all`,
checkpoint delta, and external Version claims all use the same message
observation boundary.

## Covered boundaries

- sparse same-agent sequence knowledge without implicit sequence causality
- child-before-parent pending isolation and reducer-driven release
- equivalent duplicate delivery
- exact conflicts in content, parents, `origin_left`, and `origin_right`
- mixed-message conflict atomicity: a canonically earlier fresh operation remains
  unapplied when a later operation conflicts
- multi-agent insert/delete/undelete and multi-parent operations
- origin-only readiness dependencies preserving declared-parent frontier semantics
- historical and multi-head checkpoints and checkout
- exact fresh delta from the lagging receiver's captured Version, followed by
  applying that exported message to converge with the sender
- full export and external overclaim deprivation
- generated 6 × 6 delivery-order catalog with observed/required ID equality
- flat-maximum, premature-admission, and implicit-sequence-parent reducer
  mutations
- model mutation for a deleted catalog case, plus replay mutations for Version
  observations, message heads, and incomplete schedule coverage

The entry point also reruns existing Version codec/resource/sparse contracts
and Gate V0’s 15 hand-written traces plus the 1,000-case official corpus in
both delivery modes.

## Run

```bash
cd tools/verification/text_sync_gate_v2
./run.sh --dev
# After committing the exact candidate:
./run.sh --candidate
```

The script pins Quint 0.32.0 through `package-lock.json` and Apalache 0.62.2
under Java 21. When active Java is not 21, it uses
`nix shell nixpkgs#jdk21_headless` if available. Candidate mode refuses a dirty
worktree before and after verification.

The suite is native-only and outside the root workspace. It adds no production
package dependency or public test hook.

## Evidence boundaries

- Quint proves only the recorded finite bounds.
- Public correspondence is exhaustive for emitted named and catalog prefixes,
  not every symbolic Apalache path.
- Visible Fugue ordering remains Gate V0’s responsibility.
- Concrete Version cardinality and byte limits remain existing resource tests’
  responsibility.
- Dishonest external knowledge claims can cause deprivation and are not treated
  as recoverable by this stateless protocol.
