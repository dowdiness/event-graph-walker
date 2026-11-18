# Migrating to v0.9

## Toolchain and dependencies

Upgrade to MoonBit 0.10.15 or newer before resolving dependencies. CI uses
compiler and core `0.10.15+943464bfa`; older compilers are not supported.
Use `dowdiness/event-graph-walker@0.9.0` and run `moon update`.

This release resolves published `dowdiness/alga@0.5.0`,
`dowdiness/rle@0.3.0`, `moonbitlang/quickcheck@0.15.0`, and
`moonbitlang/x@0.5.5`. No workspace override, vendoring, or cache patch is
needed. If your application directly uses RLE, replace `Rle::extend` and
`Runs::extend` with `extend_from`. Custom shrinking implementations must
import `moonbitlang/core/quickcheck/shrink` and implement its `Shrink` trait;
`VersionVector`'s promoted `shrink()` method remains available.

## Public text transition API

Replace explicit `TextAdmissionTransition` annotations with
`TextSyncTransition`. Both `SyncSession::apply_transition` and
`apply_transition_with_limits` return the renamed type.

- `transition.finish()` becomes `transition.report()`.
- `transition.availability()` becomes `transition.effect_availability()`.
- `version_before()` and `version_after()` are unchanged.

Applications using `SyncSession::apply` or `apply_with_limits` do not need
this rename. The compiler/dependency migration does not change wire schemas:
text remains schema 2; tree and container schemas are unchanged.

## Experimental compact history

`TextState::export_compact_experimental` and
`TextState::restore_compact_direct_experimental` are now available. They are
experimental archive/restore APIs, not replacements for the synchronization
wire format. Existing callers do not need to adopt them.

Direct imports of `internal/*` are unsupported consumer interfaces. Internal
change-application and restore APIs also changed since 0.8.0; use the public
facades rather than compatibility aliases.
