# API Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move 7 implementation packages behind `internal/`, clean the `text` and `undo` public surfaces to expose no internal types, and tighten struct visibility — producing a surface that TypeScript/FFI bindings can target directly.

**Architecture:** The `internal/` directory path is MoonBit's only mechanism for restricting package imports; packages at `a/b/internal/**` are only accessible to `a/b/**`. The `text` and `undo` packages remain public. After the move, import paths in `moon.pkg` change from e.g. `"dowdiness/event-graph-walker/core"` to `"dowdiness/event-graph-walker/internal/core"` — but source-level aliases (`@core`, `@document`, etc.) are derived from the final path segment and remain unchanged.

**Tech Stack:** MoonBit, `moon check` / `moon test` / `moon info` / `moon fmt`

**Design doc:** `docs/plans/2026-03-03-api-hardening-design.md`

---

## Phase 1 — Move packages to `internal/`

### Task 1: Move leaf packages (no internal deps)

**Files:**
- Move: `core/` → `internal/core/`
- Move: `fugue/` → `internal/fugue/`
- Move: `rle/` → `internal/rle/`

**Step 1: Create directory and move with git**

```bash
mkdir -p internal
git mv core internal/core
git mv fugue internal/fugue
git mv rle internal/rle
```

Expected: three directories now live under `internal/`.

**Step 2: Verify `moon check` fails (expected — dependents not updated yet)**

```bash
moon check 2>&1 | head -30
```

Expected: errors about unresolved packages `dowdiness/event-graph-walker/core` etc.

**Step 3: Commit the moves**

```bash
git add internal/
git commit -m "refactor: move core, fugue, rle to internal/"
```

---

### Task 2: Move packages with internal deps

**Files:**
- Move: `causal_graph/` → `internal/causal_graph/`
- Move: `oplog/` → `internal/oplog/`
- Move: `branch/` → `internal/branch/`
- Move: `document/` → `internal/document/`

**Step 1: Move with git**

```bash
git mv causal_graph internal/causal_graph
git mv oplog internal/oplog
git mv branch internal/branch
git mv document internal/document
```

**Step 2: Commit**

```bash
git add internal/
git commit -m "refactor: move causal_graph, oplog, branch, document to internal/"
```

---

### Task 3: Update all `moon.pkg` import paths

Every package that imported a now-moved package needs its `moon.pkg` updated. The alias (e.g. `@core`) does not change — only the import path string.

**Files to modify:**

- `internal/causal_graph/moon.pkg`
- `internal/oplog/moon.pkg`
- `internal/branch/moon.pkg`
- `internal/document/moon.pkg`
- `undo/moon.pkg`
- `text/moon.pkg`

**Step 1: Update `internal/causal_graph/moon.pkg`**

```
import {
  "dowdiness/event-graph-walker/internal/core",
  "moonbitlang/core/bench",
  "moonbitlang/core/queue",
  "moonbitlang/core/json",
  "moonbitlang/core/immut/hashmap" @immut/hashmap,
  "moonbitlang/core/immut/hashset" @immut/hashset,
  "moonbitlang/core/quickcheck",
  "moonbitlang/quickcheck" @qc,
}

options(
  is_main: false,
)
```

**Step 2: Update `internal/oplog/moon.pkg`**

```
import {
  "dowdiness/event-graph-walker/internal/core",
  "dowdiness/event-graph-walker/internal/causal_graph",
  "moonbitlang/core/bench",
  "moonbitlang/core/json",
  "moonbitlang/core/immut/hashset" @immut/hashset,
}

options(
  is_main: false,
)
```

**Step 3: Update `internal/branch/moon.pkg`**

```
import {
  "dowdiness/event-graph-walker/internal/core",
  "dowdiness/event-graph-walker/internal/causal_graph",
  "dowdiness/event-graph-walker/internal/oplog",
  "dowdiness/event-graph-walker/internal/fugue",
  "moonbitlang/core/bench",
}

options(
  is_main: false,
)
```

**Step 4: Update `internal/document/moon.pkg`**

```
import {
  "dowdiness/event-graph-walker/internal/core",
  "dowdiness/event-graph-walker/internal/causal_graph",
  "dowdiness/event-graph-walker/internal/oplog",
  "dowdiness/event-graph-walker/internal/fugue",
  "dowdiness/event-graph-walker/internal/branch",
}

options(
  is_main: false,
)
```

**Step 5: Update `undo/moon.pkg`**

```
import {
  "dowdiness/event-graph-walker/internal/core",
  "dowdiness/event-graph-walker/internal/document",
}

import {
  "dowdiness/event-graph-walker/text",
  "moonbitlang/core/quickcheck",
} for "test"

options(
  is_main: false,
)
```

**Step 6: Update `text/moon.pkg`**

```
import {
  "dowdiness/event-graph-walker/internal/core",
  "dowdiness/event-graph-walker/internal/causal_graph",
  "dowdiness/event-graph-walker/internal/oplog",
  "dowdiness/event-graph-walker/internal/fugue",
  "dowdiness/event-graph-walker/internal/branch",
  "dowdiness/event-graph-walker/internal/document",
  "dowdiness/event-graph-walker/internal/rle",
  "dowdiness/event-graph-walker/undo",
}

import {
  "moonbitlang/core/quickcheck",
  "moonbitlang/quickcheck" @qc,
} for "test"

options(
  is_main: false,
)
```

**Step 7: Verify compilation**

```bash
moon check
```

Expected: zero errors. All `@core`, `@document`, etc. aliases still resolve since the last path segment is unchanged.

**Step 8: Run all tests**

```bash
moon test
```

Expected: all 347 tests pass.

**Step 9: Commit**

```bash
git add internal/ undo/moon.pkg text/moon.pkg
git commit -m "refactor: update moon.pkg paths for internal/ move"
```

---

## Phase 2 — Redesign `undo` package

The `undo` package currently depends on `@document.Undoable` (internal) and returns `Array[@core.Op]` from `undo()`/`redo()`. We replace these with a self-contained `Undoable` trait and `UndoError` type, and change `undo()`/`redo()` to return `Unit`.

### Task 4: Add `UndoError` and `Undoable` trait to `undo`

**Files:**
- Modify: `undo/types.mbt`
- Create: `undo/undoable.mbt`

**Step 1: Add `UndoError` to `undo/types.mbt`**

Append to the end of `undo/types.mbt`:

```moonbit
///|
/// Errors that can occur during undo/redo operations
pub(all) suberror UndoError {
  ItemNotFound
  Internal(detail~ : String)
}

///|
pub fn UndoError::message(self : UndoError) -> String {
  match self {
    ItemNotFound => "Undo target item not found in document"
    Internal(detail~) => "Internal undo error: \{detail}"
  }
}

///|
pub fn UndoError::is_retryable(self : UndoError) -> Bool {
  match self {
    ItemNotFound => false
    Internal(_) => false
  }
}
```

**Step 2: Create `undo/undoable.mbt`**

```moonbit
///| Undoable — interface between UndoManager and a document

///|
/// Implement this trait on a document type to make it compatible with UndoManager.
/// TextDoc in the text package provides the canonical implementation.
pub trait Undoable {
  lv_to_position(Self, Int) -> Int?
  delete_lv(Self, Int) -> Unit raise UndoError
  undelete_lv(Self, Int) -> Unit raise UndoError
}
```

**Step 3: Verify compilation**

```bash
moon check
```

Expected: zero errors.

**Step 4: Commit**

```bash
git add undo/types.mbt undo/undoable.mbt
git commit -m "feat(undo): add UndoError and Undoable trait"
```

---

### Task 5: Update `UndoManager` to use new types

**Files:**
- Modify: `undo/undo_manager.mbt`
- Modify: `undo/moon.pkg`

**Step 1: Replace `undo()` signature and body in `undo/undo_manager.mbt`**

Replace the entire `undo()` function:

```moonbit
///|
/// Pop undo group and apply inverses locally. Push inverse group to redo stack.
/// For peer sync after undo: capture version before calling, then export_since.
pub fn[D : Undoable] UndoManager::undo(
  self : UndoManager,
  doc : D,
) -> Unit raise UndoError {
  guard self.undo_stack.length() > 0
  let group = self.undo_stack.unsafe_pop()
  let was_tracking = self.tracking_enabled
  self.tracking_enabled = false
  let redo_items : Array[UndoItem] = []
  for i = group.items.length() - 1; i >= 0; i = i - 1 {
    let item = group.items[i]
    try {
      match item.op_type {
        Insert => {
          match doc.lv_to_position(item.target_lv) {
            Some(_) => {
              doc.delete_lv(item.target_lv)!
              redo_items.push({
                target_lv: item.target_lv,
                op_type: Insert,
                content: item.content,
              })
            }
            None => ()
          }
        }
        Delete => {
          doc.undelete_lv(item.target_lv)!
          redo_items.push({
            target_lv: item.target_lv,
            op_type: Delete,
            content: item.content,
          })
        }
      }
    } catch {
      UndoError::ItemNotFound => continue
      e => {
        self.tracking_enabled = was_tracking
        raise e
      }
    }
  }
  if redo_items.length() > 0 {
    redo_items.rev_in_place()
    self.redo_stack.push({ items: redo_items, timestamp: group.timestamp })
  }
  self.tracking_enabled = was_tracking
}
```

**Step 2: Replace `redo()` signature and body**

```moonbit
///|
/// Pop redo group and reapply. Push inverse group back to undo stack.
pub fn[D : Undoable] UndoManager::redo(
  self : UndoManager,
  doc : D,
) -> Unit raise UndoError {
  guard self.redo_stack.length() > 0
  let group = self.redo_stack.unsafe_pop()
  let was_tracking = self.tracking_enabled
  self.tracking_enabled = false
  let undo_items : Array[UndoItem] = []
  for i = group.items.length() - 1; i >= 0; i = i - 1 {
    let item = group.items[i]
    try {
      match item.op_type {
        Insert => {
          doc.undelete_lv(item.target_lv)!
          undo_items.push({
            target_lv: item.target_lv,
            op_type: Insert,
            content: item.content,
          })
        }
        Delete => {
          match doc.lv_to_position(item.target_lv) {
            Some(_) => {
              doc.delete_lv(item.target_lv)!
              undo_items.push({
                target_lv: item.target_lv,
                op_type: Delete,
                content: item.content,
              })
            }
            None => ()
          }
        }
      }
    } catch {
      UndoError::ItemNotFound => continue
      e => {
        self.tracking_enabled = was_tracking
        raise e
      }
    }
  }
  if undo_items.length() > 0 {
    undo_items.rev_in_place()
    self.undo_stack.push({ items: undo_items, timestamp: group.timestamp })
  }
  self.tracking_enabled = was_tracking
}
```

**Step 3: Remove the `@document` and `@core` imports from `undo/moon.pkg`**

`undo` no longer needs `internal/document` or `internal/core` in its main imports (only tests need `text`):

```
import {
}

import {
  "dowdiness/event-graph-walker/text",
  "moonbitlang/core/quickcheck",
} for "test"

options(
  is_main: false,
)
```

**Step 4: Verify**

```bash
moon check
```

Expected: errors in `undo_manager.mbt` referencing `@document.DocumentError` — the old error type. Also `@core.Op` references. Those are in the old `undo()` / `redo()` — confirm you replaced them fully in steps 1-2.

**Step 5: Run tests (some undo tests may fail — fix in next task)**

```bash
moon test 2>&1 | grep -E "FAIL|Error" | head -20
```

**Step 6: Commit**

```bash
git add undo/
git commit -m "refactor(undo): use Undoable trait and UndoError, undo/redo return Unit"
```

---

### Task 6: Update `text/undoable_impl.mbt` and `undo_helpers.mbt`

**Files:**
- Modify: `text/undoable_impl.mbt`
- Modify: `text/undo_helpers.mbt`

**Step 1: Rewrite `text/undoable_impl.mbt`**

Replace the entire file content:

```moonbit
///| Undoable impl for TextDoc
///  Lives in text/ package where TextDoc's private fields are accessible.

///|
pub impl @undo.Undoable for TextDoc with lv_to_position(self, lv) {
  self.inner.lv_to_position(lv)
}

///|
pub impl @undo.Undoable for TextDoc with delete_lv(self, lv) {
  self.inner.delete_by_lv(lv) catch {
    _ => raise @undo.UndoError::ItemNotFound
  }
}

///|
pub impl @undo.Undoable for TextDoc with undelete_lv(self, lv) {
  self.inner.undelete(lv) catch {
    _ => raise @undo.UndoError::ItemNotFound
  }
}
```

**Step 2: Rewrite `text/undo_helpers.mbt`**

`insert()` and `delete()` now return `Unit`, so call `self.inner` directly to get the `Op` and its `lv`:

```moonbit
///| Integration helpers for TextDoc + UndoManager

///|
/// Insert text and record each character's LV for undo tracking.
pub fn TextDoc::insert_and_record(
  self : TextDoc,
  pos : Pos,
  text : String,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  let doc_len = self.len()
  let pos_val = pos.value()
  if pos_val > doc_len {
    raise TextError::InvalidPosition(pos=pos_val, len=doc_len)
  }
  for i = 0; i < text.length(); i = i + 1 {
    let ch = text[i:i + 1].to_string() catch { _ => continue }
    let op = try {
      self.inner.insert(pos_val + i, ch)
    } catch {
      err => raise TextError::from_document_error(err, doc_len)
    }
    mgr.record_insert(op.lv, op.agent, timestamp_ms, content=Some(ch))
  }
}

///|
/// Delete a character and record its target LV for undo tracking.
pub fn TextDoc::delete_and_record(
  self : TextDoc,
  pos : Pos,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  let doc_len = self.len()
  let pos_val = pos.value()
  let items = self.inner.get_visible_items()
  let content : String? = if pos_val < items.length() {
    Some(items[pos_val].1.content)
  } else {
    None
  }
  let op = try {
    self.inner.delete(pos_val)
  } catch {
    err => raise TextError::from_document_error(err, doc_len)
  }
  match op.get_delete_target() {
    Some(raw) =>
      match self.inner.raw_to_lv(raw) {
        Some(lv) => mgr.record_delete(lv, op.agent, timestamp_ms, content~)
        None => ()
      }
    None => ()
  }
}
```

**Step 3: Verify**

```bash
moon check
```

Expected: errors about `op.lv` and `op.agent` being private fields (if `Op` fields are still public this works; they will be made `priv` in Phase 4 with accessors added then). Fix any remaining `@document.Undoable` references.

**Step 4: Run tests**

```bash
moon test
```

Expected: all undo-related tests pass.

**Step 5: Commit**

```bash
git add text/undoable_impl.mbt text/undo_helpers.mbt
git commit -m "refactor(text): implement @undo.Undoable for TextDoc"
```

---

## Phase 3 — Clean `text` package surface

### Task 7: Change `insert()` and `delete()` to return `Unit`

**Files:**
- Modify: `text/text_doc.mbt`
- Modify: `text/text_test.mbt` (any test using the returned `Change`)

**Step 1: Update `insert()` in `text/text_doc.mbt`**

Replace the `insert` function:

```moonbit
///|
/// Insert text at the given position
pub fn TextDoc::insert(
  self : TextDoc,
  pos : Pos,
  text : String,
) -> Unit raise TextError {
  let doc_len = self.len()
  let pos_val = pos.value()
  if pos_val > doc_len {
    raise TextError::InvalidPosition(pos=pos_val, len=doc_len)
  }
  self.inner.insert(pos_val, text) catch {
    err => raise TextError::from_document_error(err, doc_len)
  }
  |> ignore
}
```

**Step 2: Update `delete()` in `text/text_doc.mbt`**

```moonbit
///|
/// Delete a single character at the given position
pub fn TextDoc::delete(self : TextDoc, pos : Pos) -> Unit raise TextError {
  let doc_len = self.len()
  let pos_val = pos.value()
  if pos_val >= doc_len {
    raise TextError::InvalidPosition(pos=pos_val, len=doc_len)
  }
  self.inner.delete(pos_val) catch {
    err => raise TextError::from_document_error(err, doc_len)
  }
  |> ignore
}
```

**Step 3: Run tests to find any test that used the `Change` return value**

```bash
moon check 2>&1 | grep -E "error|Change"
```

Fix any test that captured the return value of `insert()` or `delete()`.

**Step 4: Run all tests**

```bash
moon test
```

Expected: all tests pass.

**Step 5: Commit**

```bash
git add text/text_doc.mbt text/text_test.mbt
git commit -m "refactor(text): insert/delete return Unit"
```

---

### Task 8: Remove leaky `TextDoc` methods

**Files:**
- Modify: `text/text_doc.mbt`
- Modify: `text/text_test.mbt` (remove tests for removed methods)

**Step 1: Delete these functions from `text/text_doc.mbt`**

Remove entirely:
- `TextDoc::apply_remote(self, op: @core.Op)`
- `TextDoc::merge_remote(self, Array[@core.Op], Array[@core.RawVersion])`
- `TextDoc::get_all_ops(self) -> Array[@core.Op]`
- `TextDoc::get_frontier_raw(self) -> Array[@core.RawVersion]`
- `TextDoc::get_version_vector(self) -> @causal_graph.VersionVector`
- `TextDoc::from_document(doc: @document.Document) -> TextDoc`

**Step 2: Check and fix tests**

```bash
moon check 2>&1 | grep "error"
```

Remove or rewrite any test in `text/text_test.mbt` that calls these methods. Tests for sync round-trips should be rewritten using `sync().export_all()` and `sync().apply()`.

**Step 3: Run all tests**

```bash
moon test
```

Expected: all tests pass.

**Step 4: Commit**

```bash
git add text/
git commit -m "refactor(text): remove leaky TextDoc methods"
```

---

### Task 9: Clean up `SyncMessage`, `SyncSession`, and `Version`

**Files:**
- Modify: `text/sync.mbt`
- Modify: `text/types.mbt`
- Modify: `text/text_test.mbt`

**Step 1: Remove from `text/sync.mbt`**

From `SyncMessage`, remove:
- `SyncMessage::new(Array[@core.Op], Array[@core.RawVersion]) -> SyncMessage`
- `SyncMessage::get_ops(self) -> Array[@core.Op]`
- `SyncMessage::get_heads(self) -> Array[@core.RawVersion]`

From `SyncSession`, remove:
- `SyncSession::new(doc: TextDoc) -> SyncSession`

**Step 2: Make `Version::from_frontier` and `to_frontier` private in `text/types.mbt`**

Find `Version::from_frontier` and `Version::to_frontier`. Change `pub fn` to `pub(package) fn` (or simply `priv fn` if only used within `text/`). These are internal bridging helpers.

**Step 3: Check and fix tests**

```bash
moon check 2>&1 | grep "error"
```

Fix any test that called `SyncMessage::new()`, `get_ops()`, `get_heads()`, or `SyncSession::new()`.

**Step 4: Run tests**

```bash
moon test
```

**Step 5: Commit**

```bash
git add text/sync.mbt text/types.mbt text/text_test.mbt
git commit -m "refactor(text): seal SyncMessage and SyncSession"
```

---

### Task 10: Remove `TextView` internals, `TextSpan`, `Range`, `Change` re-export

**Files:**
- Modify: `text/view.mbt`
- Modify: `text/span.mbt` (delete or gut)
- Modify: `text/text_doc.mbt` (remove `pub using @core {type Change}` if present)
- Modify: `text/text_test.mbt`, `text/span_test.mbt`

**Step 1: Remove from `text/view.mbt`**

Remove:
- `TextView::from_branch(@branch.Branch) -> TextView` (remove `pub`, make `priv fn`)
- `TextView::to_rle(self) -> @rle.Runs[String]`
- `TextView::to_spans(self) -> @rle.Runs[TextSpan]`

`TextView::runs(self) -> Iter[String]` stays.

**Step 2: Remove `TextSpan` from `text/span.mbt`**

`TextSpan` was only used by `to_spans()`. Remove the entire `span.mbt` contents (or delete the file if no other content).

**Step 3: Remove `Range` type**

`Range` is declared in `text/types.mbt`. Remove it — it is not used in the cleaned surface.

**Step 4: Remove `pub using @core {type Change}` re-export**

Find this in `text/` (likely `text/types.mbt` or `text/text_doc.mbt`) and remove the `pub using` line. `Change` is now internal.

**Step 5: Fix tests**

```bash
moon check 2>&1 | grep "error"
```

Remove `span_test.mbt` entries or the whole file if it only tested `TextSpan`.

**Step 6: Run tests**

```bash
moon test
```

**Step 7: Commit**

```bash
git add text/
git commit -m "refactor(text): remove TextView internals, TextSpan, Range, Change re-export"
```

---

### Task 11: Make `TextError` conversion helpers private

**Files:**
- Modify: `text/errors.mbt`

**Step 1: Change three functions from `pub fn` to `fn` (package-private)**

In `text/errors.mbt`, change:
- `pub fn TextError::from_document_error(...)` → `fn TextError::from_document_error(...)`
- `pub fn TextError::from_oplog_error(...)` → `fn TextError::from_oplog_error(...)`
- `pub fn TextError::from_branch_error(...)` → `fn TextError::from_branch_error(...)`

These are still used within `text/` — just not exported.

**Step 2: Verify**

```bash
moon check
```

Expected: zero errors (all callers are within `text/`).

**Step 3: Run tests**

```bash
moon test
```

**Step 4: Commit**

```bash
git add text/errors.mbt
git commit -m "refactor(text): make error conversion helpers private"
```

---

## Phase 4 — Visibility cleanup in internal packages

### Task 12: Make `OpLog` and `Branch` struct fields `priv`

**Files:**
- Modify: `internal/oplog/oplog.mbt` (or wherever `OpLog` struct is defined)
- Modify: `internal/branch/branch.mbt`

**Step 1: Make `OpLog` fields private**

Find the `OpLog` struct definition and add `priv` to all fields:

```moonbit
pub struct OpLog {
  priv mut operations : Array[@core.Op]
  priv mut pending : Array[@core.Op]
  priv graph : @causal_graph.CausalGraph
  priv agent_id : String
}
```

**Step 2: Make `Branch` fields private**

```moonbit
pub struct Branch {
  priv frontier : @core.Frontier
  priv tree : @fugue.FugueTree[String]
  priv oplog : @oplog.OpLog
}
```

**Step 3: Remove `Branch::inner_tree()`**

Find and delete `pub fn Branch::inner_tree(self : Branch) -> @fugue.FugueTree[String]`.

Update `text/view.mbt`'s `to_spans()` — but that method is already being removed in Task 10, so there should be no callers left. Verify:

```bash
grep -r "inner_tree" .
```

Expected: no results (or only definition site which we're deleting).

**Step 4: Fix any compilation errors caused by field access**

```bash
moon check 2>&1 | grep "error"
```

Any code inside `internal/oplog/` or `internal/branch/` that accesses these fields directly still works (same package). Code in OTHER packages that accessed fields directly will error — add accessor methods as needed.

**Step 5: Run tests**

```bash
moon test
```

**Step 6: Commit**

```bash
git add internal/oplog/ internal/branch/
git commit -m "refactor(internal): make OpLog and Branch fields priv"
```

---

### Task 13: Make `CausalGraph` fields `priv` and remove deprecated `inner()` methods

**Files:**
- Modify: `internal/causal_graph/causal_graph.mbt`
- Modify: `internal/core/graph_types.mbt` (Frontier)
- Modify: `internal/core/version.mbt` (VersionVector — check if here or causal_graph)
- Modify: `internal/fugue/tree.mbt` or wherever `Lv`, `ReplicaId`, `Timestamp` are defined

**Step 1: Make `CausalGraph` fields private**

```moonbit
pub struct CausalGraph {
  priv mut entries : @hashmap.HashMap[Int, @core.GraphEntry]
  priv mut version_map : @hashmap.HashMap[@core.RawVersion, Int]
  priv mut next_lv : Int
  priv mut frontier : @core.Frontier
  priv mut agent_seqs : @hashmap.HashMap[String, Int]
}
```

**Step 2: Remove deprecated `inner()` methods**

Find and delete:
- `Frontier::inner(self) -> Array[Int]` (marked `#deprecated` in `core/graph_types.mbt`)
- `VersionVector::inner(self) -> Map[String, Int]` (marked `#deprecated`)
- `Lv::inner(self) -> Int` (marked `#deprecated` in `fugue/`)
- `ReplicaId::inner(self) -> String` (marked `#deprecated` in `fugue/`)
- `Timestamp::inner(self) -> Int` (marked `#deprecated` in `fugue/`)

Search first to confirm locations:

```bash
grep -rn "#deprecated" internal/
```

**Step 3: Fix any callers of deleted `inner()` methods**

```bash
moon check 2>&1 | grep "error"
```

Replace `.inner()` calls with direct field access or alternative accessor methods.

**Step 4: Run tests**

```bash
moon test
```

**Step 5: Commit**

```bash
git add internal/
git commit -m "refactor(internal): CausalGraph fields priv, remove deprecated inner() methods"
```

---

### Task 14: Make `Op` struct fields `priv` and add accessors; seal `UndoManager`

**Files:**
- Modify: `internal/core/operation.mbt`
- Modify: `undo/undo_manager.mbt`
- Modify: `undo/types.mbt`

**Step 1: Make `Op` fields private in `internal/core/operation.mbt`**

```moonbit
pub struct Op {
  priv lv : Int
  priv parents : Array[RawVersion]
  priv agent : String
  priv seq : Int
  priv content : OpContent
  priv origin_left : RawVersion?
  priv origin_right : RawVersion?
}
```

**Step 2: Add minimal accessor methods to `Op`**

These are needed by `text/undo_helpers.mbt`:

```moonbit
pub fn Op::lv(self : Op) -> Int { self.lv }
pub fn Op::agent(self : Op) -> String { self.agent }
```

**Step 3: Fix compilation errors**

```bash
moon check 2>&1 | grep "error"
```

Any code accessing `op.lv` or `op.agent` as fields (outside `internal/core/`) now needs to use the accessor methods.

**Step 4: Make `UndoManager` struct fields `priv`**

In `undo/undo_manager.mbt`:

```moonbit
pub struct UndoManager {
  priv agent_id : String
  priv mut undo_stack : Array[UndoGroup]
  priv mut redo_stack : Array[UndoGroup]
  priv capture_timeout_ms : Int
  priv mut last_change_ms : Int
  priv mut tracking_enabled : Bool
}
```

**Step 5: Make `UndoGroup` and `UndoItem` package-private**

In `undo/types.mbt`, change `pub struct UndoGroup` → `struct UndoGroup` and `pub struct UndoItem` → `struct UndoItem`. Also make their fields package-private or remove `pub` from them.

**Step 6: Run tests**

```bash
moon test
```

Expected: all tests pass.

**Step 7: Commit**

```bash
git add internal/core/ undo/
git commit -m "refactor: Op fields priv with accessors; seal UndoManager internals"
```

---

## Phase 5 — Final verification

### Task 15: Regenerate interfaces, format, full test run

**Step 1: Regenerate `.mbti` interface files**

```bash
moon info
```

**Step 2: Review `text/pkg.generated.mbti` for clean surface**

```bash
cat text/pkg.generated.mbti
```

Verify:
- No `@core.Op`, `@core.RawVersion`, `@core.Frontier` in any signature
- No `@causal_graph.VersionVector` in any signature
- No `@branch.Branch`, `@document.Document`, `@rle.Runs` in any signature
- `SyncMessage` has only `is_empty`, `op_count`, `Show`
- `TextDoc::insert` and `delete` return `Unit`
- No `from_document_error`, `from_oplog_error`, `from_branch_error` visible

**Step 3: Review `undo/pkg.generated.mbti`**

```bash
cat undo/pkg.generated.mbti
```

Verify:
- `UndoManager::undo` and `redo` return `Unit raise UndoError`
- `UndoGroup` and `UndoItem` are not visible
- No `@core.Op` or `@document.DocumentError` in any signature
- `Undoable` trait is present with `Unit`-returning methods

**Step 4: Run format**

```bash
moon fmt
```

**Step 5: Final full test run**

```bash
moon test
```

Expected: all tests pass.

**Step 6: Final commit**

```bash
git add .
git commit -m "chore: moon info + moon fmt after API hardening"
```

---

## Summary

| Phase | Tasks | What changes |
|---|---|---|
| 1 | 1-3 | 7 packages moved to `internal/`, all `moon.pkg` paths updated |
| 2 | 4-6 | `undo` gets `Undoable` + `UndoError`; `undo()`/`redo()` return `Unit` |
| 3 | 7-11 | `text` surface cleaned: `Unit` returns, leaky methods removed, `SyncMessage` sealed |
| 4 | 12-14 | Struct fields `priv`, deprecated `inner()` removed, `Op` sealed |
| 5 | 15 | `moon info`, `moon fmt`, full test run, MBTI review |

After completion, external library users can only import `text` and `undo`. No internal types appear anywhere in either package's public API.
