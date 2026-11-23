# Migrating to v0.11

This guide describes the API changes in **0.11.0**.
These changes are not part of v0.9 or v0.10. Use the
[v0.10 toolchain migration](to-v0.10.md) first, then update the EGW dependency
to `dowdiness/event-graph-walker@0.11.0`.
This is a source-API upgrade. Text SyncMessage and Version continue to use
schema 2, with the same canonical wire domain as v0.8. No additional persisted
version conversion is required. Earlier schema 1 data still requires the
[schema 2 migration](text-schema-2.md).

## Update renamed APIs

| Before | New API |
| --- | --- |
| `TextAdmissionTransition` | `TextSyncTransition` |
| `transition.availability()` / `transition.effect_availability()` | `transition.publication()` |
| `transition.finish()` | `transition.report()` |
| `history.CausalSnapshot` | `history.CausalView` |
| `TextState.causal_snapshot()` / `container.Document.causal_snapshot()` | `causal_view()` |
| `view.children_count(lv)` | Obtain `let counts = view.children_counts()` once, then use `counts[lv]` |

Admission and projection publication are independent outcomes. Inspect
`transition.publication()` and handle every `TextPublication` case:

- `Exact(effects)`: replay the owned sequential effects, including an empty array.
- `SnapshotRequired`: the projection is valid, but exact effects are unavailable;
  replace the host's projection from the current text.
- `Unavailable(error)`: stop using the projection; do not attempt to read it as a
  recovery fallback. Accepted history may still have advanced.

`transition.admission_result()` returns `Result[SyncReport, TextError]` independently
of publication. Reconcile available publication before propagating an admission
error: failure does not imply that no operations were committed. The convenience
`report()` raises the projection error for `Unavailable`, otherwise returns or
raises the admission result. This is a failure-contract change, not just a rename.

`TextState.text() -> String`, `len() -> Int32`, and `is_empty() -> Bool` now all
raise `TextError`. Callers must propagate or handle these errors. Ordinary reads
do not implicitly repair an invalid projection.

`CausalView` aliases the live document graph. `entry()`, `frontier()`, and
`children_counts()` return owning values, but separate reads across document
mutations do not form a frozen snapshot. Capture the values you need during one
non-mutating diagnostic refresh. Counts mean direct successors, not descendants.
Custom view constructors must replace their `(Int) -> Int` callback with
`() -> Array[Int]`, returning a fresh owning array indexed by local version.
No deprecated aliases are supplied for the removed names.

## Choose one editing interface and coordinate system

Existing `TextState` operations remain available and use Unicode scalar
positions. `Editor` is an opt-in session facade with its own document and Undo
history. It accepts half-open **UTF-16** ranges and validates them against the
expected version. Do not convert an existing scalar position into an Editor
offset by merely wrapping or renaming it: an astral character occupies two
UTF-16 units but one scalar.

Use `Editor.edit` for a replacement or `edit_many` for a normalized `ChangeSet`.
The latter covers the complete original text through `Keep` and `Replace`
sections, including any unchanged suffix. It validates all boundaries before
applying the request. Surrogate splits and stale versions are rejected rather
than clamped or automatically rebased.

Two representations of an accepted update serve different consumers:

- `update.edits()`: replay in order; each range addresses the progressively
  updated text.
- `update.change_set()`: one composed change set in the original text's
  coordinates, suitable for an atomic parser update.

Apply either representation to the projection at `update.before`, then advance
its version to `update.after`. Do not treat sequential edits as simultaneous
original-coordinate replacements. Empty edits do not imply an unchanged causal
version: a receive can admit operations without changing visible text.

Handle every result explicitly:

- `Applied(update)`: publish the accepted update.
- `Rejected(error)`: visible text and causal version are unchanged.
- `Invalidated(error)`: stop using this session and its projection. History may
  have advanced. Reopening/recovery is explicit; `snapshot()` is not a recovery
  fallback. History export remains available.

`Editor.version()` identifies the displayed cut; `history_version()` identifies
all accepted history. `accept_remote()` admits history without advancing the
display and remains available after invalidation. `receive()` also advances the
display and invalidates the session on failure, even if its displayed version
did not change. `reopen_view()` rebuilds the full accepted cut on the same Editor
and clears its Undo history. The host must establish a new native input/Undo
baseline when publishing the returned snapshot.

See the executable-test-backed [Editor examples](../guides/examples.md#editor-change-stream)
for request construction, composition, and failure handling.

## Keep Undo ownership explicit

The default `NewGroup` records one nonempty local request as one Undo group.
`JoinPrevious` joins only an eligible preceding local group. Applications choose
typing/IME boundaries; Editor supplies no browser event policy or timing heuristic.

Use `NoHistory` for seeding or when another layer owns Undo. A browser-native
Undo operation can be submitted as a normal accepted edit with `NoHistory`;
do not also invoke `Editor.undo()` for that same action. EGW does not manipulate
textarea values or guarantee browser history preservation: the host must avoid
unnecessary programmatic value replacements and validate its input integration.

Low-level `TextState` plus `UndoManager` users can keep their existing recording
API. The new `UndoManager.record_group` supports explicit items/groups; it does
not require migrating existing timestamp-based capture.

## Release boundary

This release contains EGW's Editor/change contracts and graph/projection
optimizations. It does not include the experimental run-wire decoder, a new
transport protocol, Loom parser changes, or a ready-made Loomark input adapter.
Existing experimental archive/restore APIs remain experimental. Consumers can
upgrade EGW first and migrate their application integration separately.
