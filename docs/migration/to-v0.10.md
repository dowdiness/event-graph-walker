# Migrating to v0.10

## Toolchain and dependencies

Upgrade to MoonBit 0.10.21 before resolving dependencies. CI uses compiler and
core `0.10.21+06da1ed44`; older compilers are not supported. Use
`dowdiness/event-graph-walker@0.10.0` and run `moon update`.

This release resolves `dowdiness/rle@0.4.0`, `dowdiness/btree@0.3.0`,
`dowdiness/order-tree@0.3.0`, `dowdiness/alga@0.5.0`,
`moonbitlang/quickcheck@0.15.1`, and `moonbitlang/x@0.5.7`. No workspace
override, vendoring, or cache patch is needed.

## Direct RLE, BTree or OrderTree use

The event-graph-walker public API is unchanged. If your application depends
on the same modules directly, rle 0.4.0 fallible operations raise `RleError`
instead of returning `Result`. Custom `Sliceable` implementations return
`Self raise RleError`; call sites drop `Ok`/`Err` matching and propagate or
`catch` the error. See the rle 0.4.0 and btree 0.3.0 changelogs.
