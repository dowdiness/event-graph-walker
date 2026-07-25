# Migrating the Undoable API

This guide covers the source-breaking migration to the named compensating-edit
results used by the `undo` package. It does not change synchronization wire
formats or require document data migration.

## Who needs to migrate?

Most users of `TextState::insert_and_record`, `delete_and_record`,
`replace_range_and_record`, and `delete_range_and_record` do not need to change
source code. This migration affects code that implements `@undo.Undoable`
directly or handles the old `UndoError::ItemNotFound` case.

## Update the Undoable implementation

The old trait exposed visibility lookup and returned no outcome:

```moonbit
pub(open) trait Undoable {
  fn lv_to_position(Self, Int) -> Int?
  fn delete_lv(Self, Int) -> Unit raise UndoError
  fn undelete_lv(Self, Int) -> Unit raise UndoError
}
```

The new trait hides target classification behind the compensating-edit methods:

```moonbit
pub(open) trait Undoable {
  fn delete_lv(Self, Int) -> CompensatingEditResult raise UndoError
  fn undelete_lv(Self, Int) -> CompensatingEditResult raise UndoError
}
```

For each method, return:

- `CompensatingEditResult::applied()` after committing a compensating CRDT
  operation.
- `CompensatingEditResult::stale()` when the requested direction is already
  satisfied and no operation is needed.
- `UndoError::Internal(detail~)` when the target is structurally missing or an
  invariant is violated. Do not use `Stale` to hide an internal failure or a
  target that is merely unavailable because causal data has not arrived.

Target-state classification belongs in the Document or Adapter that owns the
relevant state. `UndoManager` should not call `lv_to_position`, inspect
Fugue/tombstone state, or construct CRDT operation payloads.

## Remove ItemNotFound handling

`UndoError::ItemNotFound` is no longer part of the public error type. Replace
legacy handling with the returned result:

```moonbit
let result = doc.delete_lv(target_lv)
match result {
  @undo.CompensatingEditResult::Applied => on_applied()
  @undo.CompensatingEditResult::Stale => on_stale_noop()
}
```

A stale result is not an exception. It emits no CRDT operation, produces no
new synchronization delta, and does not create opposite Undo/Redo history.

## Undo and redo callers

`UndoManager::undo` and `UndoManager::redo` still return `Bool`:

- `true`: at least one compensating edit was applied.
- `false`: the stack was empty or the popped group was entirely stale.

Capture the document version before calling and export the delta only when the
result is `true`:

```moonbit
let before = document.version()
if manager.undo(document) {
  let delta = document.sync().export_since(before)
  // Send delta to peers.
}
```

An `Internal` failure restores tracking, clears both local Undo and Redo
history, propagates the error, and does not roll back CRDT operations that were
already committed. Treat the manager's old history as invalid after such an
error; future edits may start a new local history.

## Compatibility summary

| Area | Migration required |
| --- | --- |
| TextState recording helpers | No, unless implementing a custom Adapter |
| Custom `@undo.Undoable` implementations | Yes: remove `lv_to_position`, return `Applied`/`Stale` |
| `ItemNotFound` exception handling | Yes: match the returned result instead |
| Sync envelopes and persisted CRDT data | No |
| Peer version negotiation | No |
