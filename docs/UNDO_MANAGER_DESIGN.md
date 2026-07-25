# UndoManager Design Plan for eg-walker CRDT

> **📚 DESIGN RECORD — some paths no longer match the shipped code.** This document describes the plan as drafted; the actual implementation diverged in a few places. Reader beware of the following:
> - The `Undoable` trait ships in `undo/undoable.mbt` (not `document/undoable.mbt`).
> - The shipped `Undoable` trait signatures diverge from this plan: `delete_lv` and `undelete_lv` return `CompensatingEditResult raise UndoError`, **not** `Unit raise UndoError` or `@oplog.Op raise DocumentError` as drafted below. Stale target classification is owned by the Document Module and mapped by the TextState Adapter.
> - The `undo/moon.pkg` snippet below lists `dowdiness/event-graph-walker/document` and `dowdiness/event-graph-walker/oplog` as imports; the actual `undo/moon.pkg` has no non-test imports.
> - The Phase 3 plan references `core/change.mbt` and a `Change` type. **Neither exists in the current tree** — the `Change` type was never created; `RawToLv` lives in `internal/core/traits.mbt`. This design item is **not implemented** despite the ✅ markers below. See `docs/decisions-needed.md`.
> - All MoonBit packages have been moved under `internal/` since this doc was written (e.g. `oplog/` → `internal/oplog/`, `fugue/` → `internal/fugue/`, `core/traits.mbt` → `internal/core/traits.mbt`). The shipped top-level facade packages are `text/`, `tree/`, `undo/`, and `container/`. No `document/` facade was ever created — references to `@document.*` in the body should be read as the implementation that now lives in `internal/document/` or as the `container/` facade.
>
> Phase 1 + Phase 2 shipped and are correct. Phase 3 (TypeScript wire-up, compaction) is unstarted. Verify against the source before implementing from this doc.

## Current shipped compensating-edit contract

The current source of truth is `undo/undoable.mbt`, `undo/undo_manager.mbt`,
`undo/types.mbt`, and `text/undoable_impl.mbt`:

```moonbit
pub(open) trait Undoable {
  fn delete_lv(Self, Int) -> CompensatingEditResult raise UndoError
  fn undelete_lv(Self, Int) -> CompensatingEditResult raise UndoError
}
```

`CompensatingEditResult::Applied` means a new CRDT operation was committed.
`CompensatingEditResult::Stale` means the requested direction was already
satisfied and no CRDT operation or sync delta was emitted. `UndoManager` does
not inspect positions, tombstones, or Fugue details. Target classification is
owned by the Document Module and mapped by the TextState Adapter.

`UndoManager::undo` and `UndoManager::redo` return `Bool`: `true` means at
least one compensating edit was applied; `false` means the stack was empty or
the popped group was entirely stale. Internal failures restore tracking, clear
both local history stacks, propagate the error, and do not roll back already
committed CRDT operations. The obsolete `UndoError::ItemNotFound` compatibility
variant has been retired; stale targets use `CompensatingEditResult::Stale`.

The implementation steps below are retained as historical design rationale;
when they conflict with the current contract above or the source, the source
wins.

## Overview

Add an LV-based UndoManager as a **separate `undo/` package** in `event-graph-walker/` that plugs into `TextState` via a small `Undoable` trait. Solves P2-1 (remote ops polluting undo stack) and P2-2 (stale positions after concurrent edits).

## Key Design Decisions

- **Separate package** — `event-graph-walker/undo/` as a plugin that imports `document/` + `oplog/` only. TextState adds a small `Undoable` impl, no direct access to `FugueTree` from undo.
- **LV-based tracking** — Operations tracked by **target element LV** (the inserted/deleted item's ID), not cursor position or operation LV
- **Tombstone revival** — Undoing a delete revives the tombstone (`deleted = false`). Character reappears at its exact original position even after concurrent edits.
- **Global undo (Phase 2 implemented)** — Undo/redo generate real ops that sync to peers. Undo-insert creates a `Delete` op, undo-delete creates an `Undelete` op. Both are added to the oplog and can be synced via `SyncSession`.

## Package Structure

The following sketch is historical. The shipped `Undoable` trait is in
`undo/undoable.mbt`; the Phase 3 `Change` helper shown below is not implemented.
Current paths in the source and generated `.mbti` files are authoritative.

```
event-graph-walker/
├── undo/                    ← NEW PACKAGE
│   ├── moon.pkg.json
│   ├── undo_manager.mbt     # UndoManager type and core logic
│   ├── types.mbt            # UndoGroup, UndoItem, UndoOpType
│   ├── undo_manager_test.mbt
│   └── undo_manager_wbtest.mbt  (if whitebox tests needed)
│
│   (depends on document/ + oplog/)
├── fugue/
│   ├── item.mbt             # +mark_visible()
│   └── tree.mbt             # +undelete(), +lv_to_position()
├── text/
│   └── types.mbt            # +Undoable impl
├── core/
│   ├── change.mbt           # unimplemented Phase 3 Change plan
│   └── traits.mbt           # historical RawToLv location
├── document/
│   └── undoable.mbt          # historical location; not shipped
│
│   (core/change.mbt is unimplemented; RawToLv ships in internal/core/traits.mbt)
│   (document/undoable.mbt is historical; Undoable ships in undo/undoable.mbt)
│   (text/: implements Undoable for TextState through the shipped Adapter)
│   (undo/: generic over Undoable, no text/ dependency)
└── ...
```

### `undo/moon.pkg`

```json
{
  "is_main": false,
  "import": [
    "dowdiness/event-graph-walker/document",
    "dowdiness/event-graph-walker/oplog"
  ],
  "test-import": [
    "dowdiness/event-graph-walker/text",
    "moonbitlang/core/quickcheck"
  ]
}
```

## Implementation Steps

### Step 0: `undo/undoable.mbt` — shipped Undoable trait

The shipped trait is intentionally small. It exposes compensating-edit intent,
not positions, tombstones, or CRDT operation payloads.

```moonbit
pub(open) trait Undoable {
  fn delete_lv(Self, Int) -> CompensatingEditResult raise UndoError
  fn undelete_lv(Self, Int) -> CompensatingEditResult raise UndoError
}
```

**File:** `event-graph-walker/undo/undoable.mbt`

### Step 1: `fugue/item.mbt` — Add `mark_visible()`

Inverse of `mark_deleted()` (line 74). Returns new Item with `deleted: false`.

```moonbit
///|
/// Mark item as visible (revive tombstone)
fn Item::mark_visible(self : Item) -> Item {
  { ..self, deleted: false }
}
```

**File:** `event-graph-walker/fugue/item.mbt` (after line 76)

### Step 2: `fugue/tree.mbt` — Add `undelete()` and `lv_to_position()`

**`undelete(id)`** — Revives tombstone. Mirrors `delete()` (line 113). Idempotent.

```moonbit
///|
/// Undelete an item (revive tombstone)
pub fn FugueTree::undelete(self : FugueTree, id : Int) -> Unit raise FugueError {
  match self[id] {
    Some(item) => {
      if item.deleted {
        let visible_item = item.mark_visible()
        self.items = self.items.add(id, visible_item)
      }
    }
    None => raise FugueError::MissingItem(id~)
  }
}
```

**`lv_to_position(id)`** — Finds 0-based visible position of an LV. O(n), consistent with existing `position_to_lv` in `document.mbt:59`.

```moonbit
///|
/// Find visible position of an item by LV.
/// Returns None if deleted or missing.
pub fn FugueTree::lv_to_position(self : FugueTree, id : Int) -> Int? {
  let visible = self.get_visible_items()
  for i = 0; i < visible.length(); i = i + 1 {
    let (lv, _) = visible[i]
    if lv == id {
      return Some(i)
    }
  }
  None
}
```

**File:** `event-graph-walker/fugue/tree.mbt` (after line 121)

### Step 3a: `core/traits.mbt` — NEW: `RawToLv` trait

```moonbit
///| Trait for resolving RawVersion (agent, seq) to LV.
///  Implemented by Document (has access to oplog graph).
pub(open) trait RawToLv {
  raw_to_lv(Self, @causal_graph.RawVersion) -> Int?
}
```

**File:** `event-graph-walker/internal/core/traits.mbt` (shipped)

### Step 3b: `core/change.mbt` — Unimplemented Phase 3 plan

`Change` and `Change::target_lv` were planned but are not shipped. Do not use
this section as an implementation reference.

```moonbit
///|
/// Get the target element LV for undo tracking.
/// For Insert: the inserted item's LV (same as op.lv).
/// For Delete: must look up the deleted item's LV from the RawVersion via oplog.
/// This requires access to the document's oplog graph.
pub fn[R : RawToLv] Change::target_lv(self : Change, resolver : R) -> Int? {
  match self.op.content {
    Insert(_) => Some(self.op.lv)
    Delete =>
      match self.op.origin_left {
        None => None
        Some(raw) => resolver.raw_to_lv(raw)
      }
  }
}

///|
/// Get the agent ID that created this change.
pub fn Change::agent(self : Change) -> String {
  self.op.agent
}
```

**File:** `event-graph-walker/core/change.mbt` (not present; unimplemented plan)

**Note:** `Change::target_lv(resolver)` is safe and returns `None` if the delete target cannot be resolved (missing origin or unknown RawVersion). The resolver is implemented by `Document` via `@core.RawToLv`.

The `TextState` Adapter lives in `text/` because it accesses private fields.
It maps the Document Module's applied/stale result to the Undoable result and
maps unexpected Document failures to `UndoError::Internal`.

```moonbit
pub impl @undo.Undoable for TextState with fn delete_lv(self, lv) {
  let result = self.inner.delete_if_visible(lv) catch {
    _ => raise @undo.UndoError::Internal(detail="document error during delete_lv")
  }
  map_target_edit_result(result)
}

pub impl @undo.Undoable for TextState with fn undelete_lv(self, lv) {
  let result = self.inner.undelete_if_deleted(lv) catch {
    _ => raise @undo.UndoError::Internal(detail="document error during undelete_lv")
  }
  map_target_edit_result(result)
}
```

### Step 4: `undo/types.mbt` — NEW: UndoGroup, UndoItem

```moonbit
///| Types for undo/redo tracking

///|
pub enum UndoOpType {
  Insert
  Delete
} derive(Show, Eq)

///|
/// A single tracked operation.
/// `target_lv` is the LV of the element being inserted/deleted (NOT the op LV).
/// For inserts: the inserted item's LV.
/// For deletes: the deleted item's LV (the tombstone to revive on undo).
pub struct UndoItem {
  target_lv : Int
  op_type : UndoOpType
  content : String?     // Insert: the inserted text; Delete: deleted char (if known)
} derive(Show)

///|
/// A group of operations undone/redone together
pub struct UndoGroup {
  items : Array[UndoItem]
  timestamp : Int
} derive(Show)
```

**File:** `event-graph-walker/undo/types.mbt` (NEW)

### Step 5: `undo/undo_manager.mbt` — NEW: Core logic

```moonbit
///| UndoManager - LV-based undo/redo plugin, generic over Undoable

pub struct UndoManager {
  agent_id : String
  mut undo_stack : Array[UndoGroup]
  mut redo_stack : Array[UndoGroup]
  capture_timeout_ms : Int
  mut last_change_ms : Int
  mut tracking_enabled : Bool
} derive(Show)
```

**Methods:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `new` | `(agent_id, capture_timeout_ms?: Int) -> UndoManager` | Constructor, default timeout 500ms |
| `record_insert` | `(target_lv: Int, agent: String, timestamp_ms: Int, content?: String) -> Unit` | Record insert. `target_lv` is the inserted item's LV. Filters by agent (only records if agent matches `self.agent_id`). Groups by inactivity (time since last edit). Clears redo stack. |
| `record_delete` | `(target_lv: Int, agent: String, timestamp_ms: Int, content?: String) -> Unit` | Record delete. `target_lv` is the deleted item's LV (the tombstone). Filters by agent (only records if agent matches `self.agent_id`). Groups by inactivity (time since last edit). Clears redo stack. |
| `undo` | `[D : @undo.Undoable](self, doc: D) -> Bool raise UndoError` | Apply compensating edits, push only Applied results to redo, and return whether anything changed. Use `export_since()` after this call to sync. |
| `redo` | `[D : @undo.Undoable](self, doc: D) -> Bool raise UndoError` | Reapply compensating edits, push only Applied results to undo, and return whether anything changed. Use `export_since()` after this call to sync. |
| `set_tracking` | `(enabled: Bool) -> Unit` | Suppress/resume tracking |
| `is_tracking` | `() -> Bool` | Query tracking state |
| `can_undo` | `() -> Bool` | Undo stack non-empty |
| `can_redo` | `() -> Bool` | Redo stack non-empty |
| `clear` | `() -> Unit` | Reset both stacks |

The text integration layer (which sees `Change` and doc internals) is responsible for extracting the correct `target_lv` and calling `record_insert`/`record_delete`. This keeps `undo/` generic.

**Multi-char insert handling:** `TextState::insert("Hello")` internally generates 5 separate ops (one per char) and returns `Unit`. To track all chars, the integration helper inserts one character at a time and records each LV individually.

Convenience methods (`insert_and_record`, `delete_and_record`) are not on
UndoManager itself because they require TextState-specific methods (`insert`,
`delete`) that are outside the `Undoable` trait. These live in `text/` (which
imports both `text/` types and `undo/`).

**`text/undo_helpers.mbt`** — NEW: Integration helpers

```moonbit
///|
/// Insert text and record each character's LV for undo tracking.
/// Each character is inserted individually so its LV is captured.
/// Time grouping in UndoManager batches them into a single undo group
/// based on time since the last edit.
pub fn TextState::insert_and_record(
  self : TextState,
  pos : Pos,
  text : String,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  for i = 0; i < text.length(); i = i + 1 {
    let ch = text[i:i + 1].to_string() catch { _ => continue }
    // Capture the next LV before inserting so we know which item was created
    let lv = self.inner.next_lv()
    self.insert(Pos::at(pos.value() + i), ch)!
    mgr.record_insert(lv, self.agent_id, timestamp_ms, content=ch)
  }
}

///|
/// Delete a character and record its target LV for undo tracking.
/// Looks up the deleted item's LV and content before deletion.
pub fn TextState::delete_and_record(
  self : TextState,
  pos : Pos,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  // Look up the target LV and content before deleting
  let items = self.inner.get_visible_items()
  guard pos.value() < items.length() else { raise TextError::OutOfBounds }
  let (target_lv, item) = items[pos.value()]
  let content = Some(item.content)
  self.delete(pos)!
  mgr.record_delete(target_lv, self.agent_id, timestamp_ms, content~)
}
```

**File:** `event-graph-walker/text/undo_helpers.mbt` (NEW)

**Requires** `text/moon.pkg.json` to add `undo` to imports.

**Note:** Per-character insertion via `TextState::insert` is equivalent to
`Document::insert("Hello")` in terms of origin tracking — `Document::insert`
already resolves origins per-character in its internal loop (document.mbt:97-138).
The per-character approach just makes each LV accessible for recording.

**Undo algorithm (shipped):**

```moonbit
undo[D : @undo.Undoable](self, doc: D) -> Bool raise UndoError:
  group = undo_stack.pop()
  suppress tracking
  for item in group.items (reverse order):
    result = doc.delete_lv(item.target_lv) or doc.undelete_lv(item.target_lv)
    if result == Applied: collect the opposite history item
    if result == Stale: skip without emitting an operation
  if any item was Applied: push the opposite group to redo_stack
  restore tracking
  return whether anything was Applied
```

An `Internal` failure restores tracking, clears both local history stacks, and
propagates without rolling back already-committed CRDT operations. Stale groups
are consumed without creating opposite history. Redo is the mirror image and
uses the same result contract.

**Syncing undo ops:** After calling `undo`/`redo`, use `export_since()` to capture the inverse operations that were just applied, then send that message to peers via `SyncSession`. Example:
```moonbit
let ver_before = doc.version()
mgr.undo(doc)
let msg = doc.sync().export_since(ver_before)
// Send msg to peers
```

**File:** `event-graph-walker/undo/undo_manager.mbt` (NEW)

### Step 6: `undo/undo_manager_test.mbt` — Tests

1. Basic undo insert: insert "H", undo → text empty
2. Basic undo delete: insert "H", delete, undo → text "H" (tombstone revival)
3. Undo-redo roundtrip: insert "H", undo, redo → text "H"
4. Redo cleared on new edit: insert "H", undo, insert "X" → redo empty
5. Time grouping: insert "abc" within 500ms, undo once → all removed
6. Time grouping split: insert "a" at t=0, "b" at t=1000, undo → only "b" removed
7. Time grouping continuous typing: edits spaced <500ms apart for >500ms total → one group
8. Per-agent filtering: agent A inserts and calls `record_insert`, agent B's remote ops arrive via `doc.sync().apply()` (not recorded), undo only affects A's ops
9. Suppress tracking: disable tracking, insert, verify undo stack empty
10. Concurrent resilience: A inserts "abc", B inserts "XY" between a/b (remote), A undoes → correct text
11. Undo of already-deleted item: item deleted by remote peer → `lv_to_position` returns `None` → no-op

**File:** `event-graph-walker/undo/undo_manager_test.mbt` (NEW)

### Step 7: Verify

```bash
cd event-graph-walker
moon check
moon test
moon info
moon fmt
git diff *.mbti  # verify shipped API changes; RawToLv is in internal/core and Change is not shipped
```

## Usage Example

```moonbit
let doc = @text.TextState::new("alice")
let mgr = @undo.UndoManager::new("alice")

// Insert with tracking — helper records each char's LV
doc.insert_and_record(@text.Pos::at(0), "Hello", mgr, timestamp_ms=1000)

// Delete with tracking — helper looks up content before deleting
doc.delete_and_record(@text.Pos::at(4), mgr, timestamp_ms=2000)

// Remote op — apply directly; no set_tracking needed.
// sync().apply() never calls record_insert/record_delete,
// so remote ops are never recorded regardless of the tracking flag.
// (set_tracking is only needed if you call record_insert/record_delete manually
// and want to temporarily suppress them.)
doc.sync().apply(remote_message)

// Undo — returns Bool. Tracking is suppressed automatically during undo/redo.
// Export a sync delta only when at least one edit was applied.
let ver_before = doc.version()
if mgr.undo(doc) {
  let msg = doc.sync().export_since(ver_before)
  // peer.sync().apply(msg)
}
```

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Undo insert already deleted by remote | The Adapter returns `Stale`; no operation is emitted and nothing is pushed to redo. |
| Undo delete of concurrently deleted item | `undelete_if_deleted` applies an Undelete operation and the local user's intent wins. |
| Already-visible undelete target | The Adapter returns `Stale`; no operation is emitted. |
| Multi-char insert | `insert_and_record` inserts per-char, records each LV. Time grouping batches them into one undo group. |
| Double undo/redo | Stacks transfer correctly. Tracking is suppressed during undo/redo. |
| Error during undo/redo | Tracking is restored, both local history stacks are cleared, and the Internal error propagates. |
| Structurally missing target | The Adapter raises `Internal`; it is not treated as stale. |
| Synced edit after undo | No intent drift — undo ops are synced to peers, all replicas converge. |

## File Summary

| File | Action | ~Lines |
|------|--------|--------|
| `event-graph-walker/undo/moon.pkg` | Create | 12 |
| `event-graph-walker/undo/types.mbt` | Create | ~30 |
| `event-graph-walker/undo/undo_manager.mbt` | Create | ~250 |
| `event-graph-walker/undo/undo_manager_test.mbt` | Create | ~200 |
| `event-graph-walker/document/undoable.mbt` | Historical plan only | — |
| `event-graph-walker/fugue/item.mbt` | Modify | +4 |
| `event-graph-walker/fugue/tree.mbt` | Modify | +25 |
| `event-graph-walker/core/change.mbt` | Unimplemented Phase 3 plan | — |
| `event-graph-walker/core/traits.mbt` | Historical plan; shipped under `internal/core/traits.mbt` | ~8 |
| `event-graph-walker/text/types.mbt` | Modify | +? (Undoable impl for TextState) |
| `event-graph-walker/text/undo_helpers.mbt` | Create | ~40 (insert_and_record, delete_and_record) |
| `event-graph-walker/text/moon.pkg.json` | Modify | +1 (add undo import) |

## Implementation Status (as of 2026-02-01)

**Phase 1 (local-only undo/redo):** ✅ Complete
- ✅ `RawToLv` ships under `internal/core/traits.mbt`; the planned `Change` type remains unimplemented
- ✅ `undo/undoable.mbt` trait added (originally planned at `document/undoable.mbt`; relocated to the `undo/` package during implementation)
- ✅ `Document` implements the shipped `@core.RawToLv` trait
- ✅ `fugue` tombstone revive + LV lookup (`mark_visible`, `undelete`, `lv_to_position`)
- ✅ `text` implements `Undoable` for `TextState`
- ✅ `text/undo_helpers.mbt` with `insert_and_record` + `delete_and_record`
- ✅ `undo` package (`types.mbt`, `undo_manager.mbt`, `undo_manager_test.mbt`)
- ✅ Time grouping uses **time since last edit** (continuous typing stays one group)
- ✅ Tests updated/added for grouping, redo, agent filtering, etc.

**Phase 2 (synced undo/redo):** ✅ Complete
- ✅ `OpContent::Undelete` variant added to `oplog/operation.mbt`
- ✅ `Op::new_undelete`, `Op::is_undelete`, `Op::get_delete_target` added
- ✅ `Document::undelete`, `Document::delete_by_lv` added (return ops)
- ✅ `Document::apply_remote` handles `Undelete` ops
- ✅ `Undoable` trait methods return `CompensatingEditResult` (not operation payloads)
- ✅ `UndoManager.undo()`/`redo()` return whether any compensating edit was applied; callers sync with `export_since()`
- ✅ `branch/` handles `Undelete` in apply and merge
- ✅ Tests: `undo-insert generates Delete op`, `undo-delete generates Undelete op`, `undo ops can be applied to peer`

### Phase 2 Implementation Summary

> Paths in this table are the as-shipped locations after the package
> reorganization (everything below `oplog/`, `document/`, `branch/` now lives
> under `internal/`).

| Step | File | Status |
|------|------|--------|
| 1. Add `Undelete` variant | `internal/core/operation.mbt` | ✅ |
| 2. Add `Op::new_undelete` | `internal/core/operation.mbt` | ✅ |
| 3. Add `Op::is_undelete`, `Op::get_delete_target` | `internal/core/operation.mbt` | ✅ |
| 4. `Document::undelete`, `Document::delete_by_lv` | `internal/document/document.mbt` | ✅ |
| 5. Handle in `apply_remote` | `internal/document/document.mbt` | ✅ |
| 6. Handle in branch apply/merge | `internal/branch/branch.mbt`, `internal/branch/branch_merge.mbt` | ✅ |
| 7. Serialize/deserialize | `internal/core/operation.mbt` | ✅ (derived) |
| 8. Update `UndoManager.undo()`/`redo()` | `undo/undo_manager.mbt` | ✅ |
| 9. Update `Undoable` trait | `undo/undoable.mbt` | ✅ |
| 10. Sync integration tests | `undo/undo_manager_test.mbt`, `text/text_test.mbt` | ✅ |
| 11. Retire `ItemNotFound` compatibility plumbing | `undo/types.mbt`, `undo/undo_manager.mbt` | ✅ |

### Conflict Resolution Semantics

When `Delete` and `Undelete` are concurrent (neither causally precedes the other):

| Semantics | Behavior | Pros | Cons |
|-----------|----------|------|------|
| **LWW (Last Writer Wins)** | Higher op LV wins | Simple, deterministic | Arbitrary winner |
| **Add-wins** | Undelete always wins | User-friendly (data preserved) | May resurrect unwanted content |
| **Remove-wins** | Delete always wins | Safe (no surprise data) | Undo feels broken |
| **Multi-value** | Keep both states, resolve later | Flexible | Complex UI needed |

**Recommendation:** Add-wins — matches user expectation that "undo should work."

### `OpContent` After Phase 2

```moonbit
pub enum OpContent {
  Insert(String)
  Delete
  Undelete  // Revive a previously deleted character
} derive(Eq, Show, FromJson, ToJson)
```

**Note:** `Undelete` carries no payload. The target tombstone is identified via
the `origin_left` field of the enclosing `Op`, consistent with how `Delete`
identifies its target. The design doc originally proposed `Undelete(Int)` but
the implementation uses the existing `origin_left` mechanism instead.

### `UndoManager.undo()` Return Value

`undo()` and `redo()` return `Bool`: `true` if at least one compensating edit
was applied, otherwise `false` for an empty or entirely stale group. Their
`Undoable` methods return `CompensatingEditResult`, not CRDT operation payloads.
The Document writes any applied operation to its own OpLog, and peers receive
it through `export_since()`.

### Effort Estimate

~1 day with LWW/add-wins semantics. Longer if multi-value or complex conflict UI needed.

## Phase 3 (Future)

- Implement the planned `Change` / `Change::target_lv` helper only if a concrete consumer requires it; it is currently unimplemented.
- Property-based tests for undo-redo roundtrip invariants across concurrent edits
- Wire up to valtio module's TypeScript API (replace broken position-based undo)
- Compaction/GC support (handle tombstone removal + undo interaction)
