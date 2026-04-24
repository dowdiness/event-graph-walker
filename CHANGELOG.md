# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### ⚠ BREAKING CHANGES

- `Document::apply_remote_sync_message` now returns `SyncReport` instead of
  `Unit`. The report includes applied tree ops, applied text ops,
  duplicates, and pending ops. (`051524c`)
- Inserts at position 0 on non-empty text now land at the beginning of the
  document rather than the end. The prior Fugue `find_parent_and_side`
  rule was inconsistent with Algorithm 1 of the Fugue paper. (`ab9cfbc`)

### Added

- Document-level undo grouping: multiple operations can be grouped into a
  single undoable unit at the `Document` level. (`3e9cdf2`)
- Positional move operations: `move_node_before` and `move_node_after` move
  tree nodes relative to siblings. (`9d175ed`)
- `Document` text operations: `insert_text`, `delete_text`, `replace_text`,
  `get_text`, and `text_len`. (`a062000`)
- `TextBlock` with per-block `FugueTree`, supporting multi-block documents.
  (`a06bd6a`)
- `container/` package introduced with the top-level `Document` struct that
  composes the CRDT substrate. (`6d17462`)

### Changed

- Positional move sync has convergence and `SyncReport` test coverage.
  (`8e46d83`)
- Position cache updates incrementally on `apply_remote`; previously the
  cache was rebuilt from scratch on every remote apply. (`c3bfbb4`,
  `976c652`)
- `CausalGraph` internals migrated to the iter-based `DirectedGraph` API
  with flat arrays and a children index. (`bfe915f`, `e010461`)
- `BTreeElem` implemented for the internal `VisibleRun` to satisfy the
  updated `order-tree` dependency. (`777327f`)
- Dropped deprecated MoonBit v0.9 syntax: `derive(Show)` → `derive(Debug)`,
  `substring()` → slice syntax, `not()` → `!()`. (`2fe392b`, `21529fb`,
  `223cc78`, `8461520`)

### Fixed

- `export_sync_message` raises `DocumentError` on failure instead of
  aborting, so callers can handle the error. (`eace9bb`)
- Position cache guarded against `FugueMax` position rewriting that could
  corrupt incremental state. (`187faa2`)

## [0.2.0] - 2026-04-22

First tracked release after 0.1.0 shipped to mooncakes. 0.1.0 exposed the
eg-walker internals (`causal_graph`, `document`, `oplog`, `branch`, `fugue`,
`rle`) as public top-level packages. This release moves all of them behind
`internal/` and introduces stable public facades for text, tree, undo, and
container document APIs. **Upgrades from 0.1.0 are not source-compatible** —
see BREAKING CHANGES below.

### ⚠ BREAKING CHANGES

- **Internal packages sealed.** The following packages moved under `internal/`
  and are no longer importable from outside this module: `causal_graph`,
  `document`, `oplog`, `branch`, `fugue`. Consumers must switch to the public
  facades (`text`, `tree`, `undo`, `container`).
- **`rle` package removed** from the public API. It shipped in 0.1.0 but was
  never an intended public surface.
- **`TextDoc` renamed to `TextState`** for consistency with the new
  `TreeState` and `UndoManager` facades. (`23864e8`)
- **`TextState::insert` and `TextState::delete` now return `Unit`** instead
  of `Change`. The `Change` intermediate type has been removed from the
  public API; sync is driven through `TextState::sync()` / `SyncMessage`
  rather than exposed `Change` values.
- **`SyncFailure` enum gained `Timeout(detail~)` and `Cancelled(detail~)`
  variants.** Consumers with exhaustive matches must add arms for these.
- **Public types and methods removed from `text`:** `Change`, `TextSpan`,
  `TextDoc::from_document`, `TextDoc::inner_document`,
  `TextView::from_branch`, `TextView::inner_branch`, `TextView::to_rle`,
  `TextView::to_spans`, `SyncMessage::new`, `SyncMessage::get_heads`,
  `SyncMessage::get_ops`, `SyncSession::new`,
  `TextError::from_branch_error`, `TextError::from_document_error`,
  `TextError::from_oplog_error`, `Version::from_frontier`,
  `Version::to_frontier`, plus the `Show` impls for `Pos`, `Range`, and
  `SyncMessage`. These leaked internal representations. Equivalent behavior
  is available through the public `text` methods, or through
  `SyncMessage::to_json_string` / `from_json_string` and
  `Version::to_json_string` / `from_json_string` for serialization.

### Added

- **New `tree/` public facade** — MovableTree CRDT (Kleppmann's undo-do-redo
  algorithm + fractional indexing) exposed through `TreeState`. Entirely new
  since 0.1.0. (`1a25cfb`)
- **New `undo/` public facade** — `UndoManager` plus `Undoable` trait. Text
  integration is via `TextState::insert_and_record`,
  `TextState::delete_and_record`, `TextState::replace_range_and_record`,
  `TextState::delete_range_and_record`. Entirely new since 0.1.0.
- **New `container/` public facade** — top-level `Document` struct. Initial
  commit (`6d17462`) shipped the tree-backed `Document`; block-text ops
  (`a062000`), sync substrate (`68bda63`), and document-level undo grouping
  (`3e9cdf2`) landed in follow-up commits. Entirely new since 0.1.0.
- **Document-level undo grouping** — multiple ops within a single document
  transaction are grouped as a single undoable unit. (`3e9cdf2`)
- **Positional move operations** — `Document::move_node_before` and
  `Document::move_node_after` reposition tree nodes relative to siblings.
  (`9d175ed`)
- **`SyncReport` from remote sync** — `apply_remote_sync_message` returns a
  `SyncReport` describing which operations were applied. (`051524c`)
- **Container sync substrate (Phase 3)** — full bidirectional sync between
  container peers over a message-passing channel. (`68bda63`)
- **Document text operations** — `insert_text`, `delete_text`, `replace_text`,
  `get_text`, `text_len` on `Document`. (`a062000`)
- **`create_node_after`** — positional sibling insertion in the tree. (`5bed0cf`)
- **Public `TreeNodeId` surface** — public constructor and field accessors;
  `tree_node_id_key`, `tree_node_id_eq` for external consumers; `TreeNodeId`
  re-exported from the tree and container facades. (`d2d8944`, `1754355`,
  `a0c34e5`)
- **`BTreeElem` for `VisibleRun`** — visible-run sequences participate in the
  balanced-tree index. (`777327f`)
- **Text range operations** — `TextState::delete_range` and
  `TextState::replace_range` on the public text API.
- **Sync message and version JSON serialization** —
  `SyncMessage::to_json_string` / `from_json_string` and
  `Version::to_json_string` / `from_json_string`.

### Changed

- **CausalGraph migrated to iter-based `DirectedGraph`** — uses the `alga`
  dependency; internals use flat arrays and a children index for better cache
  locality. (`bfe915f`, `e010461`)
- **`export_sync_message` raises instead of aborting** — now raises
  `DocumentError` on failure so callers can recover. (`eace9bb`)

### Fixed

- **Fugue `find_parent_and_side`** aligned with Algorithm 1 of the Fugue
  paper, correcting parent-side assignment during concurrent inserts.
  (`ab9cfbc`)
- **Position cache** guards against `FugueMax` position rewriting, preventing
  stale cache entries after tombstone promotion. (`187faa2`)
- **`create_node_after`** correctly handles equal-positions and missing-after
  edge cases. (`0baae40`)
- **Tree ops raise `TreeError`** instead of `abort`, avoiding unrecoverable
  crashes on invalid input. (`74dc069`; error type later renamed in `2b69807`)

### Performance

- **Incremental position cache** for non-sequential inserts cuts worst-case
  cost on random-order workloads; snapshot in `docs/benchmarks/`.
  (`976c652`, `f76ec06`)
- **Incremental cache update on `apply_remote`** avoids a full cache rebuild
  per incoming operation. (`c3bfbb4`)

## [0.1.0]

Initial release published to mooncakes:
<https://mooncakes.io/docs/dowdiness/event-graph-walker@0.1.0>. No prior
changelog was maintained. Public surface was a flat set of packages (`text`,
`causal_graph`, `document`, `oplog`, `branch`, `fugue`, `rle`); all except
`text` have been superseded in 0.2.0.

[Unreleased]: https://github.com/dowdiness/event-graph-walker/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/dowdiness/event-graph-walker/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/dowdiness/event-graph-walker/releases/tag/v0.1.0

