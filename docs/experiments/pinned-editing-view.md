# Pinned editing view design notes

The editing-view model described here is included in the unpublished 0.11.0
release candidate. See the [v0.11 migration guide](../migration/to-v0.11.md)
for the public contract. These design and verification notes do not define a
persistence API; durable storage and Loomark integration remain separate work.

One `Editor` owns one operation log/causal graph and one visible tree/index.
`accept_remote(message)` accepts remote history without projecting it. The editing cut
retains only its causal frontier and exact sparse membership summary. Local
UTF-16 edits continue to use the existing direct tree/index update path, with
parents from that cut and sequence allocation from the shared graph.

## Contract

- `version()` and `snapshot().version` describe the displayed cut. Hidden remote
  admission does not invalidate a textarea input's expected version.
- `history_version()` describes all integrated history. Pending operations with
  missing dependencies are not represented by that version.
- `export_since(version)` reads shared history, including hidden accepted edits.
- `accept_remote(message)` applies the normal message/pending limits. It never
  writes the displayed tree or clears undo, even when the projection is invalid.
  Its `Admission` contains before/after history versions, pending count and the
  success/error result. An error does not erase partial progress or promise rollback.
- `advance_view()` explicitly projects accepted operations and returns their exact
  sequential edits. It preserves EGW selective undo, but a native textarea host
  must not call it during its input session.
- `receive(message)` is always acceptance plus explicit advancement, including
  earlier hidden history. It has no attached/pinned policy switch.
- `reopen_view()` rebuilds the full accepted cut and clears EGW undo. It can also
  recover an invalidated projection. The host must explicitly start a new native
  editing session if it assigns this text to a textarea.
- Every Editor has its own displayed cut from creation. The lower-level
  TextState API retains its existing immediate-projection contract, using the
  same explicit editing-cut model and projection settlement as Editor. No
  attached/pinned mode or automatic mode switch remains. No additional
  ViewRevision type or persisted display-cut requirement is introduced.

Native textarea Undo arrives as ordinary local `NoHistory` replacements; remote
admission must not assign the textarea value. This preserves the current editing
session, not native Undo across reopening/integration. The prototype does not
expose arbitrary historical cuts as editable views: EGW allows origin references
outside parent ancestry, so not every historical causal cut is safe to edit.

## Deliberate limits

This measures the shared-history/editing-view boundary, not a complete offline
persistence implementation. It adds no durable receipt ACK, append store,
compaction, crash recovery, total-document memory budget, or saved projection
cut. `accept_remote` is in-memory acceptance, not durability. Existing wire limits still
apply; large histories need bounded messages rather than one unlimited export.

Explicit reopening uses canonical checkout and can block on a large history.
Advancement walks backward from history's frontier, stopping each branch at an
identity already in the causally closed editing cut. It traverses compressed
causal runs and locates partially displayed run boundaries by binary search.
The resulting LV intervals supply operations in admission order and update
membership in sequence ranges, without a per-operation visited set or identity
array. Single-operation and bulk advancement use this same path.
It does not scan or rebuild the complete sparse summary for each received character.
Owning version snapshots are reused until membership changes. Materializing a
new public version still costs work proportional to the summary's ranges; the
optimization does not make fragmented Editor versions constant-cost.
Neither operation is part of a native keystroke. Native OS IMEs and other browsers require
separate checks; Chromium CDP composition is not OS IME verification.

## Unified internal model

Every Document owns an EditingProjection, including a newly created or restored
TextState. Local operation parents always come from this projection's frontier.
Both immediate receive and explicit advancement project all accepted operations
missing from the displayed cut, in admission order. A duplicate-only receive
therefore still publishes previously hidden history; its admission report can
contain zero newly committed operations while its projection effects are nonempty.

Missing origins outside the displayed cut are not classified as projection
corruption. Missing origins inside the cut invalidate the projection. Ordinary
reads and mutations return typed errors without attempting canonical recovery.
Only explicit reopening rebuilds and publishes the complete accepted cut.
Committed operations survive failure; neither rollback nor preservation of Undo
after a partially committed failure is promised.

Reopening constructs the tree, paired index, and complete view before installing
them together. There is no internal arbitrary-cut repair path. Projection health,
lazy index readiness, and Editor session usability remain separate responsibilities.
Session invalidation and reopening share the same Undo/join-state reset.

Local edits validate the expected version, every range and Unicode boundary,
and build their scalar-coordinate plans before starting application. Invalid
input returns `Rejected` without changing history or Undo. Application failures
invalidate the session; neither an exception-name list nor an unchanged displayed
version establishes that no work was committed. In particular, failed `receive`
invalidates even when its view version is unchanged. Use `accept_remote` for
independent history-only admission results without ending the editing session.

This removes the optional projection mode and the separate advancement settlement,
but does not remove readiness/error states or immediate receive's ingress checks.
Those describe projection health and input validation, not a second view model.

The position tree and identity locator form one optional `ProjectionIndex`.
A valid visible tree without an index is a normal lazy-cache state, not a failed
projection. Building that index does not perform canonical checkout.

`DocumentChanges` owns one projection publication independently of admission:
`Exact` owns sequential effects (including the empty array), `SnapshotRequired`
means valid text without proven incremental effects, and `Unavailable` carries
the projection error. The public `TextSyncTransition.publication()` exposes the
same distinction as `TextPublication`; `admission_result()` remains inspectable
even if projection failed. Its convenience `report()` requires both to succeed.
`TextState.text()`, `len()`, and `is_empty()` now raise `TextError` rather than
implicitly repairing an invalid projection or aborting a reader.

## Checks

`moon test --target js text/editor_test.mbt` exercises hidden Unicode edits,
duplicate delivery, dependency-delayed delivery, local undo/redo, and comparison
with an independent writer that receives no remote edits until the final merge.
Existing tests exercise immediate receive and selective undo. Additional cases
cover receive after hidden acceptance, explicit advancement, unchanged text with
a changed causal version, acceptance after invalidation, reopening, and injected
partial admission followed by retry. The separate
Loomark probe uses the real Source, textarea, input handlers and preview, with a
validation-only admission hook; it does not implement a network transport or
change Loomark's storage policy.
