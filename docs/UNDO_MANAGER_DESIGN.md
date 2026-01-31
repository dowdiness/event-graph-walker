# UndoManager Design Plan for eg-walker CRDT

## Overview

Add an LV-based UndoManager as a **separate `undo/` package** in `event-graph-walker/` that plugs into `TextDoc` via a small `Undoable` trait. Solves P2-1 (remote ops polluting undo stack) and P2-2 (stale positions after concurrent edits).

## Key Design Decisions

- **Separate package** — `event-graph-walker/undo/` as a plugin that imports `document/` + `oplog/` only. TextDoc adds a small `Undoable` impl, no direct access to `FugueTree` from undo.
- **LV-based tracking** — Operations tracked by **target element LV** (the inserted/deleted item's ID), not cursor position or operation LV
- **Tombstone revival** — Undoing a delete revives the tombstone (`deleted = false`). Character reappears at its exact original position even after concurrent edits.
- **Fully local for Phase 1** — Undo/redo are strictly local UI operations. No ops are synced to peers. Undo-insert marks the item as deleted locally (no Delete op generated). Undo-delete revives the tombstone locally. Phase 2 adds `OpContent::Undelete` for synced undo.

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
  undelete_lv(Self, Int) -> Unit raise DocumentError
  delete_lv(Self, Int) -> Unit raise DocumentError  // Phase 1: local delete by LV, no op returned
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

### Step 3: `core/change.mbt` — Move `Change` + add safe `target_lv`

```moonbit
///|
/// Get the target element LV for undo tracking.
/// For Insert: the inserted item's LV (same as op.lv).
/// For Delete: must look up the deleted item's LV from the RawVersion via oplog.
/// This requires access to the document's oplog graph.
pub fn Change::target_lv(self : Change, resolver : @core.RawToLv) -> Int? {
  match self.op.content {
    Insert(_) => Some(self.op.lv)
    Delete => {
      // origin_left is RawVersion (agent, seq), map via resolver
      self.op.origin_left.and_then(raw => resolver.raw_to_lv(raw))
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
  self.inner.tree.undelete(lv) catch {
    e => raise @document.DocumentError::Fugue(e)
  }
}

///|
pub impl @document.Undoable for TextDoc with delete_lv(self, lv) {
  self.inner.tree.delete(lv) catch {
    e => raise @document.DocumentError::Fugue(e)
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
| `record_insert` | `(target_lv: Int, agent: String, timestamp_ms: Int, content?: String) -> Unit` | Record insert. `target_lv` is the inserted item's LV. Filters by agent (only records if agent matches `self.agent_id`). Groups by time window. Clears redo stack. |
| `record_delete` | `(target_lv: Int, agent: String, timestamp_ms: Int, content?: String) -> Unit` | Record delete. `target_lv` is the deleted item's LV (the tombstone). Filters by agent (only records if agent matches `self.agent_id`). Groups by time window. Clears redo stack. |
| `undo` | `[D : @document.Undoable](self, doc: D) -> Unit raise DocumentError` | Pop undo group, apply inverses locally, push to redo (only if action succeeded). No ops returned (Phase 1 is fully local). |
| `redo` | `[D : @document.Undoable](self, doc: D) -> Unit raise DocumentError` | Pop redo group, apply inverses locally, push to undo (only if action succeeded). No ops returned (Phase 1 is fully local). |
| `set_tracking` | `(enabled: Bool) -> Unit` | Suppress/resume tracking |
| `is_tracking` | `() -> Bool` | Query tracking state |
| `can_undo` | `() -> Bool` | Undo stack non-empty |
| `can_redo` | `() -> Bool` | Redo stack non-empty |
| `clear` | `() -> Unit` | Reset both stacks |

The text integration layer (which sees `Change` and doc internals) is responsible for extracting the correct `target_lv` and calling `record_insert`/`record_delete`. This keeps `undo/` generic.

**Multi-char insert handling:** `TextDoc::insert("Hello")` internally generates 5 separate ops (one per char), but returns a single `Change` for the last op. To track all chars:
- Option A: Change `TextDoc::insert` to return `Array[Change]` (all ops)
- Option B: Add `TextDoc::insert_and_record(pos, text, mgr)` helper that records each op as it's created
- **Recommended:** Option B — avoids API change, keeps recording atomic with insertion

Convenience methods (`insert_and_record`, `delete_and_record`) are not on
UndoManager itself because they require TextDoc-specific methods (`insert`,
`delete`) that are outside the `Undoable` trait. These belong in `text/` or an
integration package that imports both `text/` and `undo/`.

**Undo algorithm (Phase 1 — fully local):**

```
undo[D : @document.Undoable](self, doc: D) -> Unit:
  group = undo_stack.pop()
  suppress tracking (use guard/defer to ensure restore on error)
  redo_items = []
  for item in group.items (reverse order):
    try:
      if item.op_type == Insert:
        pos = doc.lv_to_position(item.target_lv)
        if pos != None:
          doc.delete_lv(item.target_lv)   # local delete, no op generated
          redo_items.push({ target_lv: item.target_lv, op_type: Insert, content: item.content })
        // If pos == None, item already deleted by remote — skip, don't push to redo
      if item.op_type == Delete:
        doc.undelete_lv(item.target_lv)   # local tombstone revival, no op generated
        redo_items.push({ target_lv: item.target_lv, op_type: Delete, content: item.content })
    catch MissingItem:
      // Item was GC'd or compacted — skip silently, don't push to redo
      continue
  if redo_items.length() > 0:
    redo_stack.push(reversed redo_items)
  resume tracking
```

 **Error handling:** Per-item try/catch ensures one bad item doesn't corrupt the entire group. Missing items (due to GC/compaction) are skipped silently. Only successfully applied items are pushed to redo.
Match missing items as `DocumentError::Fugue(FugueError::MissingItem(_))` since `Undoable` methods raise `DocumentError`.

**Redo is the mirror image:** Insert items → `doc.undelete_lv(target_lv)`, Delete items → `doc.delete_lv(target_lv)`. Both are local mutations. Only push to undo stack if action succeeded.

**Phase 1 limitations:**
1. Undo/redo are not persisted (lost on reload) and not visible to peers
2. **Intent drift risk:** Local-only undo mutates tree without oplog entries. Subsequent synced edits use `position_to_lv` from the locally-mutated tree, which peers don't share. This can cause anchoring differences. Mitigations:
   - Document this as expected Phase 1 behavior
   - Phase 2 eliminates this by always producing ops
   - Alternative: Block synced edits until undo state is "committed" (complex)

**File:** `event-graph-walker/undo/undo_manager.mbt` (NEW)

### Step 6: `undo/undo_manager_test.mbt` — Tests

1. Basic undo insert: insert "H", undo → text empty
2. Basic undo delete: insert "H", delete, undo → text "H" (tombstone revival)
3. Undo-redo roundtrip: insert "H", undo, redo → text "H"
4. Redo cleared on new edit: insert "H", undo, insert "X" → redo empty
5. Time grouping: insert "abc" within 500ms, undo once → all removed
6. Time grouping split: insert "a" at t=0, "b" at t=1000, undo → only "b" removed
7. Per-agent filtering: agent A inserts and calls `record_insert`, agent B's remote ops arrive via `doc.sync().apply()` (not recorded), undo only affects A's ops
8. Suppress tracking: disable tracking, insert, verify undo stack empty
9. Concurrent resilience: A inserts "abc", B inserts "XY" between a/b (remote), A undoes → correct text
10. Undo of already-deleted item: item deleted by remote peer → `lv_to_position` returns `None` → no-op

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
let mgr = @undo.UndoManager::new("alice") // Doc type inferred as TextDoc

// Insert with tracking — use helper that records all char ops
doc.insert_and_record(@text.Pos::at(0), "Hello", mgr, timestamp_ms=1000)!

// Remote op — suppress tracking
mgr.set_tracking(false)
doc.sync().apply(remote_message)!
mgr.set_tracking(true)

// Undo — fully local in Phase 1, no ops returned
mgr.undo(doc)!
// Document state updated locally; peers do not see the undo
```

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Undo insert already deleted by remote | `lv_to_position` → `None` → skip, don't push to redo (already gone) |
| Undo delete of concurrently deleted item | `undelete` revives it — local user's intent wins |
| Multi-char insert | Use `insert_and_record` helper to record each char's LV. Time grouping batches them. |
| Double undo/redo | Stacks transfer correctly. Tracking suppressed during undo/redo. |
| Error during undo/redo | Per-item try/catch skips bad items; guard/defer restores `tracking_enabled` |
| Item GC'd/compacted | `MissingItem` caught, item skipped, redo stack only gets successful items |
| Synced edit after local undo | **Intent drift possible** — peers have different tree state. Document as Phase 1 limitation. |

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
| `event-graph-walker/undo/moon.pkg.json` | Modify | +2 / -2 |

## Phase 2: Global Undo with `OpContent::Undelete`

Phase 2 adds synced undo-of-delete, eliminating the Phase 1 asymmetry where undo-insert syncs but undo-delete doesn't.

### Implementation Steps

| Step | File | Difficulty | Work |
|------|------|------------|------|
| 1. Add `Undelete(Int)` variant | `oplog/operation.mbt` | Easy | +1 line to enum |
| 2. Add `Op::new_undelete` constructor | `oplog/operation.mbt` | Easy | +10 lines |
| 3. Add `Op::is_undelete`, `Op::get_undelete_target` | `oplog/operation.mbt` | Easy | +15 lines |
| 4. Handle in `Document::apply` | `document/document.mbt` | Medium | Match `Undelete(target_lv)` → `tree.undelete(target_lv)` |
| 5. Handle in `apply_remote` | `document/document.mbt` | Medium | Same as local apply |
| 6. **Conflict resolution** | `fugue/tree.mbt` | **Hard** | Concurrent Delete + Undelete? Pick semantics (see below) |
| 7. Handle in branch merge | `document/merge.mbt` | **Hard** | Undelete in version graph traversal |
| 8. Serialize/deserialize | `oplog/operation.mbt` | Easy | Already derived `FromJson, ToJson` |
| 9. Update `UndoManager.undo()` | `undo/undo_manager.mbt` | Medium | Return `Undelete` op instead of local mutation |
| 10. Property tests | `undo/undo_manager_test.mbt` | Medium | Delete↔Undelete interleaving |

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

### Updated `UndoManager.undo()` Return Value

After Phase 2, undo returns synced ops for **both** insert and delete undos:

```
undo[D : @document.Undoable](doc: D) -> Array[@oplog.Op]:
  ...
  if item.op_type == Delete:
    op = doc.undelete_lv(item.target_lv)  // Now returns Op, not Unit
    synced_ops.push(op)
  ...
```

### Effort Estimate

~1 day with LWW/add-wins semantics. Longer if multi-value or complex conflict UI needed.

## Phase 3 (Future)

- Property-based tests for undo-redo roundtrip invariants across concurrent edits
- Wire up to valtio module's TypeScript API (replace broken position-based undo)
- Compaction/GC support (handle tombstone removal + undo interaction)
