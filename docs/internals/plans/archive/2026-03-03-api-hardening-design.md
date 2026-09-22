# API Hardening Design

**Date:** 2026-03-03
**Status:** Approved

## Problem

The module currently exposes all 8 packages (`core`, `fugue`, `oplog`, `causal_graph`, `branch`, `document`, `rle`, `text`, `undo`) as directly importable by external library users. There is no intentional API surface design. Internal types (`Op`, `RawVersion`, `Frontier`, `LV`, `VersionVector`) leak into the `text` facade, and struct fields on `OpLog`, `Branch`, `CausalGraph`, and `UndoManager` are publicly mutable.

This must be hardened before TypeScript/FFI bindings are added, since FFI bindings will lock in the surface.

## Goal

Only `text` and `undo` are importable by external users. Everything else is an implementation detail. No internal types appear in any public method signature.

## Design

### 1. Package Structure — `internal/` Directory

MoonBit restricts packages under `a/b/internal/` to `a/b` and `a/b/**` only. Move 7 packages:

```
event-graph-walker/
├── text/               ← public facade
├── undo/               ← public plugin
└── internal/
    ├── core/
    ├── fugue/
    ├── oplog/
    ├── causal_graph/
    ├── branch/
    ├── document/
    └── rle/
```

`text` and `undo` update their import paths from e.g.
`"dowdiness/event-graph-walker/core"` → `"dowdiness/event-graph-walker/internal/core"`.

Each package directory gets a `moon.pkg` file (new format, replacing `moon.pkg.json`).

### 2. `text` Package — Ideal Public Surface

Derived from first principles: a library user needs to create a document, edit it, read it, sync with peers, travel to past versions, and optionally undo. Nothing else.

**`TextDoc`** — keep:
```
TextDoc::new(String) -> TextDoc
TextDoc::text(Self) -> String
TextDoc::len(Self) -> Int
TextDoc::is_empty(Self) -> Bool
TextDoc::insert(Self, Pos, String) -> Unit raise TextError
TextDoc::delete(Self, Pos) -> Unit raise TextError
TextDoc::version(Self) -> Version
TextDoc::checkout(Self, Version) -> TextView raise TextError
TextDoc::sync(Self) -> SyncSession
TextDoc::insert_and_record(Self, Pos, String, UndoManager, timestamp_ms~) -> Unit raise TextError
TextDoc::delete_and_record(Self, Pos, UndoManager, timestamp_ms~) -> Unit raise TextError
```

**Remove from `TextDoc`:**
- `apply_remote(@core.Op)` — raw internal type; streaming covered by `sync().apply()`
- `merge_remote(Array[@core.Op], Array[@core.RawVersion])` — duplicate of `sync().apply()`
- `get_all_ops() -> Array[@core.Op]` — internal type leak
- `get_frontier_raw() -> Array[@core.RawVersion]` — internal type leak; use `version()`
- `get_version_vector() -> @causal_graph.VersionVector` — internal type leak
- `from_document(@document.Document)` — migration escape hatch; `document` is now internal

**`insert()` and `delete()` return `Unit`** (not `Change`). The `Change` type disappears from the public surface entirely. `insert_and_record` / `delete_and_record` access `self.inner` directly for LV recording.

**`SyncMessage`** — keep only:
```
SyncMessage::is_empty(Self) -> Bool
SyncMessage::op_count(Self) -> Int
```
Remove: `new(Array[@core.Op], Array[@core.RawVersion])`, `get_ops()`, `get_heads()`.
`SyncMessage` is fully opaque — obtained only from `export_all()` / `export_since()`, applied only via `sync().apply()`.

**`SyncSession`** — keep:
```
SyncSession::export_all(Self) -> SyncMessage raise TextError
SyncSession::export_since(Self, Version) -> SyncMessage raise TextError
SyncSession::apply(Self, SyncMessage) -> Unit raise TextError
SyncSession::current_version(Self) -> Version
```
Remove: `new(TextDoc)` — use `TextDoc::sync()` instead.

**`TextView`** — keep:
```
TextView::text(Self) -> String
TextView::len(Self) -> Int
TextView::version(Self) -> Version
TextView::runs(Self) -> Iter[String]
```
Remove: `from_branch(@branch.Branch)`, `to_rle()`, `to_spans()`.

**`Version`** — keep as opaque token:
```
Version::empty() -> Version
```
Remove `from_frontier(@core.Frontier)` and `to_frontier()` from public surface (make `priv`).

**`Pos` and `Range`** — keep `Pos::at()`, `Pos::value()`. Remove `Range` (unused in the cleaned surface).

**`TextError` / `SyncFailure`** — keep all user-facing methods (`message()`, `help()`, `is_retryable()`, `debug()`). Make `from_document_error()`, `from_oplog_error()`, `from_branch_error()` package-private (`priv fn`).

**`TextSpan`** — remove (only used by the removed `to_spans()`).

**`pub using @core {type Change}`** — remove the re-export.

### 3. `undo` Package — Plugin Redesign

**`Undoable` trait moves from `document` to `undo`:**

```moonbit
pub trait Undoable {
  lv_to_position(Self, Int) -> Int?
  delete_lv(Self, Int) -> Unit raise UndoError
  undelete_lv(Self, Int) -> Unit raise UndoError
}
```

Sealed (not `pub(open)`) — only the type's package (`text`) can implement it for `TextDoc`. The implementation in `text/undoable_impl.mbt` converts `DocumentError` → `UndoError`.

**New `UndoError` type in `undo`:**

```moonbit
pub(all) suberror UndoError {
  ItemNotFound
  Internal(detail~ : String)
}
```

Replaces `@document.DocumentError` in `undo()` / `redo()` signatures.

**`undo()` and `redo()` return `Unit`** (not `Array[@core.Op]`). For peer sync after undo:
```moonbit
let v = doc.version()
undo_mgr.undo(doc)
let delta = doc.sync().export_since(v)
peer.sync().apply(delta)
```

**`UndoManager` struct fields → all `priv`.** Access via `can_undo()`, `can_redo()`, `is_tracking()`.

**`UndoGroup` and `UndoItem` → package-private** (no `pub`). Internal bookkeeping only.

**`UndoManager`** public surface:
```
UndoManager::new(String, capture_timeout_ms?: Int) -> UndoManager
UndoManager::undo(Self, D: Undoable) -> Unit raise UndoError
UndoManager::redo(Self, D: Undoable) -> Unit raise UndoError
UndoManager::can_undo(Self) -> Bool
UndoManager::can_redo(Self) -> Bool
UndoManager::clear(Self) -> Unit
UndoManager::set_tracking(Self, Bool) -> Unit
UndoManager::is_tracking(Self) -> Bool
```

### 4. Visibility Cleanup in Internal Packages

These packages are now behind `internal/` so external users cannot import them. Tightening visibility prevents accidental misuse within the module.

| Package | Change |
|---|---|
| `oplog` | `OpLog` fields (`operations`, `pending`, `graph`, `agent_id`) → `priv` |
| `branch` | `Branch` fields (`frontier`, `tree`, `oplog`) → `priv`; remove `inner_tree()` |
| `causal_graph` | `CausalGraph` all fields → `priv` |
| `fugue` | Remove deprecated `Lv::inner()`, `ReplicaId::inner()`, `Timestamp::inner()` |
| `core` | Remove deprecated `Frontier::inner()`, `VersionVector::inner()` |
| `core` | `Op` struct fields → `priv` (accessed via constructor fns and accessor methods) |
| `undo` | `UndoGroup`, `UndoItem` fields → `priv`; types themselves package-private |

## Affected Files Summary

**New structure (directory moves):**
- `core/` → `internal/core/`
- `fugue/` → `internal/fugue/`
- `oplog/` → `internal/oplog/`
- `causal_graph/` → `internal/causal_graph/`
- `branch/` → `internal/branch/`
- `document/` → `internal/document/`
- `rle/` → `internal/rle/`

**Modified packages:**
- `text/` — remove leaky methods, `Change` return type, error conversion helpers
- `undo/` — new `Undoable` trait, new `UndoError`, `Unit` returns, `priv` fields

**All `moon.pkg` files** in moved packages update import paths.

## What This Enables

After this hardening, the TypeScript/FFI bindings can target a clean, stable surface:
- 2 importable packages: `text` and `undo`
- No internal types (`Op`, `RawVersion`, `Frontier`, `LV`, `VersionVector`) anywhere in signatures
- All sync through `SyncSession` / `SyncMessage`
- All undo through `UndoManager` + `Undoable` trait

## Out of Scope

- Serialization of `SyncMessage` (future: `to_json()` / `from_json()`)
- `TextView::runs()` styled text (future: multiple runs with attributes)
- Persistent storage, presence awareness, GC/compaction
