# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Staged for the next mooncakes release after 0.1.0. A `v0.2.0` git tag was
cut on 2026-04-22 (`0f80444`) but yanked before publishing because four
upstream path-deps (`rle`, `btree`, `order-tree`, `alga`) were not on
mooncakes. Those deps are now version-pinned, so the staged work below can
be promoted to a real release on demand. The version label and date are
left unset until the publish call is made.

### ⚠ BREAKING CHANGES

- **Internal packages sealed.** The following packages moved under `internal/`
  and are no longer importable from outside this module: `causal_graph`,
  `core`, `document`, `oplog`, `branch`, `fugue`, `fractional_index`,
  `movable_tree`. Consumers must switch to the public facades (`text`,
  `tree`, `undo`, `container`). Note: a handful of internal type names
  (`@movable_tree.TreeNodeId`, `@movable_tree.TreeOp`,
  `@causal_graph.VersionVector`, `@core.RawVersion`) still appear in facade
  signatures as opaque values — consumers receive and pass them but cannot
  import the defining packages.
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
  `SyncMessage`. These leaked internal representations. Sync wire-format
  helpers (`SyncMessage::to_json_string` / `from_json_string`,
  `Version::to_json_string` / `from_json_string`) cover the JSON
  serialization path; the removed inspection / construction helpers
  (`Change`, `TextSpan`, `to_rle`, `to_spans`, `get_heads`, `get_ops`,
  `SyncMessage::new`, `SyncSession::new`, `Version::from_frontier`,
  `Version::to_frontier`) have no like-for-like replacements — if you
  depended on them, file an issue.

  (`Document::apply_remote_sync_message` returning `SyncReport` instead of
  `Unit` is documented under Added below — `Document` is new in 0.2.0 and
  has no 0.1.0 predecessor, so it's not a 0.1.0→0.2.0 break.)
- **Inserts at position 0 on non-empty text now land at the beginning of the
  document** rather than the end. The prior `find_parent_and_side` rule
  diverged from Algorithm 1 of the Fugue paper; see ADR
  `docs/decisions/2026-03-31-fugue-find-parent-and-side-fix.md`. Saved
  documents created with the old rule will not round-trip identically.
  (`ab9cfbc`)

### Added

- **New `tree/` public facade** — MovableTree CRDT (Kleppmann's undo-do-redo
  algorithm + fractional indexing) exposed through `TreeState`. The CRDT
  shipped as `TreeDoc` in `1a25cfb` and was renamed to `TreeState` in
  `2b69807` for consistency with `TextState`.
- **New `undo/` public facade** — `UndoManager` plus `Undoable` trait. Text
  integration is via `TextState::insert_and_record`,
  `TextState::delete_and_record`, `TextState::replace_range_and_record`,
  `TextState::delete_range_and_record`.
- **New `container/` public facade** — top-level `Document` struct. Initial
  commit (`6d17462`) shipped the tree-backed `Document`; block-text ops
  (`a062000`), sync substrate (`68bda63`), and document-level undo grouping
  (`3e9cdf2`) landed in follow-up commits.
- **Document-level undo grouping** — multiple ops within a single document
  transaction are grouped as a single undoable unit. (`3e9cdf2`)
- **Positional move operations** — `Document::move_node_before` and
  `Document::move_node_after` reposition tree nodes relative to siblings.
  (`9d175ed`)
- **`SyncReport` from remote sync** — `Document::apply_remote_sync_message`
  returns a `SyncReport` with sync-layer counters (`applied_tree_ops`,
  `applied_text_ops`, `duplicate_ops`, `pending_ops`). Counters reflect
  version-record dedup, not payload-layer state changes; see the
  `SyncReport` doc comment in `container/document.mbt` for the full
  semantics, including caveats about mixing direct `apply_remote_op` with
  sync-message ingestion. (`051524c`)
- **Container sync substrate** — bidirectional sync between container peers
  over a message-passing channel. (`68bda63`)
- **Document text operations** — `insert_text`, `delete_text`, `replace_text`,
  `get_text`, `text_len` on `Document`. (`a062000`)
- **`TextBlock` with per-block `FugueTree`** — multi-block documents have
  one Fugue text CRDT per block, with all blocks sharing the document's
  global logical-version (LV) space so cross-block ordering remains
  causally consistent. (`a06bd6a`)
- **`create_node_after`** — positional sibling insertion in the tree. (`5bed0cf`)
- **Public `TreeNodeId` surface** — public constructor and field accessors;
  `tree_node_id_key`, `tree_node_id_eq` for external consumers; `TreeNodeId`
  re-exported from the tree and container facades. (`d2d8944`, `1754355`,
  `a0c34e5`)
- **Text range operations** — `TextState::delete_range` and
  `TextState::replace_range` on the public text API.
- **Sync message and version JSON serialization** —
  `SyncMessage::to_json_string` / `from_json_string` and
  `Version::to_json_string` / `from_json_string`.

### Changed

- **CausalGraph internals rewritten** for better cache locality (flat arrays
  + children index, on top of the `alga` graph dep). No public API change;
  improves walker / merge throughput on large oplogs. (`bfe915f`, `e010461`)
- **`export_sync_message` raises instead of aborting** — now raises
  `DocumentError` on failure so callers can recover. (`eace9bb`)
- **MoonBit v0.9 syntax migration** — `derive(Show)` → `derive(Debug)` plus
  manual `Show` impls where used by `inspect`; `substring()` → slice syntax;
  `not()` → `!()`. Consumers building this package need MoonBit ≥ v0.9.
  (`21529fb`, `2fe392b`, `223cc78`, `8461520`)

### Fixed

- **Fugue `find_parent_and_side`** aligned with Algorithm 1 of the Fugue
  paper (see ADR `docs/decisions/2026-03-31-fugue-find-parent-and-side-fix.md`),
  correcting parent-side assignment during concurrent inserts. (`ab9cfbc`)
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
`causal_graph`, `document`, `oplog`, `branch`, `fugue`, `rle`); `rle` is
removed entirely, the rest are sealed under `internal/` and superseded by
the new public facades described above.

[Unreleased]: https://github.com/dowdiness/event-graph-walker/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dowdiness/event-graph-walker/releases/tag/v0.1.0
