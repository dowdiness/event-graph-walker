# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

This is the first tracked changelog entry. It covers all work up to the current
`main` (50 commits, no prior tag). When tagging `v0.1.0`, move this entire
section under `[0.1.0] - YYYY-MM-DD` and start a fresh `[Unreleased]` above.

### ⚠ BREAKING CHANGES

- **Public type rename.** The top-level text and tree state types have been renamed for consistency. Update any downstream imports:
  - `TextDoc` → `TextState`
  - `TreeDoc` → `TreeState`
  - `TreeDocError` → `TreeError`

  Commits: `2b69807`, `23864e8`.

### Added

- **Document-level undo grouping** — multiple ops within a single document transaction are now grouped as a single undoable unit. (`3e9cdf2`)
- **Positional move operations** — `move_node_before` and `move_node_after` reposition tree nodes relative to siblings. (`9d175ed`)
- **`SyncReport` from remote sync** — `apply_remote_sync_message` returns a `SyncReport` describing which operations were applied, letting callers react to remote changes. (`051524c`)
- **Container sync substrate (Phase 3)** — full bidirectional sync between container peers over a message-passing channel. (`68bda63`)
- **Document text operations** — `insert_text`, `delete_text`, `replace_text`, `get_text`, `text_len` on the top-level `Document` type. (`a062000`)
- **`TextBlock`** — per-block `FugueTree` for fine-grained collaborative text editing within tree nodes. (`a06bd6a`)
- **`Document` struct** — unified entry point for tree + text state, in the new `container/` package. (`6d17462`)
- **MovableTree CRDT** — Kleppmann's undo-do-redo algorithm plus fractional indexing for conflict-free concurrent moves. (`1a25cfb`)
- **`create_node_after`** — positional sibling insertion in the tree. (`5bed0cf`)
- **Public `TreeNodeId` surface** — public constructor and field accessors; `tree_node_id_key`, `tree_node_id_eq` for external consumers; `TreeNodeId` re-exported so callers no longer need to reach into `internal/`. (`d2d8944`, `1754355`, `a0c34e5`)
- **`BTreeElem` for `VisibleRun`** — visible-run sequences can participate in the balanced-tree index. (`888691a`)

### Changed

- **CausalGraph migrated to iter-based `DirectedGraph`** — uses the `alga` dependency; internals now use flat arrays and a children index for better cache locality. Public API surface is source-compatible. (`bfe915f`, `e010461`)
- **`export_sync_message` raises instead of aborting** — now raises `DocumentError` on failure so callers can recover. (`eace9bb`)

### Fixed

- **Fugue `find_parent_and_side`** aligned with Algorithm 1 of the Fugue paper, correcting parent-side assignment during concurrent inserts. (`ab9cfbc`)
- **Position cache** now guards against `FugueMax` position rewriting, preventing stale cache entries after tombstone promotion. (`187faa2`)
- **`create_node_after`** correctly handles equal-positions and missing-after edge cases. (`0baae40`)
- **Tree ops raise `TreeError`** instead of `abort`, avoiding unrecoverable crashes on invalid input. (`570ea30`)

### Performance

- **Incremental position cache** for non-sequential inserts cuts worst-case cost on random-order workloads; a benchmark snapshot is in `docs/benchmarks/`. (`976c652`, `f76ec06`)
- **Incremental cache update on `apply_remote`** avoids a full cache rebuild per incoming operation. (`c3bfbb4`)

<!-- Link references will be added once the first version is tagged. -->
<!-- [Unreleased]: https://github.com/dowdiness/event-graph-walker/compare/v0.1.0...HEAD -->

