# UndoManager Design Plan for eg-walker CRDT

## Overview

Add an LV-based UndoManager as a **separate `undo/` package** in `event-graph-walker/` that plugs into `TextDoc` via a small `Undoable` trait. Solves P2-1 (remote ops polluting undo stack) and P2-2 (stale positions after concurrent edits).

## Key Design Decisions

- **Separate package** — `event-graph-walker/undo/` as a plugin that imports `document/` + `oplog/` only. TextDoc adds a small `Undoable` impl, no direct access to `FugueTree` from undo.
- **LV-based tracking** — Operations tracked by **target element LV** (the inserted/deleted item's ID), not cursor position or operation LV
- **Tombstone revival** — Undoing a delete revives the tombstone (`deleted = false`). Character reappears at its exact original position even after concurrent edits.
- **Global undo (Phase 2 implemented)** — Undo/redo generate real ops that sync to peers. Undo-insert creates a `Delete` op, undo-delete creates an `Undelete` op. Both are added to the oplog and can be synced via `SyncSession`.

## Package Structure

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
│   └── types.mbt            # +Undoable impl, re-export @core.Change
├── core/
│   ├── change.mbt           # Change type + safe target_lv(resolver)
│   └── traits.mbt           # RawToLv trait
├── document/
│   └── undoable.mbt          # NEW: Undoable trait (minimal host API)
│
│   (core/: defines Change + RawToLv)
│   (document/: defines Undoable, uses DocumentError + @oplog.Op + Int)
│   (text/: implements Undoable for TextDoc, bridges Pos/@core.Change -> Int/Op and TextError -> DocumentError)
│   (undo/: generic over Undoable, no text/ dependency)
└── ...
```

### `undo/moon.pkg.json`

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

### Step 0: `document/undoable.mbt` — NEW: Undoable trait

Minimal host API needed by UndoManager. Uses MoonBit trait method signatures (no `fn`).

```moonbit
///| Minimal host API needed by UndoManager.
///  Uses only document-level types to avoid circular dependency
///  (document/ cannot import text/ since text/ already imports document/).
///  Mutating methods take `Self` (MoonBit structs are reference types).
pub(open) trait Undoable {
  lv_to_position(Self, Int) -> Int?
  undelete_lv(Self, Int) -> @oplog.Op raise DocumentError
  delete_lv(Self, Int) -> @oplog.Op raise DocumentError
}
```

**File:** `event-graph-walker/document/undoable.mbt` (NEW)

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

**File:** `event-graph-walker/core/traits.mbt` (NEW)

### Step 3b: `core/change.mbt` — Move `Change` + add safe `target_lv`

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

**File:** `event-graph-walker/core/change.mbt` (NEW)

**Note:** `Change::target_lv(resolver)` is safe and returns `None` if the delete target cannot be resolved (missing origin or unknown RawVersion). The resolver is implemented by `Document` via `@core.RawToLv`.

Add `Undoable` impl for `TextDoc` (exact internals may vary). This impl must live
in `text/` because it accesses TextDoc private fields.

```moonbit
///| Undoable impl for TextDoc
///  Lives in text/ package where TextDoc's private fields are accessible.
///|
pub impl @document.Undoable for TextDoc with lv_to_position(self, lv) {
  self.inner.tree.lv_to_position(lv)
}

///|
pub impl @document.Undoable for TextDoc with undelete_lv(self, lv) {
  self.inner.undelete(lv) catch {
    e => raise e
  }
}

///|
pub impl @document.Undoable for TextDoc with delete_lv(self, lv) {
  self.inner.delete_by_lv(lv) catch {
    e => raise e
  }
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
| `undo` | `[D : @document.Undoable](self, doc: D) -> Array[@oplog.Op] raise @document.DocumentError` | Pop undo group, apply inverses locally, push to redo. Returns ops to sync (empty in Phase 1, populated in Phase 2). |
| `redo` | `[D : @document.Undoable](self, doc: D) -> Array[@oplog.Op] raise @document.DocumentError` | Pop redo group, apply inverses locally, push to undo. Returns ops to sync (empty in Phase 1, populated in Phase 2). |
| `set_tracking` | `(enabled: Bool) -> Unit` | Suppress/resume tracking |
| `is_tracking` | `() -> Bool` | Query tracking state |
| `can_undo` | `() -> Bool` | Undo stack non-empty |
| `can_redo` | `() -> Bool` | Redo stack non-empty |
| `clear` | `() -> Unit` | Reset both stacks |

The text integration layer (which sees `Change` and doc internals) is responsible for extracting the correct `target_lv` and calling `record_insert`/`record_delete`. This keeps `undo/` generic.

**Multi-char insert handling:** `TextDoc::insert("Hello")` internally generates 5 separate ops (one per char), but returns a single `Change` for the last op. To track all chars, the integration helper inserts one character at a time and records each LV individually.

Convenience methods (`insert_and_record`, `delete_and_record`) are not on
UndoManager itself because they require TextDoc-specific methods (`insert`,
`delete`) that are outside the `Undoable` trait. These live in `text/` (which
imports both `text/` types and `undo/`).

**`text/undo_helpers.mbt`** — NEW: Integration helpers

```moonbit
///|
/// Insert text and record each character's LV for undo tracking.
/// Each character is inserted individually so its LV is captured.
/// Time grouping in UndoManager batches them into a single undo group
/// based on time since the last edit.
pub fn TextDoc::insert_and_record(
  self : TextDoc,
  pos : Pos,
  text : String,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  let doc = self.inner_document()
  for i = 0; i < text.length(); i = i + 1 {
    let ch = text[i:i + 1].to_string() catch { _ => continue }
    let change = self.insert(Pos::at(pos.value() + i), ch)!
    match change.target_lv(doc) {
      Some(lv) => mgr.record_insert(lv, change.agent(), timestamp_ms, content=ch)
      None => ()  // unreachable for local inserts
    }
  }
}

///|
/// Delete a character and record its target LV for undo tracking.
/// Looks up the deleted item's content before deletion for redo display.
pub fn TextDoc::delete_and_record(
  self : TextDoc,
  pos : Pos,
  mgr : @undo.UndoManager,
  timestamp_ms~ : Int,
) -> Unit raise TextError {
  let doc = self.inner_document()
  // Look up content before deleting (pos is already 0-based visible position)
  let items = self.inner.tree.get_visible_items()
  let content = if pos.value() < items.length() {
    Some(items[pos.value()].1.content)
  } else {
    None
  }
  let change = self.delete(pos)!
  match change.target_lv(doc) {
    Some(lv) => mgr.record_delete(lv, change.agent(), timestamp_ms, content~)
    None => ()
  }
}
```

**File:** `event-graph-walker/text/undo_helpers.mbt` (NEW)

**Requires** `text/moon.pkg.json` to add `undo` to imports.

**Note:** Per-character insertion via `TextDoc::insert` is equivalent to
`Document::insert("Hello")` in terms of origin tracking — `Document::insert`
already resolves origins per-character in its internal loop (document.mbt:97-138).
The per-character approach just makes each LV accessible for recording.

**Undo algorithm (Phase 2 — global sync):**

```
undo[D : @document.Undoable](self, doc: D) -> Array[@oplog.Op]:
  group = undo_stack.pop()
  suppress tracking (use guard/defer to ensure restore on error)
  synced_ops = []        // ops to sync to peers
  redo_items = []
  for item in group.items (reverse order):
    try:
      if item.op_type == Insert:
        pos = doc.lv_to_position(item.target_lv)
        if pos != None:
          op = doc.delete_lv(item.target_lv)   # creates Delete op via Document::delete_by_lv
          synced_ops.push(op)
          redo_items.push({ target_lv: item.target_lv, op_type: Insert, content: item.content })
        // If pos == None, item already deleted by remote — skip, don't push to redo
      if item.op_type == Delete:
        op = doc.undelete_lv(item.target_lv)   # creates Undelete op via Document::undelete
        synced_ops.push(op)
        redo_items.push({ target_lv: item.target_lv, op_type: Delete, content: item.content })
    catch MissingItem:
      // Item was GC'd or compacted — skip silently, don't push to redo
      continue
  if redo_items.length() > 0:
    redo_stack.push(reversed redo_items)
  resume tracking
  return synced_ops      // Delete/Undelete ops to sync with peers
```

 **Error handling:** Per-item try/catch ensures one bad item doesn't corrupt the entire group. Missing items (due to GC/compaction) are skipped silently. Only successfully applied items are pushed to redo.
Match missing items as `DocumentError::Fugue(FugueError::MissingItem(_))` since `Undoable` methods raise `DocumentError`.

**Redo is the mirror image:** Insert items → `doc.undelete_lv(target_lv)` (returns `Undelete` op), Delete items → `doc.delete_lv(target_lv)` (returns `Delete` op). Both generate ops to sync. Only push to undo stack if action succeeded.

**Syncing undo ops:** The returned `Array[@oplog.Op]` should be sent to peers via `SyncSession`. Example:
```moonbit
let undo_ops = mgr.undo(doc)!
let msg = @text.SyncMessage::new(undo_ops, doc.sync().export_all().get_heads())
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
git diff *.mbti  # verify API changes: fugue/ gets undelete+lv_to_position, core/ gets Change + RawToLv
```

## Usage Example

```moonbit
let doc = @text.TextDoc::new("alice")
let mgr = @undo.UndoManager::new("alice")

// Insert with tracking — helper records each char's LV
doc.insert_and_record(@text.Pos::at(0), "Hello", mgr, timestamp_ms=1000)!

// Delete with tracking — helper looks up content before deleting
doc.delete_and_record(@text.Pos::at(4), mgr, timestamp_ms=2000)!

// Remote op — suppress tracking
mgr.set_tracking(false)
doc.sync().apply(remote_message)!
mgr.set_tracking(true)

// Undo — returns Delete/Undelete ops to sync with peers
let undo_ops = mgr.undo(doc)!
// Send ops to peers via SyncSession
let msg = @text.SyncMessage::new(undo_ops, doc.sync().export_all().get_heads())
// peer.sync().apply(msg)!
```

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Undo insert already deleted by remote | `lv_to_position` → `None` → skip, don't push to redo (already gone) |
| Undo delete of concurrently deleted item | `undelete` revives it — local user's intent wins |
| Multi-char insert | `insert_and_record` inserts per-char, records each LV. Time grouping batches them into one undo group. |
| Double undo/redo | Stacks transfer correctly. Tracking suppressed during undo/redo. |
| Error during undo/redo | Per-item try/catch skips bad items; guard/defer restores `tracking_enabled` |
| Item GC'd/compacted | `MissingItem` caught, item skipped, redo stack only gets successful items |
| Synced edit after undo | No intent drift — undo ops are synced to peers, all replicas converge. |

## File Summary

| File | Action | ~Lines |
|------|--------|--------|
| `event-graph-walker/undo/moon.pkg.json` | Create | 12 |
| `event-graph-walker/undo/types.mbt` | Create | ~30 |
| `event-graph-walker/undo/undo_manager.mbt` | Create | ~250 |
| `event-graph-walker/undo/undo_manager_test.mbt` | Create | ~200 |
| `event-graph-walker/document/undoable.mbt` | Create | ~10 |
| `event-graph-walker/fugue/item.mbt` | Modify | +4 |
| `event-graph-walker/fugue/tree.mbt` | Modify | +25 |
| `event-graph-walker/core/change.mbt` | Create | ~40 |
| `event-graph-walker/core/traits.mbt` | Create | ~8 |
| `event-graph-walker/text/types.mbt` | Modify | +? (remove Change, re-export @core.Change + Undoable impl) |
| `event-graph-walker/text/undo_helpers.mbt` | Create | ~40 (insert_and_record, delete_and_record) |
| `event-graph-walker/text/moon.pkg.json` | Modify | +1 (add undo import) |

## Implementation Status (as of 2026-02-01)

**Phase 1 (local-only undo/redo):** ✅ Complete
- ✅ `core/` package added (`Change`, `RawToLv`)
- ✅ `document/undoable.mbt` trait added
- ✅ `Document` implements `@core.RawToLv`
- ✅ `fugue` tombstone revive + LV lookup (`mark_visible`, `undelete`, `lv_to_position`)
- ✅ `text` implements `Undoable` for `TextDoc`
- ✅ `text/undo_helpers.mbt` with `insert_and_record` + `delete_and_record`
- ✅ `undo` package (`types.mbt`, `undo_manager.mbt`, `undo_manager_test.mbt`)
- ✅ Time grouping uses **time since last edit** (continuous typing stays one group)
- ✅ Tests updated/added for grouping, redo, agent filtering, etc.

**Phase 2 (synced undo/redo):** ✅ Complete
- ✅ `OpContent::Undelete` variant added to `oplog/operation.mbt`
- ✅ `Op::new_undelete`, `Op::is_undelete`, `Op::get_delete_target` added
- ✅ `Document::undelete`, `Document::delete_by_lv` added (return ops)
- ✅ `Document::apply_remote` handles `Undelete` ops
- ✅ `Undoable` trait methods return `@oplog.Op` (not `Unit`)
- ✅ `UndoManager.undo()`/`redo()` collect and return synced ops
- ✅ `branch/` handles `Undelete` in apply and merge
- ✅ Tests: `undo-insert generates Delete op`, `undo-delete generates Undelete op`, `undo ops can be applied to peer`

### Phase 2 Implementation Summary

| Step | File | Status |
|------|------|--------|
| 1. Add `Undelete` variant | `oplog/operation.mbt` | ✅ |
| 2. Add `Op::new_undelete` | `oplog/operation.mbt` | ✅ |
| 3. Add `Op::is_undelete`, `Op::get_delete_target` | `oplog/operation.mbt` | ✅ |
| 4. `Document::undelete`, `Document::delete_by_lv` | `document/document.mbt` | ✅ |
| 5. Handle in `apply_remote` | `document/document.mbt` | ✅ |
| 6. Handle in branch apply/merge | `branch/branch.mbt`, `branch/branch_merge.mbt` | ✅ |
| 7. Serialize/deserialize | `oplog/operation.mbt` | ✅ (derived) |
| 8. Update `UndoManager.undo()`/`redo()` | `undo/undo_manager.mbt` | ✅ |
| 9. Update `Undoable` trait | `document/undoable.mbt` | ✅ |
| 10. Sync integration tests | `undo/undo_manager_test.mbt` | ✅ |

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
  Undelete(Int)  // target_lv of the tombstone to revive
} derive(Eq, Show, FromJson, ToJson)
```

### `UndoManager.undo()` Return Value — No API Break

The return type `Array[@oplog.Op]` is established in Phase 1 (always empty). Phase 2 populates it — no signature change needed. The `Undoable` trait changes: `undelete_lv` returns `@oplog.Op` instead of `Unit`, and `delete_lv` also returns `@oplog.Op`.

```moonbit
///| Phase 2 Undoable trait (updated signatures)
pub(open) trait Undoable {
  lv_to_position(Self, Int) -> Int?
  undelete_lv(Self, Int) -> @oplog.Op raise DocumentError  // was Unit
  delete_lv(Self, Int) -> @oplog.Op raise DocumentError    // was Unit
}
```

Undo algorithm collects ops from both branches:

```
undo[D : Undoable](doc: D) -> Array[Op]:
  ...
  if item.op_type == Insert:
    op = doc.delete_lv(item.target_lv)    // now returns synced Delete op
    synced_ops.push(op)
  if item.op_type == Delete:
    op = doc.undelete_lv(item.target_lv)  // now returns synced Undelete op
    synced_ops.push(op)
  ...
  return synced_ops
```

### Effort Estimate

~1 day with LWW/add-wins semantics. Longer if multi-value or complex conflict UI needed.

## Phase 3 (Future)

- Property-based tests for undo-redo roundtrip invariants across concurrent edits
- Wire up to valtio module's TypeScript API (replace broken position-based undo)
- Compaction/GC support (handle tombstone removal + undo interaction)
