# PROTOTYPE: EG-walker reference differential Gate 0

This throwaway prototype answers one question:

> Does `reference-frh@1.0.0`, the executable reference implementation shipped
> with the EG-walker paper, produce exactly the same visible text as this
> repository's public `text.TextState` façade for the same local edit and
> full-sync command trace?

## Verdict: NO-GO for exact-text differential testing

Run:

```sh
./tools/verification/text_reference/run.sh
```

The command intentionally exits with status 2 when it reproduces the Gate 0
counterexamples. Outputs and unified diffs are written under `.out/`.

At prototype commit time, 8 of 13 traces matched and 5 diverged. Every observed
divergence involved concurrent insertion ordering:

- concurrent inserts into an empty document;
- a three-replica insertion fork;
- concurrent insertion runs at one position; and
- concurrent inserts between common anchors.

The smallest counterexample is `traces/02-concurrent-same-position.trace`.
After Alice inserts `A`, Bob concurrently inserts `B`, and Alice's history is
merged into Bob:

```text
reference-frh: AB
MoonBit:       BA
```

Both MoonBit replicas still converge with each other. The failed proposition is
exact compatibility with the reference implementation's visible ordering, not
Document Convergence within the MoonBit implementation.

| Trace class | Result |
|---|---|
| single-replica edit and full sync | match |
| concurrent insert at the same empty position | diverged |
| concurrent edits at opposite ends | match |
| concurrent deletes | match |
| concurrent insert/delete | match |
| three-replica insertion fork | diverged |
| duplicate full sync | match |
| edit after synchronization | match |
| multiple edit/sync rounds | match |
| concurrent delete of the same item | match |
| concurrent insertion runs | diverged |
| three-replica delivery ordering | diverged |
| concurrent inserts between common anchors | diverged |

The repository's Fugue layer orders siblings using Lamport timestamp, replica
ID, and local item identity (`internal/fugue/item.mbt`). The reference package
orders Fugue identities by replica ID and sequence. Both provide deterministic
total orders, but their exact visible results need not be identical. Adapting
or renaming identities in the reference driver would make the oracle depend on
MoonBit's ordering policy and weaken its independence, so this prototype does
not do that.

## Scope

The trace language deliberately uses only public behavior shared by both
implementations:

```text
replica NAME
insert NAME POSITION ASCII_SCALAR
delete NAME POSITION
sync FROM TO
sync-duplicate FROM TO
expect-converged NAME NAME...
```

`reference_driver.mjs` replays commands through `reference-frh`.
`main.mbt` replays the same commands through:

- `TextState::new`;
- `TextState::insert` / `TextState::delete`;
- `TextState::sync().export_all()`; and
- `SyncSession::apply`.

The MoonBit driver additionally requires duplicate sync to report zero applied
operations, at least one duplicate, and zero pending operations. Convergence
checks compare visible text, `Version`, and pending count.

No production API, private hook, wire format, or event-graph implementation is
changed.

## Consequence for the Quint plan

Do not use unmodified `reference-frh` visible text as the expected state for a
Quint-to-MoonBit conformance suite. Better next candidates are:

1. use Quint to generate bounded schedules and check implementation-independent
   invariants such as convergence, idempotence, monotone causal knowledge, and
   pending drain;
2. compare MoonBit against a small specification parameterized by MoonBit's
   documented total-order policy; or
3. first make exact reference ordering an explicit project requirement, then
   investigate the production difference as a separate correctness change.

This prototype does not choose among those follow-ups and does not authorize a
production ordering change.

## Toolchain

- `reference-frh@1.0.0`, pinned by `package-lock.json`;
- `moonbitlang/async@0.21.0` for the native file-reading shell;
- the current event-graph-walker workspace source through the private
  `moon.work` file.

The strict repository-wide check currently reports pre-existing deprecation
warnings on current MoonBit. The targeted native prototype check succeeds with
those existing warnings:

```sh
cd tools/verification/text_reference
moon check . --target native
```
